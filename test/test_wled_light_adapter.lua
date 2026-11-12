--- The WLED light adapter on its own, against a hand-built controller model: the JSON each library
--- command puts on the wire (levels, colors on every strip type, all segments on, the rated on from
--- off, stops, long fades in legs) and the report each controller state gives back (echoes of the
--- latest command within a byte, and another client's change mid-legs).
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_light_adapter.lua

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")

local Adapter = require("wled.light_wled")
local Color = require("lib.light.color")
local Device = require("wled.device")

local RGB, WHITE, CCT = Device.CAP_RGB, Device.CAP_WHITE, Device.CAP_CCT

--- A controller model as the adapter reads it.
--- @param lc integer Capability bits.
--- @param opts table|nil on, bri, segments (count), off (segment ids off), presetPending.
local function model(lc, opts)
  opts = opts or {}
  local off = {}
  for _, id in ipairs(opts.off or {}) do
    off[id] = true
  end
  local segments, seg = {}, {}
  for i = 1, opts.segments or 2 do
    local id = i - 1
    segments[i] = { id = id, start = id * 30, stop = (id + 1) * 30, on = not off[id], lc = lc }
    seg[i] = { id = id, start = id * 30, stop = (id + 1) * 30, col = { { 255, 255, 255, 0 } }, cct = 127 }
  end
  return {
    lc = lc,
    on = opts.on ~= false,
    bri = opts.bri or 255,
    segments = segments,
    state = { seg = seg, mainseg = 0 },
    presetPending = opts.presetPending,
  }
end

local sent, refreshed = {}, 0

local function adapter(device, warm, cool)
  sent = {}
  W.clearTimers()
  require("lib.persist"):delete("WledLightShownColor")
  return Adapter:new({
    device = device,
    send = function(json)
      sent[#sent + 1] = json
    end,
    refresh = function()
      refreshed = refreshed + 1
    end,
    warm = function()
      return warm or 2700
    end,
    cool = function()
      return cool or 6500
    end,
  })
end

--- A LightCommand: a change on an on light, setting nothing, unless the fields say otherwise.
local function cmd(fields)
  local c = {
    kind = "change",
    on = true,
    fromOff = false,
    level = 1,
    setsLevel = false,
    setsColor = false,
    transitionMs = 0,
    from = { level = 1 },
    colorUnchosen = false,
  }
  for k, v in pairs(fields or {}) do
    c[k] = v
  end
  return c
end

local function xy(x, y)
  return { x = x, y = y, mode = "xy" }
end

local function kelvin(k)
  local x, y = C4:ColorCCTtoXY(k)
  return { x = x, y = y, mode = "cct", kelvin = k }
end

local RED = xy(0.64, 0.33)
local GREEN = xy(0.17, 0.70)

--- The controller now shows these on every segment.
local function shows(device, s)
  if s.bri then
    device.bri = s.bri
  end
  if s.on ~= nil then
    device.on = s.on
  end
  for _, seg in ipairs(device.state.seg) do
    if s.col then
      seg.col = { s.col }
    end
    if s.cct then
      seg.cct = s.cct
    end
  end
end

local function bris()
  local out = {}
  for _, json in ipairs(sent) do
    out[#out + 1] = json.bri or false
  end
  return out
end

--------------------------------------------------------------------------------
T.section("a level goes to master brightness, with the command's fade time")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  a:send(cmd({ level = 0.8, setsLevel = true }))
  T.eq("at once", sent[1], { on = true, bri = 204, tt = 0 })
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 4000 }))
  T.eq("over 4 s", sent[2], { on = true, bri = 255, tt = 40 })
  a:send(cmd({ level = 0.001, setsLevel = true }))
  T.eq("the lowest level is 1, never 0", sent[3].bri, 1)
  a:send(cmd({ on = false, level = 0.8, setsLevel = true, transitionMs = 2000 }))
  T.eq("off carries no level: WLED keeps its own", sent[4], { on = false, tt = 20 })
  a:send(cmd({ level = 0.5, setsColor = true, color = RED }))
  T.eq("a color alone leaves the level and the power", { sent[5].bri, sent[5].on }, { nil, nil })
  a:send(cmd({ on = false, level = 0.8, setsColor = true, color = RED }))
  T.eq("a color while off stays off and only takes the color", { sent[6].on, sent[6].bri }, { nil, nil })
  T.truthy("and carries the color", sent[6].seg ~= nil)
  -- Dim-To-Warm: an off fades to its Dim color as it goes dark.
  a:send(cmd({ on = false, level = 0.8, setsLevel = true, setsColor = true, color = RED, transitionMs = 2000 }))
  T.eq("an off with its Dim color goes off over its time", { sent[7].on, sent[7].bri, sent[7].tt }, { false, nil, 20 })
  T.truthy("fading to that color as it goes", sent[7].seg ~= nil and sent[7].seg[1].col[1][1] == 255)
end

