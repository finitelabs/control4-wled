--- The WLED controller's light against a fake controller: capabilities from the
--- controller's bits and their changes, levels and the straight-line fade, long
--- fades in legs, colors that end an effect, color temperature, a rated on from
--- off, the controller's echoes, and 16.0.1 and 0.15.4 controllers.
---
--- Run from the driver root:
---   make test

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"

--- The light capabilities the build writes into driver.xml, from the profile the driver's chunk gave
--- Light.new: the source driver.xml carries none of them.
local function builtCaps()
  local made = require("lib.light").made
  local out = {}
  for _, row in ipairs(require("lib.light.caps").static(made[#made].profile)) do
    out[row.key] = row.value
  end
  return out
end
local PROXY = 5001
local PROXY_DEVICE = 9001

package.preload["cloud-client-byte"] = function()
  return {}
end
package.loaded["lib.http"] = W.http

local function defaultProperties()
  local f = assert(io.open(XML, "r"))
  local xml = f:read("*a")
  f:close()
  local props = {}
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    if name then
      props[name] = block:match("<default>(.-)</default>") or ""
    end
  end
  return props
end

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.2"
  end
  return configInfo(self, section)
end

function C4:GetDevicesByC4iName()
  return {}
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

function C4:GetProxyDevices()
  return PROXY_DEVICE
end

function C4:GetDeviceVariable()
  return nil
end

function C4:FireEventByID() end

local told = {}

function C4:SendToProxy(idBinding, strCommand, tParams)
  told[#told + 1] = { binding = idBinding, command = strCommand, params = tParams or {}, at = W.now() }
end

local fake, since = nil, 0

local function mark()
  told = {}
  since = fake and #fake.commands or 0
end

--- The commands the controller got since the mark.
local function sent()
  local out = {}
  for i = since + 1, #fake.commands do
    out[#out + 1] = fake.commands[i]
  end
  return out
end

--- Each `field` of `command` the proxy was told since the mark.
local function toldOf(command, field)
  local out = {}
  for _, t in ipairs(told) do
    if t.binding == PROXY and t.command == command then
      out[#out + 1] = field and t.params[field] or t.params
    end
  end
  return out
end

local function lastCaps()
  local caps = toldOf("DYNAMIC_CAPABILITIES_CHANGED")
  return caps[#caps]
end

local nextHost = 60

--- A fresh project on a controller of `profile`, connected and settled.
local function fresh(profile, props)
  W.reset()
  nextHost = nextHost + 1
  fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  require("lib.persist"):delete("WledControllerMac")
  require("lib.persist"):delete("WledShown")
  for _, key in ipairs({ "color_on_mode", "previous_color", "white_point", "brightness_on_mode" }) do
    require("lib.persist"):delete(key)
  end
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  for k, v in pairs(props or {}) do
    Properties[k] = v
  end
  Properties["IP Address"] = fake.ip
  T.unload("^drivers%-common%-public%.module%.websocket$", "^wled%.")
  fake.commands = {}
  told, since = {}, 0
  dofile(DRIVER)
  ShimLateInit()
  W.run(3000)
  return fake
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

--------------------------------------------------------------------------------
T.section("capabilities come from the controller's own bits")
--------------------------------------------------------------------------------
do
  local cases = {
    { "esp32-rgbw-pwm-16", true, true, true, true },
    { "esp32-rgbw-015", true, false, true, true },
    { "esp8266-ws2812b-015", true, false, true, true },
    { "esp32-cct-16", false, true, true, true },
    { "esp32-white-16", false, false, true, true },
    { "esp32-relay-16", false, false, false, false },
  }
  for _, c in ipairs(cases) do
    fresh(c[1])
    local caps = lastCaps() or {}
    T.eq(
      c[1] .. ": color, color temperature, dimming, color stop",
      { caps.supports_color, caps.supports_color_correlated_temperature, caps.dimmer, caps.supports_color_stop },
      { c[2], c[3], c[4], c[5] }
    )
  end
  fresh("esp32-cct-16")
  local caps = lastCaps()
  T.eq(
    "the color temperature range is the installer's white points",
    { caps.color_correlated_temperature_min, caps.color_correlated_temperature_max },
    { 2700, 6500 }
  )
  T.eq("a rate can run past what one WLED command carries", caps.brightness_rate_max, 86400000)
end

--------------------------------------------------------------------------------
T.section("a change of the controller's bits mid-connection is told")
--------------------------------------------------------------------------------
do
  -- White balance correction turned on adds the CCT bit to a plain RGB strip.
  fresh("esp32-rgbw-accurate-16")
  T.eq("an RGB strip has no color temperature", lastCaps().supports_color_correlated_temperature, false)
  mark()
  fake.si.state.seg[1].lc = 5
  fake:change(nil, { leds = { lc = 5, seglc = { 5 } } })
  W.run(2000)
  T.eq(
    "white balance on: color temperature told",
    lastCaps() and lastCaps().supports_color_correlated_temperature,
    true
  )

  -- An RGBW strip's white mode set to Accurate leaves RGB: its white goes on RGB.
  fresh("esp32-rgbw-015")
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0, RATE = 0 }
  )
  local before = sent()[1]
  T.eq("RGBW: four channels", before and #before.seg[1].col[1], 4)
  fake:change(nil, { leds = { lc = 1, seglc = { 1 } } })
  W.run(2000)
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.17, LIGHT_COLOR_TARGET_Y = 0.70, LIGHT_COLOR_TARGET_MODE = 0, RATE = 0 }
  )
  local after = sent()[1]
  T.eq("white mode Accurate: three", after and #after.seg[1].col[1], 3)
end

--------------------------------------------------------------------------------
T.section("levels go to master brightness, and a fade runs in a straight line")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  mark()
  proxy("SET_LEVEL", { LEVEL = "80" })
  local cmd = sent()[1]
  T.eq("a level at once", cmd and { cmd.on, cmd.bri, cmd.tt }, { true, 204, 0 })
  T.eq("no segment, so no effect is touched", cmd and cmd.seg, nil)
  W.run(3000)
  T.eq(
    "told once, the echo is the driver's own",
    toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 80 }
  )

  proxy("SET_LEVEL", { LEVEL = "20" })
  W.run(3000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "4000" })
  cmd = sent()[1]
  T.eq("a rated level: the controller fades", cmd and { cmd.bri, cmd.tt }, { 255, 40 })
  W.run(1000)
  mark()
  proxy("SET_BRIGHTNESS_STOP")
  cmd = sent()[1]
  -- A quarter of the way along a straight line from 20 to 100: 40.
  T.eq(
    "a stop a quarter through holds where the straight line is",
    toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 40 }
  )
  T.eq("sent as that level at once", cmd and { cmd.bri, cmd.tt }, { 102, 0 })
end

--------------------------------------------------------------------------------
T.section("a light with no color declares a color stop, so the proxy passes its brightness stop on")
--------------------------------------------------------------------------------
do
  fresh("esp32-white-16")
  T.differs(
    "driver.xml declares it before the controller reports",
    "BENIGN: the build writes the light's capabilities; the source driver.xml carries none"
  )
  T.eq("the build's driver.xml declares it before the controller reports", builtCaps().supports_color_stop, "True")
  T.eq("a white-only strip is told it too", lastCaps().supports_color_stop, true)
  proxy("SET_LEVEL", { LEVEL = "20" })
  W.run(3000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "4000" })
  W.run(1000)
  mark()
  proxy("SET_COLOR_STOP")
  T.eq("a color stop mid-ramp sends the controller nothing", sent(), {})
  T.eq("and tells the proxy nothing", told, {})
  proxy("SET_BRIGHTNESS_STOP")
  local cmd = sent()[1]
  T.eq(
    "its brightness stop still holds a quarter through",
    toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"),
    { 40 }
  )
  T.eq("sent as that level at once", cmd and { cmd.bri, cmd.tt }, { 102, 0 })
end

--------------------------------------------------------------------------------
T.section("a fade longer than one command carries goes in legs on one line")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  mark()
  local snaps = fake.snaps
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "200000" })
  W.run(199000)
  T.eq("no level told before the fade's end", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), {})
  W.run(2000)
  local cmds = sent()
  local bris, tts = {}, {}
  for _, c in ipairs(cmds) do
    if c.bri then
      bris[#bris + 1] = c.bri
      tts[#tts + 1] = c.tt
    end
  end
  T.eq(
    "four legs of 49.6 s and three 0.5 s gaps, along one line from 128 to 255",
    { bris, tts },
    { { 160, 192, 223, 255 }, { 496, 496, 496, 496 } }
  )
  T.eq("no leg reaches the controller while one runs", fake.snaps - snaps, 0)
  T.eq("told one change at the start", #toldOf("LIGHT_BRIGHTNESS_CHANGING"), 1)
  T.eq("and its end", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 100 })
  local wraps = 0
  for _, c in ipairs(cmds) do
    if (c.tt or 0) > 655 then
      wraps = wraps + 1
    end
  end
  T.eq("no command past 65.5 s, where tt wraps", wraps, 0)
end

--------------------------------------------------------------------------------
T.section("each leg of a long fade goes after the last one ends, so 16.x fades it")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("SET_LEVEL", { LEVEL = "10" })
  W.run(3000)
  local function legs()
    local out = {}
    for _, c in ipairs(sent()) do
      if c.bri then
        out[#out + 1] = c
      end
    end
    return out
  end
  -- When each command reached the controller.
  local at = {}
  local apply = fake.apply
  fake.apply = function(self, cmd)
    at[cmd] = W.now()
    return apply(self, cmd)
  end

  mark()
  local snaps = fake.snaps
  local t0 = W.now()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "70000" })
  T.eq("two legs, the gap taken out of them: the first at once", #legs(), 1)
  W.run(35000)
  T.eq("the second not at 35 s", #legs(), 1)
  W.run(249)
  T.eq("nor just before 0.5 s past the first one's end", #legs(), 1)
  W.run(1)
  T.eq("but 0.5 s after it", #legs(), 2)
  local second = legs()[2] or {}
  T.eq("each leg 34.8 s", { legs()[1].tt, second.tt }, { 348, 348 })
  T.truthy(
    "the second leg ends within 50 ms of 70 s",
    at[second] and second.tt and math.abs(at[second] + second.tt * 100 - (t0 + 70000)) <= 50
  )
  T.eq("so no leg reaches the controller while one runs", fake.snaps - snaps, 0)
  W.run(34749)
  T.eq("no level told before 70 s", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), {})
  W.run(1)
  T.eq("and the fade's end told at 70 s", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 20 })

  -- A stop in the gap holds where the first leg ended, and the second leg never goes.
  proxy("SET_LEVEL", { LEVEL = "10" })
  W.run(3000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "70000" })
  local first = legs()[1]
  W.run(35000)
  proxy("SET_BRIGHTNESS_STOP")
  local stop = legs()[2]
  T.truthy("a stop in the gap is sent at once", stop and stop.tt == 0)
  T.truthy("near where the first leg ended", stop and first and math.abs(stop.bri - first.bri) <= 1)
  W.run(40000)
  T.eq("and the second leg never goes", #legs(), 2)

  -- A busy answer replays the first leg 250 ms late; the next still lands after it ends.
  proxy("SET_LEVEL", { LEVEL = "10" })
  W.run(3000)
  mark()
  snaps = fake.snaps
  t0 = W.now()
  fake.wsBusy = 1
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "70000" })
  W.run(71000)
  local busy = legs()
  T.eq("both legs reach the controller once", #busy, 2)
  T.truthy("the first after the busy answer's retry", busy[1] and at[busy[1]] and at[busy[1]] - t0 >= 250)
  T.eq("and still no leg arrives while one runs", fake.snaps - snaps, 0)
end

--------------------------------------------------------------------------------
T.section("a color goes to every segment and ends an effect; a level never does")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  for _, seg in ipairs(fake.si.state.seg) do
    seg.fx = 12
  end
  mark()
  proxy("SET_LEVEL", { LEVEL = "70" })
  W.run(3000)
  T.eq("a level leaves the effect running", { fake.si.state.seg[1].fx, fake.si.state.seg[2].fx }, { 12, 12 })
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0, RATE = 0 }
  )
  local cmd = sent()[1]
  local ids = {}
  for _, s in ipairs(cmd and cmd.seg or {}) do
    ids[#ids + 1] = s.id
  end
  T.eq("every segment", ids, { 0, 1 })
  T.eq("its effect stopped", cmd and { cmd.seg[1].fx, cmd.seg[2].fx }, { 0, 0 })
  T.eq("red on the color LEDs, white off", cmd and cmd.seg[1].col[1][4], 0)
  T.truthy("red is red", cmd and cmd.seg[1].col[1][1] == 255 and cmd.seg[1].col[1][3] < 64)
  W.run(3000)
  T.eq("the effect is gone at the controller", { fake.si.state.seg[1].fx, fake.si.state.seg[2].fx }, { 0, 0 })
  T.eq("the color is told once, the echo the driver's own", #toldOf("LIGHT_COLOR_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("a color temperature on a tunable white strip sets its CCT between the white points")
--------------------------------------------------------------------------------
do
  fresh("esp32-cct-16")
  mark()
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = "4000", RATE = "0" })
  local cmd = sent()[1]
  local cct = cmd and cmd.seg[1].cct
  -- (4000 - 2700) / (6500 - 2700) of 255.
  T.truthy("4000 K is CCT 87", cct and math.abs(cct - 87) <= 1, cct)
  T.eq("on the white LEDs", cmd and cmd.seg[1].col[1], { 0, 0, 0, 255 })
  fresh("esp32-cct-16", { ["Warm White (K)"] = "2000", ["Cool White (K)"] = "6000" })
  mark()
  -- 4000 K is the fake's own CCT 128 under these white points: a command the light already shows still goes.
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = "4000", RATE = "0" })
  cmd = sent()[1]
  cct = cmd and cmd.seg[1].cct
  T.truthy("other white points move it: CCT 128", cct and math.abs(cct - 128) <= 1, cct)
  W.run(3000)
  mark()
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = "5000", RATE = "0" })
  cmd = sent()[1]
  cct = cmd and cmd.seg[1].cct
  -- (5000 - 2000) / (6000 - 2000) of 255.
  T.truthy("and 5000 K is CCT 191", cct and math.abs(cct - 191) <= 1, cct)
