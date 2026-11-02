--- The WLED driver against a fake controller: Connected and its events at every reconnect,
--- Device Info for a 16.0.1 and a 0.15.4 controller, the light proxy's online state and nothing
--- else at a start, a different controller at the address, and the IP Address property.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_driver.lua

local T = require("testlib")
local W = require("wled_fake")

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

function C4:SendToProxy(idBinding, strCommand, tParams)
  told[#told + 1] = { binding = idBinding, command = strCommand, params = tParams or {} }
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
local function fresh(profile)
  W.reset()
  nextHost = nextHost + 1
  local fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  local persist = require("lib.persist")
  persist:delete("WledControllerMac")
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  Properties["IP Address"] = fake.ip
  mark()
  dofile(DRIVER)
  OnDriverLateInit()
  return fake
end

--- Reload the driver over its stored state, as a driver update or controller restart does:
--- the old instance is destroyed and the Lua modules load fresh.
local function restart()
  OnDriverDestroyed()
  T.unload("^drivers%-common%-public%.module%.websocket$", "^wled%.")
  mark()
  dofile(DRIVER)
  OnDriverLateInit()
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
  T.eq("proxy told online once", toldCount("ONLINE_CHANGED"), 1)
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
T.section("A start tells the light proxy its online state and nothing else")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  W.run(200)
  local other = 0
  for _, t in ipairs(told) do
    if t.binding == PROXY and t.command ~= "ONLINE_CHANGED" then
      other = other + 1
    end
  end
  T.eq("no light state told at a first start", other, 0)

  restart()
  W.run(200)
  other = 0
  for _, t in ipairs(told) do
    if t.binding == PROXY and t.command ~= "ONLINE_CHANGED" then
      other = other + 1
    end
  end
  T.eq("none after a restart either", other, 0)
  T.eq("Connected event fires at a restart's connect", eventCount(1), 1)
  T.eq("Connected again", Variables["Connected"], "1")
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
T.section("Light commands are left for the next layer")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(200)
  mark()
  ReceivedFromProxy(PROXY, "ON", {})
  ReceivedFromProxy(PROXY, "SET_LEVEL", { LEVEL = "50" })
  W.run(2000)
  T.eq("nothing sent to the controller", #fake.commands, 0)
  T.eq("nothing told the proxy", #told, 0)
end

T.finish()
