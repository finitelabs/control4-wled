--- The WLED controller's light adapter for the shared light library: it puts the library's
--- commands on the wire as WLED JSON state, and reads the controller's model back as reports. A
--- segment light runs it over a controller that holds just its segment (wled.segment).
---
--- WLED behavior this follows (wled00/json.cpp, led.cpp and FX_fcn.cpp at
--- v16.0.1 and v0.15.4):
---   - `tt` is whole tenths of a second, kept as 16-bit milliseconds, so one
---     command carries at most 65.5 s; longer fades go as legs on one line.
---   - 16.x puts every fade at its target when a call lands while one runs (measured on the
---     strip, 2026-11-11 and 11-12). So each leg goes a moment after the last one ends, and a timed
---     command that lands mid-fade first holds the light where the adapter's own fade has it, at
---     0 ms, then goes a moment later with every channel's target: every channel restarts over the
---     command's time, as `fade.retimes` says.
---   - Brightness fades in a straight line from where the output is.
---   - The controller reports a command's target at once, and pushes at most
---     once a second.
---   - CCT is 0 (warm) to 255 (cool); the strip's real white points are the
---     installer's Warm White and Cool White.
---   - `{"on":true,"bri":N,"tt":T}` from off fades up from nothing by itself.
---
--- The memos (the latest command's wire form, the legs or freeze in flight, and the adapter's own
--- wire fade) live for one connection: forget(), which the driver calls with light:lost and
--- light:reset, ends them. A report after it is reported as the controller shows it, and no leg
--- or held command goes after it.

require("lib.utils")

local Color = require("lib.light.color")
local log = require("lib.logging")
local persist = require("lib.persist")
local Device = require("wled.device")

local TT_MAX = 655
local LEG_MS = TT_MAX * 100
--- How long after one leg's end the next is sent; enough for a leg replayed after a busy answer,
--- which goes 250 ms late.
local LEG_GAP_MS = 500
--- How long after a freeze the command goes. WLED 16 puts every fade at its target when a call lands
--- while one runs; a call this long after a 0 ms one fades from where the freeze held the light.
local FREEZE_GAP_MS = 150
--- How long after a landing a report may still predate it; WLED pushes at most once a second.
local WAIT_MS = 2500
--- The longest fade the proxy may offer, in ms; legs carry a fade past 65.5 s.
local RATE_MAX = 86400000
local DEFAULT_CCT = 127
--- The adapter's own persist key: the latest color it sent and that color's wire form, so the first
--- report after a reload that still shows those bytes is that color, not their rounding.
local SHOWN_PERSIST_KEY = "WledLightShownColor"

--- The values a command or a leg put on the wire, as the controller reports them back.
--- @class WledWire
--- @field on boolean Master power, with a segment lit.
--- @field bri integer|nil Master brightness, 1-255; nil when the command leaves it.
--- @field col integer[]|nil The main segment's primary color, 0-255 per channel.
--- @field cct integer|nil 0 (warm) to 255 (cool), on a strip with CCT.

--- @class WledLegs
--- @field gen integer The legGen the legs belong to.
--- @field leg WledWire The leg in flight.
--- @field hold boolean|nil A freeze: a report that is not it leaves the command that follows it.

--- @class WledLast
--- @field cmd LightCommand The latest command.
--- @field wire WledWire Where it leaves the controller.

--- @class WledLight : LightAdapter
--- @field device WledDevice The controller's model.
--- @field sendJson fun(json: table) Sends a JSON state command to the controller.
--- @field refreshState fun()|nil Asks the controller for its whole state.
--- @field warm fun(): number Warm White, in Kelvin.
--- @field cool fun(): number Cool White, in Kelvin.
--- @field legGen integer Bumped by every command, so legs of an older fade stop.
--- @field legs WledLegs|nil The fade going out in legs.
--- @field last WledLast|nil The latest command and its wire form.
--- @field fade WledFade|nil The adapter's own wire fade: the last timed frame, legs included.
--- @field cct integer|nil The CCT last sent or reported, which a full color keeps.
--- @field whiteK number|nil The white last sent to an RGBW strip's white LEDs, in Kelvin.
local Adapter = {}
Adapter.__index = Adapter

