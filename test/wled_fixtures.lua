--- A fake WLED controller and a virtual clock for the WLED suites.
---
--- The controller answers from test/fixtures/wled/<profile>/, which test/gen_wled_fixtures.py
--- writes from the mock (test/mock-wled), so WLED's behavior has one model. It serves HTTP
--- through an object shaped like lib.http and the WebSocket through the shim's network
--- bindings, the way the vendored module reaches a controller: NetConnect, SendToNetwork,
--- OnConnectionStatusChanged and ReceivedFromNetwork. Tests script what the controller does
--- next: push a state, answer busy, drop, close with a code, ignore pings, go unreachable.
--- W.reload carries the driver across a reload, as a driver update or a Director restart makes one.
---
--- Usage:
---   local W = require("wled_fixtures")
---   local fake = W.Fake.new("esp32-rgbw-pwm-16")
---   W.run(100)

require("c4_shim")
require("drivers-common-public.global.handlers")

local C4Local = require("c4_local")
local deferred = require("deferred")
local JSON = require("JSON")

local M = {}

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
      -- The same entry goes back, so a Cancel after this fire still stops it.
      order = order + 1
      best.at, best.order = now + best.every, order
      queue[#queue + 1] = best
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
  self.wire = {}
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
  M.sockets = {}
  M.clearTimers()
end

function Fake:after(ms, fn)
  C4:SetTimer(ms, fn)
end

function Fake:isV16()
  return tostring(self.si.info.ver):match("^1%d%.") ~= nil
end

--- The presets file as the fake serves it.
--- @return table
function Fake:presetsFile()
  local file = self.files["/presets.json"]
  if type(file) == "function" then
    file = file()
  end
  return type(file) == "table" and file or {}
end

--- Apply state fields to the fake's state. A segment field other than power and brightness
--- leaves the current preset, and an effect sent outside a preset unloads a playlist, even the
--- effect already running (json.cpp unloads on any fx it is given).
--- @param cmd table
--- @param fromPreset boolean|nil
function Fake:applyFields(cmd, fromPreset)
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
  local changed, fxSent = false, false
  -- An array names segments by id; an object applies to every segment.
  if type(cmd.seg) == "table" then
    local list = cmd.seg[1] and cmd.seg or { cmd.seg }
    for _, s in ipairs(list) do
      for _, seg in ipairs(state.seg or {}) do
        if s.id == nil or s.id == seg.id then
          if type(s.col) == "table" and type(s.col[1]) == "table" then
            seg.col = seg.col or {}
            seg.col[1] = copy(s.col[1])
            changed = true
          end
          if s.fx ~= nil then
            fxSent = true
            local fx = s.fx
            -- "~n" steps the effect by n, wrapping (parseNumber in util.cpp); "~0" keeps it.
            local step = type(fx) == "string" and tonumber(fx:match("^~(%-?%d+)$"))
            if step then
              local count = #(self.files["/json/eff"] or {})
              fx = count > 0 and (seg.fx + step) % count or seg.fx
            end
            -- The effect already running changes nothing, so the preset still shows.
            if seg.fx ~= fx then
              seg.fx = fx
              if s.fxdef then
                self:effectDefaults(seg)
              end
              changed = true
            end
          end
          -- After the effect, so a field sent with it overrides the effect's default.
          for _, key in ipairs({ "cct", "sx", "ix", "pal", "c1", "c2", "o1", "o2", "o3", "on", "bri" }) do
            if s[key] ~= nil then
              seg[key] = s[key]
              changed = true
            end
          end
          if s.c3 ~= nil then
            -- Custom 3 is five bits.
            seg.c3 = math.max(0, math.min(31, s.c3))
            changed = true
          end
        end
      end
    end
  end
  if not fromPreset then
    if changed then
      state.ps = -1
    end
    if fxSent then
      state.pl = -1
    end
  end
end

--- Start a segment's effect from its own defaults, as WLED does for a command with fxdef: the
--- `sx=24,pal=50` pairs after the last `;` of the effect's metadata, else WLED's defaults.
--- @param seg table
function Fake:effectDefaults(seg)
  local meta = (self.files["/json/fxdata"] or {})[seg.fx + 1]
  local tail = type(meta) == "string" and meta:match(";([^;]*)$") or nil
  local function default(key)
    local v = tail and tail:match(key .. "=(%d+)")
    return v and tonumber(v)
  end
  for key, value in pairs({ sx = 128, ix = 128, c1 = 128, c2 = 128, c3 = 16 }) do
    seg[key] = default(key) or value
  end
  for _, key in ipairs({ "o1", "o2", "o3" }) do
    local v = default(key)
    seg[key] = v ~= nil and v ~= 0
  end
  local pal = default("pal")
  if pal then
    seg.pal = pal
  end
end

--- Apply a preset, or start a playlist and apply its first preset.
--- @param id integer
--- @param fromPlaylist boolean|nil
function Fake:applyPreset(id, fromPlaylist)
  local entry = self:presetsFile()[tostring(id)]
  if type(entry) ~= "table" or next(entry) == nil then
    return
  end
  local state = self.si.state
  if not fromPlaylist then
    state.pl = -1
  end
  if type(entry.playlist) == "table" then
    state.pl = id
    local first = type(entry.playlist.ps) == "table" and entry.playlist.ps[1] or nil
    if first then
      self:applyPreset(first, true)
    end
    return
  end
  self:applyFields(entry, true)
  state.ps = id
end

--- WLED loads a preset from its file system on a later pass of its loop, after the command's
--- answer (json.cpp); measured about 40 ms on 16.0.1.
local PRESET_LOAD_MS = 40

--- Apply a command the way the controller would for the parts these suites use. A preset loads
--- a moment later, as WLED's does.
--- @param cmd table
function Fake:apply(cmd)
  self.commands[#self.commands + 1] = cmd
  self:applyFields(cmd)
  if type(cmd.playlist) == "table" and next(cmd.playlist) == nil then
    -- 16.x takes an empty playlist sent during one as a nested playlist, and the running one
    -- carries on (playlist.cpp@v16.0.1); 0.15 unloads it.
    if not (self:isV16() and (self.si.state.pl or -1) >= 0) then
      self.si.state.pl = -1
    end
  end
  if cmd.ps ~= nil then
    self:after(PRESET_LOAD_MS, function()
      self:loadPreset(cmd.ps)
    end)
  end
end

--- Whether two values are equal all the way down, leaving out the top-level keys given.
local function same(a, b, skip)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not (skip and skip[k]) and not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if not (skip and skip[k]) and a[k] == nil then
      return false
    end
  end
  return true
end

--- Load a preset, or start a playlist, and push it: a playlist's start always is, as WLED
--- shows the playlist's own id first; a preset only when it changed something.
--- @param id integer
function Fake:loadPreset(id)
  local before = copy(self.si.state)
  self:applyPreset(id)
  local entry = self:presetsFile()[tostring(id)]
  if (type(entry) == "table" and type(entry.playlist) == "table") or not same(before, self.si.state) then
    self:schedulePush()
  end
end

--- Apply a command from a client and tell the clients as WLED does. A command that changes
--- nothing (led.cpp) or only moves the playlist (measured on 0.15.4 and 16.0.1) is pushed to no
--- one, and "v" answers the sender with the state as the command found it, unless a push is
--- already on its way (ws.cpp).
--- @param cmd table
--- @return table|nil answer The state the sender gets back on its own, if any.
function Fake:handle(cmd)
  local before = copy(self.si.state)
  self:apply(cmd)
  if not same(before, self.si.state, { pl = true }) then
    self:schedulePush()
  end
  if cmd.v == true and not self.pushDue then
    return copy(self.si)
  end
  return nil
end

-- HTTP, shaped like lib.http.

function Fake:answer(method, path, body)
  self.requests[#self.requests + 1] = { method = method, path = path, body = body }
  local d = deferred.new()
  -- slowGetMs: a GET answer built when the request arrives, as WLED builds it, and delivered
  -- that much later, so a write or push can overtake it on the way.
  if method == "GET" and self.slowGetMs and self.reachable then
    local entry = self.files[path]
    entry = copy(type(entry) == "function" and entry() or entry)
    self:after(self.slowGetMs, function()
      d:resolve({ code = 200, body = entry })
    end)
    return d
  end
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
      self.wire[#self.wire + 1] = body
      local cmd = JSON:decode(body)
      self:handle(cmd)
      if cmd.v == true then
        -- With "v" WLED answers with the state and sends its socket clients a push too.
        self:schedulePush()
        d:resolve({ code = 200, body = copy(self.si.state) })
        return
      end
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

--- Change the state (and info) the way WLED does without telling its clients: live data from
--- another system starting or ending, a preset saved, a playlist stopped elsewhere.
--- @param state table|nil
--- @param info table|nil
function Fake:changeSilently(state, info)
  if state then
    merge(self.si.state, state)
  end
  if info then
    merge(self.si.info, info)
  end
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
  self:after(self.connectDelayMs or LATENCY_MS, function()
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
    -- noUpgrade: it takes the connection but never answers the upgrade.
    if not key or self.noUpgrade then
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
        self.wire[#self.wire + 1] = frame.payload
        local answer = ok and type(cmd) == "table" and self:handle(cmd) or nil
        if answer then
          self:after(LATENCY_MS, function()
            self:sendText(JSON:encode(answer))
          end)
        end
      end
    elseif frame.opcode == 9 then
      self:receive(string.char(0x8A, 0))
    end
  end
end

local function fakeFor(binding, port)
  local address = C4:GetBindingAddress(binding)
  if port and byAddress[tostring(address) .. ":" .. port] then
    return byAddress[address .. ":" .. port]
  end
  for key, fake in pairs(byAddress) do
    if key:match("^(.-):") == address then
      return fake
    end
  end
  return nil
end

local netConnect, netDisconnect, sendToNetwork = C4.NetConnect, C4.NetDisconnect, C4.SendToNetwork

function C4:NetConnect(binding, port, ...)
  local fake = fakeFor(binding, port)
  if fake and port == fake.port then
    fake:onConnect(binding)
    return
  end
  return netConnect(self, binding, port, ...)
end

function C4:NetDisconnect(binding, port, ...)
  local fake = fakeFor(binding, port)
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
  local fake = fakeFor(binding, port)
  if fake and port == fake.port then
    fake:onSend(data)
  end
end

-- ─── mDNS ──────────────────────────────────────────────────────────────────
--
-- The driver looks for controllers with a LuaSocket UDP socket. Every suite gets this socket,
-- so none sends a real packet. A query to the mDNS group is answered by each fake that is
-- reachable and announces, as an mDNS responder answers a one-shot query: by unicast from
-- port 5353, repeating the query's id and question, with the instance's SRV, TXT and A records
-- added and names compressed.

local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32(n)
  return u16(math.floor(n / 65536)) .. u16(n % 65536)
end

local function label(text)
  return string.char(#text) .. text
end

--- A compressed name: a pointer to a 0-based offset in the message.
local function pointer(offset)
  return u16(49152 + offset)
end

local function record(name, rtype, ttl, rdata)
  return name .. u16(rtype) .. u16(1) .. u32(ttl) .. u16(#rdata) .. rdata
end

--- An answer to a _wled._tcp query.
--- @param a table {id, instance, host, port, mac, ip or ips, ttl, withoutSrv, withoutTxt, withoutA}
--- @return string
function M.mdnsAnswer(a)
  local ttl = a.ttl or 10
  local ips = (a.withoutA or a.withoutSrv) and {} or a.ips or { a.ip }
  local extra = (a.withoutSrv and 0 or 1) + (a.withoutTxt and 0 or 1) + #ips
  local msg = u16(a.id or 0) .. u16(33792) .. u16(1) .. u16(1) .. u16(0) .. u16(extra)
  -- The question at offset 12: "_wled" at 12, "_tcp" at 18, "local" at 23.
  msg = msg .. label("_wled") .. label("_tcp") .. label("local") .. "\0" .. u16(12) .. u16(1)
  local instanceAt = #msg + 12
  msg = msg .. record(pointer(12), 12, ttl, label(a.instance) .. pointer(12))
  local hostAt
  if not a.withoutSrv then
    hostAt = #msg + 2 + 10 + 6
    msg = msg
      .. record(pointer(instanceAt), 33, ttl, u16(0) .. u16(0) .. u16(a.port or 80) .. label(a.host) .. pointer(23))
  end
  if not a.withoutTxt then
    msg = msg .. record(pointer(instanceAt), 16, ttl, label("mac=" .. a.mac))
  end
  for _, ip in ipairs(ips) do
    local octets = {}
    for octet in ip:gmatch("%d+") do
      octets[#octets + 1] = string.char(tonumber(octet))
    end
    msg = msg .. record(pointer(hostAt), 1, ttl, table.concat(octets))
  end
  return msg
end

--- The service a query asks for, lowercase, or nil for something else.
--- @param data string
--- @return string|nil
local function askedFor(data)
  local labels, pos = {}, 13
  while true do
    local len = data:byte(pos)
    if not len then
      return nil
    end
    if len == 0 then
      break
    end
    labels[#labels + 1] = data:sub(pos + 1, pos + len)
    pos = pos + len + 1
  end
  local qtype = (data:byte(pos + 1) or 0) * 256 + (data:byte(pos + 2) or 0)
  return qtype == 12 and table.concat(labels, "."):lower() or nil
end

--- How this fake answers a query, or nil when it does not.
--- @param query string
--- @return string|nil
function Fake:mdnsAnswerTo(query)
  -- mdns = "always": it answers mDNS while its web server does not.
  if (not self.reachable and self.mdns ~= "always") or self.mdns == false or askedFor(query) ~= "_wled._tcp.local" then
    return nil
  end
  local mac = self.si.info.mac
  local name = self.mdnsName or ("wled-" .. mac:sub(7))
  return M.mdnsAnswer({
    id = query:byte(1) * 256 + query:byte(2),
    instance = name,
    host = name,
    port = self.port,
    mac = mac,
    ip = self.ip,
    withoutTxt = self.mdnsWithoutTxt,
  })
end

local Udp = {}
Udp.__index = Udp

--- Every UDP socket the driver opened, oldest first.
M.sockets = {}

function M.udp()
  local udp = setmetatable({ inbox = {}, sent = {}, closed = false }, Udp)
  M.sockets[#M.sockets + 1] = udp
  return udp
end

function Udp:settimeout(timeout)
  self.timeout = timeout
  return 1
end

function Udp:setsockname(address, port)
  self.bound = { address, port }
  return 1
end

--- Set to an error to make every send fail with it, as a sandbox that refuses one does.
M.sendFails = nil

function Udp:sendto(data, ip, port)
  if self.closed then
    return nil, "closed"
  end
  if M.sendFails then
    return nil, M.sendFails
  end
  self.sent[#self.sent + 1] = { data = data, ip = ip, port = port }
  if ip == "224.0.0.251" and port == 5353 then
    for _, fake in pairs(byAddress) do
      local answer = fake:mdnsAnswerTo(data)
      if answer then
        C4:SetTimer(fake.mdnsDelayMs or 50, function()
          self.inbox[#self.inbox + 1] = { answer, fake.ip, 5353 }
        end)
      end
    end
  end
  return #data
end

function Udp:receivefrom()
  if self.closed then
    return nil, "closed"
  end
  local datagram = table.remove(self.inbox, 1)
  if not datagram then
    return nil, "timeout"
  end
  return datagram[1], datagram[2], datagram[3]
end

function Udp:close()
  self.closed = true
  return 1
end

--- The mDNS queries sent since the last reset.
--- @return integer
function M.mdnsQueries()
  local n = 0
  for _, udp in ipairs(M.sockets) do
    for _, sent in ipairs(udp.sent) do
      if sent.ip == "224.0.0.251" then
        n = n + 1
      end
    end
  end
  return n
end

local ok, realSocket = pcall(require, "socket")
package.loaded["socket"] = setmetatable({ udp = M.udp }, { __index = ok and realSocket or nil })

-- ─── Driver reloads ────────────────────────────────────────────────────────

--- Director's part of a driver reload, between the old instance's OnDriverDestroyed and the new
--- load's dofile. The new load starts in a fresh Lua state, with every lib.* module and the driver's
--- own unloaded (lib.http stays the fake's), and without the dynamic bindings, which it adds again.
--- Then a driver update, where Director keeps the driver's variables, or a Director restart, where
--- none survives; both land every persist write still waiting and start the variable ids over.
--- @param how "update"|"restart"
function M.reload(how)
  if how ~= "update" and how ~= "restart" then
    error("a reload is an update or a restart, not " .. tostring(how), 2)
  end
  C4Local.freshLuaState({ "^drivers%-common%-public%.module%.websocket$", "^wled%." })
  package.loaded["lib.http"] = M.http
  C4Local.dropDynamicBindings()
  if how == "update" then
    ShimUpdateDriver()
  else
    ShimRestartDirector()
  end
end

return M
