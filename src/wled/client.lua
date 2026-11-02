--- Transport to one WLED controller.
---
--- One WebSocket (ws://host:port/ws) carries the controller's pushes and the driver's commands.
--- WLED sends its full state and info when the socket opens and again after any change, from
--- any source, at most once a second. Liveness is WLED's own text ping: "p" every 30 s, answered
--- "pong"; two missed answers close the socket. While the socket is down it reconnects with
--- growing waits capped at 30 s, sends commands over HTTP and polls /json/si slowly. HTTP keeps
--- one request in flight, because the controller serves every request from one shared buffer;
--- a busy answer ({"error":3}, or HTTP 503 on 0.15) waits and retries.
---
--- The driver sees three things: onState(state, info) for every state the controller reports,
--- onOnline() when it can reach the controller again, and onOffline(reason) when it cannot.

local deferred = require("deferred")
local JSON = require("JSON")

local log = require("lib.logging")

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")

--- Text ping cadence and how many unanswered pings close the socket.
local PING_MS = 30000
local PINGS_MISSED_LIMIT = 2

--- Reconnect waits: doubled after each failure, capped, reset once the socket opens.
local RECONNECT_FIRST_MS = 1000
local RECONNECT_MAX_MS = 30000

--- How long a new socket has to open before the first HTTP poll, and the poll cadence after.
local OPEN_GRACE_MS = 5000
local POLL_MS = 10000

--- A busy controller is retried this many times, waiting 250 ms, 500 ms, 1 s and so on.
local BUSY_RETRIES = 5
local BUSY_FIRST_MS = 250

--- A busy answer this soon after a WebSocket command is taken as that command's.
local WS_BUSY_WINDOW_MS = 2000

--- Largest command the controller takes in one WebSocket frame (ws.cpp); bigger ones go over HTTP.
local FRAME_LIMIT = { esp8266 = 528 }
local FRAME_LIMIT_DEFAULT = 1428

local HTTP_TIMEOUT_S = 10

--- @class WledClient
--- @field host string|nil
--- @field port integer|nil
--- @field arch string|nil Chip the controller reported, for the frame limit.
--- @field mode "ws"|"http"|"offline" How the controller is reached now.
local Client = {}
Client.__index = Client

--- @class WledClientOptions
--- @field onState fun(state: table|nil, info: table|nil)|nil
--- @field onOnline fun()|nil
--- @field onOffline fun(reason: string)|nil
--- @field http table|nil An object with get(url, headers, options) and post(url, data, headers, options); lib.http by default.
--- @field WebSocket table|nil The WebSocket class; the vendored module by default.

--- @param opts WledClientOptions|nil
--- @return WledClient
function Client.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Client)
  self.onState = opts.onState or function() end
  self.onOnline = opts.onOnline or function() end
  self.onOffline = opts.onOffline or function() end
  self.http = opts.http or require("lib.http")
  self.WebSocket = opts.WebSocket or require("drivers-common-public.module.websocket")
  self.gen = 0
  self.mode = "offline"
  self.queue = {}
  self.closing = deferred.new():resolve(nil)
  return self
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

--- Run fn after ms unless the client was stopped or restarted meanwhile.
--- @param gen integer
--- @param ms integer
--- @param fn fun()
function Client:after(gen, ms, fn)
  delay(ms):next(function()
    if self.gen == gen then
      fn()
    end
  end)
end

--- Move to a new mode, telling the driver when reachability changes.
--- @param mode "ws"|"http"|"offline"
--- @param reason string|nil Why the controller cannot be reached, for "offline".
function Client:setMode(mode, reason)
  local was = self.mode
  self.mode = mode
  if was == "offline" and mode ~= "offline" then
    self.onOnline()
  elseif was ~= "offline" and mode == "offline" then
    self.onOffline(reason or "Not connected")
  end
end

--- Whether the controller can be reached, over the socket or HTTP.
--- @return boolean
function Client:isOnline()
  return self.mode ~= "offline"
end

--- Connect to a controller, closing any connection already open.
--- @param host string
--- @param port integer|nil
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
--- @return Deferred
function Client:closeSocket()
  local d = deferred.new()
  local ws = self.ws
  self.ws = nil
  if not ws then
    self.closing = self.closing or d:resolve(nil)
    return self.closing
  end
  self.closing, self.closingUrl = d, ws.url
  ws:delete(function()
    if self.closing == d then
      self.closingUrl = nil
    end
    d:resolve(nil)
  end)
  return d
end

--- @return string
function Client:socketUrl()
  return string.format("ws://%s:%d/ws", tostring(self.host), self.port or 80)
end

--- Close the connection and drop queued requests. Tells the driver nothing.
function Client:stop()
  self.gen = self.gen + 1
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
  self.mode = "offline"
end

-- ─── WebSocket ─────────────────────────────────────────────────────────────

