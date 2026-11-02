--- A fake WLED controller and a virtual clock for the WLED suites.
---
--- The controller answers from test/fixtures/wled/<profile>/, which test/gen_wled_fixtures.py
--- writes from the mock (test/mock-wled), so WLED's behavior has one model. It serves HTTP
--- through an object shaped like lib.http and the WebSocket through the shim's network
--- bindings, the way the vendored module reaches a controller: NetConnect, SendToNetwork,
--- OnConnectionStatusChanged and ReceivedFromNetwork. Tests script what the controller does
--- next: push a state, answer busy, drop, close with a code, ignore pings, go unreachable.
---
--- Usage:
---   local W = require("wled_fake")
---   local fake = W.Fake.new("esp32-rgbw-pwm-16")
---   W.run(100)

require("c4_shim")
require("drivers-common-public.global.handlers")

local deferred = require("deferred")
local JSON = require("JSON")

local M = {}

-- A Control4 global the WebSocket module uses for frames over 125 bytes: hex string to bytes.
tohex = tohex
  or function(s)
    return (tostring(s):gsub("%x%x", function(cc)
      return string.char(tonumber(cc, 16))
    end))
  end

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
M.FIXTURES = HERE .. "/fixtures/wled"

-- ─── Virtual clock ─────────────────────────────────────────────────────────

local now = 1000000
local queue, order = {}, 0

function C4:GetTime()
  return now
end

