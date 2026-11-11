--- The controller model: identity, segments and their capability bits from every profile the
--- mock defines, 0.15's seglc read by position, and what each update reports as changed.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_device.lua

local T = require("testlib")
local W = require("wled_fixtures")
local Device = require("wled.device")

local function load(profile)
  local si = W.fixture(profile, "si.json")
  local d = Device:new()
  local changes = d:update(si.state, si.info)
  return d, si, changes
end

local function bits(d)
  local out = {}
  for _, s in ipairs(d.segments) do
    out[#out + 1] = s.lc
  end
  return table.concat(out, ",")
end

--------------------------------------------------------------------------------
T.section("Identity and LED details from a 16.0.1 and a 0.15.4 controller")
--------------------------------------------------------------------------------
do
  local d, _, changes = load("esp32-rgbw-pwm-16")
  T.truthy("first update says first", changes.first)
  T.eq("16: version", d.ver, "16.0.1")
  T.eq("16: chip", d.arch, "esp32")
  T.eq("16: mac kept lower case", d.mac, "02a1b2c3d402")
  T.eq("16: mac for Composer", d:macDisplay(), "02:A1:B2:C3:D4:02")
  T.eq("16: brand", d.brand, "WLED")
  T.eq("16: product", d.product, "FOSS")
  T.eq("16: LED count", d.ledCount, 61)
  T.eq("16: controller bits", d.lc, 7)
  T.eq("16: effect count", d.fxcount, 220)
  T.eq("16: palette count", d.palcount, 72)
  T.truthy("16 line detected", Device.isV16(d.ver))

  local o = load("esp8266-ws2812b-015")
  T.eq("0.15: version", o.ver, "0.15.4")
  T.eq("0.15: chip", o.arch, "esp8266")
  T.eq("0.15: effect count", o.fxcount, 187)
  T.eq("0.15: palette count", o.palcount, 71)
  T.falsy("0.15 is not the 16 line", Device.isV16(o.ver))
end

--------------------------------------------------------------------------------
T.section("Firmware older than 0.15 is told apart")
--------------------------------------------------------------------------------
do
  T.truthy("0.14.0", Device.isUnsupported("0.14.0"))
  T.truthy("0.13.3", Device.isUnsupported("0.13.3"))
  T.falsy("0.15.0", Device.isUnsupported("0.15.0"))
  T.falsy("a 0.15 beta", Device.isUnsupported("0.15.0-b3"))
  T.falsy("0.15.4", Device.isUnsupported("0.15.4"))
  T.falsy("16.0.1", Device.isUnsupported("16.0.1"))
  T.falsy("no version yet", Device.isUnsupported(nil))
  T.falsy("a version it cannot read", Device.isUnsupported("dev"))
end

--------------------------------------------------------------------------------
T.section("Capability bits for every segment of every profile")
--------------------------------------------------------------------------------
do
  -- What each profile's segments light, from the mock's model of WLED's capability rules.
  local want = {
    ["dig2go-rgbw-015"] = "3",
    ["dig2go-rgbw-16"] = "3",
    ["esp32-cct-16"] = "6",
    ["esp32-matrix-16"] = "1",
    ["esp32-relay-16"] = "0",
    ["esp32-rgb-wb-16"] = "5",
    ["esp32-rgbw-015"] = "3",
    ["esp32-rgbw-accurate-16"] = "1",
    ["esp32-rgbw-pwm-16"] = "3,7",
    ["esp32-white-16"] = "2",
    ["esp32s3-64seg-16"] = "1",
    ["esp8266-ws2812b-015"] = "1",
    ["esp8266-ws2812b-015-nofade"] = "1",
  }
  local profiles = W.profiles()
  T.eq("every profile has an expectation", #profiles, 13)
  for _, profile in ipairs(profiles) do
    local d, si = load(profile)
    T.eq(profile .. ": segment bits", bits(d), want[profile])
    -- 16 carries each segment's own bits; 0.15 only lists them in info.leds.seglc.
    local v16 = Device.isV16(si.info.ver)
    T.eq(profile .. ": bits source", si.state.seg[1].lc ~= nil, v16)
  end
end

--------------------------------------------------------------------------------
T.section("0.15 seglc is read by position among active segments, not by id")
--------------------------------------------------------------------------------
do
  local si = W.fixture("esp32-rgbw-015", "si.json")
  -- Segment 1 deleted: ids 0 and 2 are active, and seglc lists them in that order.
  si.state.seg = {
    { id = 0, start = 0, stop = 10, on = true, bri = 255 },
    { id = 2, start = 20, stop = 30, on = true, bri = 255 },
  }
  si.info.leds.seglc = { 3, 1 }
  local d = Device:new()
  d:update(si.state, si.info)
  T.eq("two active segments", #d.segments, 2)
  T.eq("id 2 takes the second entry", d:segment(2).lc, 1)
  T.eq("id 0 takes the first entry", d:segment(0).lc, 3)
  T.eq("no segment 1", d:segment(1), nil)

  -- An inactive segment (stop not past start) in the list takes no position.
  si.state.seg = {
    { id = 0, start = 0, stop = 10 },
    { id = 1, start = 0, stop = 0 },
    { id = 2, start = 20, stop = 30 },
  }
  d = Device:new()
  d:update(si.state, si.info)
  T.eq("inactive segment skipped", #d.segments, 2)
  T.eq("id 2 still takes the second entry", d:segment(2).lc, 1)
end

--------------------------------------------------------------------------------
T.section("Each update reports only what changed")
--------------------------------------------------------------------------------
do
  local d, si = load("esp32-rgbw-pwm-16")
  local c = d:update(si.state, si.info)
  T.falsy("same push: not first", c.first)
  for _, key in ipairs({
    "identity",
    "mac",
    "leds",
    "segments",
    "effects",
    "palettes",
    "presets",
  }) do
    T.falsy("same push: no " .. key .. " change", c[key])
  end

  si.state.bri = 10
  c = d:update(si.state, nil)
  T.falsy("a state alone keeps identity", c.identity)
  T.eq("info kept from before", d.ver, "16.0.1")

  si.state.seg[1].bri = 3
  c = d:update(si.state, si.info)
  T.falsy("segment brightness is not layout", c.segments)

  si.state.seg[2].stop = 70
  c = d:update(si.state, si.info)
  T.truthy("segment range change is layout", c.segments)

  si.info.fs.pmt = 1793500000
  c = d:update(nil, si.info)
  T.truthy("presets file change seen", c.presets)

  si.info.fxcount = 221
  si.info.palcount = 73
  c = d:update(nil, si.info)
  T.truthy("effect count change seen", c.effects)
  T.truthy("palette count change seen", c.palettes)

  si.info.mac = "02A1B2C3D4FF"
  c = d:update(nil, si.info)
  T.truthy("mac change seen", c.mac)
  T.eq("mac normalized", d.mac, "02a1b2c3d4ff")
end

--------------------------------------------------------------------------------
T.section("Segments as Composer shows them")
--------------------------------------------------------------------------------
do
  local d = load("esp32-rgbw-pwm-16")
  T.eq(
    "two segments, ranges and what they light",
    d:segmentSummary(),
    "0: Strip 0-59 RGBW; 1: Accent 60-60 RGB, tunable white"
  )
  local r = load("esp32-relay-16")
  T.eq("relay", r:segmentSummary(), "0: 0-0 On/off")
  local si = W.fixture("esp32-cct-16", "si.json")
  si.state.seg[1].n = "Cabinets"
  local c = Device:new()
  c:update(si.state, si.info)
  T.contains("named segment shows its name", c:segmentSummary(), "0: Cabinets 0-")
  T.eq("no segments", Device:new():segmentSummary(), "None")
  T.eq("label for each bit combination", Device.capabilityLabel(4), "CCT")
  T.eq("unknown bits", Device.capabilityLabel(nil), "On/off")
end

T.finish()
