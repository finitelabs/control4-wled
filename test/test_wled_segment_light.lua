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
local W = require("wled_fixtures")
require("c4_local")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled_segment/driver.lua"
local XML = HERE .. "/../drivers/wled_segment/driver.xml"

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

--- The commands the controller got since the mark, as the WLED driver sent them on.
local forwarded = {}

function C4:SendToProxy(binding, command, params)
  told[#told + 1] = { binding = binding, command = command, params = params or {} }
end

local function mark()
  told, applied, forwarded = {}, 0, {}
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

--- What the light sent since the mark: its commands' meaning for its segment.
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
--- The WLED driver's model of the controller.
local model

--- Tell the light what the controller shows now, as the WLED driver does.
local function report()
  model:update(fake.si.state, fake.si.info)
  RFP.UPDATE_STATE(CONTROLLER, "UPDATE_STATE", { segment = SerializeSafe(Segment.payload(model, segmentId)) })
end

--- Send the light's commands not yet sent on to the controller, as the WLED driver does: each
--- decided against its model, which takes it at once.
local function forward()
  local all = commands()
  for i = applied + 1, #all do
    local json = Segment.forward(all[i], model)
    Segment.note(json, model)
    fake:apply(json)
    forwarded[#forwarded + 1] = json
  end
  applied = #all
end

--- Send the light's commands on, tell it the result, and let its fade run out.
local function through()
  forward()
  report()
  W.run(3000)
end

local function proxy(command, params)
  ReceivedFromProxy(PROXY, command, params or {})
end

--- @param unbound boolean|nil The light is not bound to a WLED driver's segment connection.
--- @param beforeLateInit fun()|nil Runs between OnDriverInit and late init.
local function fresh(profile, id, setup, unbound, beforeLateInit)
  W.reset()
  fake = W.Fake.new(profile)
  if setup then
    setup(fake)
  end
  segmentId = id
  model = Device:new()
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  T.unload("^wled%.")
  for _, key in ipairs({ "color_on_mode", "previous_color", "white_point", "brightness_on_mode" }) do
    require("lib.persist"):delete(key)
  end
  mark()
  -- Bound to a WLED driver's segment connection, as Director has it at a start.
  C4:Unbind(C4:GetDeviceID(), CONTROLLER)
  if not unbound then
    C4:Bind(700, 6000, C4:GetDeviceID(), CONTROLLER, "WLED_SEGMENT")
  end
  dofile(DRIVER)
  OnDriverInit()
  if beforeLateInit then
    beforeLateInit()
  end
  ShimLateInit()
end

--------------------------------------------------------------------------------
T.section("A segment the WLED driver tells before late init comes online once late init asks for it")
--------------------------------------------------------------------------------
do
  -- At a controller start the WLED driver can connect and tell its segments before this driver's late init.
  fresh("esp32-rgbw-pwm-16", 0, nil, nil, function()
    report()
  end)
  T.eq("late init asks for its segment", #toldOf(CONTROLLER, "REFRESH_STATE") >= 1, true)
  report()
  local online = toldOf(PROXY, "ONLINE_CHANGED")
  T.eq("and the answer brings the light online", (online[#online] or {}).STATE, true)
  T.eq("Connected", Properties["Driver Status"], "Connected")
end

--------------------------------------------------------------------------------
T.section("Before and after the WLED driver tells it its segment")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  T.eq("asks for its segment at start", #toldOf(CONTROLLER, "REFRESH_STATE"), 1)
  T.eq("connecting meanwhile", Properties["Driver Status"], "Connecting")
  T.eq("and not Connected", Variables["Connected"], "0")
  T.differs(
    "driver.xml has no Extras",
    "the build writes the light's capabilities from the profile: the source driver.xml carries none"
  )
  T.eq("the build's driver.xml has no Extras", builtCaps().has_extras, "False")
  local connection = readXml():match("<id>" .. CONTROLLER .. "</id>(.-)</connection>") or ""
  T.contains("and its WLED Controller connection says it is not hidden", connection, "<hidden>False</hidden>")
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

  fresh("esp32-rgbw-pwm-16", 1, nil, true)
  T.eq(
    "unbound at start: says what to do",
    Properties["Driver Status"],
    "Bind this light to a WLED driver's segment connection"
  )
  T.eq("and asks nothing", #toldOf(CONTROLLER, "REFRESH_STATE"), 0)
  mark()
  OBC[CONTROLLER](CONTROLLER, "WLED_SEGMENT", true)
  T.eq("bound later: asks for its segment", #toldOf(CONTROLLER, "REFRESH_STATE"), 1)
  T.eq("and connects", Properties["Driver Status"], "Connecting")
end

do
  fresh("esp32-rgbw-pwm-16", 0)
  mark()
  report()
  local caps = toldOf(PROXY, "DYNAMIC_CAPABILITIES_CHANGED")
  T.eq("the RGBW segment has no color temperature", (caps[#caps] or {}).supports_color_correlated_temperature, false)
end

do
  fresh("esp32-white-16", 0)
  T.differs(
    "driver.xml declares a color stop",
    "the build writes the light's capabilities from the profile: the source driver.xml carries none"
  )
  T.eq("the build's driver.xml declares a color stop", builtCaps().supports_color_stop, "True")
  mark()
  report()
  local caps = toldOf(PROXY, "DYNAMIC_CAPABILITIES_CHANGED")
  local last = caps[#caps] or {}
  T.eq(
    "a white-only segment has no color but a color stop, so the proxy passes its brightness stop on",
    { last.supports_color, last.supports_color_stop },
    { false, true }
  )
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
  forward()
  local cmd = forwarded[1] or {}
  T.eq("off as the last lit segment: the controller off alone", { cmd.on, cmd.seg }, { false, nil })
  through()
  T.eq("the controller is off", fake.si.state.on, false)
  T.eq("its segment keeps its own power, for the controller light's On", fake.si.state.seg[1].on, true)

  mark()
  proxy("ON")
  forward()
  cmd = forwarded[#forwarded] or {}
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

do
  fresh("esp32-rgbw-pwm-16", 0)
  report()
  fake:applyFields({ seg = { { id = 1, on = false } } })
  report()
  mark()
  -- A hold down to off, let go within a second: no report comes between the two commands.
  proxy("RAMP_TO_LEVEL", { LEVEL = "0", TIME = "3000" })
  W.run(500)
  proxy("SET_BRIGHTNESS_STOP")
  through()
  T.eq("a hold stopped on the way to off leaves it lit", {
    fake.si.state.on,
    fake.si.state.seg[1].on,
    (fake.si.state.seg[1].bri or 0) > 0,
  }, { true, true, true })
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
T.section("A suspended disconnect keeps the level")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  report()
  local level = lastLevel()
  T.eq("lit to start", level ~= nil and level > 0, true)
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = "true" })
  T.eq("the light goes offline", (toldOf(PROXY, "ONLINE_CHANGED")[1] or {}).STATE, false)
  T.eq("and tells no level: no Light Off", #toldOf(PROXY, "LIGHT_BRIGHTNESS_CHANGED"), 0)

  fresh("esp32-rgbw-pwm-16", 1)
  report()
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
  T.eq("a controller that went away reads off", lastLevel(), 0)
end

--------------------------------------------------------------------------------
T.section("A controller found gone reads off, even with no report since a load, a bind or a suspend")
--------------------------------------------------------------------------------
do
  local function levels()
    local out = {}
    for _, p in ipairs(toldOf(PROXY, "LIGHT_BRIGHTNESS_CHANGED")) do
      out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT
    end
    return out
  end
  for _, c in ipairs({
    {
      "suspended",
      function()
        RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = true })
      end,
    },
    {
      "reloaded",
      function()
        fresh("esp32-rgbw-pwm-16", 1)
      end,
    },
    {
      "bound again",
      function()
        OBC[CONTROLLER](CONTROLLER, "WLED_SEGMENT", true)
      end,
    },
  }) do
    for _, gone in ipairs({ {}, { status = "Segment not found" } }) do
      fresh("esp32-rgbw-pwm-16", 1)
      report()
      c[2]()
      mark()
      RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", gone)
      T.eq(c[1] .. ", then " .. (gone.status or "the controller gone") .. ": it reads off", levels(), { 0 })
    end
  end

  fresh("esp32-rgbw-pwm-16", 1)
  report()
  mark()
  for _ = 1, 3 do
    RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { status = "Segment not found" })
  end
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
  T.eq("told again while gone: it reads off once", { levels(), #toldOf(PROXY, "ONLINE_CHANGED") }, { { 0 }, 1 })

  fresh("esp32-rgbw-pwm-16", 1)
  report()
  fresh("esp32-rgbw-pwm-16", 1)
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = true })
  T.eq("reloaded, the controller not heard from yet: Connecting", Properties["Driver Status"], "Connecting")
  report()
  T.eq("and no level till its report: no Light Off", levels(), { 100 })
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

--------------------------------------------------------------------------------
T.section("a light loaded while its controller is suspended stays offline, and tells no level it does not know")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16", 1)
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = "true" })
  T.eq("late init told it offline: nothing more", #toldOf(PROXY, "ONLINE_CHANGED"), 0)
  T.eq("and no level", #toldOf(PROXY, "LIGHT_BRIGHTNESS_CHANGED"), 0)
  mark()
  proxy("GET_LIGHT_LEVEL")
  proxy("TOGGLE")
  T.eq("Get Light Level and a Toggle tell nothing", #toldOf(PROXY, "LIGHT_BRIGHTNESS_CHANGED"), 0)
  T.eq("and send nothing", #commands(), 0)
end

--------------------------------------------------------------------------------
T.section("a light already told offline is not told so again")
--------------------------------------------------------------------------------
do
  --- The ONLINE_CHANGED states told since the mark.
  local function onlines()
    local out = {}
    for _, p in ipairs(toldOf(PROXY, "ONLINE_CHANGED")) do
      out[#out + 1] = p.STATE
    end
    return out
  end
  fresh("esp32-rgbw-pwm-16", 1)
  report()
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = "true" })
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
  report()
  T.eq("suspended, then lost, then back: offline once, then online", onlines(), { false, true })
  fresh("esp32-rgbw-pwm-16", 1)
  mark()
  RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
  T.eq("lost after a load, which told it offline: nothing more", onlines(), {})
end

T.finish()