function C4:SetTimer(delayMs, callback, repeating)
  order = order + 1
  local t = { at = now + delayMs, order = order, every = repeating and delayMs or nil }
  local handle = newproxy(true)
  getmetatable(handle).__index = {
    Cancel = function()
      t.cancelled = true
    end,
  }
  t.fn = function()
    callback(handle, 0)
  end
  queue[#queue + 1] = t
  return handle
end

--- Run everything due within the next ms, in the order it falls due.
--- @param ms integer
function M.run(ms)
  local stop = now + ms
  while true do
    local best, bi
    for i, t in ipairs(queue) do
      if
        not t.cancelled
        and t.at <= stop
        and (not best or t.at < best.at or (t.at == best.at and t.order < best.order))
      then
        best, bi = t, i
      end
    end
    if not best then
      break
    end
    table.remove(queue, bi)
    now = best.at
    if best.every then
      order = order + 1
      queue[#queue + 1] = { at = now + best.every, order = order, every = best.every, fn = best.fn }
    end
    best.fn()
  end
  now = stop
end

--- @return integer ms
function M.now()
  return now
end

--- Drop every pending timer, for a test that starts over.
function M.clearTimers()
  queue = {}
end

-- ─── Fixtures ──────────────────────────────────────────────────────────────

--- @param profile string
--- @param name string
--- @return any
function M.fixture(profile, name)
  local f = assert(io.open(M.FIXTURES .. "/" .. profile .. "/" .. name, "r"))
  local text = f:read("*a")
  f:close()
  return JSON:decode(text)
end

--- Every profile the fixtures hold.
--- @return string[]
function M.profiles()
  local list = {}
  local p = io.popen('ls "' .. M.FIXTURES .. '"')
  for line in p:lines() do
    list[#list + 1] = line
  end
  p:close()
  table.sort(list)
  return list
end

local function copy(t)
  return JSON:decode(JSON:encode(t))
end

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and not v[1] then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

-- ─── WebSocket frames ──────────────────────────────────────────────────────

local function serverFrame(opcode, payload)
  local len = #payload
  local head
  if len <= 125 then
    head = string.char(0x80 + opcode, len)
  elseif len <= 65535 then
    head = string.char(0x80 + opcode, 126, math.floor(len / 256), len % 256)
  else
    local bytes = {}
    for i = 8, 1, -1 do
      bytes[i] = len % 256
      len = math.floor(len / 256)
    end
    head = string.char(0x80 + opcode, 127, unpack(bytes))
  end
  return head .. payload
end

--- Client frames are masked; returns each frame's opcode and payload.
local function clientFrames(data)
  local frames, pos = {}, 1
  while pos + 1 <= #data do
    local b1, b2 = data:byte(pos, pos + 1)
    local opcode = b1 % 16
    local len = b2 % 128
    local p = pos + 2
    if len == 126 then
      len = data:byte(p) * 256 + data:byte(p + 1)
      p = p + 2
    elseif len == 127 then
      len = 0
      for i = 0, 7 do
        len = len * 256 + data:byte(p + i)
      end
      p = p + 8
    end
    local mask = { data:byte(p, p + 3) }
    p = p + 4
    local out = {}
    for i = 0, len - 1 do
      out[#out + 1] = string.char(bit.bxor(data:byte(p + i), mask[(i % 4) + 1]))
    end
    frames[#frames + 1] = { opcode = opcode, payload = table.concat(out) }
    pos = p + len
  end
  return frames
end

-- ─── The controller ────────────────────────────────────────────────────────

--- @class WledFake
local Fake = {}
Fake.__index = Fake
M.Fake = Fake

--- Every fake by its address, so the network intercepts find the controller a binding names.
local byAddress = {}

local LATENCY_MS = 5

--- @param profile string A folder under test/fixtures/wled.
--- @param opts table|nil {ip, port}
--- @return WledFake
function Fake.new(profile, opts)
  opts = opts or {}
  local self = setmetatable({}, Fake)
  self.profile = profile
  self.ip = opts.ip or "192.0.2.10"
  self.port = opts.port or 80
  self.si = M.fixture(profile, "si.json")
  self.files = {
    ["/json/si"] = function()
      return copy(self.si)
    end,
    ["/json/state"] = function()
      return copy(self.si.state)
    end,
    ["/json/info"] = function()
      return copy(self.si.info)
    end,
    ["/json/eff"] = M.fixture(profile, "eff.json"),
    ["/json/pal"] = M.fixture(profile, "pal.json"),
    ["/json/fxdata"] = M.fixture(profile, "fxdata.json"),
    ["/presets.json"] = M.fixture(profile, "presets.json"),
  }
  self.reachable = true
  self.socketOpen = true
  self.ignorePings = false
  self.busy = 0
  self.wsBusy = 0
  self.commands = {}
  self.requests = {}
  self.pings = 0
  self.connects = 0
  self.binding = nil
  self.upgraded = false
  byAddress[self.ip .. ":" .. self.port] = self
  return self
end

--- Forget every fake.
function M.reset()
  byAddress = {}
  M.clearTimers()
end

function Fake:after(ms, fn)
  C4:SetTimer(ms, fn)
end

function Fake:isV16()
  return tostring(self.si.info.ver):match("^1%d%.") ~= nil
end

--- Apply a command the way the controller would for the parts these suites use.
--- @param cmd table
function Fake:apply(cmd)
  self.commands[#self.commands + 1] = cmd
  local state = self.si.state
  if cmd.on ~= nil then
    if cmd.on == "t" then
      state.on = not state.on
    else
      state.on = cmd.on
    end
  end
  if cmd.bri ~= nil then
    state.bri = cmd.bri
    if cmd.on == nil and cmd.bri > 0 then
      state.on = true
    end
  end
  -- An array names segments by id; an object applies to every segment.
  if type(cmd.seg) == "table" then
    local list = cmd.seg[1] and cmd.seg or { cmd.seg }
    for _, s in ipairs(list) do
      for _, seg in ipairs(state.seg or {}) do
        if s.id == nil or s.id == seg.id then
          if type(s.col) == "table" and type(s.col[1]) == "table" then
            seg.col = seg.col or {}
            seg.col[1] = copy(s.col[1])
          end
          if s.cct ~= nil then
            seg.cct = s.cct
          end
          if s.fx ~= nil then
            seg.fx = s.fx
          end
        end
      end
    end
  end
end

-- HTTP, shaped like lib.http.

function Fake:answer(method, path, body)
  self.requests[#self.requests + 1] = { method = method, path = path, body = body }
  local d = deferred.new()
  -- An unreachable controller fails after timeoutMs, as a real HTTP timeout does.
  local wait = self.reachable and LATENCY_MS or (self.timeoutMs or LATENCY_MS)
  self:after(wait, function()
    if not self.reachable then
      d:reject({ error = "HTTP " .. method .. " request failed; timeout" })
      return
    end
    if self.busy > 0 then
      self.busy = self.busy - 1
      d:reject({ error = "busy", code = 503, body = { error = 3 } })
      return
    end
    if method == "POST" then
      self:apply(JSON:decode(body))
      self:schedulePush()
      d:resolve({ code = 200, body = { success = true } })
      return
    end
    local entry = self.files[path]
    if type(entry) == "function" then
      entry = entry()
    end
    if entry == nil then
      d:reject({ error = "not found", code = 501, body = { error = 4 } })
      return
    end
    d:resolve({ code = 200, body = entry })
  end)
  return d
end

local function pathOf(fake, url)
  local host, port, path = tostring(url):match("^http://([^:/]+):(%d+)(/.*)$")
  local target = host and byAddress[host .. ":" .. port]
  return target, path
end

--- An object with lib.http's get and post, answered by whichever fake the URL names.
M.http = {}

function M.http:get(url)
  local fake, path = pathOf(nil, url)
  if not fake then
    return deferred.new():reject({ error = "HTTP GET request failed; no route" })
  end
  return fake:answer("GET", path)
end

function M.http:post(url, data)
  local fake, path = pathOf(nil, url)
  if not fake then
    return deferred.new():reject({ error = "HTTP POST request failed; no route" })
  end
  return fake:answer("POST", path, data)
end

-- WebSocket, through the shim's network bindings.

function Fake:status(status)
  if not self.binding then
    return
  end
  OnConnectionStatusChanged(self.binding, self.port, status)
end

function Fake:receive(data)
  if self.binding then
    ReceivedFromNetwork(self.binding, self.port, data)
  end
end

--- Send a text message on the open socket.
--- @param text string
function Fake:sendText(text)
  if self.upgraded then
    self:receive(serverFrame(1, text))
  end
end

--- Push the full state and info, as WLED does after any change.
function Fake:pushNow()
  self.pushDue = false
  self:sendText(JSON:encode(self.si))
end

--- WLED sends at most one push a second, carrying the latest state.
function Fake:schedulePush()
  if self.pushDue then
    return
  end
  self.pushDue = true
  self:after(1000, function()
    if self.pushDue then
      self:pushNow()
    end
  end)
end

--- Change the state (and info) as another client or a button would, then push.
--- @param state table|nil
--- @param info table|nil
function Fake:change(state, info)
  if state then
    merge(self.si.state, state)
  end
  if info then
    merge(self.si.info, info)
  end
  self:schedulePush()
end

--- The network connection drops without a close frame.
function Fake:drop()
  if self.binding and self.connected then
    self.connected, self.upgraded = false, false
    self:status("OFFLINE")
  end
end

--- Close the socket with a close code, as WLED does with 1013 when it runs short of memory.
--- @param code integer
function Fake:close(code)
  if self.upgraded then
    self:receive(serverFrame(8, string.char(math.floor(code / 256), code % 256)))
    self:after(LATENCY_MS, function()
      self:drop()
    end)
  end
end

function Fake:onConnect(binding)
  -- One client at a time: a new connection replaces the last one.
  self.binding = binding
  self.connected, self.upgraded = false, false
  self.connects = self.connects + 1
  self:after(LATENCY_MS, function()
    if self.reachable and self.socketOpen then
      self.connected = true
      self:status("ONLINE")
    else
      self:status("OFFLINE")
    end
  end)
end

function Fake:onSend(data)
  if not self.connected then
    return
  end
  if not self.upgraded then
    local key = data:match("Sec%-WebSocket%-Key: ([^\r\n]+)")
    if not key then
      return
    end
    local accept = C4:Hash("SHA1", key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", { return_encoding = "BASE64" })
    self:after(LATENCY_MS, function()
      self.upgraded = true
      self:receive(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
          .. accept
          .. "\r\n\r\n"
      )
      self:pushNow()
    end)
    return
  end
  for _, frame in ipairs(clientFrames(data)) do
    if frame.opcode == 1 then
      if frame.payload == "p" then
        self.pings = self.pings + 1
        if not self.ignorePings then
          self:after(LATENCY_MS, function()
            self:sendText("pong")
          end)
        end
      elseif self.wsBusy > 0 then
        self.wsBusy = self.wsBusy - 1
        self:after(LATENCY_MS, function()
          self:sendText('{"error":3}')
        end)
      else
        local ok, cmd = pcall(JSON.decode, JSON, frame.payload)
        if ok and type(cmd) == "table" then
          self:apply(cmd)
          self:schedulePush()
        end
      end
    elseif frame.opcode == 9 then
      self:receive(string.char(0x8A, 0))
    end
  end
end

local function fakeFor(binding)
  local address = C4:GetBindingAddress(binding)
  for key, fake in pairs(byAddress) do
    if key:match("^(.-):") == address then
      return fake
    end
  end
  return nil
end

local netConnect, netDisconnect, sendToNetwork = C4.NetConnect, C4.NetDisconnect, C4.SendToNetwork

function C4:NetConnect(binding, port, ...)
  local fake = fakeFor(binding)
  if fake and port == fake.port then
    fake:onConnect(binding)
    return
  end
  return netConnect(self, binding, port, ...)
end

function C4:NetDisconnect(binding, port, ...)
  local fake = fakeFor(binding)
  if fake and fake.binding == binding and fake.connected then
    fake.connected, fake.upgraded = false, false
    fake:after(1, function()
      fake:status("OFFLINE")
    end)
    return
  end
  return netDisconnect(self, binding, port, ...)
end

function C4:SendToNetwork(binding, port, data)
  sendToNetwork(self, binding, port, data)
  local fake = fakeFor(binding)
  if fake and port == fake.port then
    fake:onSend(data)
  end
end

return M
