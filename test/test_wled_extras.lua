--- The light's Extras menu against the fake controller: the controls each effect shows and their
--- names, as WLED's own page decides them; the setup and state the proxy is told; picks and
--- sliders sent to the controller; and the menu following the controller's reports.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_extras.lua

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

package.preload["cloud-client-byte"] = function()
  return {}
end
package.loaded["lib.http"] = W.http

local Extras = require("wled.extras")

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

--- Extras setups and states told to the proxy, in order.
local told = {}

function C4:SendToProxy(binding, command, params)
  if command == "EXTRAS_SETUP_CHANGED" or command == "EXTRAS_STATE_CHANGED" then
    told[#told + 1] = { binding = binding, command = command, xml = params.XML }
  elseif command == "DYNAMIC_CAPABILITIES_CHANGED" then
    told[#told + 1] = { binding = binding, command = command, params = params }
  end
end

local function mark()
  told = {}
end

--- @param command string
--- @return table[]
local function toldOf(command)
  local out = {}
  for _, t in ipairs(told) do
    if t.command == command then
      out[#out + 1] = t
    end
  end
  return out
end

--- @return string|nil
local function lastSetup()
  local setups = toldOf("EXTRAS_SETUP_CHANGED")
  return setups[#setups] and setups[#setups].xml
end

--- An object's attributes in a setup or state, by its id.
--- @param xml string|nil
--- @param id string
--- @return table<string, string>|nil
local function object(xml, id)
  for tag in (xml or ""):gmatch("<object [^>]*>") do
    local attrs = {}
    for k, v in tag:gmatch('([%w_]+)="([^"]*)"') do
      attrs[k] = v
    end
    if attrs.id == id then
      return attrs
    end
  end
  return nil
end

--- The items of a list object in a setup, as { text, value } pairs.
--- @param xml string|nil
--- @param id string
--- @return table[]
local function listItems(xml, id)
  local body = (xml or ""):match('<object type="list" id="' .. id .. '"[^>]*>(.-)</object>') or ""
  local out = {}
  for text, value in body:gmatch('<item text="([^"]*)" value="([^"]*)"/>') do
    out[#out + 1] = { text = text, value = value }
  end
  return out
end

local function lastCommand(fake)
  return fake.commands[#fake.commands]
end

local nextHost = 80

--- A fresh project on a fake controller, with the driver loaded and started.
--- @param profile string
--- @param setup fun(fake: table)|nil
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
  Properties["IP Address"] = fake.ip
  T.unload("^drivers%-common%-public%.module%.websocket$", "^wled%.")
  mark()
  dofile(DRIVER)
  ShimLateInit()
  return fake
end

--- Change the controller's state as its own page or another client would, then push.
--- @param fake table
--- @param cmd table
local function elsewhere(fake, cmd)
  fake:applyFields(cmd)
  fake:pushNow()
end

local function pick(id, value)
  ReceivedFromProxy(5001, "EXTRA_SET", { id = id, value = value })
end

--- The driver's warnings while fn runs.
--- @param fn function
--- @return string[]
local function warnings(fn)
  local logging = require("lib.logging")
  local seen, warn = {}, logging.warn
  logging.warn = function(_, text, ...)
    seen[#seen + 1] = string.format(text, ...)
  end
  local ok, err = pcall(fn)
  logging.warn = warn
  assert(ok, err)
  return seen
end

--------------------------------------------------------------------------------
T.section("Each effect's controls, named as WLED's own page names them")
--------------------------------------------------------------------------------
do
  T.eq("Solid shows nothing to set", Extras.controls(0, "", true), {})
  T.eq(
    "Rainbow: WLED's speed, the effect's own name for intensity, and the palette",
    Extras.controls(9, "!,Size;;!", true),
    { sx = "Effect speed", ix = "Size", pal = "Color palette" }
  )
  T.eq(
    "Scanner: a custom slider and two checks, named by the effect",
    Extras.controls(40, "!,Trail,Delay,,,Dual,Bi-delay;!,!,!;!;;m12=0,c1=0", true),
    { sx = "Effect speed", ix = "Trail", c1 = "Delay", o1 = "Dual", o2 = "Bi-delay", pal = "Color palette" }
  )
  T.eq(
    "Copy Segment: an empty entry hides speed, an empty palette entry hides the palette",
    Extras.controls(77, ",Color shift,Lighten,Brighten,ID,Axis(2D),FullStack(last frame);;;12;ix=0", true),
    {
      ix = "Color shift",
      c1 = "Lighten",
      c2 = "Brighten",
      c3 = "ID",
      o1 = "Axis(2D)",
      o2 = "FullStack(last frame)",
    }
  )
  T.eq(
    "a check left as ! keeps WLED's name",
    Extras.controls(5, "!,!,,,,!;;!", true),
    { sx = "Effect speed", ix = "Effect intensity", o1 = "Check 1", pal = "Color palette" }
  )
  T.eq(
    "an effect without metadata: speed, intensity and the palette",
    Extras.controls(62, "", true),
    { sx = "Effect speed", ix = "Effect intensity", pal = "Color palette" }
  )
  T.eq("from id 128 an effect without metadata shows all five sliders", Extras.controls(130, nil, true), {
    sx = "Effect speed",
    ix = "Effect intensity",
    c1 = "Custom 1",
    c2 = "Custom 2",
    c3 = "Custom 3",
    pal = "Color palette",
  })
  T.eq("a palette id in the metadata is the effect's own, with no control", Extras.controls(3, "!;!;42", true).pal, nil)
  T.eq("a named palette with a default drops the default", Extras.controls(3, "!;!;Hue=50", true).pal, "Hue")
  T.eq("no palette without color LEDs", Extras.controls(9, "!,Size;;!", false).pal, nil)
end

--------------------------------------------------------------------------------
T.section("The setup: lists in the controller's order, names made safe, unused controls hidden")
--------------------------------------------------------------------------------
--- A view of the given lists, with its choices and the values for a segment, preset and playlist.
--- @param lists table
--- @param seg table
--- @param ps integer
--- @param pl integer
--- @return table
local function viewOf(lists, seg, ps, pl)
  local view = {
    effects = lists.effects or {},
    palettes = lists.palettes or {},
    presets = lists.presets or {},
    playlists = lists.playlists or {},
    controls = lists.controls or {},
  }
  view.choices = Extras.choices(view)
  view.values = Extras.values(seg, ps, pl, view.choices)
  return view
end

do
  local xml = Extras.setup(viewOf({
    effects = { { id = 0, name = "Solid" }, { id = 9, name = "Rainbow" } },
    palettes = { { id = 0, name = "Default" } },
    presets = { { id = 2, name = 'Tom & "Jerry" <1>' } },
    controls = { sx = "Effect speed", ix = "Size" },
  }, { fx = 9, sx = 10, ix = 20, c3 = 31, o1 = true, pal = 0 }, 2, -1))
  T.eq(
    "effects listed, each name its own value",
    listItems(xml, "fx"),
    { { text = "Solid", value = "Solid" }, { text = "Rainbow", value = "Rainbow" } }
  )
  T.eq("the running effect picked by its name", object(xml, "fx").value, "Rainbow")
  T.eq("the palette by its name", object(xml, "pal").value, "Default")
  T.eq("the preset showing by its name", object(xml, "ps").value, "Tom &amp; &quot;Jerry&quot; &lt;1&gt;")
  T.eq("speed shown", object(xml, "sx").hidden, "false")
  T.eq("intensity named by the effect", object(xml, "ix").label, "Size")
  T.eq("Custom 1 hidden", object(xml, "c1").hidden, "true")
  T.eq("Custom 3 runs to 31, as WLED's", object(xml, "c3").max, "31")
  T.eq("Custom 3's value", object(xml, "c3").value, "31")
  T.eq("checks hidden, values kept", { object(xml, "o1").hidden, object(xml, "o1").value }, { "true", "true" })
  T.eq("palette hidden when the effect has none", object(xml, "pal").hidden, "true")
  T.eq("a preset name made safe for XML", listItems(xml, "ps")[1], {
    text = "Tom &amp; &quot;Jerry&quot; &lt;1&gt;",
    value = "Tom &amp; &quot;Jerry&quot; &lt;1&gt;",
  })
  T.eq("no playlist list without playlists", object(xml, "pl"), nil)
  T.eq("every control sends the same command", object(xml, "ps").command, "EXTRA_SET")

  local bare = Extras.setup(viewOf({ effects = { { id = 0, name = "Solid" } } }, { fx = 0 }, -1, -1))
  T.excludes("no Presets section without presets or playlists", bare, "Presets")
end

--------------------------------------------------------------------------------
T.section("Each list entry's text is unique in its list, and values are texts")
--------------------------------------------------------------------------------
do
  local view = viewOf({
    effects = { { id = 0, name = "Solid" }, { id = 9, name = "Rainbow" } },
    palettes = { { id = 11, name = "Rainbow" } },
    presets = {
      { id = 1, name = "Glow" },
      { id = 2, name = "Glow" },
      { id = 3, name = "Night" },
      { id = 4, name = "" },
      { id = 8, name = "Glow (2)" },
    },
    playlists = { { id = 5, name = "None" }, { id = 6, name = "Party" } },
  }, { fx = 9, pal = 11 }, 2, 6)
  local function texts(id)
    local out = {}
    for _, c in ipairs(view.choices[id].items) do
      out[#out + 1] = c.text
    end
    return out
  end
  T.eq(
    "a repeated name takes its id on each entry, and no two entries share a text",
    texts("ps"),
    { "Glow (1)", "Glow (2)", "Night", "4", "Glow (2) (8)" }
  )
  T.eq("None keeps its text, a playlist named None takes its id", texts("pl"), { "None", "None (5)", "Party" })
  T.eq("the same name in two lists stays plain in each", { texts("fx")[2], texts("pal")[1] }, { "Rainbow", "Rainbow" })
  T.eq("a text maps back to its id", { view.choices.ps.id["Glow (2)"], view.choices.pl.id["None"] }, { 2, -1 })
  T.eq("values are the texts", {
    view.values.fx,
    view.values.pal,
    view.values.ps,
    view.values.pl,
  }, { "Rainbow", "Rainbow", "Glow (2)", "Party" })
  local other = Extras.values({ fx = 999 }, -1, -1, view.choices)
  T.eq("an id the list lacks shows as itself; no preset, no playlist", { other.fx, other.ps, other.pl }, {
    "999",
    "",
    "None",
  })
  T.eq("a state carries the texts", object(Extras.state(view.values, {}), "ps").value, "Glow (2)")
end

--------------------------------------------------------------------------------
T.section("The menu once the controller's lists are read")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  T.eq("nothing before the lists are read", lastSetup(), nil)
  W.run(500)
  local setups = toldOf("EXTRAS_SETUP_CHANGED")
  T.eq("one setup once every list is read", #setups, 1)
  local xml = setups[1].xml
  T.eq("on the light's proxy", setups[1].binding, 5001)
  T.eq("the effects programming offers", #listItems(xml, "fx"), 163)
  T.eq("Solid running, by its name", object(xml, "fx").value, "Solid")
  T.eq("Solid shows no speed", object(xml, "sx").hidden, "true")
  T.eq("built-in palettes", #listItems(xml, "pal"), 72)
  T.eq("presets apart from playlists", listItems(xml, "ps"), {
    { text = "Mock Warm Glow", value = "Mock Warm Glow" },
    { text = "Mock Rainbow", value = "Mock Rainbow" },
  })
  T.eq("playlists after None", listItems(xml, "pl"), {
    { text = "None", value = "None" },
    { text = "Mock Cycle", value = "Mock Cycle" },
  })
  T.eq("no playlist running", object(xml, "pl").value, "None")
  T.eq("no preset showing", object(xml, "ps").value, "")

  mark()
  elsewhere(fake, { seg = { sx = 200 } })
  W.run(1500)
  T.eq("a value that moved: no new setup", #toldOf("EXTRAS_SETUP_CHANGED"), 0)
  local states = toldOf("EXTRAS_STATE_CHANGED")
  T.eq("one state", #states, 1)
  T.eq("with the speed", object(states[1] and states[1].xml, "sx").value, "200")
  T.eq("and nothing else", object(states[1] and states[1].xml, "ix"), nil)

  mark()
  elsewhere(fake, { seg = { fx = 40 } })
  W.run(1500)
  xml = lastSetup()
  T.truthy("a new effect relabels its controls", xml)
  T.eq("Scanner's intensity", object(xml, "ix").label, "Trail")
  T.eq("its Custom 1", { object(xml, "c1").label, object(xml, "c1").hidden }, { "Delay", "false" })
  T.eq("its first check", { object(xml, "o1").label, object(xml, "o1").hidden }, { "Dual", "false" })
  T.eq("its palette shown", object(xml, "pal").hidden, "false")
  T.eq("the setup carries the values, so they stay", object(xml, "sx").value, "200")
  states = toldOf("EXTRAS_STATE_CHANGED")
  local shown = states[#states] and states[#states].xml
  T.truthy("a state follows the setup, for a menu that is open", shown)
  T.eq("it shows Scanner's controls", {
    object(shown, "ix").hidden,
    object(shown, "c1").hidden,
    object(shown, "o2").hidden,
    object(shown, "pal").hidden,
  }, { "false", "false", "false", "false" })
  T.eq("and hides the ones it does not use", { object(shown, "c2").hidden, object(shown, "o3").hidden }, {
    "true",
    "true",
  })
  T.eq("lists carry no hidden flag", object(shown, "fx").hidden, nil)
  T.eq("the state after a new setup names the effect, as an open menu matches it", object(shown, "fx").value, "Scanner")
  T.eq("and the palette", object(shown, "pal").value, "Default")
end

--------------------------------------------------------------------------------
T.section("Picks and sliders reach every segment")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)

  mark()
  pick("fx", "Rainbow")
  T.eq(
    "an effect picked by its name, on both segments, from its own defaults as WLED's page starts it",
    lastCommand(fake).seg,
    { { id = 0, fx = 9, fxdef = true }, { id = 1, fx = 9, fxdef = true } }
  )
  local states = toldOf("EXTRAS_STATE_CHANGED")
  T.eq("the menu shows the pick at once, by its name", object(states[1] and states[1].xml, "fx").value, "Rainbow")
  W.run(1500)
  T.eq("Rainbow's own controls follow", object(lastSetup(), "ix").label, "Size")

  pick("sx", "300")
  T.eq("speed kept to 255", lastCommand(fake).seg[1].sx, 255)
  pick("c3", "200")
  T.eq("Custom 3 kept to 31", lastCommand(fake).seg[1].c3, 31)
  pick("o2", "true")
  T.eq("a check on", lastCommand(fake).seg[2].o2, true)
  pick("o2", "False")
  T.eq("and off", lastCommand(fake).seg[2].o2, false)
  pick("pal", "Rainbow")
  T.eq("a palette", lastCommand(fake).seg[1].pal, 11)

  pick("ps", "Mock Rainbow")
  T.eq("a preset applied", lastCommand(fake), { ps = 2 })
  mark()
  pick("pl", "Mock Cycle")
  T.eq("a playlist started", lastCommand(fake), { ps = 3 })
  states = toldOf("EXTRAS_STATE_CHANGED")
  T.eq("the menu shows it running at once", object(states[1] and states[1].xml, "pl").value, "Mock Cycle")
  W.run(1500)
  local main = fake.si.state.seg[1]
  pick("pl", "None")
  T.eq("None stops it, the running effect kept", lastCommand(fake), { seg = { { id = main.id, fx = "~0" } }, v = true })

  local n = #fake.commands
  mark()
  local warned = warnings(function()
    pick("fx", "Nothing Like This")
    pick("fx", "9")
    pick("ps", "2")
    pick("ps", "Mock Cycle")
    pick("pl", "Mock Warm Glow")
    pick("pl", "-1")
  end)
  pick("zz", "1")
  pick("sx", "fast")
  T.eq("a text the menu was not given, a bare id among them, sends nothing", #fake.commands, n)
  T.eq("and the menu is not told", #toldOf("EXTRAS_STATE_CHANGED"), 0)
  T.eq("each list pick it could not place is a warning", #warned, 6)

  ReceivedFromProxy(5002, "EXTRA_SET", { id = "fx", value = "Rainbow" })
  T.eq("another binding is not the menu", #fake.commands, n)

  -- Programming sets the same controls by the menu's names.
  mark()
  ExecuteCommand("Set Effect Custom Value", { Control = "Custom 2", Value = "100" })
  T.eq("Custom 2 from programming, on both segments", {
    lastCommand(fake).seg[1].c2,
    lastCommand(fake).seg[2].c2,
  }, { 100, 100 })
  T.eq("the menu shows it", object((toldOf("EXTRAS_STATE_CHANGED")[1] or {}).xml, "c2").value, "100")
  ExecuteCommand("Set Effect Custom Value", { Control = "Custom 3", Value = "200" })
  T.eq("Custom 3 from programming kept to 31", lastCommand(fake).seg[1].c3, 31)
  ExecuteCommand("Set Effect Option", { Option = "Check 1", State = "On" })
  T.eq("Check 1 on from programming", lastCommand(fake).seg[1].o1, true)
  ExecuteCommand("Set Effect Option", { Option = "Check 1", State = "Off" })
  T.eq("and off", lastCommand(fake).seg[1].o1, false)
  n = #fake.commands
  ExecuteCommand("Set Effect Custom Value", { Control = "Custom 9", Value = "1" })
  ExecuteCommand("Set Effect Option", { Option = "Check 9", State = "On" })
  T.eq("a control the menu does not have sends nothing", #fake.commands, n)
end

--------------------------------------------------------------------------------
T.section("A checkbox picked in the menu is not answered, so the app keeps its tick")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)

  --- The objects for one control in every state told since the mark.
  local function statesOf(id)
    local out = {}
    for _, t in ipairs(toldOf("EXTRAS_STATE_CHANGED")) do
      out[#out + 1] = object(t.xml, id)
    end
    return out
  end

  mark()
  pick("o1", "true")
  T.eq("the check reaches every segment", { lastCommand(fake).seg[1].o1, lastCommand(fake).seg[2].o1 }, { true, true })
  T.eq("and no state answers the tap", #toldOf("EXTRAS_STATE_CHANGED"), 0)
  W.run(1500)
  T.eq("the controller's report of the same check tells the menu nothing", #statesOf("o1"), 0)

  mark()
  elsewhere(fake, { seg = { { id = 0, o1 = false }, { id = 1, o1 = false } } })
  W.run(500)
  T.eq("the check changed on the controller right after a tap shows", (statesOf("o1")[1] or {}).value, "false")

  mark()
  pick("o1", "true")
  W.run(1500)
  T.eq("ticked again, not answered", #statesOf("o1"), 0)
  mark()
  pick("fx", "Scanner")
  W.run(1500)
  T.eq("an effect picked after a tap shows its own check", (statesOf("o1")[1] or {}).value, "false")

  mark()
  pick("o1", "true")
  W.run(1500)
  mark()
  pick("o1", "false")
  W.run(1500)
  T.eq("unticking is not answered either", #statesOf("o1"), 0)

  mark()
  ExecuteCommand("Set Effect Option", { Option = "Check 1", State = "On" })
  T.eq("programming's check still shows in the menu", (statesOf("o1")[1] or {}).value, "true")

  mark()
  pick("sx", "100")
  T.eq("a slider pick is still answered", object((toldOf("EXTRAS_STATE_CHANGED")[1] or {}).xml, "sx").value, "100")
end

--------------------------------------------------------------------------------
T.section("A pick is the text the menu gave its entry, and a new effect starts from its own defaults")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16", function(f)
    f:presetsFile()["7"] = { n = "2", on = true }
  end)
  W.run(500)
  mark()
  pick("ps", "2")
  T.eq("the preset named 2 applied, not preset 2", lastCommand(fake), { ps = 7 })
  T.eq("the menu shows the name sent", object(toldOf("EXTRAS_STATE_CHANGED")[1].xml, "ps").value, "2")
  pick("ps", "Mock Rainbow")
  T.eq("preset 2 by its own name", lastCommand(fake), { ps = 2 })

  -- Tetrix's metadata ends sx=0,ix=0,pal=11.
  pick("sx", "200")
  W.run(1500)
  pick("fx", "Tetrix")
  W.run(1500)
  local states = toldOf("EXTRAS_STATE_CHANGED")
  local last = states[#states].xml
  T.eq("its own speed, not the last effect's", object(last, "sx").value, "0")
  T.eq("its own palette", object(last, "pal").value, "Rainbow")

  mark()
  pick("ix", "77")
  W.run(1500)
  T.eq("a value the menu was shown is not told again", #toldOf("EXTRAS_STATE_CHANGED"), 1)
end

--------------------------------------------------------------------------------
T.section("Nothing goes to a different controller at the address")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  fake.si.info.mac = "02a1b2c3d4ee"
  fake:drop()
  W.run(5000)
  T.contains("the driver sees the other controller", Properties["Driver Status"], "Reset Driver")
  local n = #fake.commands
  mark()
  pick("fx", "Rainbow")
  pick("sx", "10")
  ExecuteCommand("Set Effect", { Effect = "Rainbow" })
  ExecuteCommand("Set Effect Custom Value", { Control = "Custom 1", Value = "50" })
  ExecuteCommand("Set Effect Option", { Option = "Check 2", State = "On" })
  T.eq("no pick or command reaches it", #fake.commands, n)
  T.eq("and the menu shows no pick", #toldOf("EXTRAS_STATE_CHANGED"), 0)
end

--------------------------------------------------------------------------------
T.section("A reconnect that finds the same lists sends no new setup")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local reads = #fake.requests
  mark()
  fake.reachable = false
  fake:drop()
  W.run(20000)
  fake.reachable = true
  W.run(20000)
  T.eq("connected again", Properties["Driver Status"], "Connected")
  T.truthy("the lists were read again", #fake.requests > reads + 3)
  T.eq("the proxy keeps the setup it has", #toldOf("EXTRAS_SETUP_CHANGED"), 0)
end

--------------------------------------------------------------------------------
T.section("The menu follows the controller")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)

  mark()
  fake:applyPreset(3)
  fake:pushNow()
  W.run(1500)
  local states = toldOf("EXTRAS_STATE_CHANGED")
  local last = states[#states] and states[#states].xml
  T.truthy("a playlist started elsewhere is told", last)
  T.eq("it shows running, by its name", (object(last, "pl") or {}).value, "Mock Cycle")
  local presetNames = { [1] = "Mock Warm Glow", [2] = "Mock Rainbow" }
  T.eq("with the preset it shows, by its name", (object(last, "ps") or {}).value, presetNames[fake.si.state.ps])

  mark()
  fake:presetsFile()["4"] = { n = "Mock Added", on = true }
  fake:change(nil, { fs = { pmt = 1762000099 } })
  W.run(2000)
  T.eq("a preset added on the controller: a new setup", #toldOf("EXTRAS_SETUP_CHANGED"), 1)
  T.eq("with it listed", listItems(lastSetup(), "ps")[3], { text = "Mock Added", value = "Mock Added" })
end

do
  local fake = fresh("esp32-white-16")
  W.run(500)
  T.truthy("a white strip gets a menu too", lastSetup())
  elsewhere(fake, { seg = { fx = 9 } })
  W.run(1500)
  local xml = lastSetup()
  T.eq("Rainbow's own controls", object(xml, "ix").label, "Size")
  T.eq("without its palette, which needs color LEDs", object(xml, "pal").hidden, "true")
  T.excludes("no presets on it", xml, "Presets")
end

do
  fresh("esp8266-ws2812b-015")
  W.run(500)
  T.eq("a 0.15 controller's effects", #listItems(lastSetup(), "fx"), 143)
end

--------------------------------------------------------------------------------
T.section("The light offers Extras, and Reset Driver empties them")
--------------------------------------------------------------------------------
do
  -- Every WLED controller has effects, so Extras are a fixed capability: a static False would make
  -- every controller start tell a dimmer's capabilities again, firing the proxy's color events.
  fresh("esp32-rgbw-pwm-16")
  T.differs(
    "driver.xml seeds it",
    "the build writes the light's capabilities from the profile: the source driver.xml carries none"
  )
  T.eq("the build writes it into driver.xml", builtCaps().has_extras, "True")
  W.run(500)
  local caps = toldOf("DYNAMIC_CAPABILITIES_CHANGED")
  T.eq("the light says it has Extras", caps[#caps] and caps[#caps].params.has_extras, true)

  mark()
  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
  local setups = toldOf("EXTRAS_SETUP_CHANGED")
  T.eq("an empty menu at once", setups[1] and setups[1].xml, "<extras_setup><extra></extra></extras_setup>")
  -- The fake answers no close frame, so the socket to the controller times out first.
  W.run(30000)
  setups = toldOf("EXTRAS_SETUP_CHANGED")
  T.eq("then the controller's menu again", #listItems(setups[#setups].xml, "fx"), 163)
end

T.finish()
