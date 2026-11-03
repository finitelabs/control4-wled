--- Preset cycling against the fake controller: the cycle from Cycle Presets and the controller's
--- presets, Next and Previous Preset from programming and their button links, a button link per
--- preset with its keypad LED, the Preset Is conditional, and what a reload and Reset Driver keep.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_cycle.lua

local T = require("testlib")
local W = require("wled_fixtures")
require("c4_local")

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"

package.preload["cloud-client-byte"] = function()
  return {}
end
package.loaded["lib.http"] = W.http

local Cycle = require("wled.cycle")

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

function C4:FireEventByID() end

--- Keypad LED states told, in order, as { binding, state }.
local leds = {}

function C4:SendToProxy(binding, command, params)
  if command == "MATCH_LED_STATE" then
    leds[#leds + 1] = { binding = binding, state = params.STATE }
  end
end

local function mark()
  leds = {}
end

--- The last LED state told on a binding.
--- @param binding integer
--- @return boolean|nil
local function ledOf(binding)
  local state
  for _, l in ipairs(leds) do
    if l.binding == binding then
      state = l.state
    end
  end
  return state
end

--- The preset links, by preset id.
--- @return table<string, Binding>
local function presetLinks()
  return require("lib.bindings"):getDynamicBindings("PresetLinks")
end

--- @param fake table
--- @return integer|nil
local function lastPreset(fake)
  for i = #fake.commands, 1, -1 do
    if fake.commands[i].ps then
      return fake.commands[i].ps
    end
  end
  return nil
end

local function elsewhere(fake, cmd)
  fake:applyFields(cmd)
  fake:pushNow()
end

local nextHost = 100

--- A fresh project on a fake controller, with the driver loaded and started.
--- @param profile string
--- @param setup fun(fake: table)|nil
--- @param props table<string, string>|nil
local function fresh(profile, setup, props)
  W.reset()
  nextHost = nextHost + 1
  local fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  if setup then
    setup(fake)
  end
  local persist = require("lib.persist")
  for _, key in ipairs({ "WledControllerMac", "WledShown", "ConnectionBindings", "Conditionals" }) do
    persist:delete(key)
  end
  ShimResetDynamicBindings()
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  for k, v in pairs(props or {}) do
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
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

local function press(binding, ...)
  for _, command in ipairs({ ... }) do
    ReceivedFromProxy(binding, command, {})
  end
end

local function setProperty(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

--------------------------------------------------------------------------------
T.section("The cycle from the installer's list")
--------------------------------------------------------------------------------
do
  local presets = { { id = 1, name = "Warm" }, { id = 4, name = "Movie Night" }, { id = 9, name = "Party" } }
  local function ids(cycle)
    local out = {}
    for i, e in ipairs(cycle) do
      out[i] = e.id
    end
    return out
  end
  T.eq("empty: every preset, by id", ids((Cycle.parse("  ", presets))), { 1, 4, 9 })
  local cycle, unknown = Cycle.parse("9, Movie Night,7, Warm (1), 9", presets)
  T.eq("ids, names and Name (id) in the order given, each once", ids(cycle), { 9, 4, 1 })
  T.eq("an entry the controller has no preset for, apart", unknown, { "7" })
  local _, _, named = Cycle.parse("Movie Night, 9", presets)
  T.eq("the id each name stands for", named, { ["Movie Night"] = 4 })
  local renamed = { { id = 1, name = "Warm" }, { id = 4, name = "Cinema" } }
  T.eq(
    "a name renamed on the controller keeps its preset",
    ids((Cycle.parse("Movie Night, 1", renamed, named))),
    { 4, 1 }
  )
  T.eq("a number is an id", ids((Cycle.parse("1", { { id = 1, name = "4" }, { id = 4, name = "1" } }))), { 1 })

  T.eq("next from the preset showing", Cycle.step(cycle, 4, nil, 1), 1)
  T.eq("wraps at the end", Cycle.step(cycle, 1, nil, 1), 9)
  T.eq("previous wraps at the start", Cycle.step(cycle, 9, nil, -1), 1)
  T.eq("from the one last applied when none in the cycle shows", Cycle.step(cycle, -1, 4, 1), 1)
  T.eq("the first when neither is in the cycle", Cycle.step(cycle, 2, 3, 1), 9)
  T.eq("previous from nothing: the last", Cycle.step(cycle, -1, nil, -1), 1)
  T.eq("nothing to step through", Cycle.step({}, 1, 1, 1), nil)
end

--------------------------------------------------------------------------------
T.section("Every preset cycles by default, each with its own button link")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  T.eq("nothing until the presets are read", Properties["Presets in Cycle"], "None")
  W.run(500)
  T.eq(
    "the controller's presets, not its playlist",
    Properties["Presets in Cycle"],
    "Mock Warm Glow (1), Mock Rainbow (2)"
  )
  local links = presetLinks()
  T.eq("a button link per preset, named from the controller", {
    links["1"] and links["1"].displayName,
    links["2"] and links["2"].displayName,
    links["3"],
  }, { "Mock Warm Glow (1) Button Link", "Mock Rainbow (2) Button Link", nil })
  T.eq("a button link Composer shows", ShimDynamicBindings()[links["1"].bindingId].class, "BUTTON_LINK")
  T.eq("offered for keypads to connect to", links["1"].provider, true)

  ExecuteCommand("Next Preset", {})
  T.eq("Next with none showing: the first", lastPreset(fake), 1)
  W.run(1500)
  ExecuteCommand("Next Preset", {})
  T.eq("then the one after the preset showing", lastPreset(fake), 2)
  W.run(1500)
  ExecuteCommand("Next Preset", {})
  T.eq("and round to the first", lastPreset(fake), 1)
  W.run(1500)
  ExecuteCommand("Previous Preset", {})
  T.eq("Previous wraps back to the last", lastPreset(fake), 2)
  W.run(1500)
  ExecuteCommand("Next Preset", {})
  W.run(1500)

  elsewhere(fake, { seg = { sx = 10 } })
  W.run(1500)
  T.eq("a change ends the preset showing", fake.si.state.ps, -1)
  ExecuteCommand("Next Preset", {})
  T.eq("Next goes on from the preset the cycle last applied", lastPreset(fake), 2)
end

--------------------------------------------------------------------------------
T.section("Keypad buttons: Next and Previous Preset, and a preset's own link")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f:presetsFile()["4"] = { n = "Mock Ocean", on = true }
  end)
  W.run(500)
  local n = #fake.commands
  press(303, "DO_PUSH", "DO_CLICK")
  T.eq("a tap steps once", #fake.commands, n + 1)
  T.eq("to the first preset", lastPreset(fake), 1)
  W.run(1500)
  press(303, "DO_CLICK")
  T.eq("the next tap steps again", lastPreset(fake), 2)
  W.run(1500)
  press(304, "DO_PUSH")
  T.eq("Previous Preset Button Link", lastPreset(fake), 1)
  W.run(1500)
  n = #fake.commands
  press(304, "DO_RELEASE")
  T.eq("a release alone does nothing", #fake.commands, n)

  press(303, "DO_CLICK")
  W.run(600)
  press(303, "DO_CLICK")
  T.eq(
    "two taps before the controller reports step twice",
    { fake.commands[#fake.commands - 1].ps, lastPreset(fake) },
    {
      2,
      4,
    }
  )
  W.run(1500)

  press(300, "DO_CLICK")
  T.eq("the light's own On Button Link still turns it on", fake.commands[#fake.commands].on, true)
  W.run(1500)

  local links = presetLinks()
  local ocean, rainbow = links["4"].bindingId, links["2"].bindingId
  mark()
  press(rainbow, "DO_PUSH", "DO_CLICK")
  T.eq("a preset's link applies it", lastPreset(fake), 2)
  W.run(1500)
  T.eq("its LED lit while it shows", ledOf(rainbow), true)
  T.eq("the one lit before goes off", ledOf(ocean), false)
  mark()
  ReceivedFromProxy(rainbow, "REQUEST_BUTTON_COLORS", {})
  T.eq("a keypad that asks is told", ledOf(rainbow), true)
  mark()
  elsewhere(fake, { seg = { sx = 40 } })
  W.run(1500)
  T.eq("off once the look changes", ledOf(rainbow), false)
  mark()
  elsewhere(fake, { seg = { ix = 99 } })
  W.run(1500)
  T.eq("and not told again by a report that leaves it", #leds, 0)
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  ExecuteCommand("Next Preset", {})
  W.run(1500)
  ExecuteCommand("Next Preset", {})
  W.run(1500)
  T.eq("the controller reports the second step", fake.si.state.ps, 2)
  fake:applyPreset(1)
  fake:pushNow()
  W.run(1500)
  ExecuteCommand("Next Preset", {})
  T.eq("after a preset picked elsewhere, Next steps from that one", lastPreset(fake), 2)
end

--------------------------------------------------------------------------------
T.section("Cycle Presets picks which presets cycle and their order")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16", nil, { ["Cycle Presets"] = "2, Mock Warm Glow, 9, 2" })
  W.run(500)
  T.eq(
    "in the order given, without the unknown one",
    Properties["Presets in Cycle"],
    "Mock Rainbow (2), Mock Warm Glow (1)"
  )
  ExecuteCommand("Next Preset", {})
  T.eq("Next starts at the first in the list", lastPreset(fake), 2)

  setProperty("Cycle Presets", "1")
  T.eq("a shorter list", Properties["Presets in Cycle"], "Mock Warm Glow (1)")
  T.eq("drops the link for a preset taken out", presetLinks()["2"], nil)

  setProperty("Cycle Presets", "5")
  T.eq("a list with nothing the controller has", Properties["Presets in Cycle"], "None")
  local n = #fake.commands
  ExecuteCommand("Next Preset", {})
  T.eq("leaves nothing to step through", #fake.commands, n)
end

--------------------------------------------------------------------------------
T.section("The links follow the controller's presets")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local links = presetLinks()
  local rainbow = links["2"].bindingId
  -- A keypad button connected to Mock Warm Glow's link.
  C4:Bind(C4:GetDeviceID(), links["1"].bindingId, 555, 1, "BUTTON_LINK")

  mark()
  local file = fake:presetsFile()
  file["2"].n = "Mock Sunset"
  file["1"] = nil
  file["6"] = { n = "Mock Ocean", on = true }
  fake.files["/presets.json"] = file
  fake:change(nil, { fs = { pmt = 1762000500 } })
  W.run(2000)
  links = presetLinks()
  T.eq("renamed on the controller, renamed here", links["2"] and links["2"].displayName, "Mock Sunset (2) Button Link")
  T.eq("under the same connection", links["2"] and links["2"].bindingId, rainbow)
  T.eq("its keypad is told its LED again", ledOf(rainbow), false)
  T.eq("a new preset gets a link", links["6"] and links["6"].displayName, "Mock Ocean (6) Button Link")
  T.truthy("one deleted on the controller keeps the link a keypad is connected to", links["1"])
  T.eq("but leaves the cycle", Properties["Presets in Cycle"], "Mock Sunset (2), Mock Ocean (6)")
  local n = #fake.commands
  press(links["1"].bindingId, "DO_CLICK")
  T.eq("and its button sends nothing", #fake.commands, n)

  file["6"] = nil
  fake:change(nil, { fs = { pmt = 1762000600 } })
  W.run(2000)
  T.eq("one nothing is connected to goes with its preset", presetLinks()["6"], nil)
end

do
  local fake = fresh("esp32-rgbw-pwm-16", nil, { ["Cycle Presets"] = "Mock Rainbow, Mock Warm Glow" })
  W.run(500)
  local rainbow = presetLinks()["2"].bindingId
  C4:Bind(C4:GetDeviceID(), rainbow, 556, 1, "BUTTON_LINK")
  local file = fake:presetsFile()
  file["2"].n = "Mock Sunset"
  fake.files["/presets.json"] = file
  fake:change(nil, { fs = { pmt = 1762000700 } })
  W.run(2000)
  T.eq(
    "a preset Cycle Presets names keeps its place after a rename",
    Properties["Presets in Cycle"],
    "Mock Sunset (2), Mock Warm Glow (1)"
  )
  T.eq("and its link", presetLinks()["2"] and presetLinks()["2"].bindingId, rainbow)
  local wired = false
  for _, c in ipairs(ShimConnections()) do
    wired = wired or (c.providerBinding == rainbow and c.consumer == 556)
  end
  T.truthy("with the keypad still connected", wired)
end

--------------------------------------------------------------------------------
T.section("Preset Is, a conditional with the controller's presets")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f:presetsFile()["5"] = { n = "Mock, Comma", on = true }
  end)
  W.run(500)
  local conditional
  for _, c in pairs(GetConditionals()) do
    if c.condition_statement == "Preset Is" then
      conditional = c
    end
  end
  T.truthy("listed for Composer", conditional)
  T.eq(
    "with each preset as programming shows it, a comma in a name made a space",
    conditional.list_items,
    "Mock Warm Glow (1),Mock Rainbow (2),Mock  Comma (5)"
  )
  T.eq("a list conditional", conditional.type, "LIST")
  ExecuteCommand("Apply Preset", { Preset = "Mock Rainbow (2)" })
  W.run(1500)
  T.truthy(
    "true for the preset showing",
    TestCondition(conditional.name, { VALUE = "Mock Rainbow (2)", LOGIC = "EQUAL" })
  )
  T.falsy("false for another", TestCondition(conditional.name, { VALUE = "Mock Warm Glow (1)", LOGIC = "EQUAL" }))
  T.truthy("and Is Not", TestCondition(conditional.name, { VALUE = "Mock Warm Glow (1)", LOGIC = "NOT_EQUAL" }))
  local file = fake:presetsFile()
  file["2"].n = "Mock Sunset"
  fake.files["/presets.json"] = file
  fake:change(nil, { fs = { pmt = 1762000800 } })
  W.run(2000)
  T.truthy(
    "a test written before a rename still holds",
    TestCondition(conditional.name, { VALUE = "Mock Rainbow (2)", LOGIC = "EQUAL" })
  )

  restart(how)
  T.truthy(
    "after a reload it answers before the presets are read again (" .. how .. ")",
    TestCondition(conditional.name, { VALUE = "Mock Sunset (2)", LOGIC = "NOT_EQUAL" })
  )
  W.run(1500)
  T.truthy(
    "and from the report after (" .. how .. ")",
    TestCondition(conditional.name, { VALUE = "Mock Sunset (2)", LOGIC = "EQUAL" })
  )
  T.eq(
    "the same conditional (" .. how .. ")",
    GetConditionals()[tostring(conditional.conditionalId)].name,
    conditional.name
  )
end

--------------------------------------------------------------------------------
T.section("Preset Is answers after a reload with every preset deleted")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local conditional
  for _, c in pairs(GetConditionals()) do
    if c.condition_statement == "Preset Is" then
      conditional = c
    end
  end
  fake.files["/presets.json"] = { ["0"] = {} }
  fake:change(nil, { fs = { pmt = 1762000900 } })
  W.run(2000)
  T.eq("every preset deleted: an empty list", GetConditionals()[tostring(conditional.conditionalId)].list_items, "")
  restart(how)
  T.truthy(
    "after a reload Is Not still answers (" .. how .. ")",
    TestCondition(conditional.name, { VALUE = "Mock Rainbow (2)", LOGIC = "NOT_EQUAL" })
  )
  W.run(1500)
  T.truthy(
    "and after the presets are read (" .. how .. ")",
    TestCondition(conditional.name, { VALUE = "Mock Rainbow (2)", LOGIC = "NOT_EQUAL" })
  )
end

--------------------------------------------------------------------------------
T.section("A reload keeps the links and their connections; Reset Driver clears them")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16", nil, { ["Cycle Presets"] = "2" })
  W.run(500)
  local id = presetLinks()["2"].bindingId
  restart(how)
  W.run(1)
  local n = #fake.commands
  press(303, "DO_CLICK")
  press(id, "DO_CLICK")
  W.run(100)
  T.eq("its button and Next work before the presets are read again (" .. how .. ")", #fake.commands, n + 2)
  T.eq(
    "restored at init under the same id (" .. how .. ")",
    ShimDynamicBindings()[id] and ShimDynamicBindings()[id].name,
    "Mock Rainbow (2) Button Link"
  )
  W.run(1500)
  press(id, "DO_CLICK")
  T.eq("and its button works (" .. how .. ")", lastPreset(fake), 2)

  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
  T.eq("Reset Driver removes the links (" .. how .. ")", ShimDynamicBindings()[id], nil)
  T.eq("and the conditional (" .. how .. ")", next(GetConditionals()), nil)
  T.eq("and empties Cycle Presets (" .. how .. ")", Properties["Cycle Presets"], "")
  -- The fake answers no close frame, so the socket to the controller times out first.
  W.run(30000)
  T.eq(
    "then every preset cycles again (" .. how .. ")",
    Properties["Presets in Cycle"],
    "Mock Warm Glow (1), Mock Rainbow (2)"
  )
  T.truthy("with its links (" .. how .. ")", presetLinks()["1"] and presetLinks()["2"])
end

--------------------------------------------------------------------------------
T.section("Nothing cycles a different controller, or one with no presets")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  ExecuteCommand("Apply Preset", { Preset = "Mock Rainbow (2)" })
  W.run(1500)
  local warm = presetLinks()["1"].bindingId
  mark()
  fake.si.info.mac = "02a1b2c3d4ee"
  fake.si.state.ps = 1
  fake:drop()
  W.run(5000)
  local preset
  for _, c in pairs(GetConditionals()) do
    preset = c.name
  end
  T.truthy(
    "Preset Is answers from our controller, not the one at the address",
    TestCondition(preset, { VALUE = "Mock Rainbow (2)", LOGIC = "EQUAL" })
  )
  T.eq("which lights no link", ledOf(warm), nil)
  local n = #fake.commands
  ExecuteCommand("Next Preset", {})
  press(303, "DO_CLICK")
  T.eq("no step reaches another controller at the address", #fake.commands, n)
end

do
  local fake = fresh("esp32-white-16")
  W.run(500)
  T.eq("a controller without presets", Properties["Presets in Cycle"], "None")
  T.eq("has no preset links", next(presetLinks()), nil)
  T.eq("and no Preset Is", next(GetConditionals()), nil)
  local n = #fake.commands
  ExecuteCommand("Previous Preset", {})
  T.eq("and nothing to step through", #fake.commands, n)
end

T.finish()
