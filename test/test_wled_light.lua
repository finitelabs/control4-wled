--- The WLED controller's light against a fake controller: capabilities from the
--- controller's bits and their changes, levels and the straight-line fade, long
--- fades in legs, colors that end an effect, color temperature, a rated on from
--- off, the controller's echoes, and 16.0.1 and 0.15.4 controllers.
---
--- Run from the driver root:
---   make test

local T = require("testlib")
local W = require("wled_fake")
require("color_math").install()

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"
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
    { "esp32-rgbw-pwm-16", true, true, true },
    { "esp32-rgbw-015", true, false, true },
    { "esp8266-ws2812b-015", true, false, true },
    { "esp32-cct-16", false, true, true },
    { "esp32-white-16", false, false, true },
    { "esp32-relay-16", false, false, false },
  }
  for _, c in ipairs(cases) do
    fresh(c[1])
    local caps = lastCaps() or {}
    T.eq(
      c[1] .. ": color, color temperature, dimming",
      { caps.supports_color, caps.supports_color_correlated_temperature, caps.dimmer },
      { c[2], c[3], c[4] }
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
T.section("a fade longer than one command carries goes in legs on one line")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  mark()
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
    "four legs of 50 s, along one line from 128 to 255",
    { bris, tts },
    { { 160, 192, 223, 255 }, { 500, 500, 500, 500 } }
  )
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
  proxy("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = "4000", RATE = "0" })
  cmd = sent()[1]
  cct = cmd and cmd.seg[1].cct
  T.truthy("other white points move it: CCT 128", cct and math.abs(cct - 128) <= 1, cct)
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
  T.eq("two commands", #cmds, 2)
  T.eq(
    "first the color, at once, the light left off",
    cmds[1] and { cmds[1].on, cmds[1].bri, cmds[1].tt },
    { nil, nil, 0 }
  )
  T.truthy("green", cmds[1] and cmds[1].seg and cmds[1].seg[1].col[1][2] == 255)
  T.eq("then on, to 80 over 2 s", cmds[2] and { cmds[2].on, cmds[2].bri, cmds[2].tt }, { true, 204, 20 })
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
  proxy("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "200000" })
  W.run(201000)
  local cmds = sent()
  local last = cmds[#cmds]
  T.eq("the last leg turns it off and keeps the starting level", last and { last.on, last.bri }, { false, 204 })
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

T.finish()