--------------------------------------------------------------------------------
T.section("a color goes to every segment and ends its effect")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = RED }))
  local json = sent[1]
  T.eq("every segment", { json.seg[1].id, json.seg[2].id }, { 0, 1 })
  T.eq("its effect stopped", { json.seg[1].fx, json.seg[2].fx }, { 0, 0 })
  local col = json.seg[1].col[1]
  T.eq("RGBW: four channels, white off", { #col, col[4] }, { 4, 0 })
  T.truthy("red is red", col[1] == 255 and col[3] < 64, T.show(col))
  T.eq("no CCT on a strip without it", json.seg[1].cct, nil)
  a = adapter(model(RGB))
  a:send(cmd({ setsColor = true, color = GREEN }))
  T.eq("RGB: three channels", #sent[1].seg[1].col[1], 3)
  a = adapter(model(RGB, { segments = 0 }))
  a:send(cmd({ setsColor = true, color = RED }))
  T.eq("a controller listing no segments gets one object", sent[1].seg.fx, 0)
end

--------------------------------------------------------------------------------
T.section("a color temperature on a tunable white strip sets its CCT between the white points")
--------------------------------------------------------------------------------
do
  local a = adapter(model(WHITE + CCT))
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  local seg = sent[1].seg[1]
  -- (4000 - 2700) / (6500 - 2700) of 255.
  T.truthy("4000 K is CCT 87", math.abs(seg.cct - 87) <= 1, seg.cct)
  T.eq("on the white LEDs", seg.col[1], { 0, 0, 0, 255 })
  a = adapter(model(WHITE + CCT), 2000, 6000)
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  T.truthy("other white points move it: CCT 128", math.abs(sent[1].seg[1].cct - 128) <= 1, sent[1].seg[1].cct)
end

--------------------------------------------------------------------------------
T.section("a white on an RGB strip with CCT goes to its white LEDs, or all three without them")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE + CCT))
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  T.eq("white LEDs", sent[1].seg[1].col[1], { 0, 0, 0, 255 })
  T.truthy("at its CCT", math.abs(sent[1].seg[1].cct - 87) <= 1, sent[1].seg[1].cct)
  a = adapter(model(RGB + CCT))
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  T.eq("no white LEDs: all three", sent[1].seg[1].col[1], { 255, 255, 255 })
  T.truthy("at its CCT", math.abs(sent[1].seg[1].cct - 87) <= 1, sent[1].seg[1].cct)
  a = adapter(model(RGB + WHITE + CCT))
  a:report()
  a.device.state.seg[1].cct = 200
  a:report()
  a:send(cmd({ setsColor = true, color = RED }))
  T.eq("a full color keeps the CCT the controller showed", sent[1].seg[1].cct, 200)
  T.eq("and lights the color LEDs", sent[1].seg[1].col[1][4], 0)
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  a:send(cmd({ setsColor = true, color = RED }))
  T.eq("or the one last sent, before any report", sent[3].seg[1].cct, sent[2].seg[1].cct)
end

--------------------------------------------------------------------------------
T.section("an RGBW strip shows a white near the white locus on its white LEDs")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  local x, y = C4:ColorCCTtoXY(4000)
  a:send(cmd({ setsColor = true, color = xy(x, y) }))
  T.eq("a full color on the locus", sent[1].seg[1].col[1], { 0, 0, 0, 255 })
  -- Offsets square to the locus near 4000 K, whose direction toward warm is about (0.897, 0.440) in xy.
  local function off(d)
    return xy(x - 0.440 * d, y + 0.897 * d)
  end
  a:send(cmd({ setsColor = true, color = off(0.03) }))
  T.eq("one off it shows in RGB", sent[2].seg[1].col[1][4], 0)
  a:send(cmd({ setsColor = true, color = off(0.004) }))
  T.eq("one near it is on it", sent[#sent].seg[1].col[1], { 0, 0, 0, 255 })
  a:send(cmd({ setsColor = true, color = off(0.010) }))
  T.eq("so is one inside the library's white band, past the old 0.005", sent[#sent].seg[1].col[1], { 0, 0, 0, 255 })
  a:send(cmd({ setsColor = true, color = off(0.016) }))
  T.eq("one just past the band shows in RGB", sent[#sent].seg[1].col[1][4], 0)
  x, y = C4:ColorCCTtoXY(9000)
  a:send(cmd({ setsColor = true, color = xy(x, y) }))
  T.eq("one past Cool White shows in RGB", sent[#sent].seg[1].col[1][4], 0)
  a:send(cmd({ setsColor = true, color = kelvin(3000) }))
  T.eq("a color temperature", sent[#sent].seg[1].col[1], { 0, 0, 0, 255 })
end

--------------------------------------------------------------------------------
T.section("an RGB strip shows a white as its RGB")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB))
  a:send(cmd({ setsColor = true, color = kelvin(4000) }))
  local col = sent[1].seg[1].col[1]
  T.truthy("all three lit, warm", #col == 3 and col[1] == 255 and col[3] > 0 and col[3] < 255, T.show(col))
end

--------------------------------------------------------------------------------
T.section("on from off lights every segment, unless a preset just sent sets them")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB, { on = false, off = { 1 } }))
  a:send(cmd({ fromOff = true, level = 0.5, setsLevel = true }))
  T.eq("the segment that was off is turned on", sent[1].seg, { { id = 1, on = true } })
  T.eq("at the command's level", sent[1].bri, 128)
  a:send(cmd({ fromOff = true, level = 0.5, setsLevel = true, setsColor = true, color = RED }))
  T.eq("with a color, the same entries", { sent[2].seg[1].on, sent[2].seg[2].on }, { nil, true })
  a = adapter(model(RGB, { on = false, off = { 1 }, presetPending = true }))
  a:send(cmd({ fromOff = true, level = 0.5, setsLevel = true }))
  T.eq("a preset pending sets its own", sent[1].seg, nil)
  a = adapter(model(RGB, { off = { 1 } }))
  a:send(cmd({ level = 0.5, setsLevel = true }))
  T.eq("an on controller leaves each segment as its light set it", sent[1].seg, nil)
end

--------------------------------------------------------------------------------
T.section("a rated on from off sends its color first; the controller fades up by itself")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { on = false }))
  local preOn = cmd({ kind = "preOn", fromOff = true, level = 1 / 255, setsLevel = true })
  a:send(preOn)
  T.eq("no color: nothing goes first", #sent, 0)
  preOn.setsColor, preOn.color = true, GREEN
  a:send(preOn)
  T.eq("the color, at once, the light left off", { sent[1].on, sent[1].bri, sent[1].tt }, { nil, nil, 0 })
  T.truthy("green", sent[1].seg[1].col[1][2] == 255, T.show(sent[1].seg[1].col[1]))
  a:send(cmd({ level = 0.8, setsLevel = true, setsColor = true, color = GREEN, transitionMs = 2000 }))
  T.eq("then on, to 80 over 2 s", { sent[2].on, sent[2].bri, sent[2].tt }, { true, 204, 20 })
end

--------------------------------------------------------------------------------
T.section("a stop holds where the fade got to, ends any legs, and re-times a color left running")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 200000, from = { level = 0.2 } }))
  W.run(30000)
  -- The library's estimate is 0.5; the adapter's own line has the controller 15% of the way from 51.
  local rest = a:send(cmd({ kind = "stop", level = 0.5, setsLevel = true }))
  local at = round(51 + 204 * 0.15)
  T.eq("held at once where its own fade has the controller", sent[#sent], { on = true, bri = at, tt = 0 })
  T.eq("and that place is the rest", rest and rest.level, at / 255)
  local count = #sent
  W.run(250000)
  T.eq("no leg goes after it", #sent, count)
  count = #sent
  rest = a:send(cmd({ kind = "stop", level = 0.5, setsLevel = true, color = RED, transitionMs = 3000 }))
  T.eq("with no fade of its own, a stop holds at the level it names", sent[#sent], { on = true, bri = 128, tt = 0 })
  T.eq("and rests nowhere else", rest, nil)
  W.run(1000)
  T.eq("a color the adapter has no fade for is left alone", #sent, count + 1)
end

--------------------------------------------------------------------------------
T.section("a fade longer than one command carries goes in legs on one line from where it starts")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 0.8, setsLevel = true, transitionMs = 70000, from = { level = 0.2 } }))
  T.eq("the first leg at once, halfway", { #sent, sent[1].bri, sent[1].on }, { 1, 128, true })
  W.run(34750 + 499)
  T.eq("not before 0.5 s past its end", #sent, 1)
  W.run(1)
  T.eq("then the whole command", sent[2], { on = true, bri = 204, tt = 348 })
  T.eq("each leg 34.8 s, so the fade keeps its length", sent[1].tt, 348)

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 200000, from = { level = 0.2 } }))
  W.run(201000)
  T.eq("legs on the line from 51", bris(), { 102, 153, 204, 255 })

  a = adapter(model(RGB + WHITE, { bri = 204 }))
  a:send(cmd({ on = false, level = 0.8, setsLevel = true, transitionMs = 200000, from = { level = 0.8 } }))
  W.run(201000)
  T.eq("to off: the legs leave the power", { sent[1].on, sent[2].on, sent[3].on }, { nil, nil, nil })
  T.eq("and the last turns it off, keeping the starting level", { sent[4].on, sent[4].bri }, { false, 204 })

  a = adapter(model(RGB + WHITE, { bri = 128 }))
  a:send(cmd({ on = false, level = 0.8, setsLevel = true, transitionMs = 200000, from = { level = 0.5 } }))
  W.run(201000)
  T.eq("an off keeps the level it carries, not where the fade began", sent[4].bri, 204)

  a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = GREEN }))
  a:send(cmd({ setsColor = true, color = RED }))
  local green, red = sent[1].seg[1].col[1], sent[2].seg[1].col[1]
  a = adapter(model(RGB + WHITE, { bri = 204 }))
  a:send(cmd({ setsColor = true, color = GREEN }))
  a:send(cmd({
    on = false,
    level = 0.8,
    setsLevel = true,
    setsColor = true,
    color = RED,
    transitionMs = 200000,
    from = { level = 0.8, color = GREEN },
  }))
  W.run(201000)
  local legs = { sent[2], sent[3], sent[4], sent[5] }
  local first = legs[1].seg and legs[1].seg[1].col[1]
  T.truthy(
    "a long off with its Dim color steps the color with the level",
    first and first[1] > green[1] and first[1] < red[1] and legs[2].bri < legs[1].bri,
    T.show(legs)
  )
  T.eq("its legs leave the power", { legs[1].on, legs[2].on, legs[3].on }, { nil, nil, nil })
  T.eq("and the last turns it off in the color", { legs[4].on, legs[4].seg[1].col[1] }, { false, red })

  a = adapter(model(RGB + WHITE, { on = false, bri = 128 }))
  a:send(cmd({ fromOff = true, level = 0.8, setsLevel = true, transitionMs = 70000, from = { level = 0.5 } }))
  T.eq("from off, the legs start from nothing", sent[1].bri, 102)

  a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 70000, from = { level = 1, color = GREEN } }))
  local mid = sent[1].seg[1].col[1]
  T.truthy("a color's legs pass between the two colors", mid[1] > 64 and mid[1] < 255 and mid[2] > 64, T.show(mid))
  T.eq("and leave the level and the power", { sent[1].bri, sent[1].on }, { nil, nil })
  W.run(70000)
  T.eq("and the last leg is the color", sent[2].seg[1].col[1][1], 255)
end

--------------------------------------------------------------------------------
T.section("a report is the controller's state")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 102 }))
  shows(a.device, { col = { 255, 0, 0, 0 } })
  local r = a:report()
  T.eq("an unasked push, on at the master's level", { r.kind, r.on, r.level }, { "push", true, 102 / 255 })
  T.eq("a full color", r.color and r.color.mode, "xy")
  T.truthy("red, as Control4 converts it", r.color and math.abs(r.color.x - 0.708) < 0.01, T.show(r.color))
  a.device.segments[1].on, a.device.segments[2].on = false, false
  T.eq("every segment off reads off", a:report().on, false)
  a.device.on = false
  a.device.segments[1].on = true
  T.eq("the master off reads off, keeping its level", { a:report().on, a:report().level }, { false, 102 / 255 })

  a = adapter(model(WHITE + CCT))
  shows(a.device, { col = { 0, 0, 0, 255 }, cct = 87 })
  r = a:report()
  T.eq("a tunable white reports a color temperature", r.color.mode, "cct")
  T.truthy("from the white points", math.abs(r.color.kelvin - 4000) <= 15, r.color.kelvin)

  a = adapter(model(RGB + CCT))
  shows(a.device, { col = { 200, 200, 200 }, cct = 0 })
  r = a:report()
  T.eq("all three alike on a strip without white LEDs is its white", { r.color.mode, r.color.kelvin }, { "cct", 2700 })

  a = adapter(model(RGB + WHITE))
  shows(a.device, { col = { 0, 0, 0, 255 } })
  T.eq("an RGBW strip's white LEDs alone are a white", a:report().color.mode, "cct")
  shows(a.device, { col = { 0, 0, 0, 0 } })
  T.eq("nothing lit carries no color", a:report().color, nil)

  a = adapter(model(WHITE))
  T.eq("a white-only strip carries no color", a:report().color, nil)