end

--------------------------------------------------------------------------------
T.section("a rated on from off fades up from nothing, its on color set first")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("SET_LEVEL", { LEVEL = "0" })
  W.run(3000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "2000" })
  local cmds = sent()
  T.eq("one command: the controller fades up from off by itself", #cmds, 1)
  T.eq("on, to 80 over 2 s", cmds[1] and { cmds[1].on, cmds[1].bri, cmds[1].tt }, { true, 204, 20 })
  T.eq(
    "told from 1, so Control4 shows it on from the start",
    toldOf("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_CURRENT"),
    { 1 }
  )

  -- With a Color On Mode the color goes first, at once, without turning the light on.
  proxy("SET_LEVEL", { LEVEL = "0" })
  W.run(3000)
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = "3",
    COLOR_PRESET_ORIGIN = "2",
    COLOR_PRESET_COLOR_X = "0.17",
    COLOR_PRESET_COLOR_Y = "0.70",
    COLOR_PRESET_COLOR_MODE = "0",
    COLOR_FADE_PRESET_ID = "0",
    COLOR_FADE_PRESET_ORIGIN = "0",
  })
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "2000" })
  cmds = sent()
  T.differs(
    "two commands: first the color, at once, the light left off, then on to 80 over 2 s",
    "An on from off fades the color from the one the light kept to its on color, over the on's time."
  )
  T.eq("one command: on, to 80 over 2 s", #cmds, 1)
  T.eq("its level and time", cmds[1] and { cmds[1].on, cmds[1].bri, cmds[1].tt }, { true, 204, 20 })
  T.truthy("fading to green with it", cmds[1] and cmds[1].seg and cmds[1].seg[1].col[1][2] == 255)
end

--------------------------------------------------------------------------------
T.section("the fake shows 16.x putting a running color fade at its target, and 0.15.4 keeping its timer")
--------------------------------------------------------------------------------
do
  -- Measured on the dig2go, 2026-11-12: on 16.0.1 a call that lands while a fade runs puts every
  -- color at its target at once, a level-only call too; 0.15.4 keeps a fading segment's start and timer.
  local function blueShare(f)
    local col = f:output().seg[0].col
    return col[3] / math.max(1, col[1] + col[3])
  end
  for _, case in ipairs({ { "dig2go-rgbw-16", true }, { "esp32-rgbw-015", false } }) do
    local profile, v16 = case[1], case[2]
    W.reset()
    local f = W.Fake.new(profile)
    f:apply({ on = true, bri = 255, seg = { { id = 0, col = { { 255, 0, 0, 0 } } } }, tt = 0 })
    f:apply({ seg = { { id = 0, col = { { 0, 0, 255, 0 } } } }, tt = 100 })
    W.run(2000)
    T.truthy(profile .. ": the color fade is part way", math.abs(blueShare(f) - 0.2) < 0.03, blueShare(f))
    f:apply({ bri = 128, tt = 20 })
    if v16 then
      T.eq(profile .. ": a level call mid-fade puts the color at its target", f:output().seg[0].col, { 0, 0, 255, 0 })
      T.eq(profile .. ": counted as a jump", f.colorJumps, 1)
    else
      T.truthy(profile .. ": a level call mid-fade leaves the color fading", blueShare(f) < 0.3, blueShare(f))
      T.eq(profile .. ": no jump", f.colorJumps or 0, 0)
      f:apply({ seg = { { id = 0, col = { { 0, 255, 0, 0 } } } }, tt = 20 })
      T.eq(profile .. ": a new color mid-fade jumps on the old timer", f.colorJumps, 1)
    end
    W.run(10000)
    f:apply({ seg = { { id = 0, col = { { 255, 0, 0, 0 } } } }, tt = 20 })
    W.run(1000)
    local red = f:output().seg[0].col[1]
    T.truthy(profile .. ": a fade sent after the last one ended fades", red > 64 and red < 230, red)
  end
end

--------------------------------------------------------------------------------
T.section("the fake makes 0.15.4's changes at once with Crossfade off, and 16.x a white-LED to RGB fade")
--------------------------------------------------------------------------------
do
  W.reset()
  local f = W.Fake.new("esp8266-ws2812b-015-nofade")
  T.eq("its LED settings have Crossfade off", f.files["/json/cfg"].light.tr.mode, false)
  f:apply({ on = true, bri = 255, seg = { { id = 0, col = { { 255, 0, 0 } } } }, tt = 0 })
  f:apply({ bri = 50, seg = { { id = 0, col = { { 0, 0, 255 } } } }, tt = 50 })
  W.run(10)
  T.eq("a level and a color land at once", { f:output().bri, f:output().seg[0].col }, { 50, { 0, 0, 255 } })
  W.reset()
  f = W.Fake.new("dig2go-rgbw-16")
  T.eq("16.x has no Crossfade switch", f.files["/json/cfg"].light.tr.mode, nil)
  f:apply({ on = true, bri = 255, seg = { { id = 0, col = { { 0, 0, 0, 255 } } } }, tt = 0 })
  f:apply({ seg = { { id = 0, col = { { 255, 0, 0, 0 } } } }, tt = 30 })
  W.run(50)
  T.eq("16.x: the white LEDs to red land within a frame", f:output().seg[0].col, { 255, 0, 0, 0 })
  W.reset()
  f = W.Fake.new("dig2go-rgbw-015")
  f:apply({ on = true, bri = 255, seg = { { id = 0, col = { { 0, 0, 0, 255 } } } }, tt = 0 })
  f:apply({ seg = { { id = 0, col = { { 255, 0, 0, 0 } } } }, tt = 30 })
  W.run(1500)
  local red = f:output().seg[0].col[1]
  T.truthy("0.15.4 fades it", red > 0 and red < 255, red)
end

--------------------------------------------------------------------------------
T.section("a level mid color fade holds the color first, so the strip shows no jump")
--------------------------------------------------------------------------------
do
  fresh("dig2go-rgbw-16")
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33", LIGHT_COLOR_TARGET_MODE = "0", RATE = "0" }
  )
  W.run(3000)
  local jumps, snaps = fake.colorJumps or 0, fake.snaps
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = "0.17", LIGHT_COLOR_TARGET_Y = "0.70", LIGHT_COLOR_TARGET_MODE = "0", RATE = "10000" }
  )
  W.run(2000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "2000" })
  W.run(12000)
  T.eq("no color jumped at the controller", (fake.colorJumps or 0) - jumps, 0)
  T.eq("nor the level", fake.snaps - snaps, 0)
  T.eq("and it ends green", fake:output().seg[0].col[2], 255)
