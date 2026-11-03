--- The WLED driver's side of segment lights, against the fake controller: a connection per
--- segment, named from WLED; what each segment light is told, and when; its commands sent on to
--- the controller; connections that follow renumbered, resized, renamed and deleted segments; a
--- reload and Reset Driver; and the controller light's power with every segment off.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_segments.lua

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

--- Everything told over a binding, in order.
local told = {}

function C4:SendToProxy(binding, command, params)
  told[#told + 1] = { binding = binding, command = command, params = params or {} }
end

local function mark()
  told = {}
end

--- What was told on a binding since the mark, as { command, params }.
--- @param binding integer
--- @param command string|nil Only this command.
--- @return table[]
local function toldOn(binding, command)
  local out = {}
  for _, t in ipairs(told) do
    if t.binding == binding and (command == nil or t.command == command) then
      out[#out + 1] = t
    end
  end
  return out
end

--- The last payload told a binding since the mark.
--- @param binding integer
--- @return table|nil
local function lastPayload(binding)
  local states = toldOn(binding, "UPDATE_STATE")
  local last = states[#states]
  return last and DeserializeSafe(last.params.segment)
end

--- The segment connections, by record key.
--- @return table<string, Binding>
local function links()
  return require("lib.bindings"):getDynamicBindings("Segments")
end

--- A segment connection by the name it shows.
--- @param name string
--- @return Binding|nil
local function linkNamed(name)
  for _, b in pairs(links()) do
    if b.displayName == name then
      return b
    end
  end
  return nil
end

local function countLinks()
  local n = 0
  for _ in pairs(links()) do
    n = n + 1
  end
  return n
end

local function elsewhere(fake, cmd)
  fake:applyFields(cmd)
  fake:pushNow()
end

--- A segment light connected to a binding, as Director binds one.
--- @param bindingId integer
local function connectLight(bindingId)
  C4:Bind(C4:GetDeviceID(), bindingId, 700 + bindingId, 5002, "WLED_SEGMENT")
  OBC[bindingId](bindingId, "WLED_SEGMENT", true)
end

--- A segment light's command, as it sends one over its binding.
--- @param bindingId integer
--- @param json table
--- @param id integer The segment id the light was told.
local function lightSends(bindingId, json, id)
  ReceivedFromProxy(bindingId, "ENTITY_COMMAND", { body = SerializeSafe(json), segment = id })
end

local nextHost = 140

local function fresh(profile, setup)
  W.reset()
  nextHost = nextHost + 1
  local fake = W.Fake.new(profile, { ip = "192.0.2." .. nextHost })
  if setup then
    setup(fake)
  end
  local persist = require("lib.persist")
  for _, key in ipairs({ "WledControllerMac", "WledShown", "ConnectionBindings", "Conditionals", "WledSegmentRecords" }) do
    persist:delete(key)
  end
  ShimResetDynamicBindings()
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
  mark()
  dofile(DRIVER)
  OnDriverInit()
  ShimLateInit()
end

--------------------------------------------------------------------------------
T.section("Finding a segment again: same id and range, then range, then id")
--------------------------------------------------------------------------------
do
  local segs = {
    { id = 0, start = 0, stop = 30 },
    { id = 1, start = 30, stop = 60 },
  }
  local matched, unmatched = Segment.match({
    a = { id = 1, start = 30, stop = 60 },
    b = { id = 5, start = 0, stop = 30 },
    c = { id = 9, start = 90, stop = 99 },
  }, segs)
  T.eq("same id and range", matched.a and matched.a.id, 1)
  T.eq("a renumbered segment by its range", matched.b and matched.b.id, 0)
  T.eq("one that is gone matches nothing", matched.c, nil)
  T.eq("every segment taken", #unmatched, 0)

  matched, unmatched = Segment.match({ a = { id = 0, start = 0, stop = 20 } }, segs)
  T.eq("a resized segment by its id", matched.a and matched.a.stop, 30)
  T.eq("the other one is new", unmatched[1] and unmatched[1].id, 1)

  matched = Segment.match({ a = { id = 1, start = 0, stop = 30 }, b = { id = 0, start = 50, stop = 60 } }, segs)
  T.eq("a range beats an id", matched.a and matched.a.id, 0)
  T.eq("and the id goes to what is left", matched.b and matched.b.id, nil)
end

do
  local seg = { { id = 5, start = 20, stop = 30 } }
  local matched = Segment.match({
    seg10 = { id = 5, start = 50, stop = 60 },
    seg2 = { id = 5, start = 0, stop = 10 },
  }, seg)
  T.eq("records by the number in their key: seg2 before seg10", { matched.seg2 ~= nil, matched.seg10 ~= nil }, {
    true,
    false,
  })

  matched = Segment.match({
    seg1 = { id = 7, start = 0, stop = 10, live = false },
    seg2 = { id = 3, start = 0, stop = 10 },
  }, { { id = 0, start = 0, stop = 10 } })
  T.eq("a record whose segment was there goes before one whose segment was gone", {
    matched.seg1 ~= nil,
    matched.seg2 ~= nil,
  }, { false, true })

  matched = Segment.match(
    { seg1 = { id = 1, start = 60, stop = 61, live = false } },
    { { id = 1, start = 61, stop = 70 } }
  )
  T.eq("a gone segment's record does not take a new segment by its old id", matched.seg1, nil)
  matched = Segment.match(
    { seg1 = { id = 4, start = 61, stop = 70, live = false } },
    { { id = 1, start = 61, stop = 70 } }
  )
  T.eq("but finds its segment back on its LEDs", matched.seg1 and matched.seg1.id, 1)

  matched = Segment.match({
    seg1 = { id = 8, start = 0, stop = 10, name = "Right" },
    seg2 = { id = 9, start = 0, stop = 10, name = "Left" },
  }, { { id = 0, start = 0, stop = 10, name = "Left" }, { id = 1, start = 0, stop = 10, name = "Right" } })
  T.eq("segments on the same LEDs go by their names", {
    matched.seg1 and matched.seg1.name,
    matched.seg2 and matched.seg2.name,
  }, { "Right", "Left" })
end

--------------------------------------------------------------------------------
T.section("A connection per segment, named from WLED")
--------------------------------------------------------------------------------
do
  fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip"), linkNamed("Accent")
  T.truthy("the Strip segment's connection", strip)
  T.truthy("the Accent segment's connection", accent)
  T.eq("two in all", countLinks(), 2)
  T.eq("offered for segment lights", ShimDynamicBindings()[strip.bindingId].class, "WLED_SEGMENT")
  T.eq("as a provider", strip.provider, true)
  T.eq("a proxy connection", strip.type, "PROXY")
end

do
  fresh("esp32-white-16")
  W.run(500)
  T.truthy("an unnamed segment shows its id", linkNamed("Segment 0"))
end

--------------------------------------------------------------------------------
T.section("What a segment light is told, and when")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  mark()
  connectLight(accent)
  local payload = lastPayload(accent)
  T.truthy("told its segment when it connects", payload)
  T.eq("its own id, range and bits", {
    payload.segment.id,
    payload.segment.start,
    payload.segment.stop,
    payload.segment.lc,
  }, { 1, 60, 61, 7 })
  T.eq("the master power and level", payload.master, { on = true, bri = 128 })

  mark()
  elsewhere(fake, { seg = { { id = 1, bri = 40 } } })
  W.run(1500)
  T.eq("told again at each report", lastPayload(accent).segment.bri, 40)

  mark()
  ReceivedFromProxy(accent, "REFRESH_STATE", {})
  T.truthy("and when it asks", lastPayload(accent))
end

--------------------------------------------------------------------------------
T.section("A segment light's commands go to the controller")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  local n = #fake.commands
  lightSends(accent, { seg = { { id = 1, on = false } }, tt = 4 }, 1)
  T.eq("sent on as it came", fake.commands[#fake.commands], { seg = { { id = 1, on = false } }, tt = 4 })
  T.eq("once", #fake.commands, n + 1)

  mark()
  lightSends(accent, { seg = { { id = 0, on = false } } }, 0)
  T.eq("not for a segment id the light was not told", #fake.commands, n + 1)
  T.truthy("which is told its segment again", lastPayload(accent))

  ReceivedFromProxy(accent, "ENTITY_COMMAND", { body = "not json", segment = 1 })
  T.eq("nor a body that is not JSON", #fake.commands, n + 1)
end

--------------------------------------------------------------------------------
T.section("Segment lights hear when the controller goes, once")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip").bindingId, linkNamed("Accent").bindingId
  mark()
  fake.reachable = false
  fake:drop()
  W.run(20000)
  T.eq("each is told", { #toldOn(strip, "UPDATE_DISCONNECT"), #toldOn(accent, "UPDATE_DISCONNECT") }, { 1, 1 })
  T.eq("and told no state", #toldOn(strip, "UPDATE_STATE"), 0)
  mark()
  ReceivedFromProxy(strip, "REFRESH_STATE", {})
  T.eq("one that asks meanwhile is told it is away", #toldOn(strip, "UPDATE_DISCONNECT"), 1)
  mark()
  fake.reachable = true
  W.run(20000)
  T.truthy("told its segment once the controller is back", lastPayload(strip))
  T.truthy("and so is the one that did not ask, its segment unchanged", lastPayload(accent))
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  mark()
  fake.si.info.mac = "02a1b2c3d4ee"
  fake:drop()
  W.run(5000)
  T.eq("a different controller at the address: told it is away", #toldOn(accent, "UPDATE_DISCONNECT"), 1)
  T.eq("and nothing about the other controller's segments", #toldOn(accent, "UPDATE_STATE"), 0)
  local n = #fake.commands
  lightSends(accent, { seg = { { id = 1, on = false } } }, 1)
  T.eq("no command reaches it", #fake.commands, n)
end

--------------------------------------------------------------------------------
T.section("Connections follow the segments")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip").bindingId, linkNamed("Accent").bindingId
  connectLight(accent)

  -- WLED deletes the first segment and renumbers the second.
  fake.si.state.seg = { fake.si.state.seg[2] }
  fake.si.state.seg[1].id = 0
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq("a renumbered segment keeps its connection", linkNamed("Accent") and linkNamed("Accent").bindingId, accent)
  T.eq("and its light is told its new id", lastPayload(accent).segment.id, 0)
  T.eq("one nothing is connected to goes with its segment", ShimDynamicBindings()[strip], nil)

  fake.si.state.seg[1].stop = 70
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq("a resized one keeps it too", lastPayload(accent).segment.stop, 70)

  fake.si.state.seg[1].n = "Shelf"
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq("a renamed one is renamed", ShimDynamicBindings()[accent].name, "Shelf")
  local wired = false
  for _, c in ipairs(ShimConnections()) do
    wired = wired or c.providerBinding == accent
  end
  T.truthy("and keeps its segment light connected", wired)

  fake.si.state.seg[2] = { id = 1, start = 70, stop = 80, on = true, bri = 255, lc = 1, col = { { 255, 0, 0 } } }
  mark()
  fake:pushNow()
  W.run(1500)
  T.truthy("a new segment gets a connection", linkNamed("Segment 1"))

  fake.si.state.seg = { fake.si.state.seg[2] }
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq(
    "one gone while a light is connected stays",
    ShimDynamicBindings()[accent] and ShimDynamicBindings()[accent].name,
    "Shelf"
  )
  local gone = toldOn(accent, "UPDATE_DISCONNECT")
  T.eq("and its light shows Segment not found", gone[#gone] and gone[#gone].params.status, "Segment not found")
  local n = #fake.commands
  lightSends(accent, { seg = { { id = 0, on = false } } }, 0)
  T.eq("and drives nothing", #fake.commands, n)

  fake.si.state.seg[2] =
    { id = 0, start = 60, stop = 70, n = "Shelf", on = true, bri = 255, lc = 7, col = { { 0, 0, 255 } } }
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq("it comes back when its segment is back on its LEDs", lastPayload(accent) and lastPayload(accent).segment.id, 0)
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  fake.si.state.seg[3] =
    { id = 2, start = 61, stop = 70, n = "Third", on = true, bri = 255, lc = 1, col = { { 255, 0, 0 } } }
  fake:pushNow()
  W.run(1500)
  local third, accent = linkNamed("Third").bindingId, linkNamed("Accent").bindingId
  for _, b in pairs(links()) do
    connectLight(b.bindingId)
  end
  -- WLED deletes Accent (id 1), and Third is renumbered to 1.
  fake.si.state.seg = { fake.si.state.seg[1], fake.si.state.seg[3] }
  fake.si.state.seg[2].id = 1
  fake:pushNow()
  W.run(1500)
  fake.si.state.seg[2].stop = 80
  mark()
  fake:pushNow()
  W.run(1500)
  T.eq("a resized segment stays with its own light", lastPayload(third) and lastPayload(third).segment.n, "Third")
  T.eq("not the light of a gone segment that had its id", lastPayload(accent), nil)
  local gone = toldOn(accent, "UPDATE_DISCONNECT")
  T.eq("which still shows Segment not found", gone[#gone] and gone[#gone].params.status, "Segment not found")
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  fake.si.state.seg = { fake.si.state.seg[1] }
  fake:pushNow()
  W.run(1500)
  fake.si.state.seg[2] = { id = 1, start = 100, stop = 120, on = true, bri = 255, lc = 1, col = { { 255, 0, 0 } } }
  mark()
  fake:pushNow()
  W.run(1500)
  T.truthy("a new segment with a gone one's id gets its own connection", linkNamed("Segment 1"))
  T.eq("and the gone one's light is not told it", lastPayload(accent), nil)

  OBC[accent](accent, "WLED_SEGMENT", false)
  T.eq("unbinding the gone segment's light removes its connection", ShimDynamicBindings()[accent], nil)
end

--------------------------------------------------------------------------------
T.section("A reload keeps the connections; Reset Driver removes them")
--------------------------------------------------------------------------------
for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  restart(how)
  T.eq(
    "restored at init under the same id (" .. how .. ")",
    ShimDynamicBindings()[accent] and ShimDynamicBindings()[accent].name,
    "Accent"
  )
  T.eq("with its light still connected (" .. how .. ")", C4:GetBoundConsumerDevices(0, accent), {
    [700 + accent] = "Device " .. (700 + accent),
  })
  mark()
  ReceivedFromProxy(accent, "REFRESH_STATE", {})
  T.eq(
    "a light that asks before the first report is told the controller is away (" .. how .. ")",
    #toldOn(accent, "UPDATE_DISCONNECT"),
    1
  )
  W.run(1500)
  T.eq(
    "then its segment, by the record kept (" .. how .. ")",
    lastPayload(accent) and lastPayload(accent).segment.id,
    1
  )
  local n = #fake.commands
  lightSends(accent, { seg = { { id = 1, bri = 9 } } }, 1)
  T.eq("and its commands go through (" .. how .. ")", #fake.commands, n + 1)

  mark()
  ExecuteCommand("Reset Driver", { ["Are You Sure?"] = "Yes" })
  T.eq("Reset Driver tells the lights first (" .. how .. ")", #toldOn(accent, "UPDATE_DISCONNECT"), 1)
  T.eq(
    "as suspended, so they keep their level (" .. how .. ")",
    (toldOn(accent, "UPDATE_DISCONNECT")[1] or { params = {} }).params.suspended,
    true
  )
  T.eq("then removes the connections (" .. how .. ")", ShimDynamicBindings()[accent], nil)
  W.run(30000)
  T.eq("and makes them again for the controller that answers (" .. how .. ")", countLinks(), 2)
end

for _, how in ipairs({ "update", "restart" }) do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  fake.si.state.seg = { fake.si.state.seg[2] }
  fake.si.state.seg[1].id = 0
  fake:pushNow()
  W.run(1500)
  restart(how)
  W.run(1500)
  local named = 0
  for _, b in pairs(links()) do
    named = named + (b.displayName == "Accent" and 1 or 0)
  end
  T.eq("after a renumber and a reload, the segment keeps one connection (" .. how .. ")", named, 1)
  T.eq("its light's (" .. how .. ")", linkNamed("Accent").bindingId, accent)
  mark()
  ReceivedFromProxy(accent, "REFRESH_STATE", {})
  T.eq("which is told its segment (" .. how .. ")", lastPayload(accent) and lastPayload(accent).segment.id, 0)
end

--------------------------------------------------------------------------------
T.section("The controller light with every segment off")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  mark()
  elsewhere(fake, { seg = { on = false } })
  W.run(1500)
  local levels = {}
  for _, t in ipairs(toldOn(5001, "LIGHT_BRIGHTNESS_CHANGED")) do
    levels[#levels + 1] = t.params.LIGHT_BRIGHTNESS_CURRENT
  end
  T.eq("reads off: nothing is lit", levels[#levels], 0)
  local n = #fake.commands
  ReceivedFromProxy(5001, "ON", {})
  W.run(100)
  local on = fake.commands[n + 1] or {}
  local segOn = {}
  for _, s in ipairs(on.seg or {}) do
    segOn[#segOn + 1] = s.id .. "=" .. tostring(s.on)
  end
  T.eq("On lights every segment", segOn, { "0=true", "1=true" })
  W.run(1500)
  T.eq("and the strip is lit", { fake.si.state.seg[1].on, fake.si.state.seg[2].on }, { true, true })

  elsewhere(fake, { seg = { { id = 1, on = false } } })
  W.run(1500)
  n = #fake.commands
  ReceivedFromProxy(5001, "OFF", {})
  W.run(100)
  ReceivedFromProxy(5001, "ON", {})
  W.run(100)
  T.eq("with a segment lit, On is the master only", fake.commands[#fake.commands].seg, nil)
  local _ = n
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  elsewhere(fake, { on = false, seg = { on = false } })
  W.run(1500)
  local n = #fake.commands
  ReceivedFromProxy(5001, "RAMP_TO_LEVEL", { LEVEL = "100", TIME = "70000" })
  W.run(100)
  local first = fake.commands[n + 1] or {}
  local segOn = {}
  for _, seg in ipairs(first.seg or {}) do
    segOn[#segOn + 1] = seg.id .. "=" .. tostring(seg.on)
  end
  T.eq("a fade too long for one command lights the segments with its first leg", segOn, { "0=true", "1=true" })
end

--------------------------------------------------------------------------------
T.section("Segment lights commanded at once, and what each report tells them")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip").bindingId, linkNamed("Accent").bindingId
  elsewhere(fake, { on = false })
  W.run(1500)
  -- A scene turns both segment lights on before the controller reports.
  lightSends(strip, Segment.intent({ on = true, bri = 255, tt = 0 }, 0), 0)
  lightSends(accent, Segment.intent({ on = true, bri = 255, tt = 0 }, 1), 1)
  W.run(1500)
  T.eq("both light", { fake.si.state.on, fake.si.state.seg[1].on, fake.si.state.seg[2].on }, { true, true, true })

  lightSends(strip, Segment.intent({ on = false, tt = 0 }, 0), 0)
  lightSends(accent, Segment.intent({ on = false, tt = 0 }, 1), 1)
  W.run(1500)
  T.eq("both off turns the controller off", fake.si.state.on, false)

  elsewhere(fake, { on = false, seg = { on = false } })
  W.run(1500)
  local n = #fake.commands
  lightSends(strip, Segment.intent({ on = true, bri = 200, tt = 0 }, 0), 0)
  ReceivedFromProxy(5001, "ON", {})
  W.run(100)
  local lit = {}
  for i = n + 2, #fake.commands do
    for _, seg in ipairs(fake.commands[i].seg or {}) do
      if seg.on == true then
        lit[#lit + 1] = seg.id
      end
    end
  end
  T.eq("the controller light's On after a segment light's sees that segment lit", lit, {})
end

do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip").bindingId, linkNamed("Accent").bindingId
  elsewhere(fake, { seg = { { id = 1, on = false } } })
  W.run(1500)
  local n = #fake.commands
  lightSends(strip, Segment.intent({ on = false, tt = 20 }, 0), 0)
  T.eq("off as the last lit segment, with a fade: the master alone", fake.commands[n + 1], { on = false, tt = 20 })
  W.run(1500)
  T.eq("the segment keeps its own power", fake.si.state.seg[1].on, true)

  mark()
  elsewhere(fake, { seg = { { id = 0, col = { { 9, 9, 9 } } } } })
  W.run(1500)
  T.eq("a report that changes another segment tells this light nothing", #toldOn(accent, "UPDATE_STATE"), 0)
  T.eq("and tells the light whose segment changed", #toldOn(strip, "UPDATE_STATE"), 1)
  ReceivedFromProxy(accent, "REFRESH_STATE", {})
  T.eq("a light that asks is told all the same", #toldOn(accent, "UPDATE_STATE"), 1)
end

--------------------------------------------------------------------------------
T.section("A light whose command the controller did not take is told its segment again")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local strip, accent = linkNamed("Strip").bindingId, linkNamed("Accent").bindingId
  connectLight(accent)
  W.run(1500)
  local shown = fake.si.state.seg[2].on
  -- The controller takes the command but does not apply it.
  fake.apply = function() end
  lightSends(accent, Segment.intent({ on = not shown, tt = 0 }, 1), 1)
  mark()
  W.run(1500)
  fake.apply = nil
  elsewhere(fake, { seg = { { id = 0, col = { { 9, 9, 9 } } } } })
  W.run(1500)
  T.eq("the light that wrote is told its segment once", #toldOn(accent, "UPDATE_STATE"), 1)
  T.eq("as the controller shows it", lastPayload(accent) and lastPayload(accent).segment.on, shown)
  T.eq("another light is told only its change", #toldOn(strip, "UPDATE_STATE"), 1)
end

--------------------------------------------------------------------------------
T.section("An unbind before the controller reports keeps the connection")
--------------------------------------------------------------------------------
do
  local fake = fresh("esp32-rgbw-pwm-16")
  W.run(500)
  local accent = linkNamed("Accent").bindingId
  connectLight(accent)
  restart("restart")
  -- Director may unbind and rebind at a controller start, before any report.
  OBC[accent](accent, "WLED_SEGMENT", false)
  T.truthy("the connection is kept", ShimDynamicBindings()[accent])
  local records = 0
  for _ in pairs(require("lib.persist"):get("WledSegmentRecords") or {}) do
    records = records + 1
  end
  T.eq("and every record", records, 2)
  if OBC[accent] then
    OBC[accent](accent, "WLED_SEGMENT", true)
  end
  mark()
  W.run(1500)
  T.eq("rebound, the light is told its segment", lastPayload(accent) and lastPayload(accent).segment.id, 1)
  T.eq("on the same connection", (linkNamed("Accent") or {}).bindingId, accent)
  T.truthy("the controller answered", fake.connects > 0)
end

T.finish()