end

--------------------------------------------------------------------------------
T.section("a report within a byte of the latest command's wire is that command's own")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  local c = cmd({ level = 0.5, setsLevel = true })
  a:send(c)
  shows(a.device, { bri = 129 })
  T.eq("a byte off is the command's level", a:report().level, 0.5)
  shows(a.device, { bri = 130 })
  T.eq("two off is the controller's own", a:report().level, 130 / 255)

  c = cmd({ setsColor = true, color = RED })
  a:send(c)
  local col = sent[#sent].seg[1].col[1]
  shows(a.device, { col = { col[1], col[2], col[3], col[4] } })
  T.truthy("the color sent is the command's color", rawequal(a:report().color, c.color))
  shows(a.device, { col = { col[1] - 1, col[2] + 1, col[3], col[4] } })
  T.truthy("a byte off per channel still is", rawequal(a:report().color, c.color))
  shows(a.device, { col = { col[1], col[2] + 2, col[3], col[4] } })
  T.falsy("two off is the controller's own", rawequal(a:report().color, c.color))

  shows(a.device, { col = { col[1], col[2], col[3], col[4] } })
  a:report()
  a:send(cmd({ level = 0.5, setsLevel = true, color = c.color }))
  T.truthy("a level command carries the color the controller showed", rawequal(a:report().color, c.color))

  a = adapter(model(WHITE + CCT))
  c = cmd({ setsColor = true, color = kelvin(4000) })
  a:send(c)
  local cct = sent[1].seg[1].cct
  shows(a.device, { col = { 0, 0, 0, 255 }, cct = cct + 1 })
  T.truthy("a CCT a byte off is the command's white", rawequal(a:report().color, c.color))
  shows(a.device, { cct = cct + 2 })
  T.falsy("two off is the controller's own", rawequal(a:report().color, c.color))
end

--------------------------------------------------------------------------------
T.section("a leg's report is the fade's end; anything else stops the legs left")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  local c = cmd({ level = 0.8, setsLevel = true, transitionMs = 200000, from = { level = 0.2 } })
  a:send(c)
  shows(a.device, { bri = sent[1].bri })
  T.eq("the leg in flight reads as the fade's end", a:report().level, 0.8)
  W.run(49625 + 500)
  T.eq("and the legs go on", #sent, 2)
  shows(a.device, { bri = 30 })
  T.eq("another client's level is its own", a:report().level, 30 / 255)
  W.run(200000)
  T.eq("and no leg goes after it", #sent, 2)

  a = adapter(model(RGB + WHITE))
  c = cmd({ setsColor = true, color = RED, transitionMs = 140000, from = { level = 1, color = GREEN } })
  a:send(c)
  shows(a.device, { col = sent[1].seg[1].col[1] })
  T.truthy("a color leg in flight reads as the fade's color", rawequal(a:report().color, c.color))
  W.run(70000)
  T.eq("and the legs go on", #sent, 2)
end

--------------------------------------------------------------------------------
T.section("the light's facts come from the controller's bits and the white points")
--------------------------------------------------------------------------------
do
  local function facts(lc)
    local d = adapter(model(lc), 2700, 6500):lightDevice()
    return { d.dims, d.color, d.cct }
  end
  T.eq("RGB", facts(RGB), { true, true, nil })
  T.eq("RGBW", facts(RGB + WHITE), { true, true, nil })
  T.eq("tunable white", facts(WHITE + CCT), { true, false, { minK = 2700, maxK = 6500 } })
  T.eq("RGB with CCT", facts(RGB + WHITE + CCT), { true, true, { minK = 2700, maxK = 6500 } })
  T.eq("white only", facts(WHITE), { true, false, nil })
  T.eq("on/off", facts(0), { false, false, nil })
  local d = adapter(model(RGB)):lightDevice()
  T.eq(
    "a device fade in a straight line, opened from off, re-timed by every call, up to a day",
    d.fade,
    { kind = "device", curve = "linear", preOn = true, retimes = true, maxMs = 86400000 }
  )
  T.eq("reports show the target and may predate a command by 2.5 s", d.feedback, {
    shows = "target",
    waitMs = 2500,
    refresh = true,
  })
  T.eq("a color sent while off is sent; 255 steps", { d.colorWhileOff, d.levelSteps }, { "send", 255 })
end

--------------------------------------------------------------------------------
T.section("a timed command that lands mid-fade holds the light where it is, then restarts every channel")
--------------------------------------------------------------------------------
do
  -- A color fade from green to red, and 2 s in a level over 2 s.
  local a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = GREEN }))
  local green = sent[1].seg[1].col[1]
  local c = cmd({ setsColor = true, color = RED, transitionMs = 10000, from = { level = 1, color = GREEN } })
  a:send(c)
  local red = sent[2].seg[1].col[1]
  -- WLED reports a fade's end at once, so a report comes during it.
  shows(a.device, { col = red })
  a:report()
  W.run(2000)
  local lvl = cmd({ level = 0.5, setsLevel = true, color = RED, transitionMs = 2000 })
  a:send(lvl)
  local freeze = sent[3]
  T.eq("first a frame at once", { #sent, freeze.tt }, { 3, 0 })
  T.eq("holding the color 20% of the way, every channel", freeze.seg[1].col[1], {
    round(green[1] + (red[1] - green[1]) * 0.2),
    round(green[2] + (red[2] - green[2]) * 0.2),
    round(green[3] + (red[3] - green[3]) * 0.2),
    0,
  })
  T.eq("and leaving the level, which the fade did not move", { freeze.on, freeze.bri }, { nil, nil })
  shows(a.device, { col = freeze.seg[1].col[1] })
  T.truthy("a report of the freeze is the command's color", rawequal(a:report().color, lvl.color))
  T.eq("and its level, which the freeze leaves, is as shown", a:report().level, 1)
  W.run(149)
  T.eq("the command waits for the freeze to land", #sent, 3)
  W.run(1)
  T.eq("then goes with the level over its time", { sent[4].on, sent[4].bri, sent[4].tt }, { true, 128, 20 })
  T.eq("and the color going on to where it was going", sent[4].seg[1].col[1], red)

  -- A level fade, and halfway a color over 2 s.
  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:report()
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  shows(a.device, { bri = 255 })
  a:report()
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  T.eq("a level fade is held where it is", { sent[2].on, sent[2].bri, sent[2].tt, sent[2].seg }, { true, 153, 0, nil })
  W.run(150)
  T.eq("then the color goes with the level's end", { sent[3].bri, sent[3].tt }, { 255, 20 })
  T.truthy("and the color", sent[3].seg ~= nil)

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(5000)
  a:send(cmd({ level = 0.5, setsLevel = true }))
  T.eq("a command at once needs no freeze", { #sent, sent[2].bri, sent[2].tt }, { 2, 128, 0 })

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(10000)
  a:send(cmd({ level = 0.5, setsLevel = true, transitionMs = 2000 }))
  T.eq("nor one after the fade ended", { #sent, sent[2].tt }, { 2, 20 })

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  shows(a.device, { bri = 30 })
  a:report()
  W.run(5000)
  a:send(cmd({ level = 0.5, setsLevel = true, transitionMs = 2000 }))
  T.eq("nor one after another client moved the light", { #sent, sent[2].tt }, { 2, 20 })
end

--------------------------------------------------------------------------------
T.section("a command inside a freeze's wait carries where the held fades go, with no second freeze")
--------------------------------------------------------------------------------
do
  -- A level fade from 51 to 255 over 10 s; halfway a color over 2 s, then 50 ms later another.
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  T.eq("the first holds the level where it is", { #sent, sent[2].bri, sent[2].tt }, { 2, 153, 0 })
  W.run(50)
  a:send(cmd({ setsColor = true, color = GREEN, transitionMs = 2000 }))
  T.eq("the second sends no freeze of its own", #sent, 2)
  W.run(99)
  T.eq("and waits for the first freeze's gap", #sent, 2)
  W.run(1)
  T.eq(
    "then goes, with the level going on to 255",
    { #sent, sent[3].on, sent[3].bri, sent[3].tt },
    { 3, true, 255, 20 }
  )
  T.truthy("and its own color", sent[3].seg ~= nil and sent[3].seg[1].col[1][2] == 255)
  W.run(1000)
  T.eq("and the first's never goes", #sent, 3)

  -- A command at once while frozen goes at once, with every target, and ends the wait.
  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  W.run(50)
  a:send(cmd({ level = 0.4, setsLevel = true }))
  T.eq("a command at once while frozen goes at once", { #sent, sent[3].bri, sent[3].tt }, { 3, 102, 0 })
  T.truthy("with the held color's target", sent[3].seg ~= nil and sent[3].seg[1].col[1][1] == 255)
  W.run(1000)
  T.eq("and nothing goes after it", #sent, 3)

  -- forget() ends the freeze: the next command starts afresh.
  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  a:forget()
  a:send(cmd({ setsColor = true, color = GREEN, transitionMs = 2000 }))
  T.eq("after forget a command goes at once, holding nothing", { #sent, sent[3].tt, sent[3].bri }, { 3, 20, nil })
end

--------------------------------------------------------------------------------
T.section("a color stop holds the color where its own fade has it, and rests there")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = GREEN }))
  local green = sent[1].seg[1].col[1]
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 10000, from = { level = 1, color = GREEN } }))
  local red = sent[2].seg[1].col[1]
  W.run(2000)
  -- The library's estimate: the color part way in xy, which WLED's channel blend need not be.
  local rest = a:send(cmd({ kind = "stop", setsColor = true, color = xy(0.4, 0.5) }))
  local at = {}
  for i = 1, 4 do
    at[i] = round(green[i] + (red[i] - green[i]) * 0.2)
  end
  T.eq("held at once where the channels have got to", { sent[3].seg[1].col[1], sent[3].tt }, { at, 0 })
  local x, y = Color.rgbToXY(at[1] / 255, at[2] / 255, at[3] / 255)
  T.eq("and that is the rest, as a full color", rest and rest.color, { x = x, y = y, mode = Color.FULL })
  shows(a.device, { col = at })
  T.eq("a report of it is the rest", a:report().color, rest and rest.color)
end

--------------------------------------------------------------------------------
T.section("a color another client set stays the controller's own bytes, so a level fade's freeze still fires")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  -- The WLED app's orange: bytes no Control4 color renders to.
  shows(a.device, { col = { 255, 160, 0, 0 } })
  local orange = a:report().color
  a:send(cmd({ level = 1, setsLevel = true, color = orange, transitionMs = 10000, from = { level = 0.2 } }))
  shows(a.device, { bri = 255 })
  T.truthy("a report during the fade shows its color as the controller has it", rawequal(a:report().color, orange))
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  T.eq("the color mid-fade holds the level first", { #sent, sent[2].bri, sent[2].tt }, { 2, 153, 0 })

  -- Another client's color during a level fade puts the fade at its end on 16.x: the light is off the
  -- adapter's line, so a command mid-fade holds nothing at a stale point.
  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:report()
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  shows(a.device, { bri = 255, col = { 0, 0, 255, 0 } })
  a:report()
  W.run(5000)
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 2000 }))
  T.eq("a foreign color mid level fade ends the fade: no freeze", { #sent, sent[2].tt }, { 2, 20 })
end

--------------------------------------------------------------------------------
T.section("a leg maps only the aspects it carries; another client's change to the other is reported as shown")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  -- The library sends only after a connection's first report.
  a:report()
  local c = cmd({ level = 1, setsLevel = true, color = RED, transitionMs = 200000, from = { level = 0.2 } })
  a:send(c)
  shows(a.device, { bri = sent[1].bri, col = { 0, 0, 255, 0 } })
  local r = a:report()
  T.eq("a level leg's report is the fade's level", r.level, 1)
  T.falsy("and another client's color is its own", rawequal(r.color, c.color))
  W.run(250000)
  T.eq("which stops the legs left", #sent, 1)

  a = adapter(model(RGB + WHITE))
  a:report()
  a:send(cmd({ setsColor = true, color = GREEN }))
  c = cmd({ setsColor = true, color = RED, transitionMs = 200000, from = { level = 1, color = GREEN } })
  a:send(c)
  shows(a.device, { col = sent[2].seg[1].col[1], bri = 20 })
  r = a:report()
  T.truthy("a color leg's report is the fade's color", rawequal(r.color, c.color))
  T.eq("and another client's level is its own", r.level, 20 / 255)
  W.run(250000)
  T.eq("which stops the legs left too", #sent, 2)
end

--------------------------------------------------------------------------------
T.section("a freeze mid legs holds the light on their line, and no leg goes after it")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 200000, from = { level = 0.2 } }))
  shows(a.device, { bri = sent[1].bri })
  a:report()
  W.run(30000)
  a:send(cmd({ level = 0.5, setsLevel = true, transitionMs = 2000 }))
  T.eq("held on the line 15% of the way", { sent[2].bri, sent[2].tt }, { round(51 + 204 * 0.15), 0 })
  W.run(150)
  T.eq("then the command", { sent[3].bri, sent[3].tt }, { 128, 20 })
  W.run(250000)
  T.eq("and no leg after it", #sent, 3)
end

--------------------------------------------------------------------------------
T.section("a stop with a color of its own running holds the color where it is, then lets it go on")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  a:send(cmd({ setsColor = true, color = GREEN }))
  local green = sent[1].seg[1].col[1]
  a:send(cmd({ level = 0.2, setsLevel = true, transitionMs = 10000, from = { level = 1 } }))
  a:send(cmd({ setsColor = true, color = RED, transitionMs = 10000, from = { level = 1, color = GREEN } }))
  W.run(150)
  local red = sent[#sent].seg[1].col[1]
  W.run(4850)
  local count = #sent
  local rest = a:send(cmd({ kind = "stop", level = 0.6, setsLevel = true, color = RED, transitionMs = 5000 }))
  local held = sent[count + 1]
  -- 255 to 51 over 10 s from 150 ms in, 4.85 s along.
  local at = round(255 + (51 - 255) * 4850 / 10000)
  T.eq("the level stops at once, where its own fade has it", { held.on, held.bri, held.tt }, { true, at, 0 })
  T.eq("which is the rest", rest and rest.level, at / 255)
  T.truthy("with the color held where it got to", held.seg ~= nil and held.seg[1].col[1][1] < red[1])
  W.run(150)
  T.eq("then the color goes on over its time left", { sent[count + 2].tt, sent[count + 2].bri }, { 50, nil })
  T.eq("to where it was going", sent[count + 2].seg[1].col[1], red)
  T.truthy("from green", green[2] > 0)
end

--------------------------------------------------------------------------------
T.section("the color last sent is kept across a reload, so a report of its bytes is still that color")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  local c = cmd({ setsColor = true, color = xy(0.6, 0.3) })
  a:send(c)
  local dev = a.device
  local bytes = sent[1].seg[1].col[1]
  shows(dev, { col = bytes })
  local function reloaded()
    return Adapter:new({
      device = dev,
      send = function() end,
      warm = function()
        return 2700
      end,
      cool = function()
        return 6500
      end,
    })
  end
  local r = reloaded():report()
  T.eq(
    "a reloaded adapter reports the bytes as the color sent",
    { r.color.x, r.color.y, r.color.mode },
    { 0.6, 0.3, "xy" }
  )
  shows(dev, { col = { 0, 0, 255, 0 } })
  r = reloaded():report()
  T.truthy("other bytes are the controller's own", r.color.x ~= 0.6)
  shows(dev, { col = bytes })
  local b = reloaded()
  b:forget()
  r = reloaded():report()
  T.truthy("forget ends it", r.color.x ~= 0.6 or r.color.y ~= 0.3)
end

--------------------------------------------------------------------------------
T.section("forget ends the echo memo and the legs left, for a light lost or reset")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB + WHITE))
  local c = cmd({ level = 0.5, setsLevel = true, setsColor = true, color = RED })
  a:send(c)
  shows(a.device, { bri = sent[1].bri, col = sent[1].seg[1].col[1] })
  T.truthy("before, the command's wire is its own", rawequal(a:report().level, c.level))
  a:forget()
  local r = a:report()
  T.eq("after, a report of the old wire is the controller's", r.level, sent[1].bri / 255)
  T.falsy("its color too", rawequal(r.color, c.color))

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 200000, from = { level = 0.2 } }))
  a:forget()
  W.run(201000)
  T.eq("no leg goes after it", #sent, 1)

  a = adapter(model(RGB + WHITE, { bri = 51 }))
  a:send(cmd({ level = 1, setsLevel = true, transitionMs = 10000, from = { level = 0.2 } }))
  W.run(5000)
  a:send(cmd({ level = 0.5, setsLevel = true, transitionMs = 2000 }))
  a:forget()
  W.run(1000)
  T.eq("nor the command a freeze was holding for", #sent, 2)
  a:send(cmd({ level = 0.8, setsLevel = true, transitionMs = 2000 }))
  T.eq("and the next command starts from the library's word, with no freeze", { #sent, sent[3].tt }, { 3, 20 })
end

--------------------------------------------------------------------------------
T.section("the contract's cases put what each command says on the wire")
--------------------------------------------------------------------------------
do
  -- test/light_contract_cases.lua's exact command lists, for the cases a WLED light can meet: a fade of
  -- the device's own, with a color sent while off.
  local Cases = require("light_contract_cases")
  local ran = 0
  for _, case in ipairs(Cases.list) do
    local d = case.device
    if d.fade.kind == "device" and d.colorWhileOff == "send" then
      ran = ran + 1
      local lc = (d.color and RGB or 0) + (d.cct and CCT or 0) + ((d.dims or d.cct) and WHITE or 0)
      local seedOn = (case.seed.level or 0) > 0
      local a = adapter(
        model(lc, { on = seedOn, bri = math.max(1, round((case.seed.level or 0) * 255)) }),
        d.cct and d.cct.minK,
        d.cct and d.cct.maxK
      )
      local clock = 0
      local frames = {}
      for i, sentCmd in ipairs(case.commands) do
        W.run(sentCmd.at - clock)
        clock = sentCmd.at
        local before = #sent
        local rest = a:send(sentCmd.command)
        frames[i] = { from = before + 1, cmd = sentCmd.command, rest = rest }
        if i > 1 then
          frames[i - 1].to = before
        end
      end
      W.run(case.runMs + 500)
      frames[#frames].to = #sent
      for i, f in ipairs(frames) do
        local cmd, out = f.cmd, {}
        for k = f.from, f.to do
          out[#out + 1] = sent[k]
        end
        local name = string.format("%s, command %d (%s)", case.name, i, cmd.kind)
        local last = out[#out]
        local bri = cmd.on and d.dims and math.max(1, round(cmd.level * 255)) or nil
        if cmd.kind == "preOn" then
          T.truthy(
            name .. ": at most its color, at once",
            #out <= 1 and (not last or (last.on == nil and last.bri == nil and last.tt == 0)),
            T.show(out)
          )
          T.eq(name .. ": the color only when it sets one", last ~= nil and last.seg ~= nil, cmd.setsColor)
        elseif cmd.kind == "stop" then
          T.eq(name .. ": held at once", out[1] and out[1].tt, 0)
          if cmd.setsLevel then
            -- Where the adapter's own fade has the controller, returned as the rest; else the level it names.
            local at = f.rest and f.rest.level and round(f.rest.level * 255) or bri
            T.eq(name .. ": held where it is", { out[1].on, out[1].bri }, { cmd.on, at })
            T.truthy(name .. ": near the library's estimate", math.abs((at or 0) - (bri or 0)) <= 13, { at, bri })
          end
          if cmd.transitionMs > 0 then
            T.eq(
              name .. ": then the other aspect over its time left",
              { #out, last.tt },
              { 2, round(cmd.transitionMs / 100) }
            )
            T.eq(name .. ": leaving the stopped level", last.bri, nil)
          else
            T.eq(name .. ": in one frame", #out, 1)
          end
        else
          T.eq(name .. ": over its time", last and last.tt, round(cmd.transitionMs / 100))
          local frozen = #out > 1
          if cmd.setsLevel then
            T.eq(name .. ": its power and level", { last.on, last.bri }, { cmd.on, bri })
          elseif not frozen then
            T.eq(name .. ": no power or level", { last.on, last.bri }, { nil, nil })
          end
          if cmd.setsColor then
            T.truthy(name .. ": its color", last.seg ~= nil)
          elseif not frozen and not (last.on == true and not a.device.on) then
            T.eq(name .. ": no color", last.seg, nil)
          end
          if frozen then
            T.eq(name .. ": a freeze first, at once", out[1].tt, 0)
          end
        end
      end
    end
  end
  T.truthy("the cases a WLED light meets ran", ran >= 5, ran)
end

--------------------------------------------------------------------------------
T.section("refresh asks the controller, show does nothing, and a bad command is dropped")
--------------------------------------------------------------------------------
do
  local a = adapter(model(RGB))
  local before = refreshed
  a:refresh()
  T.eq("refresh asks once", refreshed - before, 1)
  a:show({ minOn = 1, maxOn = 100 })
  T.eq("show sends nothing", #sent, 0)
  local ok = pcall(a.send, a, cmd({ setsColor = true, color = { x = "bad" } }))
  T.truthy("a command it cannot build does not raise", ok)
  T.eq("and sends nothing", #sent, 0)
end

T.finish()
