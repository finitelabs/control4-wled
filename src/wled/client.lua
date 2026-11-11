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
--- @field recent table[] WebSocket commands sent within the busy window, oldest first.
--- @field replaying boolean|nil Whether a busy resend waits to go out.
local Client = {}
Client.__index = Client

--- @class WledClientOptions
--- @field onState fun(state: table|nil, info: table|nil)|nil
--- @field onOnline fun()|nil
--- @field onOffline fun(reason: string)|nil
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
  self.recent, self.replaying = {}, false
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

--- Report a state answered over HTTP. An answer asked for before a restart or a later write is
--- dropped; that write's report tells the state. While the socket is down the answer also shows
--- the controller reachable, as a poll does.
--- @param client WledClient
--- @param gen integer The connection generation when the request went out.
--- @param writes integer The write count when the request went out.
--- @param state table|nil
--- @param info table|nil
--- @param tag string The error-report name for onState.
local function report(client, gen, writes, state, info, tag)
  if client.gen ~= gen then
    return
  end
  if not client.socketUp then
    client:setMode("http")
  end
  if client.writes == writes then
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
    local writes, pushes = self.writes, self.pushes
    -- A stop or a new socket rejects or outdates the request; its loop ends there.
    local function again()
      if self.gen == gen and self.socketGen == socketGen then
        self:socketPoll(gen, socketGen)
      end
    end
    self
      :enqueue("GET", "/json/si")
      :next(function(si)
        if self.pushes == pushes and type(si) == "table" then
          report(self, gen, writes, si.state, si.info, "WLED.SocketPoll")
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

--- A WebSocket command came back busy (3) or too big for a frame (9). The answer does not say
--- which command, so a busy answer sends every recent one again, in order: each carries whole
--- values, so a second copy changes nothing. A frame too big goes over HTTP.
--- @param code any The error number WLED sent.
function Client:onSocketError(code)
  local frames = self:recentFrames()
  if #frames == 0 then
    return
  end
  if code == 9 then
    local last = table.remove(self.recent)
    self:enqueue("POST", "/json/state", last.cmd):next(nil, function(err)
      if type(err) == "table" and err.error == "stopped" then
        return
      end
      log:warn("WLED command not sent: %s", type(err) == "table" and (err.error or "failed") or tostring(err))
      self:refresh()
    end)
    return
  end
  if code ~= 3 or self.replaying then
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
    return
  end
  self.replaying = true
  self:after(self.gen, BUSY_FIRST_MS * 2 ^ tries, function()
    self.replaying = false
    if not (self.socketUp and self.ws) then
      return
    end
    -- Then every command sent during the wait, so the latest still comes last; one refused
    -- while this waited is sent again here too.
    local replay, seen = {}, {}
    for _, list in ipairs({ frames, self.recent }) do
      for _, frame in ipairs(list) do
        if not seen[frame] then
          seen[frame] = true
          replay[#replay + 1] = frame
        end
      end
    end
    self.recent = replay
    for _, frame in ipairs(replay) do
      frame.tries = frame.tries + 1
      frame.at = now()
      self.ws:Send(frame.body)
    end
  end)
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
  self:enqueue("GET", "/json/si"):next(function(si)
    if type(si) == "table" then
      report(self, gen, writes, si.state, si.info, "WLED.Refresh")
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
function Client:enqueue(method, path, body)
  local d = deferred.new()
  if not self.host then
    return d:reject({ error = "not started" })
  end
  self.queue[#self.queue + 1] = { method = method, path = path, body = body, d = d, tries = 0 }
  self:pump()
  return d
end

--- Send the next queued HTTP request when none is in flight.
function Client:pump()
  if self.inFlight or #self.queue == 0 then
    return
  end
  local job = table.remove(self.queue, 1)
  self.inFlight = job
  self:request(job)
end

--- Send one HTTP request and settle its job; a busy answer is retried in the slot.
--- @param job table {method, path, body, d = its deferred, tries}
function Client:request(job)
  local gen = self.gen
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

-- ─── For later layers ──────────────────────────────────────────────────────

--- Send a state command: over the socket when it is open and the command fits one frame,
--- otherwise POST /json/state. Resolves once sent (socket) or answered (HTTP); the new state
--- arrives through onState. A command with v = true gets the state back on either path.
--- @param cmd table The state command, e.g. { on = true, bri = 128 }.
--- @return Deferred sent Resolves once sent or answered.
function Client:send(cmd)
  self.writes = self.writes + 1
  local body = JSON:encode(cmd)
  local limit = FRAME_LIMIT[self.arch or ""] or FRAME_LIMIT_DEFAULT
  if #body <= limit and self:sendFrame({ body = body, cmd = cmd, tries = 0 }) then
    return deferred.new():resolve(true)
  end
  local gen, writes = self.gen, self.writes
  local answered = self:enqueue("POST", "/json/state", cmd)
  if cmd.v ~= true then
    return answered
  end
  -- Over HTTP the state comes back as the answer, not as a push.
  return answered:next(function(state)
    if type(state) == "table" and state.seg ~= nil then
      report(self, gen, writes, state, nil, "WLED.Answer")
    end
    return state
  end)
end

--- GET a path from the controller (for example /json/eff or /presets.json).
--- @param path string The path on the controller.
--- @return Deferred answer Resolves with the decoded answer, or rejects.
function Client:get(path)
  return self:enqueue("GET", path)
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
