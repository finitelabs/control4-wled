--- The controller as its pushes describe it.
---
--- Fed every state and info the controller sends (GET /json/si, each WebSocket push), keeps
--- what later layers read: identity, LED count, segments with their capability bits, the
--- controller's own bits, and the counters that say when the effect, palette or preset lists
--- changed. Each update returns what changed, so callers act only on real changes.

--- Capability bits, as WLED's const.h names them.
local CAP_RGB, CAP_WHITE, CAP_CCT = 0x01, 0x02, 0x04

--- Integrator-facing words for each combination of capability bits.
local CAP_LABELS = {
  [0] = "On/off",
  "RGB",
  "White",
  "RGBW",
  "CCT",
  "RGB, CCT",
  "Tunable white",
  "RGB, tunable white",
}

--- @class WledSegment
--- @field id integer WLED's segment id.
--- @field start integer First LED.
--- @field stop integer One past the last LED.
--- @field name string|nil The segment's name, when it has one.
--- @field on boolean The segment's own power.
--- @field bri integer The segment's own brightness, 0 to 255.
--- @field lc integer Capability bits.

--- @class WledDevice
--- @field mac string|nil 12 lower-case hex digits.
--- @field name string|nil The controller's name.
--- @field ver string|nil Firmware version, for example "16.0.1".
--- @field vid integer|nil Firmware build id.
--- @field arch string|nil Chip, for example "esp32" or "esp8266".
--- @field brand string|nil
--- @field product string|nil
--- @field ledCount integer|nil
--- @field lc integer|nil The controller's own capability bits.
--- @field segments WledSegment[] Active segments in the controller's order.
--- @field fxcount integer|nil
--- @field palcount integer|nil
--- @field cpalcount integer|nil Custom palettes, which the palette list numbers from info.
--- @field pmt integer|nil Presets file modified time; moves on every preset save or delete.
--- @field live boolean Whether another system is streaming to the LEDs.
--- @field on boolean|nil Master power.
--- @field bri integer|nil Master brightness.
local Device = {}
Device.__index = Device

Device.CAP_RGB, Device.CAP_WHITE, Device.CAP_CCT = CAP_RGB, CAP_WHITE, CAP_CCT

--- @return WledDevice
function Device.new()
  return setmetatable({ segments = {}, live = false }, Device)
end

--- Whether a capability value has a bit set.
--- @param lc integer|nil
--- @param bit integer
--- @return boolean
function Device.has(lc, bit)
  return type(lc) == "number" and math.floor(lc / bit) % 2 == 1
end

--- Integrator-facing words for a capability value.
--- @param lc integer|nil
--- @return string
function Device.capabilityLabel(lc)
  return CAP_LABELS[(tonumber(lc) or 0) % 8] or "On/off"
end

--- Whether a version string is the 16 line or later, where segments carry their own bits.
--- @param ver string|nil
--- @return boolean
function Device.isV16(ver)
  local major = tonumber(tostring(ver or ""):match("^(%d+)"))
  return major ~= nil and major >= 16
end

local function integer(v)
  local n = tonumber(v)
  if n == nil or n ~= n then
    return nil
  end
  return math.floor(n)
end

local function str(v)
  if type(v) ~= "string" or v == "" then
    return nil
  end
  return v
end

--- Segments from a state, with their capability bits. A 16.x segment carries its own `lc`;
--- 0.15 lists the bits in info.leds.seglc by position among active segments, not by id.
--- @param state table
--- @param info table|nil
--- @return WledSegment[]
local function readSegments(state, info)
  local segs = {}
  local seglc = info and info.leds and info.leds.seglc
  local position = 0
  for _, s in ipairs(type(state.seg) == "table" and state.seg or {}) do
    local start, stop = integer(s.start) or 0, integer(s.stop) or 0
    if stop > start then
      position = position + 1
      local lc = integer(s.lc)
      if lc == nil and type(seglc) == "table" then
        lc = integer(seglc[position])
      end
      segs[#segs + 1] = {
        id = integer(s.id) or (position - 1),
        start = start,
        stop = stop,
        name = str(s.n),
        on = s.on ~= false,
        bri = integer(s.bri) or 255,
        lc = lc or 0,
      }
    end
  end
  return segs
end

