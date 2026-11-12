--- Transport to one WLED controller.
---
--- One WebSocket (ws://host:port/ws) carries the controller's pushes and the driver's commands.
--- WLED sends its full state and info when the socket opens and again after any change, from
--- any source, at most once a second. Liveness is WLED's own text ping: "p" every 30 s, answered
--- "pong"; two missed answers close the socket. While the socket is down it reconnects with
--- growing waits capped at 30 s, sends commands over HTTP and polls /json/si slowly. While the
--- socket is up, /json/si is still asked for every 15 s, because WLED pushes nothing for live data
--- from another system, a preset save or a playlist stopped elsewhere. HTTP keeps one request in
--- flight, because the controller serves every request from one shared buffer; a busy answer
--- ({"error":3}, or HTTP 503 on 0.15) waits and retries.
---
--- The driver sees three things: onState(state, info) for every state the controller reports,
--- onOnline() when it can reach the controller again, and onOffline(reason) when it cannot.

local deferred = require("deferred")
local JSON = require("JSON")
local WebSocket = require("drivers-common-public.module.websocket")

local http = require("lib.http")
local log = require("lib.logging")
--#ifdef DRIVERCENTRAL
local diagnostics = require("lib.diagnostics")
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")

--- Text ping cadence and how many unanswered pings close the socket.
local PING_MS = 30 * ONE_SECOND
local PINGS_MISSED_LIMIT = 2

--- Reconnect waits: doubled after each failure, capped, reset once the socket opens.
local RECONNECT_FIRST_MS = ONE_SECOND
local RECONNECT_MAX_MS = 30 * ONE_SECOND

--- How long a new socket has to open before the first HTTP poll, and the poll cadence after.
local OPEN_GRACE_MS = 5 * ONE_SECOND
local POLL_MS = 10 * ONE_SECOND

--- How often /json/si is asked for while the socket is up, for what WLED never pushes, and how
--- soon a turn skipped for other traffic is tried again.
local SOCKET_POLL_MS = 15 * ONE_SECOND
local SOCKET_POLL_RETRY_MS = 2 * ONE_SECOND

--- A socket that connects but never finishes its upgrade is given up after this long.
local CONNECT_TIMEOUT_MS = 10 * ONE_SECOND

--- A busy controller is retried this many times, waiting 250 ms, 500 ms, 1 s and so on.
local BUSY_RETRIES = 5
local BUSY_FIRST_MS = ONE_SECOND / 4

--- A busy answer this soon after WebSocket commands is taken as theirs.
local WS_BUSY_WINDOW_MS = 2 * ONE_SECOND

--- Largest command the controller takes in one WebSocket frame (ws.cpp); bigger ones go over HTTP.
local FRAME_LIMIT = { esp8266 = 528 }
local FRAME_LIMIT_DEFAULT = 1428

--- An HTTP request is given up after this long. One request is in flight at a time, so a
--- controller that has gone away holds the queue this long before the next request runs.
local HTTP_TIMEOUT_S = 10

--- Each client's timers are named apart, so stop() cancels its own.
local gClients = 0

--- A callback whose error would otherwise be lost (the WebSocket module's pcall only prints it,
--- and a deferred handler's error becomes a rejection nothing reads): Cloud Monitoring hears of it.
--- @param fn function
--- @param source string
--- @return function
local function guarded(fn, source)
  --#ifdef DRIVERCENTRAL
  fn = diagnostics:wrap(fn, source)
  --#endif
  return fn
end

--- @class WledClient
--- @field host string|nil The controller's address. Nil until started.
--- @field port integer|nil The controller's web port.
--- @field arch string|nil Chip the controller reported, for the frame limit.
--- @field mode "ws"|"http"|"offline"|"starting" How the controller is reached now; "starting" until the first answer or failure after a (re)start.
--- @field onState fun(state: table|nil, info: table|nil) Told every state the controller reports.
--- @field onOnline fun() Told when the controller can be reached again.
--- @field onOffline fun(reason: string) Told when it cannot.
--- @field http table The HTTP object requests go through.
--- @field WebSocket table The WebSocket class sockets are made from.
--- @field gen integer Bumped at every start and stop; callbacks from an older one do nothing.
--- @field queue table[] HTTP requests waiting for the one in flight.
--- @field inFlight table|nil The HTTP request under way.
--- @field ws table|nil The open socket.
--- @field socketUp boolean Whether the socket finished its upgrade and is in use.
--- @field socketGen integer|nil Bumped at every socket change, so a ping loop ends with its socket.
--- @field backoff integer|nil The wait before the next socket try, in ms.
--- @field missedPings integer|nil Pings sent since the last pong.
--- @field downReason string|nil Why the socket last went down, for the offline report.
--- @field polling boolean|nil Whether the HTTP poll loop runs.
--- @field pollToken integer|nil The poll loop allowed to run; an older one stops.
--- @field closing Deferred Resolves once the last socket closed.
--- @field closingUrl string|nil The URL of a socket still closing.
--- @field timerPrefix string This client's timer names start with it, so stop() cancels its own.
--- @field timers table<string, boolean> The client's timers still pending, by name.
--- @field timerCount integer Timers set so far, for unique names.
--- @field writes integer Writes sent so far; an HTTP answer asked for before the latest is stale.
--- @field pushes integer States pushed on the socket so far; a poll answer asked for before the latest is stale.
--- @field recent table[] Commands sent within the busy window, oldest first; those sent over HTTP are marked posted.
--- @field replaying boolean|nil Whether a busy resend waits to go out.
--- @field owed table[]|nil The commands a waiting busy resend sends again, oldest first.
--- @field replayToken integer|nil Bumped when a busy resend is taken or called off; an older one does nothing.
--- @field gapUntil number|nil Until when no command may follow the last one that asked for a gap after it.
--- @field held table[]|nil Commands waiting for a gap, a busy resend or a replay to finish, oldest first.
--- @field flushing boolean|nil Whether a send of the held commands is due.
--- @field seq table|nil A replay going out frame by frame: {frames, i}.
--- @field pumpWaiting boolean|nil Whether the HTTP queue waits for a gap.
local Client = {}
Client.__index = Client

--- @class WledClientOptions
--- @field onState fun(state: table|nil, info: table|nil)|nil Told every state the controller reports; does nothing when nil.
--- @field onOnline fun()|nil Told when the controller can be reached again; does nothing when nil.
--- @field onOffline fun(reason: string)|nil Told when it cannot; does nothing when nil.
--- @field http table|nil An object with get(url, headers, options) and post(url, data, headers, options); lib.http by default.
--- @field WebSocket table|nil The WebSocket class; the vendored module by default.

--- Creates the transport to one controller; start() connects it.
--- @param opts WledClientOptions|nil
--- @return WledClient client A client not yet connected.
function Client:new(opts)
  opts = opts or {}
  local instance = setmetatable({}, self)
  instance.onState = opts.onState or function() end
  instance.onOnline = opts.onOnline or function() end
  instance.onOffline = opts.onOffline or function() end
  instance.http = opts.http or http
  instance.WebSocket = opts.WebSocket or WebSocket
  instance.gen = 0
  instance.mode = "offline"
  instance.queue = {}
  gClients = gClients + 1
  instance.timerPrefix = "WledClient" .. gClients .. "_"
  instance.timers, instance.timerCount = {}, 0
  instance.writes = 0
  instance.pushes = 0
  instance.recent = {}
  instance.closing = deferred.new():resolve(nil)
  return instance
end

local function now()
  return C4:GetTime()
end

--- Decode a body that may already be a table (lib.http decodes JSON replies).
--- @param body any
--- @return any
local function decode(body)
  if type(body) == "string" then
    local ok, value = pcall(JSON.decode, JSON, body)
    if ok then
      return value
    end
    return nil
  end
  return body
end

local function isBusy(body)
  return type(body) == "table" and body.error == 3
end

--- Run fn after ms unless the client was stopped or restarted meanwhile. The timer is the
--- client's own, so stop() cancels it.
--- @param gen integer The start the timer belongs to.
--- @param ms integer The wait.
--- @param fn fun() What to run.
function Client:after(gen, ms, fn)
  self.timerCount = self.timerCount + 1
  local id = self.timerPrefix .. self.timerCount
  self.timers[id] = true
  SetTimer(id, ms, function()
    self.timers[id] = nil
    if self.gen == gen then
      fn()
    end
  end)
end

local function reachable(mode)
  return mode == "ws" or mode == "http"
end

--- Move to a new mode, telling the driver when reachability changes. From "starting", the
--- first answer reports online and the first failure reports offline.
--- @param mode "ws"|"http"|"offline"
--- @param reason string|nil Why the controller cannot be reached, for "offline".
function Client:setMode(mode, reason)
  local was = self.mode
  self.mode = mode
  if not reachable(was) and reachable(mode) then
    guarded(self.onOnline, "WLED.Online")()
  elseif was ~= "offline" and mode == "offline" then
    guarded(self.onOffline, "WLED.Offline")(reason or "Not connected")
  end
end

--- Connect to a controller, closing any connection already open.
--- @param host string The controller's address.
--- @param port integer|nil Its web port, 80 when nil.
function Client:start(host, port)
  self:stop()
  self.host, self.port = host, tonumber(port) or 80
  self.backoff = RECONNECT_FIRST_MS
  local gen = self.gen
  -- The module hands back a closing socket for the same URL until its close finishes.
  local wait = self.closingUrl == self:socketUrl() and self.closing or deferred.new():resolve(nil)
  wait:next(function()
    if self.gen == gen then
      self:openSocket(gen)
    end
  end)
  self:after(gen, OPEN_GRACE_MS, function()
    if not self.socketUp then
      self:startPolling(gen)
    end
  end)
end

--- Close the socket; resolves once the module has released it.
--- @return Deferred closed Resolves once the module has released the socket.
function Client:closeSocket()
  local d = deferred.new()
  local ws = self.ws
  self.ws = nil
  if not ws then
    self.closing = self.closing or d:resolve(nil)
    return self.closing
  end
  self.closing, self.closingUrl = d, ws.url
  local ok, err = pcall(ws.delete, ws, function()
    if self.closing == d then
      self.closingUrl = nil
    end
    d:resolve(nil)
  end)
  if not ok then
    log:warn("WLED WebSocket not closed cleanly: %s", tostring(err))
    --#ifdef DRIVERCENTRAL
    diagnostics:captureError(tostring(err), nil, "WLED.WsDelete")
    --#endif
    if self.closing == d then
      self.closingUrl = nil
    end
    d:resolve(nil)
  end
  return d
end

--- The WebSocket URL of the controller.
--- @return string url ws://host:port/ws
function Client:socketUrl()
  return string.format("ws://%s:%d/ws", tostring(self.host), self.port or 80)
end

--- Close the connection and drop queued requests. Tells the driver nothing now; after a
--- start, the first answer or failure is reported.
function Client:stop()
  self.gen = self.gen + 1
  for id in pairs(self.timers) do
    CancelTimer(id)
  end
  self.timers = {}
  self.recent, self.replaying, self.owed = {}, false, nil
  local held = self.held or {}
  self.held, self.flushing, self.seq, self.gapUntil, self.pumpWaiting = {}, false, nil, nil, false
  for _, h in ipairs(held) do
    h.d:reject({ error = "stopped" })
  end
  self.socketUp = false
  self.pollToken = (self.pollToken or 0) + 1
  self:closeSocket()
  local queue = self.queue
  self.queue = {}
  for _, job in ipairs(queue) do
    job.d:reject({ error = "stopped" })
  end
  if self.inFlight then
    self.inFlight.d:reject({ error = "stopped" })
    self.inFlight = nil
  end
  self.mode = "starting"
end

-- ─── WebSocket ─────────────────────────────────────────────────────────────

--- Open the live socket, with a timeout for an upgrade that never comes.
--- @param gen integer The start it belongs to.
function Client:openSocket(gen)
  local url = self:socketUrl()
  local ok, ws, err = pcall(self.WebSocket.new, self.WebSocket, url)
  if not ok then
    -- A raise is a fault, unlike a socket the module declines with nil and an error.
    ws, err = nil, ws
    --#ifdef DRIVERCENTRAL
    diagnostics:captureError(tostring(err), nil, "WLED.WsNew")
    --#endif
  end
  if not ws then
    self:socketDown(gen, "No connection to the controller: " .. tostring(err))
    return
  end
  self.ws = ws
  -- The module's own control-frame ping is replaced by WLED's text ping below.
  ws.ping_interval = 24 * 3600
  -- A controller that takes the connection but never finishes the upgrade is tried again.
  self:after(gen, CONNECT_TIMEOUT_MS, function()
    if self.ws == ws and not self.socketUp then
      self:socketDown(gen, "No answer from the controller")
    end
  end)

  ws:SetEstablishedFunction(guarded(function(socket)
    if self.gen ~= gen or self.ws ~= socket then
      return
    end
    log:debug("WLED WebSocket open to %s", self.host)
    self.socketUp = true
    self.backoff = RECONNECT_FIRST_MS
    self.missedPings = 0
    self.socketGen = (self.socketGen or 0) + 1
    self:pingLoop(gen, self.socketGen)
    self:socketPoll(gen, self.socketGen)
    self:setMode("ws")
  end, "WLED.WsEstablished"))
  ws:SetProcessMessageFunction(guarded(function(socket, data)
    if self.gen == gen and self.ws == socket then
      self:onMessage(data)
    end
  end, "WLED.WsMessage"))
  ws:SetClosedByRemoteFunction(guarded(function(socket)
    if self.gen == gen and self.ws == socket then
      self:socketDown(gen, "The controller closed the connection")
    end
  end, "WLED.WsClosedByRemote"))
  ws:SetOfflineFunction(guarded(function(socket)
    if self.gen == gen and self.ws == socket then
      self:socketDown(gen, "No connection to the controller")
    end
  end, "WLED.WsOffline"))
  ok, err = pcall(ws.Start, ws)
  if not ok then
    --#ifdef DRIVERCENTRAL
    diagnostics:captureError(tostring(err), nil, "WLED.WsStart")
    --#endif
    self:socketDown(gen, "No connection to the controller: " .. tostring(err))
  end
end

--- Send WLED's text ping every PING_MS while the socket stays up; two unanswered close it.
--- @param gen integer The start it belongs to.
--- @param socketGen integer The socket it belongs to.
function Client:pingLoop(gen, socketGen)
  self:after(gen, PING_MS, function()
    if not self.socketUp or self.socketGen ~= socketGen then
      return
    end
    if self.missedPings >= PINGS_MISSED_LIMIT then
      self:socketDown(gen, "No answer from the controller")
      return
    end
    self.missedPings = self.missedPings + 1
    self.ws:Send("p")
    self:pingLoop(gen, socketGen)
  end)
end

--- Report a state answered over HTTP. An answer asked for before a restart, a later write or a
--- later push is dropped; that write or push tells the state. While the socket is down the
--- answer also shows the controller reachable, as a poll does.
--- @param client WledClient
--- @param gen integer The connection generation when the request went out.
--- @param writes integer The write count when the request went out.
--- @param pushes integer The push count when the request went out.
--- @param state table|nil
--- @param info table|nil
--- @param tag string The error-report name for onState.
local function report(client, gen, writes, pushes, state, info, tag)
  if client.gen ~= gen then
    return
  end
  if not client.socketUp then
    client:setMode("http")
  end
  if client.writes == writes and client.pushes == pushes then
    guarded(client.onState, tag)(state, info)
  end
end

--- Ask for the state every SOCKET_POLL_MS while the socket stays up, and report it as a push. A
--- turn waits while an HTTP request is under way, a command was just sent or a busy resend waits,
--- so the poll never queues behind other work or takes the controller's one buffer from a command.
--- An answer that a later write or push overtook is dropped; that one tells the state.
--- @param gen integer The start it belongs to.
--- @param socketGen integer The socket it belongs to.
--- @param ms integer|nil The wait before this turn; SOCKET_POLL_MS when nil.
function Client:socketPoll(gen, socketGen, ms)
  self:after(gen, ms or SOCKET_POLL_MS, function()
    if not self.socketUp or self.socketGen ~= socketGen then
      return
    end
    if self.replaying or self.inFlight or #self.queue > 0 or #self:recentFrames() > 0 then
      self:socketPoll(gen, socketGen, SOCKET_POLL_RETRY_MS)
      return
    end
    local writes = self.writes
    -- A stop or a new socket rejects or outdates the request; its loop ends there.
    local function again()
      if self.gen == gen and self.socketGen == socketGen then
        self:socketPoll(gen, socketGen)
      end
    end
    local answer, job = self:enqueue("GET", "/json/si")
    answer
      :next(function(si)
        if type(si) == "table" then
          report(self, gen, writes, job.pushes, si.state, si.info, "WLED.SocketPoll")
        end
      end)
      :next(again, again)
  end)
end

--- The socket closed or stopped answering: reconnect after a wait, and use HTTP meanwhile.
--- @param gen integer The start it belongs to.
--- @param reason string Why, for the offline report.
function Client:socketDown(gen, reason)
  local wasUp = self.socketUp
  self.socketUp = false
  self.socketGen = (self.socketGen or 0) + 1
  local closed = self:closeSocket()
  log:debug("WLED WebSocket to %s down: %s", tostring(self.host), reason)
  self.downReason = reason
  local wait = self.backoff or RECONNECT_FIRST_MS
  self.backoff = math.min(wait * 2, RECONNECT_MAX_MS)
  self:after(gen, wait, function()
    closed:next(function()
      if self.gen == gen and not self.socketUp and not self.ws then
        self:openSocket(gen)
      end
    end)
  end)
  if wasUp or not self.polling then
    self:startPolling(gen)
  end
end

--- A text frame from the controller: a pong, an error, or its state and info.
--- @param data string The frame's text.
function Client:onMessage(data)
  if data == "pong" then
    self.missedPings = 0
    return
  end
  local msg = decode(data)
  if type(msg) ~= "table" then
    return
  end
  if msg.error ~= nil then
    self:onSocketError(msg.error)
    return
  end
  if msg.state ~= nil or msg.info ~= nil then
    if type(msg.info) == "table" then
      self.arch = msg.info.arch
    end
    self.pushes = self.pushes + 1
    self.onState(msg.state, msg.info)
  end
end

--- The WebSocket commands sent within the busy window, oldest first.
--- @return table[] frames The commands still within the window, oldest first.
function Client:recentFrames()
  local kept = {}
  for _, frame in ipairs(self.recent) do
    if now() - frame.at <= WS_BUSY_WINDOW_MS then
      kept[#kept + 1] = frame
    end
  end
  self.recent = kept
  return kept
end

--- POST a command the socket did not take; if that fails too, ask for the state.
--- @param frame table A frame from sendFrame.
function Client:postFrame(frame)
  local answered, job = self:enqueue("POST", "/json/state", frame.cmd)
  if job then
    job.gapAfterMs = frame.gapAfterMs
  end
  answered:next(nil, function(err)
    if type(err) == "table" and err.error == "stopped" then
      return
    end
    log:warn("WLED command not sent: %s", type(err) == "table" and (err.error or "failed") or tostring(err))
    self:refresh()
  end)
end

--- POST a window of commands from its oldest socket frame on, oldest first; the commands before
--- that went over HTTP already and land in order.
--- @param frames table[] Recent commands, oldest first.
function Client:postWindow(frames)
  local started = false
  for _, frame in ipairs(frames) do
    started = started or not frame.posted
    if started then
      self:postFrame(frame)
    end
  end
end

--- Whether a command in a window went over HTTP.
--- @param frames table[]
--- @return boolean
local function anyPosted(frames)
  for _, frame in ipairs(frames) do
    if frame.posted then
      return true
    end
  end
  return false
end

--- Take what a busy resend owes, oldest first: the commands answered busy, then every one sent
--- during the wait. The resend is called off.
--- @return table[] frames
function Client:takeOwed()
  local owed, seen = {}, {}
  for _, list in ipairs({ self.owed or {}, self.recent }) do
    for _, frame in ipairs(list) do
      if not seen[frame] then
        seen[frame] = true
        owed[#owed + 1] = frame
      end
    end
  end
  self.owed, self.recent, self.replaying = nil, {}, false
  self.replayToken = (self.replayToken or 0) + 1
  return owed
end

--- A WebSocket command came back busy (3) or not taken (9, a frame WLED could not read whole).
--- The answer does not say which command, so every recent one goes again, in order: each carries
--- whole values, so a second copy changes nothing. A busy answer resends them on the socket after
--- a wait, or over HTTP when one in the window already went that way, so it can't land first; a 9
--- sends them over HTTP, so the one not taken lands and the newest still lands last.
--- @param code any The error number WLED sent.
function Client:onSocketError(code)
  local frames = self:recentFrames()
  local seq = self.seq
  if seq and (code == 9 or code == 3) then
    -- A replay going out stops here: its frames not yet sent go with the rest, still in order.
    self.seq = nil
    for i = seq.i, #seq.frames do
      frames[#frames + 1] = seq.frames[i]
    end
  end
  if #frames == 0 and not self.replaying then
    self:flushHeld()
    return
  end
  if code == 9 then
    local resend = frames
    if self.replaying then
      resend = self:takeOwed()
      local have = {}
      for _, frame in ipairs(resend) do
        have[frame] = true
      end
      for _, frame in ipairs(frames) do
        if not have[frame] then
          resend[#resend + 1] = frame
        end
      end
    end
    self.recent = {}
    self:postWindow(resend)
    self:flushHeld()
    return
  end
  if code ~= 3 or self.replaying then
    return
  end
  if anyPosted(frames) then
    self.recent = {}
    self:postWindow(frames)
    self:flushHeld()
    return
  end
  local tries = 0
  for _, frame in ipairs(frames) do
    tries = math.max(tries, frame.tries)
  end
  if tries >= BUSY_RETRIES then
    log:warn("WLED controller stayed busy; %d command(s) dropped", #frames)
    self.recent = {}
    self:refresh()
    self:flushHeld()
    return
  end
  self.replaying, self.owed = true, frames
  self.replayToken = (self.replayToken or 0) + 1
  local token = self.replayToken
  self:after(self.gen, BUSY_FIRST_MS * 2 ^ tries, function()
    if self.replayToken ~= token then
      return
    end
    -- One refused while this waited is sent again here too, and the latest still comes last.
    local replay = self:takeOwed()
    self.recent = {}
    self:replayFrames(replay, 1)
  end)
end

--- Send a replay frame by frame, keeping the gap a frame asked for before the next; then the commands
--- held meanwhile. Over HTTP when the socket is down.
--- @param frames table[]
--- @param i integer The next frame to send.
function Client:replayFrames(frames, i)
  self.seq = { frames = frames, i = i }
  while i <= #frames do
    if not (self.socketUp and self.ws) then
      self.seq = nil
      local rest = {}
      for k = i, #frames do
        rest[#rest + 1] = frames[k]
      end
      self:postWindow(rest)
      self:flushHeld()
      return
    end
    local wait = (self.gapUntil or 0) - now()
    if wait > 0 then
      local seq = self.seq
      self:after(self.gen, wait, function()
        if self.seq == seq then
          self:replayFrames(frames, i)
        end
      end)
      return
    end
    local frame = frames[i]
    frame.tries = frame.tries + 1
    frame.at = now()
    self.recent[#self.recent + 1] = frame
    self.ws:Send(frame.body)
    if frame.gapAfterMs then
      self.gapUntil = now() + frame.gapAfterMs
    end
    i = i + 1
    self.seq.i = i
  end
  self.seq = nil
  self:flushHeld()
end

--- Send a command over the socket, kept for a busy resend.
--- @param frame table {body = the JSON text, cmd = the command, tries = resends so far}
--- @return boolean sent Whether the socket took the frame.
function Client:sendFrame(frame)
  if self.socketUp and self.ws then
    frame.at = now()
    -- A resend that waits still owes every frame it holds, however long it waits.
    if not self.replaying then
      self:recentFrames()
    end
    self.recent[#self.recent + 1] = frame
    self.ws:Send(frame.body)
    return true
  end
  return false
end

--- Ask the controller for its state and report it, for a command it may not have taken.
function Client:refresh()
  local gen, writes = self.gen, self.writes
  local answer, job = self:enqueue("GET", "/json/si")
  answer:next(function(si)
    if type(si) == "table" then
      report(self, gen, writes, job.pushes, si.state, si.info, "WLED.Refresh")
    end
  end, function() end)
end

-- ─── HTTP ──────────────────────────────────────────────────────────────────

--- Start polling now, replacing any poll loop already waiting.
--- @param gen integer The start it belongs to.
function Client:startPolling(gen)
  self.pollToken = (self.pollToken or 0) + 1
  self:poll(gen, self.pollToken)
end

--- Poll /json/si while the socket is down; it keeps the state current and tells whether the
--- controller can be reached at all.
--- @param gen integer The start it belongs to.
--- @param token integer|nil The poll loop it belongs to; the current one when nil.
function Client:poll(gen, token)
  token = token or self.pollToken
  if self.socketUp or self.gen ~= gen or token ~= self.pollToken then
    self.polling = false
    return
  end
  self.polling = true
  -- A write sent after this poll was asked for makes its answer stale: ask again at once, behind
  -- the write.
  local writes, stale = self.writes, false
  -- The next poll waits for this one to settle, so polls never pile up behind timeouts.
  local function again()
    if stale then
      self:poll(gen, token)
      return
    end
    self:after(gen, POLL_MS, function()
      self:poll(gen, token)
    end)
  end
  self
    :enqueue("GET", "/json/si")
    :next(function(si)
      if self.gen ~= gen or self.socketUp then
        return
      end
      if type(si) == "table" then
        if type(si.info) == "table" then
          self.arch = si.info.arch
        end
        self:setMode("http")
        if self.writes ~= writes then
          stale = true
          return
        end
        guarded(self.onState, "WLED.PollState")(si.state, si.info)
      end
    end, function(err)
      if self.gen ~= gen or self.socketUp or (type(err) == "table" and err.error == "stopped") then
        return
      end
      self:setMode("offline", self.downReason or "No connection to the controller")
    end)
    :next(again, again)
end

--- Queue an HTTP request; one is in flight at a time.
--- @param method "GET"|"POST"
--- @param path string The path on the controller, e.g. /json/si.
--- @param body table|nil The JSON body of a POST.
--- @return Deferred answer Resolves with the decoded answer, or rejects.
--- @return table|nil job The request; its pushes field is the push count when it last went out.
function Client:enqueue(method, path, body)
  local d = deferred.new()
  if not self.host then
    return d:reject({ error = "not started" }), nil
  end
  local job = { method = method, path = path, body = body, d = d, tries = 0 }
  self.queue[#self.queue + 1] = job
  self:pump()
  return d, job
end

--- Send the next queued HTTP request when none is in flight.
function Client:pump()
  if self.inFlight or #self.queue == 0 then
    return
  end
  local wait = (self.gapUntil or 0) - now()
  if self.queue[1].method == "POST" and wait > 0 then
    if not self.pumpWaiting then
      self.pumpWaiting = true
      self:after(self.gen, wait, function()
        self.pumpWaiting = false
        self:pump()
      end)
    end
    return
  end
  local job = table.remove(self.queue, 1)
  self.inFlight = job
  self:request(job)
end

--- Send one HTTP request and settle its job; a busy answer is retried in the slot. WLED builds
--- the answer when the request arrives, so a push after this one is newer than it.
--- @param job table {method, path, body, d = its deferred, tries, pushes}
function Client:request(job)
  local gen = self.gen
  job.pushes = self.pushes
  local url = string.format("http://%s:%d%s", self.host, self.port, job.path)
  local req
  if job.method == "POST" then
    req = self.http:post(
      url,
      JSON:encode(job.body),
      { ["Content-Type"] = "application/json" },
      { timeout = HTTP_TIMEOUT_S }
    )
  else
    req = self.http:get(url, nil, { timeout = HTTP_TIMEOUT_S })
  end
  req:next(function(res)
    if self.gen ~= gen then
      return
    end
    local value = decode(res and res.body)
    if isBusy(value) then
      self:retryBusy(job)
      return
    end
    self.inFlight = nil
    if job.gapAfterMs then
      self.gapUntil = now() + job.gapAfterMs
    end
    job.d:resolve(value)
    self:pump()
  end, function(err)
    if self.gen ~= gen then
      return
    end
    if type(err) == "table" and err.code == 503 then
      self:retryBusy(job)
      return
    end
    self.inFlight = nil
    job.d:reject(err)
    self:pump()
  end)
end

--- Keep the slot while waiting, so queued requests do not reach a busy controller first.
--- @param job table The request answered busy.
function Client:retryBusy(job)
  if job.tries >= BUSY_RETRIES then
    self.inFlight = nil
    job.d:reject({ error = "busy", code = 503 })
    self:pump()
    return
  end
  local wait = BUSY_FIRST_MS * 2 ^ job.tries
  job.tries = job.tries + 1
  self:after(self.gen, wait, function()
    self:request(job)
  end)
end

-- ─── Commands ──────────────────────────────────────────────────────────────

--- Whether a POST is queued or under way, so a later command must not overtake it.
--- @return boolean pending
function Client:postPending()
  if self.inFlight and self.inFlight.method == "POST" then
    return true
  end
  for _, job in ipairs(self.queue) do
    if job.method == "POST" then
      return true
    end
  end
  return false
end

--- Send a state command: over the socket when it is open, the command fits one frame and no
--- POST is ahead of it, otherwise POST /json/state, so commands land in the order sent. Resolves
--- once sent (socket) or answered (HTTP); the new state arrives through onState. A command with
--- v = true gets the state back on either path.
--- @param cmd table The state command, e.g. { on = true, bri = 128 }.
--- @return Deferred sent Resolves once sent or answered.
function Client:send(cmd, opts)
  local held = self.held or {}
  self.held = held
  local limit = FRAME_LIMIT[self.arch or ""] or FRAME_LIMIT_DEFAULT
  local socket = self.socketUp and self.ws and #JSON:encode(cmd) <= limit and not self:postPending()
  -- One that must go over HTTP takes what a busy resend owes over HTTP ahead of it (sendNow), and the
  -- HTTP queue keeps a frame's gap.
  if #held > 0 or self.seq or (socket and ((self.replaying and self:owesGap()) or (self.gapUntil or 0) > now())) then
    -- Behind a busy resend, a replay or a gap a frame asked for: it goes after them, in order.
    local d = deferred.new()
    held[#held + 1] = { cmd = cmd, opts = opts, d = d }
    self:flushHeld()
    return d
  end
  return self:sendNow(cmd, opts)
end

--- Whether a waiting busy resend owes a frame that asked for a gap after it; the frames sent meanwhile
--- wait for it then, so the replay keeps the gap. Without one, they go at once and the replay sends
--- them again after it, as the newest must land last.
--- @return boolean
function Client:owesGap()
  for _, list in ipairs({ self.owed or {}, self.recent }) do
    for _, frame in ipairs(list) do
      if frame.gapAfterMs then
        return true
      end
    end
  end
  return false
end

--- Send the held commands that may go now, oldest first; the rest wait for the gap or the resend.
function Client:flushHeld()
  local held = self.held or {}
  while #held > 0 and not (self.replaying and self:owesGap()) and not self.seq do
    local wait = (self.gapUntil or 0) - now()
    if wait > 0 then
      if not self.flushing then
        self.flushing = true
        self:after(self.gen, wait, function()
          self.flushing = false
          self:flushHeld()
        end)
      end
      return
    end
    local h = table.remove(held, 1)
    self:sendNow(h.cmd, h.opts):next(function(value)
      h.d:resolve(value)
    end, function(err)
      h.d:reject(err)
    end)
  end
end

--- @param cmd table
--- @param opts {gapAfterMs: number|nil}|nil
--- @return Deferred
function Client:sendNow(cmd, opts)
  self.writes = self.writes + 1
  local body = JSON:encode(cmd)
  local limit = FRAME_LIMIT[self.arch or ""] or FRAME_LIMIT_DEFAULT
  local gap = opts and tonumber(opts.gapAfterMs) or nil
  if
    #body <= limit
    and not self:postPending()
    and self:sendFrame({ body = body, cmd = cmd, tries = 0, gapAfterMs = gap })
  then
    if gap then
      self.gapUntil = now() + gap
    end
    return deferred.new():resolve(true)
  end
  local gen, writes = self.gen, self.writes
  -- What a busy resend owes was sent first, so it goes ahead of this.
  if self.replaying then
    self:postWindow(self:takeOwed())
  end
  local answered, job = self:enqueue("POST", "/json/state", cmd)
  if job then
    job.gapAfterMs = gap
  end
  -- Kept in the window, so a busy answer arriving after it for an earlier frame resends that
  -- frame behind it.
  self:recentFrames()
  self.recent[#self.recent + 1] = { cmd = cmd, posted = true, at = now(), tries = 0, gapAfterMs = gap }
  if cmd.v ~= true then
    return answered
  end
  -- Over HTTP the state comes back as the answer, not as a push.
  return answered:next(function(state)
    if type(state) == "table" and state.seg ~= nil then
      report(self, gen, writes, job.pushes, state, nil, "WLED.Answer")
    end
    return state
  end)
end

--- GET a path from the controller (for example /json/eff or /presets.json).
--- @param path string The path on the controller.
--- @return Deferred answer Resolves with the decoded answer, or rejects.
function Client:get(path)
  return (self:enqueue("GET", path))
end

Client.PING_MS = PING_MS
Client.POLL_MS = POLL_MS
Client.SOCKET_POLL_MS = SOCKET_POLL_MS
Client.OPEN_GRACE_MS = OPEN_GRACE_MS
Client.CONNECT_TIMEOUT_MS = CONNECT_TIMEOUT_MS
Client.RECONNECT_MAX_MS = RECONNECT_MAX_MS
Client.BUSY_FIRST_MS = BUSY_FIRST_MS
Client.BUSY_RETRIES = BUSY_RETRIES

return Client
