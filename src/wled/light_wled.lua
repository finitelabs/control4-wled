--- The WLED controller's light for the light model (wled.light): the
--- controller's master power and level, and the color of every segment,
--- translated between WLED's JSON state and the model's channel fields. A
--- segment light runs it over a controller that holds just its segment
--- (wled.segment).
---
--- WLED behavior this follows (wled00/json.cpp, led.cpp and FX_fcn.cpp at
--- v16.0.1 and v0.15.4):
---   - `tt` is whole tenths of a second, kept as 16-bit milliseconds, so one
---     command carries at most 65.5 s; longer fades go as legs on one line.
---   - Brightness fades in a straight line from where the output is.
---   - The controller reports a command's target at once, and pushes at most
---     once a second.
---   - CCT is 0 (warm) to 255 (cool); the strip's real white points are the
---     installer's Warm White and Cool White.
---   - `{"on":true,"bri":N,"tt":T}` from off fades up from nothing by itself.

require("lib.utils")

local light = require("wled.light")
local Device = require("wled.device")

local CM = light.ColorMode

local TT_MAX = 655
local LEG_MS = TT_MAX * 100
--- How long a level or color sent waits for the controller's report of it before the light
--- model takes the report it has; WLED pushes at most once a second.
local ECHO_WAIT_MS = 2500
--- The longest ramp rate offered, in ms over the full range; legs carry a fade past 65.5 s.
local RATE_MAX = 86400000

local COLOR_FIELDS = { "rgb", "color_brightness", "white", "color_temperature", "color_mode" }

--- @class WledLight
--- @field device WledDevice The controller's model.
--- @field sendJson fun(json: table) Sends a JSON state command to the controller.
--- @field warm fun(): number Warm White, in Kelvin.
--- @field cool fun(): number Cool White, in Kelvin.
--- @field rgb number[] The last full color sent or reported, 0-1 per channel.
--- @field legGen integer Bumped by every command, so legs of an older fade stop.
--- @field legs table|nil The fade going out in legs: the leg in flight and the fade's end.
--- @field out table|nil The last fade sent: from, to (0-255), its start time and length.
--- @field fields table|nil Color brightness, white and color temperature last sent or reported.
--- @field cct integer|nil The CCT (0-255) last sent.
--- @field lastCol integer[]|nil The main segment's color (0-255) at the last report.
--- @field extras boolean Whether the light has an Extras menu.
local Adapter = {}
Adapter.__index = Adapter

--- @class WledLightOptions
--- @field send fun(json: table) Sends a JSON state command to the controller.
--- @field device WledDevice The controller's model.
--- @field warm fun(): number Warm White, in Kelvin.
--- @field cool fun(): number Cool White, in Kelvin.
--- @field extras boolean|nil False for a light without an Extras menu.

local function byte(v)
  return InRange(round((tonumber(v) or 0) * 255), 0, 255)
end

--- Creates the adapter for one light.
--- @param opts WledLightOptions The controller's model, its send, and the white points.
--- @return WledLight wledLight An adapter at full white, nothing sent yet.
function Adapter:new(opts)
  local instance = setmetatable({}, self)
  instance.sendJson = opts.send
  instance.device = opts.device
  instance.warm = opts.warm
  instance.cool = opts.cool
  instance.extras = opts.extras ~= false
  instance.legGen = 0
  instance.rgb = { 1, 1, 1 }
  return instance
end

--- The light model's adapter table for this light.
--- @return table adapter What light.attach takes: send, normalize, curve, echo wait and capabilities.
function Adapter:adapter()
  return {
    send = function(cmd)
      self:send(cmd)
    end,
    normalize = function(cmd)
      self:normalize(cmd)
    end,
    curve = function(p)
      return p
    end,
    echoWaitMs = ECHO_WAIT_MS,
    capabilities = {
      brightness_rate_max = RATE_MAX,
      color_rate_max = RATE_MAX,
      -- Effects, palettes, presets and playlists (src/wled/extras.lua).
      has_extras = self.extras,
    },
  }
end

--- The light model's color mode for capability bits.
--- @param lc integer|nil Capability bits; nil has none.
--- @return integer mode A light.ColorMode value.
function Adapter.modeFor(lc)
  local rgb, white, cct =
    Device.has(lc, Device.CAP_RGB), Device.has(lc, Device.CAP_WHITE), Device.has(lc, Device.CAP_CCT)
  if rgb then
    if cct then
      return CM.COLOR_MODE_RGB_COLOR_TEMPERATURE
    end
    return white and CM.COLOR_MODE_RGB_WHITE or CM.COLOR_MODE_RGB
  end
  if cct then
    return CM.COLOR_MODE_COLOR_TEMPERATURE
  end
  return white and CM.COLOR_MODE_BRIGHTNESS or CM.COLOR_MODE_ON_OFF