local function sameSegments(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.id ~= y.id or x.start ~= y.start or x.stop ~= y.stop or x.name ~= y.name or x.lc ~= y.lc then
      return false
    end
  end
  return true
end

local function sameSegmentState(a, b)
  for i = 1, math.min(#a, #b) do
    if a[i].on ~= b[i].on or a[i].bri ~= b[i].bri then
      return false
    end
  end
  return #a == #b
end

--- @class WledChanges
--- @field first boolean The first update this model has seen.
--- @field identity boolean Name, firmware, chip, brand or product changed.
--- @field mac boolean The MAC changed.
--- @field leds boolean LED count or the controller's own bits changed.
--- @field segments boolean Segment layout, names or bits changed.
--- @field segmentState boolean A segment's own power or brightness changed.
--- @field master boolean Master power or brightness changed.
--- @field effects boolean The effect count changed.
--- @field palettes boolean The palette or custom palette count changed.
--- @field presets boolean The presets file changed.
--- @field live boolean Live data started or stopped.

--- Take a state and info, as a push or /json/si carries them. Either may be nil: a reply to a
--- state-only request carries no info, and the model keeps what it last knew.
--- @param state table|nil
--- @param info table|nil
--- @return WledChanges changes
function Device:update(state, info)
  local c = {
    first = self.seen ~= true,
    identity = false,
    mac = false,
    leds = false,
    segments = false,
    segmentState = false,
    master = false,
    effects = false,
    palettes = false,
    presets = false,
    live = false,
  }
  self.seen = true

  if type(info) == "table" then
    local mac = str(info.mac) and string.lower(info.mac) or nil
    if mac ~= self.mac then
      c.mac, self.mac = true, mac
    end
    local identity = {
      name = str(info.name),
      ver = str(info.ver),
      vid = integer(info.vid),
      arch = str(info.arch),
      brand = str(info.brand),
      product = str(info.product),
    }
    for k, v in pairs(identity) do
      if self[k] ~= v then
        c.identity, self[k] = true, v
      end
    end
    local leds = type(info.leds) == "table" and info.leds or {}
    local count, lc = integer(leds.count), integer(leds.lc)
    if count ~= self.ledCount or lc ~= self.lc then
      c.leds, self.ledCount, self.lc = true, count, lc
    end
    local fxcount, palcount = integer(info.fxcount), integer(info.palcount)
    if fxcount ~= self.fxcount then
      c.effects, self.fxcount = true, fxcount
    end
    local cpalcount = integer(info.cpalcount)
    if palcount ~= self.palcount or cpalcount ~= self.cpalcount then
      c.palettes, self.palcount, self.cpalcount = true, palcount, cpalcount
    end
    local pmt = type(info.fs) == "table" and integer(info.fs.pmt) or nil
    if pmt ~= self.pmt then
      c.presets, self.pmt = true, pmt
    end
    local live = info.live == true
    if live ~= self.live then
      c.live, self.live = true, live
    end
    self.info = info
  end

  if type(state) == "table" then
    local on = state.on
    if type(on) ~= "boolean" then
      on = self.on
    end
    local bri = integer(state.bri) or self.bri
    if on ~= self.on or bri ~= self.bri then
      c.master, self.on, self.bri = true, on, bri
    end
    if state.seg ~= nil then
      local segs = readSegments(state, info or self.info)
      if not sameSegments(segs, self.segments) then
        c.segments = true
      elseif not sameSegmentState(segs, self.segments) then
        c.segmentState = true
      end
      self.segments = segs
    end
    self.state = state
  end

  return c
end

--- The segment with an id, if active.
--- @param id integer
--- @return WledSegment|nil
function Device:segment(id)
  for _, s in ipairs(self.segments) do
    if s.id == id then
      return s
    end
  end
  return nil
end

--- A short line per segment for Composer, LED ranges inclusive: "0: 0-59 RGBW; 1: 60-60 RGB, tunable white".
--- @return string
function Device:segmentSummary()
  local parts = {}
  for _, s in ipairs(self.segments) do
    local label = s.name and (s.name .. " ") or ""
    parts[#parts + 1] = string.format("%d: %s%d-%d %s", s.id, label, s.start, s.stop - 1, Device.capabilityLabel(s.lc))
  end
  if #parts == 0 then
    return "None"
  end
  return table.concat(parts, "; ")
end

--- The MAC as Composer shows it, colon separated and upper case.
--- @return string|nil
function Device:macDisplay()
  if not self.mac or #self.mac ~= 12 then
    return self.mac
  end
  return string.upper((self.mac:gsub("(%x%x)", "%1:"):gsub(":$", "")))
end

return Device
