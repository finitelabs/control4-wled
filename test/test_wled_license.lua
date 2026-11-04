--- The WLED driver's DriverCentral build under its license gate, against the repo's fake WLED controller, with the
--- real cloud client and a fake Cloud driver: five minutes without a license it drops the connection and sends the
--- controller nothing more, its light keeps its level and no event fires; a license connects it again at once.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_license.lua

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")
-- After the fixture's timers, so the fake Cloud driver drives the client's ping on top of them.
local cloud = require("dc_cloud")

DEBUG_WEBSOCKET = false
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"
local PROXY = 5001

package.loaded["lib.http"] = W.http

local function readXml()
  local f = assert(io.open(XML, "r"))
  local xml = f:read("*a")
  f:close()
  return xml
end
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.2"
  elseif section == "version" then
    return "20261104"
  elseif section == "config" then
    return readXml():match("<config>(.-)</config>")
  end
  return configInfo(self, section)
end
function C4:GetVersionInfo()
  return { version = "3.3.2.0-res" }
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
local events = {}
function C4:FireEventByID(id)
  events[#events + 1] = id
end
--- What the light proxy is told, by command.
local told = {}
function C4:SendToProxy(id, command, params)
  if id == PROXY then
    told[#told + 1] = { command = command, params = params or {} }
  end
end

--- Run the Lua file at `path` as the DriverCentral build compiles it: the lines its directives leave out are blanked.
local function dofileDriverCentral(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local directive, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if directive then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (directive == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  assert(load(table.concat(lines, "\n"), "@" .. path))()
end

W.reset()
local fake = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2.41" })
for block in readXml():gmatch("<property>(.-)</property>") do
  local name = block:match("<name>(.-)</name>")
  if name then
    Properties[name] = block:match("<default>(.-)</default>") or ""
  end
end
Properties["IP Address"] = fake.ip
Properties["Cloud Status"] = ""
Properties["Automatic Updates"] = "Off"

--- `n` rounds of 10 s: one of the client's pings, then 10 s of the driver's own time, the gate's read in it.
local function tick(n)
  for _ = 1, n or 1 do
    cloud.poll(1)
    W.run(10000)
  end
end

--- Whether a light proxy command reaches the controller.
local function reaches(command, params)
  local before = #fake.commands
  ReceivedFromProxy(PROXY, command, params or {})
  W.run(500)
  return #fake.commands > before
end

--- The brightness the proxy was told last since `from`, or nil.
local function brightnessSince(from)
  for i = #told, from + 1, -1 do
    if told[i].command == "LIGHT_BRIGHTNESS_CHANGED" then
      return told[i].params.LIGHT_BRIGHTNESS_CURRENT
    end
  end
end

cloud.answer = { AC = 0, AS = "Invalid License" }
dofileDriverCentral(DRIVER)
OnDriverInit()
OnDriverLateInit("DIT_ADDED")
W.run(200)

T.section("Without a license the driver runs five minutes after its load, then drops the controller")
do
  T.eq("connected while the grace runs", Properties["Driver Status"], "Connected")
  tick(29)
  T.eq("29 reads of 0: a light SET_LEVEL still reaches the controller", reaches("SET_LEVEL", { LEVEL = "35" }), true)
  local eventsBefore, toldBefore = #events, #told
  tick()
  T.eq("the 30th read stops it: Driver Status", Properties["Driver Status"], "No active license")
  T.eq("the light is told it is offline", Select(told, #told, "command"), "ONLINE_CHANGED")
  T.eq("at the level it had, so no Light Off", brightnessSince(toldBefore), nil)
  T.eq("and no event fires", #events, eventsBefore)
  local requests = #fake.requests
  T.eq("a light ON reaches nothing", reaches("ON"), false)
  ExecuteCommand("Set_Effect_Speed", { Speed = "200" })
  ExecuteCommand("Apply_Preset", { Preset = "1" })
  UpdateProperty("Port", "80")
  OnPropertyChanged("Port")
  tick(10)
  T.eq("nor does Control4 programming, a property change or a poll", #fake.requests, requests)
  T.eq("Driver Status after a property change", Properties["Driver Status"], "No active license")
end

T.section("A license connects it again at once")
do
  cloud.say({ AC = 1, AS = "License Activated" })
  W.run(2000)
  T.eq("Driver Status", Properties["Driver Status"], "Connected")
  T.eq("a light ON reaches the controller again", reaches("ON"), true)
end

T.section("A Cloud driver update does not stop it")
do
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  cloud.silent = false
  tick()
  T.eq("DC_X once the new Cloud driver answers", DC_X, 1)
  tick(40)
  T.eq("still connected", Properties["Driver Status"], "Connected")
  T.eq("a light OFF still reaches the controller", reaches("OFF"), true)
end

T.finish()
