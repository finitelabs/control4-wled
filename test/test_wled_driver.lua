--- The WLED driver against a fake controller: Connected and its events at every reconnect,
--- Device Info for a 16.0.1 and a 0.15.4 controller, what the light proxy is told at a start
--- and a restart, a different controller at the address, and the IP Address property.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_driver.lua

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"
local PROXY = 5001

-- The DriverCentral client is not part of the shim; neither build needs it under test.
package.preload["cloud-client-byte"] = function()
  return {}
end

-- HTTP goes to the fake, as the client takes lib.http when it is not handed one.
package.loaded["lib.http"] = W.http

--- Properties as Composer gives them at a first load: every name in driver.xml with its default.
local function defaultProperties()
  local f = assert(io.open(XML, "r"))
  local xml = f:read("*a")
  f:close()
  local props = {}
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    if name then
      props[name] = default
    end
  end
  return props
end

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.2"
  end
  if section == "config" then
    -- Director gives the driver.xml <config> section, which property resets read.
    local f = assert(io.open(XML, "r"))
    local xml = f:read("*a")
    f:close()
    return xml:match("<config>(.-)</config>")
  end
  return configInfo(self, section)
end

function C4:GetDevicesByC4iName()
  return {}
end

-- Director writes a property's new value back; the shim's UpdateProperty does not.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

local told, events = {}, {}

-- The proxy's variables as it keeps them over a driver reload: Brightness Percent (1001) and
-- its target (1110), Current Color Chromaticity (1200) and its target (1210), and its
-- Navigator Dynamic Capabilities (6661), driver.xml's until it is told others and again after a
-- controller start (measured on dev; test/light_proxy_fake.lua models the same).
local PROXY_DEVICE = 9001
local proxyVars = {}
local proxyCaps = {}

local CAPABILITY_KEYS = {
  "dimmer",
  "supports_target",
  "supports_brightness_stop",
  "supports_color",
  "supports_color_correlated_temperature",
  "supports_color_stop",
  "brightness_rate_min",
  "brightness_rate_max",
  "color_correlated_temperature_min",
  "color_correlated_temperature_max",
  "color_rate_behavior",
  "color_rate_min",
  "color_rate_max",
  "has_extras",
  "click_rate_min",
  "click_rate_max",
  "hold_rate_min",
  "hold_rate_max",
  "cold_start",
  "supports_color_cycling",
  "advanced_scene_support",
  "hide_proxy_properties",
  "hide_proxy_commands",
  "hide_proxy_events",
  "hide_proxy_conditionals_loops",
}

--- Put the proxy's 6661 back on driver.xml's capabilities, as a new proxy and a controller start do.
local function showStaticCapabilities()
  local f = assert(io.open(XML, "rb"))
  local static = f:read("*a"):match("<capabilities>(.-)</capabilities>")
  f:close()
  proxyCaps = {}
  for _, key in ipairs(CAPABILITY_KEYS) do
    proxyCaps[key] = static:match("<" .. key .. ">([^<]*)</" .. key .. ">") or "False"
  end
end

function C4:GetProxyDevices()
  return PROXY_DEVICE
end

