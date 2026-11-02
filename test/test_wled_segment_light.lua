--- A WLED Segment light against the fake controller, through what the WLED driver would tell it:
--- its capabilities from its own segment, its level and power as its segment's, lighting it while
--- the controller is off and turning off the last lit one, colors on its segment only, Segment not
--- found, and binding. The light's commands are applied to the fake and its state told back, as
--- the WLED driver passes them both ways.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_segment_light.lua

local T = require("testlib")
local W = require("wled_fake")
require("color_math").install()

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled_segment/driver.lua"
local XML = HERE .. "/../drivers/wled_segment/driver.xml"

local PROXY, CONTROLLER = 5001, 5002

package.preload["cloud-client-byte"] = function()
  return {}
end

local Device = require("wled.device")
local Segment = require("wled.segment")

local function readXml()
  local f = assert(io.open(XML, "r"))
  local xml = f:read("*a")
  f:close()
  return xml
end

local function defaultProperties()
  local props = {}
  for block in readXml():gmatch("<property>(.-)</property>") do
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
  return 9001
end

function C4:GetDeviceVariable()
  return nil
end

local told = {}

--- How many of the commands since the mark were applied to the controller.
local applied = 0

function C4:SendToProxy(binding, command, params)
  told[#told + 1] = { binding = binding, command = command, params = params or {} }
end

local function mark()
  told, applied = {}, 0
end

--- @param binding integer
--- @param command string
--- @return table[] params
local function toldOf(binding, command)
  local out = {}
  for _, t in ipairs(told) do
    if t.binding == binding and t.command == command then
      out[#out + 1] = t.params
    end
  end
  return out
end

--- The commands the light sent since the mark, as the JSON the controller gets.
--- @return table[]
local function commands()
  local out = {}
  for _, p in ipairs(toldOf(CONTROLLER, "ENTITY_COMMAND")) do
    out[#out + 1] = DeserializeSafe(p.body)
  end
  return out
end

local function lastLevel()
  local levels = toldOf(PROXY, "LIGHT_BRIGHTNESS_CHANGED")
  return levels[#levels] and levels[#levels].LIGHT_BRIGHTNESS_CURRENT
end

local fake
--- The segment this light stands for, by its WLED id.
local segmentId = 0

--- Tell the light what the controller shows now, as the WLED driver does.
local function report()
  local device = Device.new()
  device:update(fake.si.state, fake.si.info)
  RFP.UPDATE_STATE(CONTROLLER, "UPDATE_STATE", { segment = SerializeSafe(Segment.payload(device, segmentId)) })
end

--- Apply the light's commands since the mark to the controller, tell it the result, and let
--- its fade run out.
local function through()
  local all = commands()
  for i = applied + 1, #all do
    fake:apply(all[i])
  end
  applied = #all
  report()
  W.run(3000)
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

local function fresh(profile, id, setup)
  W.reset()
  fake = W.Fake.new(profile)
  if setup then
    setup(fake)
  end
  segmentId = id
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  T.unload("^wled%.")
  for _, key in ipairs({ "color_on_mode", "previous_color", "white_point", "brightness_on_mode" }) do
    require("lib.persist"):delete(key)
  end
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

--------------------------------------------------------------------------------
T.section("Before and after the WLED driver tells it its segment")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  T.eq("asks for its segment at start", #toldOf(CONTROLLER, "REFRESH_STATE"), 1)
  T.eq("connecting meanwhile", Properties["Driver Status"], "Connecting")
  T.eq("and not Connected", Variables["Connected"], "0")
  T.contains("driver.xml has no Extras", readXml(), "<has_extras>False</has_extras>")
  mark()
  report()
  T.eq("Connected once told", { Properties["Driver Status"], Variables["Connected"] }, { "Connected", "1" })
  T.eq("its segment described", Properties["Segment"], "Accent: LEDs 60-60, RGB, tunable white")
  local caps = toldOf(PROXY, "DYNAMIC_CAPABILITIES_CHANGED")
  local last = caps[#caps] or {}
  T.eq("color and color temperature, from its own segment's bits", {
    last.supports_color,
    last.supports_color_correlated_temperature,
  }, { true, true })
  T.eq("no Extras", last.has_extras, false)
  T.eq("its level is its segment's", lastLevel(), 100)
end

do
  fresh("esp32-rgbw-pwm-16", 0)
  mark()
  report()
  local caps = toldOf(PROXY, "DYNAMIC_CAPABILITIES_CHANGED")
  T.eq("the RGBW segment has no color temperature", (caps[#caps] or {}).supports_color_correlated_temperature, false)
end

--------------------------------------------------------------------------------
T.section("Its level and power are its segment's")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 0)
  report()
  mark()
  proxy("SET_LEVEL", { LEVEL = "50" })
  local cmd = commands()[1] or {}
  T.eq("a level goes to its segment", cmd.seg and cmd.seg[1].bri, 128)
  T.eq("for its segment only", cmd.seg and #cmd.seg, 1)
  T.eq("and leaves the master alone", { cmd.on, cmd.bri }, { nil, nil })
  T.eq("its segment id with it", toldOf(CONTROLLER, "ENTITY_COMMAND")[1].segment, 0)
  through()
  T.eq("the controller's master is as it was", fake.si.state.bri, 128)
  T.eq("its segment at half", fake.si.state.seg[1].bri, 128)
  T.eq("the other segment untouched", fake.si.state.seg[2].bri, 255)

  mark()
  proxy("OFF")
  cmd = commands()[1] or {}
  T.eq("off with another segment lit: its segment only", { cmd.on, cmd.seg and cmd.seg[1].on }, { nil, false })
  through()
  T.eq("the controller stays on", fake.si.state.on, true)
  T.eq("and the light reads off", lastLevel(), 0)
end

do
  fresh("esp32-rgbw-pwm-16", 0)
  report()
  fake:applyFields({ seg = { { id = 1, on = false } } })
  report()
  mark()
  proxy("OFF")
  local cmd = commands()[1] or {}
  T.eq("off as the last lit segment: the controller too", { cmd.on, cmd.seg and cmd.seg[1].on }, { false, false })
  through()
  T.eq("the controller is off", fake.si.state.on, false)

  mark()
  proxy("ON")
  cmd = commands()[#commands()] or {}
  T.eq("on with the controller off: the controller on", cmd.on, true)
  local others = {}
  for _, s in ipairs(cmd.seg or {}) do
    others[#others + 1] = s.id .. "=" .. tostring(s.on)
  end
  T.eq("this segment on and the other off", others, { "0=true", "1=false" })
  through()
  T.eq("the strip shows only this segment", {
    fake.si.state.on,
    fake.si.state.seg[1].on,
    fake.si.state.seg[2].on,
  }, { true, true, false })
  T.truthy("and the light reads on", (lastLevel() or 0) > 0)
end

do
  fresh("esp32-rgbw-pwm-16", 1)
  report()
  fake:applyFields({ on = false })
  mark()
  report()
  T.eq("its segment on but the controller off: it reads off", lastLevel(), 0)
end

--------------------------------------------------------------------------------
T.section("Colors go to its segment")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  report()
  mark()
  proxy(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = 0.64, LIGHT_COLOR_TARGET_Y = 0.33, LIGHT_COLOR_TARGET_MODE = 0, RATE = 0 }
  )
  local cmd = commands()[1] or {}
  T.eq("its segment only", cmd.seg and #cmd.seg, 1)
  T.eq("by its id", cmd.seg and cmd.seg[1].id, 1)
  T.eq("solid, ending an effect", cmd.seg and cmd.seg[1].fx, 0)
  through()
  T.eq("the controller shows red on it", fake.si.state.seg[2].col[1][1] > fake.si.state.seg[2].col[1][3], true)
  T.eq(
    "the other segment keeps its color",
    fake.si.state.seg[1].col[1],
    W.fixture("esp32-rgbw-pwm-16", "si.json").state.seg[1].col[1]
  )

  mark()
  proxy("RAMP_TO_LEVEL", { LEVEL = "20", TIME = "3000" })
  cmd = commands()[1] or {}
  T.eq("a fade keeps its rate", cmd.tt, 30)
end

--------------------------------------------------------------------------------
T.section("Segment not found, and binding")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  report()
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { status = "Segment not found" })
  T.eq("shows why", Properties["Driver Status"], "Segment not found")
  T.eq("and not Connected", Variables["Connected"], "0")
  T.eq("the light goes offline", (toldOf(PROXY, "ONLINE_CHANGED")[1] or {}).STATE, false)
  mark()
  proxy("ON")
  T.eq("and drives nothing", #commands(), 0)

  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
  T.eq("a controller that went away", Properties["Driver Status"], "Not connected to the WLED controller")

  report()
  mark()
  proxy("RAMP_TO_LEVEL", { LEVEL = "10", TIME = "140000" })
  T.eq("a fade too long for one command starts", #commands(), 1)
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { status = "Segment not found" })
  W.run(140000)
  T.eq("its later legs send nothing once the segment is gone", #commands(), 1)

  mark()
  OBC[CONTROLLER](CONTROLLER, "WLED_SEGMENT", false)
  T.eq("unbound: says what to do", Properties["Driver Status"], "Bind this light to a WLED driver's segment connection")
  mark()
  OBC[CONTROLLER](CONTROLLER, "WLED_SEGMENT", true)
  T.eq("bound: asks for its segment", #toldOf(CONTROLLER, "REFRESH_STATE"), 1)
  report()
  T.eq("and shows it", Properties["Driver Status"], "Connected")
end

T.finish()