--- @class WledLightOptions
--- @field send fun(json: table) Sends a JSON state command to the controller.
--- @field refresh fun()|nil Asks the controller for its whole state.
--- @field device WledDevice The controller's model.
--- @field warm fun(): number Warm White, in Kelvin.
--- @field cool fun(): number Cool White, in Kelvin.

local function byte(v)
  return InRange(round((tonumber(v) or 0) * 255), 0, 255)
end

--- Creates the adapter for one light.
--- @param opts WledLightOptions The controller's model, its send and refresh, and the white points.
--- @return WledLight wledLight An adapter with nothing sent yet.
function Adapter:new(opts)
  local instance = setmetatable({}, self)
  instance.sendJson = opts.send
  instance.refreshState = opts.refresh
  instance.device = opts.device
  instance.warm = opts.warm
  instance.cool = opts.cool
  instance.legGen = 0
  return instance
end

--- Whether the controller's bits include one.
--- @param bit integer One of Device's CAP_ bits.
--- @return boolean
function Adapter:has(bit)
  return Device.has(self.device.lc, bit)
end

--- Whether the controller dims: any channel but a bare on/off.
--- @return boolean
function Adapter:dims()
  return self:has(Device.CAP_RGB) or self:has(Device.CAP_WHITE) or self:has(Device.CAP_CCT)
end

--- The installer's white points, warm below cool.
--- @return number warm Warm White, in Kelvin.
--- @return number cool Cool White, in Kelvin, above warm.
function Adapter:range()
  local warm, cool = tonumber(self.warm()) or 2700, tonumber(self.cool()) or 6500
  if cool <= warm then
    cool = warm + 1
  end
  return warm, cool
end

--- The color temperature a WLED CCT stands for, between the white points.
--- @param cct number 0 (warm) to 255 (cool).
--- @return number kelvin The color temperature, in Kelvin.
function Adapter:kelvinFromCct(cct)
  local warm, cool = self:range()
  return warm + (cool - warm) * InRange(tonumber(cct) or 0, 0, 255) / 255
end

--- The WLED CCT for a color temperature, held to the white points.
--- @param kelvin number The color temperature, in Kelvin.
--- @return integer cct 0 (warm) to 255 (cool).
function Adapter:cctFromKelvin(kelvin)
  local warm, cool = self:range()
  return InRange(round((kelvin - warm) / (cool - warm) * 255), 0, 255)
end

--- The light's facts for the library, from the controller's bits and the white points.
--- @return LightDevice device
function Adapter:lightDevice()
  local warm, cool = self:range()
  return {
    dims = self:dims(),
    color = self:has(Device.CAP_RGB),
    cct = self:has(Device.CAP_CCT) and { minK = round(warm), maxK = round(cool) } or nil,
    colorWhileOff = "send",
    levelSteps = 255,
    fade = { kind = "device", curve = "linear", preOn = true, retimes = true, maxMs = RATE_MAX },
    feedback = { shows = "target", waitMs = WAIT_MS, refresh = true },
  }
end

--- The segment whose color stands for the light: the main one, else the first.
--- @param state table
--- @return table|nil
local function mainSegment(state)
  local main, first = tonumber(state.mainseg) or 0, nil
  for _, seg in ipairs(type(state.seg) == "table" and state.seg or {}) do
    if type(seg) == "table" and (tonumber(seg.stop) or 0) > (tonumber(seg.start) or 0) then
      first = first or seg
      if tonumber(seg.id) == main then
        return seg
      end
    end
  end
  return first
end

--- A segment's primary color as 0-255 channels.
--- @param seg table|nil
--- @return integer r, integer g, integer b, integer w
local function primary(seg)
  local col = seg and type(seg.col) == "table" and seg.col[1]
  if type(col) == "string" then
    local hex = col:gsub("^#", "")
    local function at(i)
      return tonumber(hex:sub(i, i + 1), 16) or 0
    end
    return at(1), at(3), at(5), #hex >= 8 and at(7) or 0
  end
  if type(col) ~= "table" then
    return 0, 0, 0, 0
  end
  local function at(i)
    return InRange(round(tonumber(col[i]) or 0), 0, 255)
  end
  return at(1), at(2), at(3), at(4)
end

--- Whether any segment is on. A controller that lists no segments counts as one.
--- @param device table
--- @return boolean
local function anySegmentOn(device)
  local segs = device.segments or {}
  for _, s in ipairs(segs) do
    if s.on ~= false then
      return true
    end
  end
  return #segs == 0