function C4:GetDeviceVariable(id, variable)
  if id ~= PROXY_DEVICE then
    return nil
  end
  if variable == 6661 then
    local xml = {}
    for key, value in pairs(proxyCaps) do
      xml[#xml + 1] = ("<%s>%s</%s>"):format(key, value, key)
    end
    return "<DynamicCapabilities>" .. table.concat(xml) .. "</DynamicCapabilities>"
  end
  return proxyVars[variable]
end

function C4:SendToProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  told[#told + 1] = { binding = idBinding, command = strCommand, params = tParams }
  if idBinding ~= PROXY then
    return
  end
  local p = tParams
  if strCommand == "LIGHT_BRIGHTNESS_CHANGED" or strCommand == "LIGHT_BRIGHTNESS_CHANGING" then
    proxyVars[1001] = tostring(p.LIGHT_BRIGHTNESS_CURRENT)
    proxyVars[1110] = tostring(p.LIGHT_BRIGHTNESS_TARGET or p.LIGHT_BRIGHTNESS_CURRENT)
  elseif strCommand == "LIGHT_COLOR_CHANGED" or strCommand == "LIGHT_COLOR_CHANGING" then
    local form = "%g,%g,%d"
    proxyVars[1200] = form:format(p.LIGHT_COLOR_CURRENT_X, p.LIGHT_COLOR_CURRENT_Y, p.LIGHT_COLOR_CURRENT_COLOR_MODE)
    proxyVars[1210] = p.LIGHT_COLOR_TARGET_X
        and form:format(p.LIGHT_COLOR_TARGET_X, p.LIGHT_COLOR_TARGET_Y, p.LIGHT_COLOR_TARGET_COLOR_MODE)
      or proxyVars[1200]
  elseif strCommand == "DYNAMIC_CAPABILITIES_CHANGED" then
    for key, value in pairs(p) do
      proxyCaps[key] = type(value) == "boolean" and (value and "True" or "False") or tostring(value)
    end
  end
end

function C4:FireEventByID(id)
  events[#events + 1] = id
end

local function mark()
  told, events = {}, {}
end

local function toldCount(command)
  local n = 0
  for _, t in ipairs(told) do
    if t.binding == PROXY and t.command == command then
      n = n + 1
    end
  end
  return n
end

local function lastOnline()
  local state
  for _, t in ipairs(told) do
    if t.command == "ONLINE_CHANGED" then
      state = t.params.STATE
    end
  end
  return state
end

local function eventCount(id)
  local n = 0
  for _, e in ipairs(events) do
    if e == id then
      n = n + 1
    end
  end
  return n
end

local nextHost = 40

--- A fresh project: default properties, an empty store, the driver loaded and started.
--- @param profile string
--- @param unreachable boolean|nil The controller does not answer from the start.
local function fresh(profile, unreachable)
  W.reset()
  proxyVars = {}
  showStaticCapabilities()
  nextHost = nextHost + 1
  local fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  fake.reachable = not unreachable
  local persist = require("lib.persist")
  persist:delete("WledControllerMac")
  persist:delete("WledShown")
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  Properties["IP Address"] = fake.ip
  T.unload("^drivers%-common%-public%.module%.websocket$", "^wled%.")
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
  return fake
end

--- Reload the driver over what it stored: the old instance is destroyed and the new one loads in a
--- fresh Lua state, as a driver update or a Director restart makes it.
--- @param how "update"|"restart"
local function restart(how)
  OnDriverDestroyed()
  W.reload(how)
  if how == "restart" then
    showStaticCapabilities()
  end
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

--------------------------------------------------------------------------------
T.section("Connects to a 16.0.1 controller and shows what it reports")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  T.eq("connecting until the first state", Properties["Driver Status"], "Connecting")
  W.run(200)
  T.eq("status", Properties["Driver Status"], "Connected")
  T.eq("Connected variable", Variables["Connected"], "1")
  T.eq("Connected event once", eventCount(1), 1)
  T.eq("no Disconnected event", eventCount(2), 0)
  T.eq("proxy told offline at late init, then online", toldCount("ONLINE_CHANGED"), 2)
  T.eq("proxy online", lastOnline(), true)
  T.eq("Name", Properties["Name"], "Mock Shelf Controller")
  T.eq("Brand", Properties["Brand"], "WLED")
  T.eq("Product", Properties["Product"], "FOSS")
  T.eq("Firmware Version", Properties["Firmware Version"], "16.0.1")
  T.eq("MAC Address", Properties["MAC Address"], "02:A1:B2:C3:D4:02")
  T.eq("LED Count", Properties["LED Count"], "61")
  T.eq("Segments", Properties["Segments"], "0: Strip 0-59 RGBW; 1: Accent 60-60 RGB, tunable white")
end

--------------------------------------------------------------------------------
T.section("Connects to a 0.15.4 ESP8266 controller")
--------------------------------------------------------------------------------
do
  fresh("esp8266-ws2812b-015")
  W.run(200)
  T.eq("status", Properties["Driver Status"], "Connected")
  T.eq("Firmware Version", Properties["Firmware Version"], "0.15.4")
  T.eq("MAC Address", Properties["MAC Address"], "02:A1:B2:C3:D4:01")
  T.eq("LED Count", Properties["LED Count"], "60")
  T.eq("Segments from seglc", Properties["Segments"]:match("RGB$"), "RGB")
end

--------------------------------------------------------------------------------
T.section("A controller on firmware older than 0.15 is driven, and the status says to update it")
--------------------------------------------------------------------------------
do
  -- Some controllers ship with 0.14 installed; the 0.15 profile reports it as 0.14.0 here.
  local fake = fresh("esp32-rgbw-015")
  fake.si.info.ver, fake.si.info.vid = "0.14.0", 2310130
  W.run(200)
  T.eq("status", Properties["Driver Status"], "Connected; WLED 0.14.0 is older than 0.15, update WLED")
  T.eq("Connected variable", Variables["Connected"], "1")
  T.eq("proxy online", lastOnline(), true)
  T.eq("Firmware Version", Properties["Firmware Version"], "0.14.0")

  -- WLED updated in place: it restarts and comes back on 0.15.
  fake.si.info.ver, fake.si.info.vid = "0.15.4", 2508020
  fake:drop()
  W.run(5000)
  T.eq("status after the update", Properties["Driver Status"], "Connected")
end

--------------------------------------------------------------------------------
T.section("A start tells the light its level and color once, and its capabilities at a first start and a restart")
--------------------------------------------------------------------------------
-- A controller start puts the proxy back on driver.xml's capabilities. The build writes their rates
-- at the library's 65535 ms while WLED's fades go to a day in legs, so every light is told them at its
-- first start and after a controller restart; a reload keeps what was told (lib.light.proxy).
for _, case in ipairs({ { "esp32-rgbw-pwm-16", 1 }, { "esp32-white-16", 0 } }) do
  local profile, color = case[1], case[2]
  for _, how in ipairs({ "update", "restart" }) do
    local name = ("%s, %s"):format(profile, how)
    fresh(profile)
    W.run(200)
    T.eq("capabilities told at the first start (" .. name .. ")", toldCount("DYNAMIC_CAPABILITIES_CHANGED"), 1)
    if color == 0 then
      T.differs(
        "a white light is told no capabilities at its first start (" .. name .. ")",
        "lib.light tells the capabilities at a first start and a restart: the build's rate keys of 65535 differ from WLED's day-long fades"
      )
    end
    T.eq("the level told once (" .. name .. ")", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 1)
    T.eq("the color told once, if it has one (" .. name .. ")", toldCount("LIGHT_COLOR_CHANGED"), color)
    restart(how)
    W.run(200)
    T.eq(
      "capabilities told again only at a restart (" .. name .. ")",
      toldCount("DYNAMIC_CAPABILITIES_CHANGED"),
      how == "restart" and 1 or 0
    )
    if color == 0 and how == "restart" then
      T.differs(
        "a white light is told no capabilities again at a restart (" .. name .. ")",
        "lib.light tells the capabilities at a first start and a restart: the build's rate keys of 65535 differ from WLED's day-long fades"
      )
    end
    T.eq("no level after a reload (" .. name .. ")", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 0)
    T.eq("no color after a reload (" .. name .. ")", toldCount("LIGHT_COLOR_CHANGED"), 0)
    T.eq("Connected event fires at a reload's connect (" .. name .. ")", eventCount(1), 1)
    T.eq("Connected again (" .. name .. ")", Variables["Connected"], "1")
  end
end

--------------------------------------------------------------------------------
T.section("Losing the controller, and every reconnect after")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  fake.reachable = false
  fake:drop()
  W.run(200)
  T.eq("Disconnected event", eventCount(2), 1)
  T.eq("Connected variable off", Variables["Connected"], "0")
  T.eq("proxy offline", lastOnline(), false)
  T.contains("status says why", Properties["Driver Status"], "Not connected:")
  T.eq("Device Info kept", Properties["Firmware Version"], "16.0.1")

  mark()
  fake.reachable = true
  W.run(40000)
  T.eq("Connected event at the reconnect", eventCount(1), 1)
  T.eq("proxy online again", lastOnline(), true)
  T.eq("status", Properties["Driver Status"], "Connected")

  mark()
  fake:close(1013)
  W.run(100)
  T.eq("a close with HTTP still answering stays connected", eventCount(2), 0)
  T.contains("status shows HTTP", Properties["Driver Status"], "over HTTP")
  W.run(5000)
  T.eq("live updates back", Properties["Driver Status"], "Connected")
  T.eq("no events for a socket that came back", #events, 0)
end

--------------------------------------------------------------------------------
T.section("A different controller at the address is not driven")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  -- Another controller takes the address.
  fake.si.info.mac = "02a1b2c3d4ee"
  fake:drop()
  W.run(5000)
  T.contains("status names the other controller", Properties["Driver Status"], "02:A1:B2:C3:D4:EE")
  T.contains("and the way to accept it", Properties["Driver Status"], "Reset Driver")
  T.eq("Connected off", Variables["Connected"], "0")
  T.eq("proxy offline", lastOnline(), false)
  T.eq("Disconnected event", eventCount(2), 1)
  T.eq("Device Info still shows the remembered one", Properties["MAC Address"], "02:A1:B2:C3:D4:02")

  mark()
  W.run(60000)
  T.eq("stays not driven", Variables["Connected"], "0")
  T.eq("no Connected event", eventCount(1), 0)

  mark()
  EC.Reset_Driver({ ["Are You Sure?"] = "No" })
  W.run(5000)
  T.eq("No changes nothing", Variables["Connected"], "0")

  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  W.run(5000)
  T.eq("Reset Driver takes the new controller", Variables["Connected"], "1")
  T.eq("its MAC shown", Properties["MAC Address"], "02:A1:B2:C3:D4:EE")
  T.eq("Connected event", eventCount(1), 1)
end

--------------------------------------------------------------------------------
T.section("The Controller Connected conditional follows the connection")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  local function test(value, logic)
    return TestCondition("CONTROLLER_CONNECTED", { VALUE = value, LOGIC = logic })
  end
  T.eq("is Connected while connected", test("Connected", "EQUAL"), true)
  T.eq("is not Disconnected while connected", test("Disconnected", "EQUAL"), false)
  T.eq("NOT_EQUAL Connected while connected", test("Connected", "NOT_EQUAL"), false)
  fake.reachable = false
  fake:drop()
  W.run(30000)
  T.eq("is Disconnected once the controller is lost", test("Disconnected", "EQUAL"), true)
  T.eq("NOT_EQUAL Connected once lost", test("Connected", "NOT_EQUAL"), true)
end

--------------------------------------------------------------------------------
T.section("Reset Driver returns the driver to its first load, keeping the address")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  Properties["Warm White (K)"] = "3000"
  Properties["Cool White (K)"] = "5000"
  Properties["Log Level"] = "5 - Debug"
  Properties["Cloud Monitoring"] = "Disabled"
  Properties["Automatic Updates"] = "Off"
  Properties["Update Channel"] = "Prerelease"
  local persist = require("lib.persist")
  T.eq("connected before the reset", Variables["Connected"], "1")
  T.eq("lit before the reset", proxyVars[1001] ~= nil and proxyVars[1001] ~= "0", true)
  mark()
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  T.differs(
    "the white this light picked is forgotten",
    "the copied model's white_point memo is gone: the WLED adapter keeps none"
  )
  T.eq("and what programming last saw", persist:get("WledShown"), nil)
  W.run(5000)
  T.eq("the proxy hears offline, then online", toldCount("ONLINE_CHANGED") >= 2 and lastOnline(), true)
  T.eq("no level told for a light that did not change", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 0)
  T.eq("Cloud Monitoring back to its default", Properties["Cloud Monitoring"], "Enabled")
  T.eq("Warm White back to its default", Properties["Warm White (K)"], "2700")
  T.eq("Cool White back to its default", Properties["Cool White (K)"], "6500")
  T.eq("Log Level back to its default", Properties["Log Level"], "3 - Info")
  T.eq("but Automatic Updates, shared with every item, stays as it was", Properties["Automatic Updates"], "Off")
  T.eq("and so does Update Channel", Properties["Update Channel"], "Prerelease")
  T.eq("IP Address kept", Properties["IP Address"], fake.ip)
  T.eq("connected again", Variables["Connected"], "1")
  T.eq("and Connected fired for the new start", eventCount(1), 1)
end

do
  fresh("esp32-rgbw-pwm-16")
  W.run(200)
  -- The fixed links from driver.xml, as Director lists them, with a keypad button on each.
  local fixed, me = {}, C4:GetDeviceID()
  for i, id in ipairs({ 300, 301, 302, 303, 304, 5001 }) do
    fixed[i] = {
      id = id,
      type = id == 5001 and "PROXY" or "CONTROL",
      provider = true,
      name = "Link " .. id,
      class = id == 5001 and "LIGHT_V2" or "BUTTON_LINK",
    }
  end
  ShimSetStaticBindings(fixed)
  for _, id in ipairs({ 300, 301, 302, 303, 304 }) do
    C4:Bind(me, id, 800 + id - 300, 1, "BUTTON_LINK")
  end
  C4:Bind(me, 5001, 9001, 5001, "LIGHT_V2")
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  local left = {}
  for _, c in ipairs(ShimConnections()) do
    left[#left + 1] = c.providerBinding
  end
  T.eq("Reset Driver unwires every keypad from the button links, and keeps the light's proxy", left, { 5001 })
  ShimSetStaticBindings({})
  ShimResetDynamicBindings()
end

--------------------------------------------------------------------------------
T.section("Reset Driver with the controller gone tells the proxy and programming it went away")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  fake.reachable = false
  fake:drop()
  mark()
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  W.run(60000)
  T.eq("the proxy hears offline", lastOnline(), false)
  T.eq("Disconnected fires once", eventCount(2), 1)
  T.eq("the variable reads disconnected", Variables["Connected"], "0")
end

--------------------------------------------------------------------------------
T.section("A light with no report since a load or a suspend reads off once the controller is found gone")
--------------------------------------------------------------------------------
do
  for _, how in ipairs({ "update", "restart" }) do
    local fake = fresh("esp32-rgbw-pwm-16")
    W.run(200)
    fake.reachable = false
    restart(how)
    W.run(60000)
    T.eq(
      "reloaded with the controller gone: it reads off once (" .. how .. ")",
      toldCount("LIGHT_BRIGHTNESS_CHANGED"),
      1
    )
    T.eq("at 0 (" .. how .. ")", proxyVars[1001], "0")
  end

  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  fake.reachable = false
  mark()
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  W.run(60000)
  T.eq("Reset Driver, then the controller gone: it reads off once", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 1)
  T.eq("at 0", proxyVars[1001], "0")

  fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  fake.si.info.mac = "02a1b2c3d4ee"
  fake:drop()
  W.run(30000)
  T.eq("a different controller answering at every report: it reads off once", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("The IP Address property")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  Properties["IP Address"] = ""
  OnPropertyChanged("IP Address")
  W.run(100)
  T.contains("empty address asks for one", Properties["Driver Status"], "Set the IP Address")
  T.eq("not connected", Variables["Connected"], "0")
  T.eq("Disconnected event", eventCount(2), 1)

  -- A second controller at a new address; the store still holds the first one's MAC.
  local second = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2.99" })
  mark()
  Properties["IP Address"] = " 192.0.2.99 "
  OnPropertyChanged("IP Address")
  W.run(200)
  T.eq("connects to the new address", Properties["Driver Status"], "Connected")
  T.eq("one connection there", second.connects, 1)
end

--------------------------------------------------------------------------------
T.section("An address that never answers ends Not connected")
--------------------------------------------------------------------------------
do
  -- First start against a controller that is gone.
  fresh("esp32-rgbw-pwm-16", true)
  W.run(30000)
  T.eq("first start", Properties["Driver Status"], "Not connected: No connection to the controller")
  T.eq("not connected", Variables["Connected"], "0")

  -- Restart with the controller still gone.
  for _, how in ipairs({ "update", "restart" }) do
    restart(how)
    W.run(30000)
    T.eq(
      "after a restart (" .. how .. ")",
      Properties["Driver Status"],
      "Not connected: No connection to the controller"
    )
    T.eq("not connected after a restart (" .. how .. ")", Variables["Connected"], "0")
  end

  -- Connected, then the IP Address moves to an address that does not answer.
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  T.eq("connected first", Variables["Connected"], "1")
  local gone = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2.98" })
  gone.reachable = false
  mark()
  Properties["IP Address"] = gone.ip
  OnPropertyChanged("IP Address")
  W.run(30000)
  T.eq("status", Properties["Driver Status"], "Not connected: No connection to the controller")
  T.eq("Connected variable off", Variables["Connected"], "0")
  T.eq("Disconnected event", eventCount(2), 1)
  T.eq("proxy offline", lastOnline(), false)
  T.eq("the old controller is left alone", fake.connects, 1)
end

--------------------------------------------------------------------------------
T.section("Destroying the driver stops its fades, timers and connection")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  ReceivedFromProxy(PROXY, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "200000" })
  W.run(1000)
  local sentBefore, connectsBefore = #fake.commands, fake.connects
  mark()
  OnDriverDestroyed()
  W.run(300000)
  T.eq("no fade leg after destroy", #fake.commands, sentBefore)
  T.eq("no reconnect after destroy", fake.connects, connectsBefore)
  T.eq("the proxy hears nothing after destroy", #told, 0)
end

--------------------------------------------------------------------------------
T.section("A start clears the WebSocket binding addresses an earlier run left")
--------------------------------------------------------------------------------
do
  local cleared = 0
  local original = C4.SetBindingAddress
  function C4:SetBindingAddress(id, address)
    if id >= 6100 and id <= 6199 and address == "" then
      cleared = cleared + 1
    end
  end
  OnDriverInit()
  C4.SetBindingAddress = original
  T.eq("all 100 network bindings cleared", cleared, 100)
end

--------------------------------------------------------------------------------
T.section("Light commands reach the controller")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  ReceivedFromProxy(PROXY, "SET_LEVEL", { LEVEL = "80" })
  W.run(2000)
  local last = fake.commands[#fake.commands]
  T.eq("a level goes out as master brightness at once", last and { last.bri, last.tt }, { 204, 0 })
  T.eq("and is told", toldCount("LIGHT_BRIGHTNESS_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("Live data from another system shows in Driver Status within one poll, though WLED pushes nothing")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  T.eq("connected", Properties["Driver Status"], "Connected")
  mark()
  -- An E1.31 sender takes over; WLED says so only in /json/si.
  fake:changeSilently(nil, { live = true, lm = "E1.31", lip = "192.0.2.200" })
  W.run(15200)
  T.eq(
    "the status says who is in control",
    Properties["Driver Status"],
    "Connected; live data from 192.0.2.200 (E1.31) is in control"
  )
  T.eq("still connected, no event", { Variables["Connected"], eventCount(1), eventCount(2) }, { "1", 0, 0 })
  T.eq("and the proxy is told nothing", #told, 0)

  -- It ends about 2.5 s after the sender's last packet.
  fake:changeSilently(nil, { live = false, lm = "", lip = "" })
  W.run(15200)
  T.eq("back to Connected once it ends", Properties["Driver Status"], "Connected")

  -- Neither the mode nor the address known: the status still says so.
  fake:changeSilently(nil, { live = true, lm = "", lip = "" })
  W.run(15200)
  T.eq("an unnamed sender", Properties["Driver Status"], "Connected; live data from another system is in control")
  fake:changeSilently(nil, { live = false })
  W.run(15200)
  T.eq("and back", Properties["Driver Status"], "Connected")

  -- With WLED's live override on, WLED shows its own state over the live data.
  fake:changeSilently({ lor = 1 }, { live = true, lm = "E1.31", lip = "192.0.2.200" })
  W.run(15200)
  T.eq("live data under the override is not in control", Properties["Driver Status"], "Connected")
  fake:changeSilently({ lor = 0 })
  W.run(15200)
  T.eq(
    "the override off, it is again",
    Properties["Driver Status"],
    "Connected; live data from 192.0.2.200 (E1.31) is in control"
  )
  fake:changeSilently(nil, { live = false })
  W.run(15200)
  T.eq("nothing told the proxy over a minute of polls", #told, 0)
  T.eq("no event either", #events, 0)
end

--------------------------------------------------------------------------------
T.section("Live data and old firmware together: the live clause first, then the update note")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-015")
  fake.si.info.ver, fake.si.info.vid = "0.14.0", 2310130
  W.run(200)
  fake:changeSilently(nil, { live = true, lm = "E1.31", lip = "192.0.2.200" })
  W.run(15200)
  T.eq(
    "both, in that order",
    Properties["Driver Status"],
    "Connected; live data from 192.0.2.200 (E1.31) is in control; WLED 0.14.0 is older than 0.15, update WLED"
  )
  fake:changeSilently(nil, { live = false, lm = "", lip = "" })
  W.run(15200)
  T.eq(
    "live data ended, the update note stays",
    Properties["Driver Status"],
    "Connected; WLED 0.14.0 is older than 0.15, update WLED"
  )
end

T.finish()
