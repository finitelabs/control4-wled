--- WLED effects, palettes, presets and playlists in Composer programming, against the fake
--- controller: the lists read from a 16.0.1 and a 0.15.4 controller, each command's JSON,
--- choices that survive a rename, the lists read again when the controller says they changed,
--- and the variables and events a report sets.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_programming.lua

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"

local EFFECT_CHANGED, PRESET_CHANGED, PLAYLIST_STARTED, PLAYLIST_ENDED = 3, 4, 5, 6

package.preload["cloud-client-byte"] = function()
  return {}
end
package.loaded["lib.http"] = W.http

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
  if section == "config" then
    return readXml():match("<config>(.-)</config>")
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

function C4:SendToProxy() end

--- Each event fired, with the programming variables as they stood when it fired.
local events = {}

function C4:FireEventByID(id)
  events[#events + 1] = {
    id = id,
    Effect = Variables["Effect"],
    Palette = Variables["Palette"],
    Preset = Variables["Preset"],
    Playlist = Variables["Playlist"],
  }
end

local function mark()
  events = {}
end

local function eventCount(id)
  local n = 0
  for _, e in ipairs(events) do
    if e.id == id then
      n = n + 1
    end
  end
  return n
end

local function firstEvent(id)
  for _, e in ipairs(events) do
    if e.id == id then
      return e
    end
  end
  return nil
end

local function programmingEvents()
  return eventCount(EFFECT_CHANGED)
    + eventCount(PRESET_CHANGED)
    + eventCount(PLAYLIST_STARTED)
    + eventCount(PLAYLIST_ENDED)
end

local function requestCount(fake, path)
  local n = 0
  for _, r in ipairs(fake.requests) do
    if r.method == "GET" and r.path == path then
      n = n + 1
    end
  end
  return n
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