end

--- Segment entries that turn on every segment the model has off, merged into the entries a
--- command carries. The command's own seg when none is off or the controller lists none.
--- @param seg table|nil The command's seg: entries, one object, or nil.
--- @param device table
--- @return table|nil
local function withAllOn(seg, device)
  local segs = device.segments or {}
  local list, byId = {}, {}
  if type(seg) == "table" and seg[1] then
    for _, e in ipairs(seg) do
      list[#list + 1] = e
      byId[e.id] = e
    end
  end
  local added = false
  for _, s in ipairs(segs) do
    if s.on == false then
      local e = byId[s.id]
      if not e then
        e = { id = s.id }
        list[#list + 1] = e
      end
      e.on = true
      added = true
    end
  end
  if not added then
    return seg
  end
  return list
end

--- The Kelvin a color shows at on the strip's white LEDs or CCT, or nil to show it in RGB: a
--- color temperature, or a color on the white locus between the white points.
--- @param color LightColor
--- @return number|nil kelvin
function Adapter:whiteOf(color)
  if not (self:has(Device.CAP_WHITE) or self:has(Device.CAP_CCT)) then
    return nil
  end
  local warm, cool = self:range()
  if color.mode == Color.CCT then
    local k = tonumber(color.kelvin) or Color.kelvin(color.x, color.y)
    return k and k > 0 and InRange(k, warm, cool) or nil
  end
  if not Color.onLocus(color.x, color.y, warm, cool) then
    return nil
  end
  return InRange(Color.kelvin(color.x, color.y), warm, cool)
end

--- The main segment's color and CCT for a color, as the controller reports them back.
--- @param color LightColor
--- @return integer[] col 0-255 per channel: four with white LEDs, else three.
--- @return integer|nil cct 0 (warm) to 255 (cool) on a strip with CCT; a full color keeps the last.
--- @return number|nil kelvin The white shown, nil for a full color.
function Adapter:render(color)
  local whiteLeds, withCct = self:has(Device.CAP_WHITE), self:has(Device.CAP_CCT)
  local cct = self.cct or DEFAULT_CCT
  local r, g, b, w = 0, 0, 0, 0
  local k = self:whiteOf(color)
  if not self:has(Device.CAP_RGB) then
    w = 255
  elseif k and whiteLeds then
    w = 255
  elseif k and withCct then
    -- A strip without white LEDs shows its white on all three.
    r, g, b = 255, 255, 255
  else
    k = nil
    local fr, fg, fb = Color.xyToRGB(color.x, color.y)
    r, g, b = byte(fr), byte(fg), byte(fb)
  end
  if k and withCct then
    cct = self:cctFromKelvin(k)
  end
  return whiteLeds and { r, g, b, w } or { r, g, b }, withCct and cct or nil, k
end

--- The seg value for a color: every segment, its effect stopped.
--- @param col integer[]
--- @param cct integer|nil
--- @return table seg An entry per segment, or one object when none are listed.
function Adapter:colorSeg(col, cct)
  local segs = {}
  for _, seg in ipairs(self.device.segments or {}) do
    segs[#segs + 1] = { id = seg.id, col = { col }, fx = 0, cct = cct }
  end
  if #segs == 0 then
    segs = { col = { col }, fx = 0, cct = cct }
  end
  return segs
end

--- Keep what a color sent leaves on the controller's other channels.
--- @param cct integer|nil
--- @param k number|nil The white sent, in Kelvin.
function Adapter:took(cct, k)
  if cct then
    self.cct = cct
  end
  if k and not self:has(Device.CAP_CCT) then
    self.whiteK = k
  end
end

--- Where a command leaves the controller, as it reports it. A command carries the whole state, and
--- the controller still shows a level or color sent earlier, so a carried value is matched too.
--- @param cmd LightCommand
--- @return WledWire wire
function Adapter:wireOf(cmd)
  local wire = { on = cmd.on == true }
  if self:dims() and (tonumber(cmd.level) or 0) > 0 then
    wire.bri = math.max(1, byte(cmd.level))
  end
  if cmd.color and (self:has(Device.CAP_RGB) or self:has(Device.CAP_CCT)) then
    wire.col, wire.cct = self:render(cmd.color)
  end
  return wire
end

--- Put one command on the wire. It never raises: one that fails is logged and dropped.
--- @param cmd LightCommand
--- @return LightRest|nil rest Always nil: the controller rests where it is told.
function Adapter:send(cmd)
  local ok, err = pcall(self.put, self, cmd)
  if not ok then
    log:error("WLED light command not sent: %s", err)
  end
  return nil
end

--- @class WledFade
--- @field t0 number When it went out, from C4:GetTime().
--- @field ms number Its length, legs included.
--- @field bri number[]|nil Master brightness (0-255) from and to; to is 0 for an off. Nil when it moves none.
--- @field col integer[][]|nil The color (0-255 per channel) from and to; nil when it moves none.
--- @field cct integer|nil The CCT that goes with the color.

--- Where the adapter's own wire fade has the controller now, with the fade's ends, while it runs.
--- @param now number From C4:GetTime().
--- @return table|nil at bri and col where the fade is, briTo and colTo where it ends, cct; nil when none runs.
function Adapter:runningAt(now)
  local f = self.fade
  if not f or f.ms <= 0 or now >= f.t0 + f.ms then
    return nil
  end
  local p = InRange((now - f.t0) / f.ms, 0, 1)
  local at = { cct = f.cct }
  if f.bri then
    at.bri, at.briTo = f.bri[1] + (f.bri[2] - f.bri[1]) * p, f.bri[2]
  end
  if f.col then
    at.col, at.colTo = {}, f.col[2]
    for i = 1, #f.col[2] do
      at.col[i] = round((f.col[1][i] or 0) + (f.col[2][i] - (f.col[1][i] or 0)) * p)
    end
  end
  return at
end

--- Put a master brightness on a frame: on at it, or off below 1. WLED keeps its level while off.
--- @param json table
--- @param bri number 0-255.
local function putBri(json, bri)
  if bri >= 1 then
    json.on, json.bri = true, math.max(1, round(bri))
  else
    json.on, json.bri = false, nil
  end
end

--- The frame that holds the controller where the adapter's own wire fade has it, as a leg the reports
--- of which are the command's; the command follows FREEZE_GAP_MS later.
--- @param at table From runningAt.
--- @param frame table The frame to send, changed in place: the aspects the fade moves where it is.
function Adapter:freeze(at, frame)
  if at.bri and frame.bri == nil and frame.on == nil then
    putBri(frame, at.bri)
  end
  if at.col and frame.seg == nil then
    frame.seg = self:colorSeg(at.col, at.cct)
  end
  frame.tt = 0
  local isOn = self.device.on == true and anySegmentOn(self.device)
  local legCol = frame.seg and (frame.seg[1] or frame.seg).col[1] or nil
  self.legs = {
    gen = self.legGen,
    hold = true,
    leg = { on = frame.on == nil and isOn or frame.on == true, bri = frame.bri, col = legCol },
  }
  self.sendJson(frame)
end

--- After a freeze, the aspects the command leaves at the ends the adapter's own fade was going to,
--- so every channel restarts over the command's time.
--- @param cmd LightCommand
--- @param json table The command's frame, changed in place.
--- @param at table From runningAt.
function Adapter:carry(cmd, json, at)
  if at.briTo and json.on == nil then
    putBri(json, at.briTo)
    if json.on == false and self:dims() and (tonumber(cmd.level) or 0) > 0 then
      json.bri = math.max(1, byte(cmd.level))
    end
  end
  if at.colTo and json.seg == nil then
    json.seg = self:colorSeg(at.colTo, at.cct)
  end
end

--- Whether two 0-255 values are within the wire's rounding.
local function near(a, b)
  return a ~= nil and b ~= nil and math.abs(a - b) <= 1
end

--- Whether a reported color and CCT are a wire form's, within a byte per channel.
--- @param col integer[]
--- @param cct integer|nil
--- @param wire WledWire
--- @return boolean
local function sameColor(col, cct, wire)
  if not wire.col then
    return false
  end
  for i = 1, #wire.col do
    if not near(col[i] or 0, wire.col[i]) then
      return false
    end
  end
  return wire.cct == nil or near(cct, wire.cct)
end

--- Keep the color a command leaves the controller showing, with its wire form, across a reload.
--- @param last WledLast
function Adapter:keepShown(last)
  local wire = last.wire
  if not (wire.col and last.cmd.color) then
    return
  end
  local kept = persist:get(SHOWN_PERSIST_KEY)
  local same = type(kept) == "table" and type(kept.col) == "table" and sameColor(kept.col, kept.cct, wire)
  if not same then
    persist:set(SHOWN_PERSIST_KEY, { col = wire.col, cct = wire.cct, color = last.cmd.color })
  end
end

--- @param cmd LightCommand
function Adapter:put(cmd)
  self.legGen = self.legGen + 1
  self.legs = nil
  local at = self:runningAt(C4:GetTime())
  self.fade = nil
  local color = cmd.setsColor and cmd.color or nil
  if cmd.kind == "preOn" then
    -- The controller fades up from off by itself: only the color goes first.
    if color then
      local col, cct, k = self:render(color)
      self:took(cct, k)
      self.sendJson({ seg = self:colorSeg(col, cct), tt = 0 })
    end
    return
  end
  self.last = { cmd = cmd, wire = self:wireOf(cmd) }
  self:keepShown(self.last)
  -- A command that sets no level leaves the power as it is.
  local json = {}
  if cmd.setsLevel then
    json.on = cmd.on == true
    if json.on and self:dims() then
      json.bri = math.max(1, byte(cmd.level))
    end
  end
  local col
  if color then
    local cct, k
    col, cct, k = self:render(color)
    self:took(cct, k)
    json.seg = self:colorSeg(col, cct)
  end
  local ms = math.max(0, tonumber(cmd.transitionMs) or 0)
  if cmd.kind == "stop" then
    self:stop(cmd, json, ms, at)
    return
  end
  -- On from off lights every segment, unless a preset just sent sets them; while on, each
  -- segment keeps what its own light set.
  local lightAll = json.on == true
    and not self.device.presetPending
    and not (self.device.on == true and anySegmentOn(self.device))
  if lightAll then
    json.seg = withAllOn(json.seg, self.device)
  end
  if ms > 0 and at then
    -- WLED puts every fade at its target when a call lands while one runs: hold it where it is first.
    self:freeze(at, {})
    self:carry(cmd, json, at)
    self:later(function()
      self:go(cmd, json, ms, col, lightAll, at)
    end)
    return
  end
  self:go(cmd, json, ms, col, lightAll, nil)
end

--- A stop: the aspects it names held at the command's values at once. The other aspect, when a ramp
--- of its own runs on, is held where it is and then goes on to where it was going over its time left.
--- @param cmd LightCommand
--- @param json table The stopped aspects' frame.
--- @param ms number The other aspect's time left.
--- @param at table|nil From runningAt.
function Adapter:stop(cmd, json, ms, at)
  if ms <= 0 then
    json.tt = 0
    self.sendJson(json)
    return
  end
  local rest = {}
  if not cmd.setsLevel then
    if at and at.briTo then
      putBri(rest, at.briTo)
    elseif cmd.on == true and self:dims() then
      rest.on, rest.bri = true, math.max(1, byte(cmd.level))
    end
  end
  if not cmd.setsColor and cmd.color then
    if at and at.colTo then
      rest.seg = self:colorSeg(at.colTo, at.cct)
    else
      local col, cct = self:render(cmd.color)
      rest.seg = self:colorSeg(col, cct)
    end
  end
  if at then
    self:freeze(at, json)
  else
    json.tt = 0
    self.sendJson(json)
  end
  local col = rest.seg and (rest.seg[1] or rest.seg).col[1] or nil
  self:later(function()
    self:go(cmd, rest, ms, col, false, at)
  end)
end

--- Run fn FREEZE_GAP_MS from now, unless another command or forget() comes first.
--- @param fn fun()
function Adapter:later(fn)
  local gen = self.legGen
  delay(FREEZE_GAP_MS):next(function()
    if self.legGen == gen then
      fn()
    end
  end)
end

--- Send a command's frame over its time, in legs past 65.5 s, and keep it as the adapter's own fade.
--- @param cmd LightCommand
--- @param json table The frame.
--- @param ms number The fade's length.
--- @param col integer[]|nil The color the frame ends at.
--- @param lightAll boolean Whether the frame turns every segment on.
--- @param at table|nil Where a freeze held the controller; nil to start from where the command says.
function Adapter:go(cmd, json, ms, col, lightAll, at)
  self.legs = nil
  if ms > LEG_MS then
    self:startLegs(cmd, json, ms, col, lightAll, at)
    return
  end
  json.tt = round(ms / 100)
  self:keep(cmd, json, ms, col, at)
  self.sendJson(json)
end

--- Keep a timed frame as the adapter's own wire fade, from where the controller is.
--- @param cmd LightCommand
--- @param json table
--- @param ms number
--- @param col integer[]|nil
--- @param at table|nil
--- @return number fromBri, integer[]|nil fromCol
function Adapter:keep(cmd, json, ms, col, at)
  local device = self.device
  local from = cmd.from or {}
  local isOn = device.on == true and anySegmentOn(device)
  local fromBri = at and at.bri or (isOn and InRange((tonumber(from.level) or 0) * 255, 0, 255) or 0)
  local fromCol = col and (at and at.col or (from.color and self:render(from.color)) or col) or nil
  if ms <= 0 then
    self.fade = nil
    return fromBri, fromCol
  end
  local toBri = json.on == false and 0 or json.bri or (json.on == true and fromBri) or nil
  local seg = json.seg and (json.seg[1] or json.seg)
  self.fade = {
    t0 = C4:GetTime(),
    ms = ms,
    bri = toBri and { fromBri, toBri } or nil,
    col = col and { fromCol, col } or nil,
    cct = seg and seg.cct or nil,
  }
  return fromBri, fromCol
end

--- A fade longer than one command carries, as legs along one straight line from where the
--- controller is.
--- @param cmd LightCommand
--- @param json table The whole command, which the last leg sends.
--- @param ms number The fade's length.
--- @param toCol integer[]|nil The color the fade ends at; nil when it sets none.
--- @param lightAll boolean Whether the first leg turns every segment on.
--- @param at table|nil Where a freeze held the controller.
function Adapter:startLegs(cmd, json, ms, toCol, lightAll, at)
  local n = math.ceil(ms / LEG_MS)
  -- The gaps come out of the legs, so the fade still ends ms after it starts.
  local legMs = (ms - (n - 1) * LEG_GAP_MS) / n
  local device = self.device
  -- A controller that is off fades up from nothing.
  local isOn = device.on == true and anySegmentOn(device)
  local setsLevel = json.on ~= nil
  local fromBri, fromCol = self:keep(cmd, json, ms, toCol, at)
  local toBri = json.on and (json.bri or fromBri) or 0
  fromCol = fromCol or toCol
  local gen = self.legGen
  local finalOn = json.on
  local function leg(k)
    if self.legGen ~= gen then
      return
    end
    local p = k / n
    local part = { tt = round(legMs / 100) }
    local last = k == n
    if last then
      for key, value in pairs(json) do
        part[key] = value
      end
      part.tt = round(legMs / 100)
      if finalOn == false and self:dims() and (tonumber(cmd.level) or 0) > 0 then
        -- WLED keeps bri while off: the off leaves the level kept, as a short fade does.
        part.bri = math.max(1, byte(cmd.level))
      end
      self.legs = nil
    else
      part.on = finalOn or nil
      if setsLevel then
        part.bri = math.max(1, round(fromBri + (toBri - fromBri) * p))
      end
      if toCol and json.seg then
        local col = {}
        for i = 1, #toCol do
          col[i] = round((fromCol[i] or 0) + (toCol[i] - (fromCol[i] or 0)) * p)
        end
        local seg = {}
        for i, s in ipairs(json.seg) do
          seg[i] = { id = s.id, col = { col }, fx = 0, cct = s.cct }
        end
        if #seg == 0 then
          seg = { col = { col }, fx = 0, cct = json.seg.cct }
        end
        part.seg = seg
      end
      local legCol = part.seg and (part.seg[1] or part.seg).col[1] or nil
      self.legs = { gen = gen, leg = { on = finalOn or isOn, bri = part.bri, col = legCol } }
      if lightAll and k == 1 then
        part.seg = withAllOn(part.seg, device)
      end
    end
    self.sendJson(part)
    if not last then
      delay(legMs + LEG_GAP_MS):next(function()
        leg(k + 1)
      end)
    end
  end
  leg(1)
end

--- The color a report shows, or nil when it carries none.
--- @param col integer[] 0-255 per channel.
--- @param cct integer|nil
--- @return LightColor|nil color
function Adapter:shownColor(col, cct)
  local whiteLeds, withCct = self:has(Device.CAP_WHITE), self:has(Device.CAP_CCT)
  local function white(k)
    local x, y = Color.kelvinToXY(k)
    return { x = x, y = y, mode = Color.CCT, kelvin = round(k) }
  end
  if not self:has(Device.CAP_RGB) then
    return withCct and white(self:kelvinFromCct(cct or DEFAULT_CCT)) or nil
  end
  local r, g, b, w = col[1] or 0, col[2] or 0, col[3] or 0, whiteLeds and col[4] or 0
  local m = math.max(r, g, b)
  if withCct and not whiteLeds and m > 0 and r == g and g == b then
    return white(self:kelvinFromCct(cct or DEFAULT_CCT))
  end
  if m > 0 and m >= w then
    local x, y = Color.rgbToXY(r / 255, g / 255, b / 255)
    return { x = x, y = y, mode = Color.FULL }
  end
  if withCct then
    return white(self:kelvinFromCct(cct or DEFAULT_CCT))
  end
  if w > 0 then
    local _, cool = self:range()
    return white(self.whiteK or cool)
  end
  return nil
end

--- The controller's state as a report. A report that is the wire form of the latest command,
--- whole or the leg in flight, is reported per aspect as that command's values; one that is
--- neither while legs run means another client moved the light, so the legs left stop.
--- @return LightReport report
function Adapter:report()
  local device = self.device
  local seg = mainSegment(device.state or {})
  local r, g, b, w = primary(seg)
  local col = self:has(Device.CAP_WHITE) and { r, g, b, w } or { r, g, b }
  local cct = nil
  if self:has(Device.CAP_CCT) then
    cct = InRange(round(tonumber(seg and seg.cct) or self.cct or DEFAULT_CCT), 0, 255)
    self.cct = cct
  end
  local on = device.on == true and anySegmentOn(device)
  local bri = tonumber(device.bri) or 0
  local report = { kind = "push", on = on }
  if self:dims() then
    report.level = bri / 255
  end
  if self:has(Device.CAP_RGB) or self:has(Device.CAP_CCT) then
    report.color = self:shownColor(col, cct)
  end
  local last = self.last
  if not last then
    local kept = persist:get(SHOWN_PERSIST_KEY)
    if report.color and type(kept) == "table" and type(kept.col) == "table" and sameColor(col, cct, kept) then
      report.color = kept.color
    end
    return report
  end
  local legs = self.legs
  if legs then
    local leg = legs.leg
    if on == leg.on and (not leg.bri or near(bri, leg.bri)) and (not leg.col or sameColor(col, cct, leg)) then
      report.level = report.level and last.cmd.level
      report.color = report.color and last.cmd.color
      return report
    end
    local wire = last.wire
    local isEnd = on == wire.on
      and (not wire.bri or near(bri, wire.bri))
      and (not wire.col or sameColor(col, cct, wire))
    if not isEnd and not legs.hold then
      -- Another client moved the light: the legs left would undo it.
      self.legGen = self.legGen + 1
      self.legs = nil
      self.fade = nil
    end
  elseif self.fade then
    local wire = last.wire
    local isEnd = on == wire.on
      and (not wire.bri or near(bri, wire.bri))
      and (not wire.col or sameColor(col, cct, wire))
    if not isEnd then
      -- The light is off the adapter's line, so the next command starts from where the library says.
      self.fade = nil
    end
  end
  if report.level and near(bri, last.wire.bri) then
    report.level = last.cmd.level
  end
  if report.color and sameColor(col, cct, last.wire) then
    report.color = last.cmd.color
  end
  return report
end

--- End the memos, any legs left and a command a freeze holds, when the light is lost or reset.
function Adapter:forget()
  self.legGen = self.legGen + 1
  self.legs = nil
  self.last = nil
  persist:delete(SHOWN_PERSIST_KEY)
  self.fade = nil
end

--- Ask the controller for its whole state; it comes back as a report.
function Adapter:refresh()
  if self.refreshState then
    self.refreshState()
  end
end

--- The controller has no page that shows the light's on levels or color temperature.
--- @param shown LightShown
function Adapter:show(shown) end

return Adapter