end

--------------------------------------------------------------------------------
T.section("after another client's color, a color mid level fade still holds the level first")
--------------------------------------------------------------------------------
do
  fresh("dig2go-rgbw-16")
  proxy("SET_LEVEL", { LEVEL = "20" })
  W.run(3000)
  -- The WLED app sets an orange no Control4 color renders to, and the controller pushes it.
  fake:change({ seg = { { id = 0, start = 0, stop = 300, col = { { 255, 160, 0, 0 } } } } })
  W.run(3000)
  local jumps, snaps = fake.colorJumps or 0, fake.snaps
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "10000" })
  -- The controller reports the fade's end at once, and pushes it.
  W.run(5000)
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33", LIGHT_COLOR_TARGET_MODE = "0", RATE = "2000" }
  )
  W.run(3000)
  local cmds = sent()
  T.eq("the color held the level first, at once", cmds[2] and cmds[2].tt, 0)
  T.eq("then went with the level's end", cmds[3] and { cmds[3].bri, cmds[3].tt }, { 255, 20 })
  T.eq("no color jumped at the controller", (fake.colorJumps or 0) - jumps, 0)
  T.eq("nor the level", fake.snaps - snaps, 0)
end

--------------------------------------------------------------------------------
T.section("a color stop while a level ramp runs tells the level the ramp goes to, not the stop's estimate")
--------------------------------------------------------------------------------
do
  local function color(x, y, rate)
    proxy(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = y, LIGHT_COLOR_TARGET_MODE = "0", RATE = rate }
    )
  end
  for _, case in ipairs({ { "1 s into the color", 1000 }, { "inside the freeze's wait", 100 } }) do
    fresh("dig2go-rgbw-16")
    proxy("SET_LEVEL", { LEVEL = "20" })
    color("0.3", "0.6", "0")
    W.run(3000)
    mark()
    proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "10000" })
    W.run(5000)
    color("0.64", "0.33", "5000")
    W.run(case[2])
    proxy("SET_COLOR_STOP", {})
    W.run(15000)
    local levels = toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
    T.eq(case[1] .. ": the strip ends at the ramp's end", fake.si.state.bri, 255)
    T.eq(case[1] .. ": and the proxy is told it", levels[#levels], 100)
  end
end

--------------------------------------------------------------------------------
T.section("another client's level mid-fade ends the fade and is told")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "10000" })
  W.run(2000)
  fake:change({ bri = 51 })
  W.run(2000)
  T.eq("told the level the other client set", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 20 })
  W.run(10000)
  T.eq("and nothing more at the fade's old end", #toldOf("LIGHT_BRIGHTNESS_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("a long fade to off leaves WLED the level it started from")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("SET_LEVEL", { LEVEL = "80" })
  W.run(2000)
  mark()
  local snaps = fake.snaps
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "200000" })
  W.run(201000)
  local cmds = sent()
  local last = cmds[#cmds]
  T.eq("the last leg turns it off and keeps the starting level", last and { last.on, last.bri }, { false, 204 })
  T.eq("no leg reaches the controller while one runs", fake.snaps - snaps, 0)
  T.eq("told off at the end", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 0 })