local function lastCommand(fake)
  return fake.commands[#fake.commands]
end

local function choices(command, param)
  return GetCommandParamList(command, param) or {}
end

local nextHost = 60

--- A fresh project on a fake controller, with the driver loaded and started.
--- @param profile string
--- @param setup fun(fake: table)|nil Changes to the fake before the driver first reads it.
local function fresh(profile, setup)
  W.reset()
  nextHost = nextHost + 1
  local fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  if setup then
    setup(fake)
  end
  require("lib.persist"):delete("WledControllerMac")
  require("lib.persist"):delete("WledShown")
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  for _, name in ipairs({ "Effect", "Palette", "Preset", "Playlist" }) do
    Variables[name] = nil
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
--- @param whileDown fun()|nil What happens after the old instance ends and before the new one loads.
local function restart(how, whileDown)
  OnDriverDestroyed()
  if whileDown then
    whileDown()
  end
  W.reload(how)
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

--------------------------------------------------------------------------------
T.section("Every command in driver.xml has its handler, and every list its choices")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  local commands = readXml():match("<commands>(.-)</commands>") or ""
  local n = 0
  for block in commands:gmatch("<command>(.-)</command>") do
    local name = block:match("<name>(.-)</name>")
    n = n + 1
    T.eq(name .. " has an EC handler", type(EC[(name:gsub("%s+", "_"))]), "function")
    if block:find("DYNAMIC_LIST", 1, true) then
      T.eq(name .. " has a GCPL handler", type(GCPL[(name:gsub("%s+", "_"))]), "function")
    end
  end
  T.eq("eleven commands", n, 11)
  T.eq("programming variables exist before the controller reports", Variables["Effect"], "")
  T.eq("Playlist variable exists", Variables["Playlist"], "")
end

--------------------------------------------------------------------------------
T.section("Lists from a 16.0.1 controller")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f.si.info.cpalcount = 2
    f.si.info.umpalnames = { "Usermod Glow" }
  end)
  W.run(500)
  local effects = choices("Set Effect", "Effect")
  T.eq("effects without placeholders or 2D-only ones", #effects, 163)
  T.eq("starts at Solid", effects[1], "Solid")
  T.falsy("no RSVD", contains(effects, "RSVD"))
  T.falsy("2D-only Rotozoomer hidden without a matrix", contains(effects, "Rotozoomer"))
  T.truthy("Image, 1D and 2D, kept", contains(effects, "Image"))
  for _, path in ipairs({ "/json/eff", "/json/fxdata", "/json/pal", "/presets.json" }) do
    T.eq(path .. " read once", requestCount(fake, path), 1)
  end

  local palettes = choices("Set Palette", "Palette")
  T.eq("built-in, custom and usermod palettes", #palettes, 72 + 2 + 1)
  T.truthy("custom palette offered", contains(palettes, "Custom Palette 2"))

  T.eq("presets by name and id", choices("Apply Preset", "Preset"), { "Mock Warm Glow (1)", "Mock Rainbow (2)" })
  T.eq("playlists apart from presets", choices("Start Playlist", "Playlist"), { "Mock Cycle (3)" })

  ExecuteCommand("Set Palette", { Palette = "Custom Palette 1" })
  T.eq("16.x numbers custom palettes down from 200", lastCommand(fake).seg[1].pal, 200)
  ExecuteCommand("Set Palette", { Palette = "Custom Palette 2" })
  T.eq("the second at 199", lastCommand(fake).seg[1].pal, 199)
  ExecuteCommand("Set Palette", { Palette = "Usermod Glow" })
  T.eq("usermod palettes down from 255", lastCommand(fake).seg[1].pal, 255)
end

do
  fresh("esp32-matrix-16")
  W.run(500)
  local effects = choices("Set Effect", "Effect")
  T.eq("a matrix keeps the 2D-only effects", #effects, 216)
  T.truthy("Rotozoomer on a matrix", contains(effects, "Rotozoomer"))
end

--------------------------------------------------------------------------------
T.section("Lists from a 0.15.4 controller")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp8266-ws2812b-015", function(f)
    f.si.info.cpalcount = 2
  end)
  W.run(500)
  local effects = choices("Set Effect", "Effect")
  T.eq("effects without placeholders or 2D-only ones", #effects, 143)
  T.falsy("no RSVD", contains(effects, "RSVD"))
  ExecuteCommand("Set Effect", { Effect = "Chase 3" })
  T.eq("an effect after a placeholder keeps its id", lastCommand(fake).seg[1].fx, 54)

  local palettes = choices("Set Palette", "Palette")
  T.eq("built-in and custom palettes", #palettes, 71 + 2)
  ExecuteCommand("Set Palette", { Palette = "Custom Palette 1" })
  T.eq("0.15 numbers custom palettes down from 255", lastCommand(fake).seg[1].pal, 255)
  ExecuteCommand("Set Palette", { Palette = "Custom Palette 2" })
  T.eq("the second at 254", lastCommand(fake).seg[1].pal, 254)

  T.eq("no presets", choices("Apply Preset", "Preset"), {})
  T.eq("no playlists", choices("Start Playlist", "Playlist"), {})
end

--------------------------------------------------------------------------------
T.section("Each command's JSON")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)

  ExecuteCommand("Set Effect", { Effect = "Rainbow" })
  T.eq(
    "Set Effect: fx on every segment, from the effect's defaults as WLED's page starts it",
    lastCommand(fake),
    { seg = { { id = 0, fx = 9, fxdef = true }, { id = 1, fx = 9, fxdef = true } } }
  )
  ExecuteCommand("Set Effect", { Effect = "65" })
  T.eq("Set Effect by id", lastCommand(fake).seg[1].fx, 65)

  ExecuteCommand("Set Effect Speed", { Speed = "40" })
  T.eq("Set Effect Speed: sx", lastCommand(fake), { seg = { { id = 0, sx = 40 }, { id = 1, sx = 40 } } })
  ExecuteCommand("Set Effect Speed", { Speed = "300" })
  T.eq("speed held to 255", lastCommand(fake).seg[1].sx, 255)

  ExecuteCommand("Set Effect Intensity", { Intensity = "200" })
  T.eq("Set Effect Intensity: ix", lastCommand(fake), { seg = { { id = 0, ix = 200 }, { id = 1, ix = 200 } } })

  ExecuteCommand("Set Palette", { Palette = "* Color 1" })
  T.eq("Set Palette: pal", lastCommand(fake), { seg = { { id = 0, pal = 2 }, { id = 1, pal = 2 } } })

  ExecuteCommand("Apply Preset", { Preset = "Mock Rainbow (2)" })
  T.eq("Apply Preset: ps", lastCommand(fake), { ps = 2 })

  ExecuteCommand("Start Playlist", { Playlist = "Mock Cycle (3)" })
  T.eq("Start Playlist: ps, asking for the state back", lastCommand(fake), { ps = 3, v = true })

  local main = fake.si.state.seg[1]
  ExecuteCommand("Stop Playlist", {})
  T.eq(
    "Stop Playlist: the running effect again, asking for the state back",
    lastCommand(fake),
    { seg = { { id = main.id, fx = main.fx } }, v = true }
  )

  local sent = #fake.commands
  ExecuteCommand("Set Effect", { Effect = "No Such Effect" })
  ExecuteCommand("Apply Preset", { Preset = "Mock Cycle (3)" })
  ExecuteCommand("Start Playlist", { Playlist = "Mock Rainbow (2)" })
  T.eq("unknown choices send nothing; a playlist is not a preset", #fake.commands, sent)
end

--------------------------------------------------------------------------------
T.section("Effect and palette commands never change power or level")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f.si.state.on = false
  end)
  W.run(500)
  local from = #fake.commands
  ExecuteCommand("Set Effect", { Effect = "Rainbow" })
  ExecuteCommand("Set Effect Speed", { Speed = "10" })
  ExecuteCommand("Set Effect Intensity", { Intensity = "10" })
  ExecuteCommand("Set Palette", { Palette = "Default" })
  W.run(1500)
  local touched = {}
  for i = from + 1, #fake.commands do
    local cmd = fake.commands[i]
    for _, key in ipairs({ "on", "bri", "tt", "transition" }) do
      if cmd[key] ~= nil then
        touched[#touched + 1] = key
      end
    end
    for _, seg in ipairs(cmd.seg or {}) do
      for _, key in ipairs({ "on", "bri", "col", "cct" }) do
        if seg[key] ~= nil then
          touched[#touched + 1] = "seg." .. key
        end
      end
    end
  end
  T.eq("four commands", #fake.commands - from, 4)
  T.eq("none carries power, level or color", touched, {})
  T.eq("the controller stays off", fake.si.state.on, false)
end

--------------------------------------------------------------------------------
T.section("Presets and playlists resolve by id after a rename")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local file = fake:presetsFile()
  file["2"].n = "Evening"
  file["3"].n = "Party"
  fake.files["/presets.json"] = file

  ExecuteCommand("Apply Preset", { Preset = "Evening (2)" })
  T.eq("a choice made after the rename, before the list is read again", lastCommand(fake), { ps = 2 })

  fake:change(nil, { fs = { pmt = 1762000000 } })
  W.run(1500)
  T.eq("the renamed preset is offered", choices("Apply Preset", "Preset"), { "Mock Warm Glow (1)", "Evening (2)" })
  ExecuteCommand("Apply Preset", { Preset = "Mock Rainbow (2)" })
  T.eq("a choice made before the rename still applies", lastCommand(fake), { ps = 2 })
  ExecuteCommand("Start Playlist", { Playlist = "Mock Cycle (3)" })
  T.eq("a playlist choice made before the rename still starts", lastCommand(fake), { ps = 3, v = true })
  ExecuteCommand("Apply Preset", { Preset = "Evening" })
  T.eq("a bare name resolves too", lastCommand(fake), { ps = 2 })
end

--------------------------------------------------------------------------------
T.section("Lists are read again only when the controller says they changed")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local function counts()
    return {
      requestCount(fake, "/json/eff"),
      requestCount(fake, "/json/pal"),
      requestCount(fake, "/presets.json"),
    }
  end
  T.eq("read once at the connect", counts(), { 1, 1, 1 })

  ExecuteCommand("Set Effect", { Effect = "Rainbow" })
  W.run(1500)
  T.eq("a state change reads nothing", counts(), { 1, 1, 1 })

  fake:change(nil, { fs = { pmt = 1762000001 } })
  W.run(1500)
  T.eq("a preset save reads the presets", counts(), { 1, 1, 2 })

  local eff = fake.files["/json/eff"]
  eff[#eff + 1] = "Mock Sparkle"
  fake.files["/json/fxdata"][#eff] = "!,!;;!"
  fake:change(nil, { fxcount = #eff })
  W.run(1500)
  T.eq("a new effect count reads the effects", counts(), { 2, 1, 2 })
  T.truthy("the new effect is offered", contains(choices("Set Effect", "Effect"), "Mock Sparkle"))

  fake:change(nil, { cpalcount = 1 })
  W.run(1500)
  T.eq("a custom palette reads the palettes", counts(), { 2, 2, 2 })
  T.truthy("and is offered", contains(choices("Set Palette", "Palette"), "Custom Palette 1"))

  fake:drop()
  W.run(5000)
  T.eq("a socket that comes back with HTTP answering reads nothing", counts(), { 2, 2, 2 })

  fake.reachable = false
  fake:drop()
  W.run(200)
  fake.reachable = true
  W.run(40000)
  T.eq("a reconnect reads every list", counts(), { 3, 3, 3 })

  fake:change(nil, { ver = "16.0.2" })
  W.run(1500)
  T.eq("new firmware reads every list", counts(), { 4, 4, 4 })
end

--------------------------------------------------------------------------------
T.section("Variables and events follow the controller's reports")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  T.eq("Effect", Variables["Effect"], "Solid")
  T.eq("Palette", Variables["Palette"], "Default")
  T.eq("no Preset", Variables["Preset"], "")
  T.eq("no Playlist", Variables["Playlist"], "")

  mark()
  ExecuteCommand("Set Effect", { Effect = "Rainbow" })
  W.run(1500)
  T.eq("Effect Changed once", eventCount(EFFECT_CHANGED), 1)
  T.eq("the variable is set before the event fires", (firstEvent(EFFECT_CHANGED) or {}).Effect, "Rainbow")
  T.eq("no preset event", eventCount(PRESET_CHANGED), 0)

  mark()
  ExecuteCommand("Set Effect Speed", { Speed = "20" })
  ExecuteCommand("Set Palette", { Palette = "* Color 1" })
  W.run(1500)
  T.eq("Palette variable", Variables["Palette"], "* Color 1")
  T.eq("speed and palette fire no effect event", eventCount(EFFECT_CHANGED), 0)

  mark()
  ExecuteCommand("Apply Preset", { Preset = "Mock Warm Glow (1)" })
  W.run(1500)
  T.eq("Preset Changed once", eventCount(PRESET_CHANGED), 1)
  T.eq("Preset variable set first", (firstEvent(PRESET_CHANGED) or {}).Preset, "Mock Warm Glow")
  T.eq("the preset's effect", Variables["Effect"], "Solid")

  mark()
  ExecuteCommand("Apply Preset", { Preset = "Mock Warm Glow (1)" })
  W.run(1500)
  T.eq("the same preset again fires nothing", programmingEvents(), 0)

  mark()
  ExecuteCommand("Start Playlist", { Playlist = "Mock Cycle (3)" })
  W.run(1500)
  T.eq("Playlist Started once", eventCount(PLAYLIST_STARTED), 1)
  T.eq("Playlist variable set first", (firstEvent(PLAYLIST_STARTED) or {}).Playlist, "Mock Cycle")
  T.truthy("Playlist is Running", TC.PLAYLIST_RUNNING("PLAYLIST_RUNNING", { VALUE = "Running", LOGIC = "EQUAL" }))
  T.falsy("not Not Running", TC.PLAYLIST_RUNNING("PLAYLIST_RUNNING", { VALUE = "Not Running", LOGIC = "EQUAL" }))

  mark()
  ExecuteCommand("Stop Playlist", {})
  W.run(1500)
  T.eq("Playlist Ended once", eventCount(PLAYLIST_ENDED), 1)
  T.eq("Playlist variable cleared first", (firstEvent(PLAYLIST_ENDED) or {}).Playlist, "")
  T.falsy("Playlist not running", TC.PLAYLIST_RUNNING("PLAYLIST_RUNNING", { VALUE = "Running", LOGIC = "EQUAL" }))
  T.eq("no second start", eventCount(PLAYLIST_STARTED), 0)

  mark()
  fake:change({ pl = 0 })
  W.run(1500)
  T.eq("a playlist sent without an id starts", eventCount(PLAYLIST_STARTED), 1)
  T.eq("it has no name", Variables["Playlist"], "")

  mark()
  ExecuteCommand("Set Effect", { Effect = "Blink" })
  W.run(1500)
  T.eq("an effect outside a preset ends the playlist", eventCount(PLAYLIST_ENDED), 1)
  T.eq("and leaves the preset", Variables["Preset"], "")
end

--------------------------------------------------------------------------------
T.section("Start and Stop Playlist show at once on 0.15 and 16.x, where WLED pushes neither")
--------------------------------------------------------------------------------
for _, profile in ipairs({ "esp32-rgbw-015", "esp32-rgbw-pwm-16" }) do
  local fake = fresh(profile, function(f)
    -- The 0.15.4 capture has no presets; both get the same ones.
    f.files["/presets.json"] = W.fixture("esp32-rgbw-pwm-16", "presets.json")
  end)
  W.run(500)
  ExecuteCommand("Apply Preset", { Preset = "Mock Warm Glow (1)" })
  W.run(1500)

  mark()
  ExecuteCommand("Start Playlist", { Playlist = "Mock Cycle (3)" })
  W.run(100)
  T.eq(
    "its first preset already showing, Playlist Started at once (" .. profile .. ")",
    eventCount(PLAYLIST_STARTED),
    1
  )
  T.eq("Playlist variable (" .. profile .. ")", Variables["Playlist"], "Mock Cycle")

  mark()
  ExecuteCommand("Stop Playlist", {})
  W.run(100)
  T.eq("Playlist Ended at once (" .. profile .. ")", eventCount(PLAYLIST_ENDED), 1)
  T.eq("Playlist variable cleared (" .. profile .. ")", Variables["Playlist"], "")
  T.eq("the controller's playlist unloaded (" .. profile .. ")", fake.si.state.pl, -1)
  T.eq("the look stays (" .. profile .. ")", { fake.si.state.ps, Variables["Preset"] }, { 1, "Mock Warm Glow" })
  W.run(10000)
  T.eq("and nothing more (" .. profile .. ")", programmingEvents(), 1)
end

--------------------------------------------------------------------------------
T.section("A preset added and applied while the controller was away fires with its name")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  fake.reachable = false
  fake:drop()
  W.run(2000)
  local presets = fake:presetsFile()
  presets["4"] = { n = "Brand New", on = true, bri = 128 }
  fake.files["/presets.json"] = presets
  fake.si.info.fs = fake.si.info.fs or {}
  fake.si.info.fs.pmt = (tonumber(fake.si.info.fs.pmt) or 0) + 100
  fake:applyPreset(4)
  mark()
  fake.reachable = true
  W.run(40000)
  T.eq("Preset Changed once", eventCount(PRESET_CHANGED), 1)
  T.eq("its variable already names the new preset", (firstEvent(PRESET_CHANGED) or {}).Preset, "Brand New")
end

--------------------------------------------------------------------------------
T.section("Nothing fires at a start or reconnect for a state that stayed the same")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f:applyPreset(3)
  end)
  W.run(500)
  T.eq("no events at the start", programmingEvents(), 0)
  T.eq("a running playlist shows at the start", Variables["Playlist"], "Mock Cycle")
  T.eq("and its preset", Variables["Preset"], "Mock Warm Glow")

  mark()
  fake:drop()
  W.run(5000)
  T.eq("reconnected", Properties["Driver Status"], "Connected")
  T.eq("no events at the reconnect", programmingEvents(), 0)

  restart(how)
  T.eq("the variables shown before the controller answers (" .. how .. ")", {
    Variables["Effect"],
    Variables["Preset"],
    Variables["Playlist"],
  }, { "Solid", "Mock Warm Glow", "Mock Cycle" })
  W.run(500)
  T.eq("no events at a reload (" .. how .. ")", programmingEvents(), 0)
  T.eq("variables kept (" .. how .. ")", Variables["Playlist"], "Mock Cycle")

  mark()
  fake.reachable = false
  fake:drop()
  W.run(200)
  fake:applyPreset(2)
  fake.reachable = true
  W.run(40000)
  T.eq("a change while away fires at the reconnect", eventCount(PRESET_CHANGED), 1)
  T.eq("the playlist it ended", eventCount(PLAYLIST_ENDED), 1)

  mark()
  -- Another controller, showing another preset, takes the address.
  fake.si.info.mac = "02a1b2c3d4ee"
  fake:applyPreset(1)
  fake:drop()
  W.run(5000)
  T.eq("a different controller is not followed", programmingEvents(), 0)
  T.eq("its preset is not shown", Variables["Preset"], "Mock Rainbow")
  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
  -- The fake answers no close frame, so the socket to the old controller times out first.
  W.run(30000)
  T.eq("Reset Driver takes it", Properties["Driver Status"], "Connected")
  T.eq("taking it with Reset Driver fires nothing", programmingEvents(), 0)
  T.eq("and shows its preset", Variables["Preset"], "Mock Warm Glow")
end

--------------------------------------------------------------------------------
T.section("A change made while the driver reloads fires at the reload")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f:applyPreset(3)
  end)
  W.run(500)
  T.eq("a running playlist shows", Variables["Playlist"], "Mock Cycle")
  restart(how, function()
    fake:applyPreset(2)
  end)
  W.run(1500)
  T.eq("the preset it changed to fires (" .. how .. ")", eventCount(PRESET_CHANGED), 1)
  T.eq("and the playlist it ended (" .. how .. ")", eventCount(PLAYLIST_ENDED), 1)
  T.eq("named (" .. how .. ")", Variables["Preset"], "Mock Rainbow")
  mark()
  restart(how)
  W.run(1500)
  T.eq("a reload with nothing changed fires nothing (" .. how .. ")", programmingEvents(), 0)
end

--------------------------------------------------------------------------------
T.section("After a reload an event waits until its list names the new value")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  T.eq("the effect shows (" .. how .. ")", Variables["Effect"], "Solid")
  local effects = fake.files["/json/eff"]
  restart(how, function()
    fake.si.state.seg[1].fx = 9
    fake.files["/json/eff"] = nil
  end)
  W.run(1500)
  T.eq("no Effect Changed while the effect list is unread (" .. how .. ")", eventCount(EFFECT_CHANGED), 0)
  T.eq("its variable still names the old effect (" .. how .. ")", Variables["Effect"], "Solid")
  fake.files["/json/eff"] = effects
  local reads = requestCount(fake, "/json/eff")
  fake:change({ bri = 90 })
  W.run(1500)
  T.eq("the next report reads the list again (" .. how .. ")", requestCount(fake, "/json/eff"), reads + 1)
  T.eq("Effect Changed fires once the list is read (" .. how .. ")", eventCount(EFFECT_CHANGED), 1)
  T.eq("with its variable naming the new effect (" .. how .. ")", (firstEvent(EFFECT_CHANGED) or {}).Effect, "Rainbow")
end

--------------------------------------------------------------------------------
T.section("A list read that fails does not hold back the next")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local Lists = require("wled.lists")
  local presetLists = Lists.presetLists
  Lists.presetLists = function()
    error("unreadable presets")
  end
  fake:change(nil, { fs = { pmt = 1762000950 } })
  W.run(1500)
  Lists.presetLists = presetLists
  local file = fake:presetsFile()
  file["2"].n = "Evening"
  fake.files["/presets.json"] = file
  fake:change(nil, { fs = { pmt = 1762000960 } })
  W.run(1500)
  T.truthy("the next read goes ahead", contains(choices("Apply Preset", "Preset"), "Evening (2)"))
end

T.finish()