--- @param gen integer
function Client:openSocket(gen)
  local url = self:socketUrl()
  local ws, err = self.WebSocket:new(url)
  if not ws then
    log:error("WLED WebSocket %s: %s", url, tostring(err))
    return
  end
  self.ws = ws
  -- The module's own control-frame ping is replaced by WLED's text ping below.
  ws.ping_interval = 24 * 3600

  ws:SetEstablishedFunction(function(socket)
    if self.gen ~= gen or self.ws ~= socket then
      return
    end
    log:debug("WLED WebSocket open to %s", self.host)
    self.socketUp = true
    self.backoff = RECONNECT_FIRST_MS
    self.missedPings = 0
    self.socketGen = (self.socketGen or 0) + 1
    self:pingLoop(gen, self.socketGen)
    self:setMode("ws")
  end)
  ws:SetProcessMessageFunction(function(socket, data)
    if self.gen == gen and self.ws == socket then
      self:onMessage(data)
    end
  end)
  ws:SetClosedByRemoteFunction(function(socket)
    if self.gen == gen and self.ws == socket then
      self:socketDown(gen, "The controller closed the connection")
    end
  end)
  ws:SetOfflineFunction(function(socket)
    if self.gen == gen and self.ws == socket then
      self:socketDown(gen, "No connection to the controller")
    end
  end)
  ws:Start()
end

--- @param gen integer
--- @param socketGen integer
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

--- The socket closed or stopped answering: reconnect after a wait, and use HTTP meanwhile.
--- @param gen integer
--- @param reason string
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

--- @param data string
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
    self.onState(msg.state, msg.info)
  end
end

--- A WebSocket command came back busy (3) or too big for a frame (9): retry, over HTTP for 9.
--- @param code any
function Client:onSocketError(code)
  local last = self.lastSocketCommand
  if not last or now() - last.at > WS_BUSY_WINDOW_MS then
    return
  end
  if code == 9 then
    self.lastSocketCommand = nil
    self:enqueue("POST", "/json/state", last.cmd)
    return
  end
  if code ~= 3 then
    return
  end
  if last.tries >= BUSY_RETRIES then
    log:warn("WLED controller stayed busy; a command was dropped")
    self.lastSocketCommand = nil
    return
  end
  local wait = BUSY_FIRST_MS * 2 ^ last.tries
  last.tries = last.tries + 1
  self:after(self.gen, wait, function()
    if self.lastSocketCommand == last then
      self:sendFrame(last)
    end
  end)
end

--- @param cmd table
function Client:sendFrame(cmd)
  if self.socketUp and self.ws then
    cmd.at = now()
    self.lastSocketCommand = cmd
    self.ws:Send(cmd.body)
    return true
  end
  return false
end

-- ─── HTTP ──────────────────────────────────────────────────────────────────

--- Start polling now, replacing any poll loop already waiting.
--- @param gen integer
function Client:startPolling(gen)
  self.pollToken = (self.pollToken or 0) + 1
  self:poll(gen, self.pollToken)
end

--- Poll /json/si while the socket is down; it keeps the state current and tells whether the
--- controller can be reached at all.
--- @param gen integer
--- @param token integer|nil
function Client:poll(gen, token)
  token = token or self.pollToken
  if self.socketUp or self.gen ~= gen or token ~= self.pollToken then
    self.polling = false
    return
  end
  self.polling = true
  self:enqueue("GET", "/json/si"):next(function(si)
    if self.gen ~= gen or self.socketUp then
      return
    end
    if type(si) == "table" then
      if type(si.info) == "table" then
        self.arch = si.info.arch
      end
      self:setMode("http")
      self.onState(si.state, si.info)
    end
  end, function(err)
    if self.gen ~= gen or self.socketUp or (type(err) == "table" and err.error == "stopped") then
      return
    end
    self:setMode("offline", self.downReason or "No connection to the controller")
  end)
  self:after(gen, POLL_MS, function()
    self:poll(gen, token)
  end)
end

--- Queue an HTTP request; one is in flight at a time.
--- @param method "GET"|"POST"
--- @param path string
--- @param body table|nil
--- @return Deferred
function Client:enqueue(method, path, body)
  local d = deferred.new()
  if not self.host then
    return d:reject({ error = "not started" })
  end
  self.queue[#self.queue + 1] = { method = method, path = path, body = body, d = d, tries = 0 }
  self:pump()
  return d
end

function Client:pump()
  if self.inFlight or #self.queue == 0 then
    return
  end
  local job = table.remove(self.queue, 1)
  self.inFlight = job
  self:request(job)
end

--- @param job table
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
--- @param job table
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
--- arrives through onState.
--- @param cmd table
--- @return Deferred
function Client:send(cmd)
  local body = JSON:encode(cmd)
  local limit = FRAME_LIMIT[self.arch or ""] or FRAME_LIMIT_DEFAULT
  if #body <= limit and self:sendFrame({ body = body, cmd = cmd, tries = 0 }) then
    return deferred.new():resolve(true)
  end
  return self:enqueue("POST", "/json/state", cmd)
end

--- GET a path from the controller (for example /json/eff or /presets.json).
--- @param path string
--- @return Deferred
function Client:get(path)
  return self:enqueue("GET", path)
end

Client.PING_MS = PING_MS
Client.POLL_MS = POLL_MS
Client.OPEN_GRACE_MS = OPEN_GRACE_MS
Client.RECONNECT_FIRST_MS = RECONNECT_FIRST_MS
Client.RECONNECT_MAX_MS = RECONNECT_MAX_MS
Client.BUSY_FIRST_MS = BUSY_FIRST_MS
Client.BUSY_RETRIES = BUSY_RETRIES

return Client