end

--------------------------------------------------------------------------------
T.section("a long fade after another client's change starts from the level it set")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("SET_LEVEL", { LEVEL = "100" })
  W.run(2000)
  fake:change({ bri = 51 })
  W.run(2000)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "200000" })
  W.run(201000)
  local bris = {}
  for _, c in ipairs(sent()) do
    if c.bri then
      bris[#bris + 1] = c.bri
    end
  end
  T.eq("legs on the line from 51, not from the old 255", bris, { 102, 153, 204, 255 })
end

--------------------------------------------------------------------------------
T.section("a 0.15.4 ESP8266 controller is driven the same way")
--------------------------------------------------------------------------------
do
  fresh("esp8266-ws2812b-015")
  mark()
  proxy("SET_LEVEL", { LEVEL = "80" })
  local cmd = sent()[1]
  T.eq("a level", cmd and { cmd.bri, cmd.tt }, { 204, 0 })
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0, RATE = 0 }
  )
  cmd = sent()[1]
  T.eq("a color on its RGB strip: three channels", cmd and #cmd.seg[1].col[1], 3)
  W.run(3000)
  T.eq("told once", #toldOf("LIGHT_COLOR_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("a 0.15.4 controller with Crossfade off takes no fade time: changes go and are told at once")
--------------------------------------------------------------------------------
do
  fresh("esp8266-ws2812b-015-nofade")
  T.eq("the light offers no stop, as it fades nothing", lastCaps() and lastCaps().supports_brightness_stop, false)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "2000" })
  W.run(50)
  local cmds = sent()
  T.eq("a timed level goes at once", cmds[1] and { cmds[1].bri, cmds[1].tt }, { 204, 0 })
  T.eq("and is told at once", toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT"), { 80 })
  T.eq("with no ramp", #toldOf("LIGHT_BRIGHTNESS_CHANGING"), 0)
  W.run(3000)
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = "0.17", LIGHT_COLOR_TARGET_Y = "0.70", LIGHT_COLOR_TARGET_MODE = "0", RATE = "2000" }
  )
  W.run(100)
  proxy("SET_COLOR_STOP", {})
  proxy("SET_BRIGHTNESS_STOP", {})
  W.run(3000)
  cmds = sent()
  T.eq("a timed color goes at once, and a stop sends nothing that moves the light", #cmds, 1)
  T.eq("the color at once", cmds[1] and cmds[1].tt, 0)

  -- A 16.x controller has no switch and still fades.
  fresh("dig2go-rgbw-16")
  T.eq("16.x offers its stops", lastCaps() and lastCaps().supports_brightness_stop, true)
end

--------------------------------------------------------------------------------
T.section("Crossfade turned off on a 0.15.4 controller is seen at the next slow poll, without a reconnect")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-015")
  T.eq("Crossfade on: the light fades and offers its stops", lastCaps() and lastCaps().supports_brightness_stop, true)
  mark()
  -- As WLED's settings page does, through /json/cfg: no push, no reconnect.
  fake.files["/json/cfg"].light.tr.mode = false
  fake.crossfade = false
  W.run(20000)
  T.eq("the next slow poll sees it: no stops now", lastCaps() and lastCaps().supports_brightness_stop, false)
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "3000" })
  W.run(50)
  T.eq("and a timed level goes at once", sent()[1] and sent()[1].tt, 0)