end

--- The light model's color mode for the controller's own capability bits.
--- @return integer mode A light.ColorMode value.
function Adapter:mode()
  return Adapter.modeFor(self.device.lc or 0)
end

--- Whether the strip has white LEDs of its own.
--- @return boolean white True when the controller's bits include white.
function Adapter:whiteLeds()
  return Device.has(self.device.lc, Device.CAP_WHITE)
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

--- The light as the light model reads it: one color mode and the mireds the
--- installer's white points give.
--- @return table entity The supported color modes and mired range.
function Adapter:entity()
  local warm, cool = self:range()
  return { supported_color_modes = { self:mode() }, min_mireds = 1e6 / cool, max_mireds = 1e6 / warm }
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

--- Channel fields for 0-255 channels and a CCT, as the controller reports them.
--- RGB that reads all off keeps the last color sent, as the white side of a
--- combined mode keeps it.
--- @param r integer Red, 0-255.
--- @param g integer Green, 0-255.
--- @param b integer Blue, 0-255.
--- @param w integer White, 0-255.
--- @param cct number 0 (warm) to 255 (cool).
--- @return table fields The light model's channel fields.
function Adapter:fieldsFrom(r, g, b, w, cct)
  local mode = self:mode()
  local f = {
    color_mode = mode,
    color_brightness = 0,
    red = self.rgb[1],
    green = self.rgb[2],
    blue = self.rgb[3],
    white = 0,
    color_temperature = 0,
    cold_white = 0,
    warm_white = 0,
  }
  local hasRgb = mode == CM.COLOR_MODE_RGB
    or mode == CM.COLOR_MODE_RGB_WHITE
    or mode == CM.COLOR_MODE_RGB_COLOR_TEMPERATURE
  if hasRgb then
    local whiteLeds = self:whiteLeds()
    if mode == CM.COLOR_MODE_RGB_COLOR_TEMPERATURE and not whiteLeds and r > 0 and r == g and g == b then
      -- A strip without white LEDs shows its white on all three.
      f.white = r / 255
    else
      local m = math.max(r, g, b)
      if m > 0 then
        f.red, f.green, f.blue = r / m, g / m, b / m
        f.color_brightness = m / 255
      end
      if whiteLeds then
        f.white = w / 255
      end
    end
  end
  if mode == CM.COLOR_MODE_RGB_COLOR_TEMPERATURE or mode == CM.COLOR_MODE_COLOR_TEMPERATURE then
    f.color_temperature = 1e6 / self:kelvinFromCct(cct)
  end
  return f
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

--- Whether a command sets any color or white channel.
local function setsColor(cmd)
  for _, field in ipairs(COLOR_FIELDS) do
    if cmd["has_" .. field] then
      return true
    end
  end
  return false
end

--- The 0-255 channels and CCT a command lights, its channels over the light's.
--- @param cmd table A command in channel fields.
--- @return integer r Red, 0-255.
--- @return integer g Green, 0-255.
--- @return integer b Blue, 0-255.
--- @return integer w White, 0-255.
--- @return integer cct 0 (warm) to 255 (cool).
function Adapter:render(cmd)
  local cur = self.fields or {}
  local function take(field, default)
    if cmd["has_" .. field] and cmd[field] ~= nil then
      return cmd[field]
    end
    if cur[field] ~= nil then
      return cur[field]
    end
    return default
  end
  local red, green, blue = self.rgb[1], self.rgb[2], self.rgb[3]
  if cmd.has_rgb then
    red, green, blue = cmd.red or 0, cmd.green or 0, cmd.blue or 0
  end
  local cb = take("color_brightness", 1)
  local white = take("white", 0)
  local ct = take("color_temperature", 0)
  local mode = self:mode()
  local r, g, b, w = byte(red * cb), byte(green * cb), byte(blue * cb), 0
  if mode == CM.COLOR_MODE_COLOR_TEMPERATURE or mode == CM.COLOR_MODE_BRIGHTNESS then
    r, g, b, w = 0, 0, 0, 255
  elseif mode == CM.COLOR_MODE_RGB_WHITE then
    w = byte(white)
  elseif mode == CM.COLOR_MODE_RGB_COLOR_TEMPERATURE then
    if self:whiteLeds() then
      w = byte(white)
    elseif white > 0 and cb <= 0 then
      r, g, b = byte(white), byte(white), byte(white)
    end
  end
  local cct = ct > 0 and self:cctFromKelvin(1e6 / ct) or (self.cct or 127)
  return r, g, b, w, cct