end

--------------------------------------------------------------------------------
T.section("a click sends the controller only the click's level, as one with Crossfade off needs")
--------------------------------------------------------------------------------
do
  fresh("esp8266-ws2812b-015-nofade")
  proxy("SET_PRESET_LEVEL", { LEVEL = "50" })
  for _, c in ipairs({ { "from off", "OFF" }, { "at the on level", "SET_LEVEL" } }) do
    proxy(c[2], { LEVEL = "50" })
    W.run(3000)
    mark()
    proxy("BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
    W.run(110)
    proxy("BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" })
    W.run(3000)
    local levels = {}
    for _, cmd in ipairs(sent()) do
      levels[#levels + 1] = cmd.bri
    end
    if c[2] == "OFF" then
      T.eq("a Top click " .. c[1] .. ": never full", levels, { 128 })
    else
      T.differs(
        "a Top click " .. c[1] .. ": nothing sent",
        "BENIGN: a click at the on level sends that level again and tells nothing"
      )
      T.eq("a Top click " .. c[1] .. ": never full, the on level again", levels, { 128 })
    end
  end
end

-- Hold and click timing inside the press delay, a color while off, button colors, and the proxy's
-- measured Dim-To-Warm and rates.

local TOP, BOTTOM, TOGGLE = "0", "1", "2"
local RELEASE_HOLD, PRESS, RELEASE_CLICK = "0", "1", "2"

--- The levels the proxy was told the light is at, since the mark.
local function changed()
  return toldOf("LIGHT_BRIGHTNESS_CHANGED", "LIGHT_BRIGHTNESS_CURRENT")
end

--- The levels the proxy was told the light is going to, since the mark.
local function changing()
  return toldOf("LIGHT_BRIGHTNESS_CHANGING", "LIGHT_BRIGHTNESS_TARGET")
end

--- What a Button Link was told of its colors since the mark: { on, off }.
local function linkColors(binding)
  local out = nil
  for _, t in ipairs(told) do
    if t.binding == binding and t.command == "BUTTON_COLORS" then
      out = { t.params.ON_COLOR, t.params.OFF_COLOR }
    end
  end
  return out
end

--- A scene step of a level over a rate, after a delay.
local function levelStep(level, rate, delay)
  local step = "<element><delay>%d</delay><rate>%d</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>%d</brightness></element>"
  return step:format(delay or 0, rate or 0, level)
end

--- A proxy setup as the proxy answers GET_SETUP, from test/light_setup.
local function setupFile(name)
  local f = assert(io.open(HERE .. "/light_setup/" .. name))
  local xml = f:read("*a")
  f:close()
  return xml
end

--------------------------------------------------------------------------------
T.section("a hold let go inside its delay stops a fade in flight where it has got to")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("OFF")
  W.run(3000)
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "5000" })
  W.run(2500)
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  W.run(150)
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = RELEASE_HOLD })
  W.run(5000)
  T.differs(
    "one command, a stop where the fade had got to, and no hold",
    "A keypad hold let go inside the hold delay leaves a fade the light was already in running; it stops only a hold or a scene ramp."
  )
  T.eq("no command, and no hold", #sent(), 0)
  T.eq("and no ramp told", changing(), {})
end

--------------------------------------------------------------------------------
T.section("a Bottom or Toggle click from on inside its press's hold delay sends one command")
--------------------------------------------------------------------------------
do
  for _, button in ipairs({ { "Bottom", BOTTOM }, { "Toggle", TOGGLE } }) do
    fresh("esp32-rgbw-pwm-16")
    proxy("SET_LEVEL", { LEVEL = "100" })
    W.run(3000)
    mark()
    proxy("BUTTON_ACTION", { BUTTON_ID = button[2], ACTION = PRESS })
    W.run(110)
    proxy("BUTTON_ACTION", { BUTTON_ID = button[2], ACTION = RELEASE_CLICK })
    W.run(5000)
    local cmds = sent()
    T.eq(button[1] .. " click from on: one command", #cmds, 1)
    T.eq(
      button[1] .. " click from on: the light ends off",
      { cmds[1] and cmds[1].on, changed()[#changed()] },
      { false, 0 }
    )
  end
end

--------------------------------------------------------------------------------
T.section("a scene started inside a press's hold delay replaces the hold")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("SET_LEVEL", { LEVEL = "80" })
  W.run(3000)
  proxy("PUSH_SCENE", { SCENE_ID = "7", ELEMENTS = levelStep(20, 2000) .. levelStep(60, 1000, 500) })
  mark()
  proxy("BUTTON_ACTION", { BUTTON_ID = TOP, ACTION = PRESS })
  W.run(100)
  proxy("ACTIVATE_SCENE", { SCENE_ID = "7" })
  W.run(15000)
  T.differs(
    "its steps run, and the hold never begins",
    "A command during a keypad's 250 ms press wait leaves it; the hold starts if the button stays down."
  )
  proxy("CLEAR_ALL_SCENES")
end

--------------------------------------------------------------------------------
T.section("a color set while the light is off is the one its next on comes on in, over the Color On Mode's")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  proxy("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = "3",
    COLOR_PRESET_ORIGIN = "2",
    COLOR_PRESET_COLOR_X = "0.15",
    COLOR_PRESET_COLOR_Y = "0.06",
    COLOR_PRESET_COLOR_MODE = "0",
    COLOR_FADE_PRESET_ID = "0",
    COLOR_FADE_PRESET_ORIGIN = "0",
  })
  proxy("OFF")
  W.run(3000)
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = "0.17", LIGHT_COLOR_TARGET_Y = "0.70", LIGHT_COLOR_TARGET_MODE = "0", RATE = "0" }
  )
  W.run(3000)
  T.eq("the proxy is told it at once", #toldOf("LIGHT_COLOR_CHANGED"), 1)
  T.eq("it goes to the controller, which stays off", { sent()[1] and sent()[1].on, fake.si.state.on }, { nil, false })
  proxy("ON")
  W.run(3000)
  local col = fake.si.state.seg[1].col[1]
  T.truthy("the next on comes on in it, over the blue On color", col[2] == 255 and col[3] < 128, T.show(col))
  proxy("OFF")
  W.run(3000)
  proxy("ON")
  W.run(3000)
  col = fake.si.state.seg[1].col[1]
  T.truthy("it holds for that on alone: the one after is in the On color", col[3] == 255 and col[2] < 64, T.show(col))
end

--------------------------------------------------------------------------------
T.section("a light's buttons have the proxy's colors, and each link is told them as it comes online")
--------------------------------------------------------------------------------
do
  local setup = setupFile("setup-643.xml"):gsub("<ON_COLOR>0000ff</ON_COLOR>", "<ON_COLOR>00ff00</ON_COLOR>", 1)
  ShimSetUIRequest(function(_, request)
    return request == "GET_SETUP" and setup or ""
  end)
  require("lib.persist"):delete("button_colors")
  fresh("esp32-rgbw-pwm-16")
  T.eq("the On link is told the proxy's colors", linkColors(300), { "00ff00", "000000" })
  T.eq(
    "and the Toggle and Off links theirs",
    { linkColors(301), linkColors(302) },
    { { "0000ff", "000000" }, { "000000", "0000ff" } }
  )
  mark()
  ReceivedFromProxy(300, "REQUEST_BUTTON_COLORS", {})
  T.eq("the On link asking is answered with them", linkColors(300), { "00ff00", "000000" })
  ShimSetUIRequest(function()
    return ""
  end)
  require("lib.persist"):delete("button_colors")
end

--------------------------------------------------------------------------------
T.section("a light's own proxy as measured: Dim-To-Warm between two presets of one color, and rates of 750 ms")
--------------------------------------------------------------------------------
do
  -- setup-643.xml: an unedited RGBCT light's proxy. Both presets are 3200 K.
  local setup = setupFile("setup-643.xml")
  ShimSetUIRequest(function(_, request)
    return request == "GET_SETUP" and setup or ""
  end)
  for _, key in ipairs({ "color_on_mode", "brightness_rate_default", "color_rate_default" }) do
    require("lib.persist"):delete(key)
  end
  fresh("esp32-rgbw-pwm-16")
  proxy("OFF")
  W.run(3000)
  mark()
  proxy("ON")
  W.run(3000)
  local last = sent()[#sent()]
  -- (3200 - 2700) / (6500 - 2700) of 255.
  T.truthy(
    "an on is in the On Color, a color temperature: CCT 34",
    last and last.seg and math.abs(last.seg[1].cct - 34) <= 1,
    T.show(last)
  )
  mark()
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30" })
  W.run(3000)
  last = sent()[#sent()]
  T.eq("a level with no rate goes out over the proxy's 750 ms", last and { last.bri, last.tt }, { 77, 8 })
  ShimSetUIRequest(function()
    return ""
  end)
end

T.finish()