end

--- Round a command to what the controller will report back, so the light
--- model takes its report as the command's own.
--- @param cmd table A command in channel fields, changed in place.
function Adapter:normalize(cmd)
  if cmd.has_brightness and (tonumber(cmd.brightness) or 0) > 0 then
    cmd.brightness = math.max(1, byte(cmd.brightness)) / 255
  end
  if not setsColor(cmd) then
    return
  end
  if cmd.has_rgb then
    self.rgb = { cmd.red or 0, cmd.green or 0, cmd.blue or 0 }
  end
  local f = self:fieldsFrom(self:render(cmd))
  if cmd.has_rgb then
    cmd.red, cmd.green, cmd.blue = f.red, f.green, f.blue
    self.rgb = { f.red, f.green, f.blue }
  end
  for _, field in ipairs({ "color_brightness", "white", "color_temperature" }) do
    if cmd["has_" .. field] then
      cmd[field] = f[field]
    end
  end
end

--- The JSON for a command's color: every segment, its effect stopped.
--- @param cmd table A command in channel fields.
--- @return table seg The seg value: an entry per segment, or one object when none are listed.
--- @return integer r Red, 0-255.
--- @return integer g Green, 0-255.
--- @return integer b Blue, 0-255.
--- @return integer w White, 0-255.
--- @return integer cct 0 (warm) to 255 (cool).
function Adapter:colorJson(cmd)
  local r, g, b, w, cct = self:render(cmd)
  local col = self:whiteLeds() and { r, g, b, w } or { r, g, b }
  local mode = self:mode()
  local withCct = mode == CM.COLOR_MODE_RGB_COLOR_TEMPERATURE or mode == CM.COLOR_MODE_COLOR_TEMPERATURE
  local segs = {}
  for _, seg in ipairs(self.device.segments or {}) do
    segs[#segs + 1] = { id = seg.id, col = { col }, fx = 0, cct = withCct and cct or nil }
  end
  if #segs == 0 then
    segs = { col = { col }, fx = 0, cct = withCct and cct or nil }
  end
  return segs, r, g, b, w, cct
end

--- Remember what a command sets, for the next one's channels.
--- @param cmd table A command in channel fields.
function Adapter:apply(cmd)
  local cur = self.fields or {}
  for _, field in ipairs({ "color_brightness", "white", "color_temperature" }) do
    if cmd["has_" .. field] then
      cur[field] = cmd[field]
    end
  end
  self.fields = cur
end

--- Master brightness (0-255) the output is at now, on the straight line of the
--- last fade sent.
--- @param now number The time, from C4:GetTime().
--- @return number bri The master brightness, 0-255.
function Adapter:outputBri(now)
  local out = self.out
  if not out then
    return self.device.on and (self.device.bri or 0) or 0
  end
  local p = out.ms > 0 and InRange((now - out.t0) / out.ms, 0, 1) or 1
  return out.from + (out.to - out.from) * p
end

--- Send a command in channel fields to the controller.
--- @param cmd table A command in channel fields.
function Adapter:send(cmd)
  self.legGen = self.legGen + 1
  self.legs = nil
  local now = C4:GetTime()
  local color = setsColor(cmd)
  if cmd.preOn then
    -- The controller fades up from off by itself: only the color goes first.
    if color then
      local seg = self:colorJson(cmd)
      self:apply(cmd)
      self.sendJson({ seg = seg, tt = 0 })
    end
    return
  end
  local json = {}
  if cmd.has_state then
    json.on = cmd.state
  end
  local bri
  if cmd.has_brightness and cmd.state ~= false and (tonumber(cmd.brightness) or 0) > 0 then
    bri = math.max(1, byte(cmd.brightness))
    json.bri = bri
  end
  local seg, r, g, b, w, cct
  if color then
    seg, r, g, b, w, cct = self:colorJson(cmd)
    json.seg = seg
    self.cct = cct
  end
  self:apply(cmd)
  -- Turning this light on from off lights the whole strip, every segment with it; a change while it
  -- is on leaves each segment as its own light set it.
  -- A preset sent just before is left to set the segments itself.
  local lightAll = json.on == true
    and not self.device.presetPending
    and not (self.device.on == true and anySegmentOn(self.device))
  if lightAll then
    json.seg = withAllOn(json.seg, self.device)
  end
  local ms = cmd.has_transition_length and (tonumber(cmd.transition_length) or 0) or nil
  local from = self:outputBri(now)
  local to = cmd.state == false and 0 or bri or from
  self.out = { from = from, to = to, t0 = now, ms = ms or 0 }
  if ms and ms > LEG_MS then
    self:startLegs(json, ms, from, to, color and { r, g, b, w } or nil, now, lightAll)
    return
  end
  if ms then
    json.tt = round(ms / 100)
  end
  self.sendJson(json)
end

--- A fade longer than one command carries, as legs along one straight line.
--- @param json table The whole command, which the last leg sends.
--- @param ms number The fade's length.
--- @param fromBri number Master brightness (0-255) the fade starts from.
--- @param toBri number Master brightness (0-255) the fade ends at.
--- @param toCol integer[]|nil The color (0-255 channels) the fade ends at; nil when it sets none.
--- @param now number The fade's start, from C4:GetTime().
--- @param lightAll boolean Whether the first leg turns every segment on.
function Adapter:startLegs(json, ms, fromBri, toBri, toCol, now, lightAll)
  local n = math.ceil(ms / LEG_MS)
  local legMs = ms / n
  local fromCol = self.lastCol or toCol
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
      if finalOn == false and fromBri >= 1 then
        -- WLED keeps bri while off: leave the level the fade started from, as a short fade does.
        part.bri = round(fromBri)
      end
    else
      part.on = finalOn ~= false or nil
      part.bri = math.max(1, round(fromBri + (toBri - fromBri) * p))
      if toCol and json.seg then
        local col = {}
        for i = 1, #toCol do
          col[i] = round((fromCol[i] or 0) + (toCol[i] - (fromCol[i] or 0)) * p)
        end
        local seg = {}
        for i, s in ipairs(json.seg) do
          seg[i] = { id = s.id, col = { self:whiteLeds() and col or { col[1], col[2], col[3] } }, fx = 0, cct = s.cct }
        end
        if #seg == 0 then
          seg = { col = { col }, fx = 0, cct = json.seg.cct }
        end
        part.seg = seg
      end
      local legCol = part.seg and (part.seg[1] or part.seg).col[1] or nil
      self.legs = {
        gen = gen,
        leg = { bri = part.bri, on = part.on ~= false, col = legCol },
        final = { on = finalOn, bri = toBri, col = toCol },
      }
    end
    if last then
      self.legs = nil
    elseif lightAll and k == 1 then
      part.seg = withAllOn(part.seg, self.device)
    end
    self.sendJson(part)
    if not last then
      delay(legMs):next(function()
        leg(k + 1)
      end)
    end
  end
  self.out = { from = fromBri, to = toBri, t0 = now, ms = ms }
  leg(1)
end

--- The light's state in channel fields, from the controller's model. A report
--- of a leg of a long fade reads as the fade's end, as a single command's does.
--- @return table state Channel fields with state and brightness.
function Adapter:state()
  local device = self.device
  local state = device.state or {}
  local seg = mainSegment(state)
  local r, g, b, w = primary(seg)
  local cct = seg and tonumber(seg.cct) or 127
  self.lastCol = { r, g, b, w }
  -- The light is on while the master is on and a segment is lit, as the strip shows.
  local on, bri = device.on == true and anySegmentOn(device), device.bri or 0
  local legs = self.legs
  if legs then
    local legCol = legs.leg.col
    local sameCol = not legCol or (legCol[1] == r and legCol[2] == g and legCol[3] == b and (legCol[4] or 0) == w)
    if on == legs.leg.on and bri == legs.leg.bri and sameCol then
      on = legs.final.on ~= false
      bri = legs.final.bri
      if legs.final.col then
        r, g, b, w = legs.final.col[1], legs.final.col[2], legs.final.col[3], legs.final.col[4] or 0
      end
    else
      -- Another client moved the light: the legs left would undo it.
      self.legGen = self.legGen + 1
      self.legs = nil
    end
  end
  -- A level that is not where the last fade was going came from another client,
  -- so the next fade starts from the report, not from the old line.
  local out = self.out
  if out and not self.legs and math.abs((on and bri or 0) - out.to) > 1 then
    self.out = nil
  end
  local f = self:fieldsFrom(r, g, b, w, cct)
  self.fields = {
    color_brightness = f.color_brightness,
    white = f.white,
    color_temperature = f.color_temperature,
  }
  if f.color_brightness > 0 then
    self.rgb = { f.red, f.green, f.blue }
  end
  f.state = on
  f.brightness = bri / 255
  return f
end

return Adapter
