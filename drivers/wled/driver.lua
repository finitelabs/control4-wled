-- WLED controller.
--
-- Owns the one connection to a WLED controller (src/wled/client.lua), keeps the controller's
-- model (src/wled/device.lua) and shows it in Composer. The controller's light is the light_v2
-- proxy on binding 5001, run by the light model (src/wled/light.lua) through the WLED adapter
-- (src/wled/light_wled.lua). Its Extras menu is src/wled/extras.lua. WLED Segment lights bind to it,
-- one per segment, and reach the controller through it (src/wled/segment.lua).

--#ifdef DRIVERCENTRAL
DC_PID = 978
DC_X = nil
DC_FILENAME = "wled.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-wled"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local values = require("lib.values")
local bindings = require("lib.bindings")
local conditionals = require("lib.conditionals")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

local constants = require("constants")
local Client = require("wled.client")
local Device = require("wled.device")
local Discovery = require("wled.discovery")
local Extras = require("wled.extras")
local Cycle = require("wled.cycle")
local Segment = require("wled.segment")
local light = require("wled.light")
local LightAdapter = require("wled.light_wled")
local Lists = require("wled.lists")

local EVENT = {
  CONNECTED = 1,
  DISCONNECTED = 2,
  EFFECT_CHANGED = 3,
  PRESET_CHANGED = 4,
  PLAYLIST_STARTED = 5,
  PLAYLIST_ENDED = 6,
}

--- Variables programming reads, each the name of what the controller shows ("" for none).
local PROGRAMMING_VARIABLES = { "Effect", "Palette", "Preset", "Playlist" }

--- The light_v2 proxy's binding.
local PROXY_BINDING = 5001

--- Button links that step through the preset cycle.
local NEXT_PRESET_BINDING, PREVIOUS_PRESET_BINDING = 303, 304

--- The fixed button links from driver.xml: the light's On, Toggle and Off, then Next and Previous Preset.
local BUTTON_LINKS = { 300, 301, 302, NEXT_PRESET_BINDING, PREVIOUS_PRESET_BINDING }

--- Namespace of the button link made for each preset in the cycle, keyed by preset id.
local PRESET_LINKS = "PresetLinks"

--- Namespace of the programming conditionals whose lists come from the controller.
local PROGRAMMING = "Programming"

--- Namespace of the connections segment lights bind to, one per segment, keyed by a record of it.
local SEGMENTS = "Segments"

--- Persist key for those records: the WLED id and LED range each connection last stood for.
local SEGMENT_RECORDS_KEY = "WledSegmentRecords"

--- A keypad tap sends DO_PUSH then DO_CLICK and some senders only one, so a link acts on the
--- first of a burst and ignores the rest for this long.
local BUTTON_LINK_COALESCE_MS = 500

--- Persist key for the MAC of the controller this driver was set up with.
local MAC_KEY = "WledControllerMac"

--- Device Info properties and the model field or method each shows.
local DEVICE_INFO = {
  { "Name", "name" },
  { "Brand", "brand" },
  { "Product", "product" },
  { "Firmware Version", "ver" },
  { "MAC Address", "macDisplay" },
  { "LED Count", "ledCount" },
  { "Segments", "segmentSummary" },
}

--- Set true once OnDriverLateInit finishes; guards the property handlers from
--- firing while Composer replays the initial property values.
local gInitialized = false

--- True while the controller answers and is the one this driver was set up with.
local gConnected = false

--- The MAC that answered when it is not the remembered one.
--- @type string|nil
local gWrongMac = nil

local device = Device:new()

--- @type WledClient
local client

--- Installer white points, the ends of WLED's CCT range.
local DEFAULT_WARM, DEFAULT_COOL = 2700, 6500

--- Send a state command; its result arrives in the controller's next report. Nothing goes to a
--- controller that is not the one this driver was set up with.
--- @param json table
local function send(json)
  if gWrongMac then
    log:warn("WLED command not sent: a different controller answers at this address")
    return
  end
  client:send(json):next(nil, function(err)
    log:warn("WLED command not sent: %s", type(err) == "table" and (err.error or "failed") or tostring(err))
    -- The light shows what was asked; the controller's state puts it right.
    if Select(err, "error") ~= "stopped" then
      client:refresh()
    end
  end)
  -- The next command before the controller reports, from this light or a segment light, sees it.
  Segment.note(json, device)
end

local wledLight = LightAdapter:new({
  device = device,
  send = send,
  warm = function()
    return tonumber(Properties["Warm White (K)"]) or DEFAULT_WARM
  end,
  cool = function()
    return tonumber(Properties["Cool White (K)"]) or DEFAULT_COOL
  end,
})
light.attach(wledLight:adapter())

local lists = Lists:new({
  device = device,
  get = function(path)
    return client:get(path)
  end,
})

--- The lists the controller model reports changes for, by the name of its change.
local LIST_KINDS = { "effects", "palettes", "presets" }

--- Lists to read at the next report: all of them when the controller comes online, then
--- the ones a report says changed.
--- @type table<string, boolean>
local gListsWanted = {}

--- The read under way; reports during it add to gListsWanted for the read after it.
--- @type Deferred|nil
local gListsReading = nil

--- Persist key for what programming last saw, so a change made while the driver reloads is
--- still told.
local SHOWN_KEY = "WledShown"

--- What programming last saw: the main segment's effect and palette, the preset and the
--- playlist. Nil until the driver's controller first reports, which seeds it without events.
--- @type {fx: integer|nil, pal: integer|nil, ps: integer, pl: integer}|nil
local gShown = persist:get(SHOWN_KEY)

--- What the Extras menu last told the proxy: the setup's shape and the values sent since. Nil
--- until the first setup after a load or reset.
--- @type string|nil
local gExtrasShape = nil
--- @type table<string, string>
local gExtrasSent = {}
--- The entries the last setup offered, by list control: a pick comes back as one's text.
--- @type table<string, WledExtrasChoices>|nil
local gExtrasChoices = nil

--- What each segment connection last stood for, by record key: the WLED id, LED range and name,
--- and whether the last report still had the segment.
--- @type table<string, WledSegmentRecord>
local gSegmentRecords = persist:get(SEGMENT_RECORDS_KEY) or {}

--- The records a report since this load found gone while a segment light was still connected.
--- @type table<string, boolean>
local gSegmentsGone = {}

--- The segment each record stands for now; a record whose segment is gone is absent.
--- @type table<string, WledSegment>
local gSegmentOf = {}

--- Whether segment lights were told the controller is there since it last went away.
local gSegmentsTold = false

--- The payload last told each segment connection, so a report tells only the lights it changed.
--- @type table<integer, table>
local gSegmentSent = {}

--- All WLED instances on this controller, sorted by device id. The lowest runs updates.
--- @return integer[]
local function getWledDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tointeger(id)
  end
  table.sort(ids)
  return ids
end

-- ─── Connection state ──────────────────────────────────────────────────────

--- Show a status line. Connected is set only by setConnected, so rewording a status never flips it.
--- @param status string
local function setStatus(status)
  UpdateProperty("Driver Status", status)
end

--- The status line for a connected controller.
--- @return string
local function connectedStatus()
  if client.mode == "http" then
    return "Connected over HTTP; reconnecting live updates"
  end
  return "Connected"
end

--- Tell Control4 the controller came or went. Connection events and the variable follow every
--- change, a reconnect included. The light is told it is offline here; it goes online with
--- the controller's first report.
--- @param connected boolean
--- @param status string
--- @param suspend boolean|nil The driver dropped the connection itself, so the lights keep their level.
local function setConnected(connected, status, suspend)
  setStatus(status)
  if not connected and light.isOnline() then
    light.disconnect(suspend == true)
  end
  if not connected and gSegmentsTold then
    gSegmentsTold = false
    gSegmentSent = {}
    for _, binding in pairs(bindings:getDynamicBindings(SEGMENTS)) do
      SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", { suspended = suspend or nil }, "NOTIFY")
    end
  end
  if connected == gConnected then
    return
  end
  gConnected = connected
  values:update("Connected", connected, "BOOL")
  C4:FireEventByID(connected and EVENT.CONNECTED or EVENT.DISCONNECTED)
  log:info("%s %s", connected and "Connected to" or "Disconnected from", Properties["IP Address"] or "")
end

--- Show the model in Device Info, writing only what changed.
local function updateDeviceInfo()
  for _, item in ipairs(DEVICE_INFO) do
    local name, value = item[1], device[item[2]]
    if type(value) == "function" then
      value = value(device)
    end
    value = value ~= nil and tostring(value) or "N/A"
    if Properties[name] ~= value then
      UpdateProperty(name, value)
    end
  end
end

--- Whether the reporting controller is the one this driver was set up with. The first one
--- seen is remembered; Reset Driver forgets it.
--- @return boolean
local function isOurController()
  if not device.mac then
    return true
  end
  local remembered = persist:get(MAC_KEY)
  if IsEmpty(remembered) then
    persist:set(MAC_KEY, device.mac)
    return true
  end
  return remembered == device.mac
end

-- ─── Programming: effects, palettes, presets, playlists ────────────────────

--- Create the programming variables a first load has not restored, so programming can use them
--- before the controller reports.
local function ensureVariables()
  for _, name in ipairs(PROGRAMMING_VARIABLES) do
    if Variables[name] == nil then
      values:update(name, "", "STRING")
    end
  end
end

--- The segment whose effect and palette stand for the controller: the main one, else the first.
--- @param state table
--- @return table|nil
local function mainSegment(state)
  local main, first = tonumber(state.mainseg) or 0, nil
  for _, seg in ipairs(type(state.seg) == "table" and state.seg or {}) do
    if type(seg) == "table" then
      first = first or seg
      if tonumber(seg.id) == main then
        return seg
      end
    end
  end
  return first
end

--- A playlist is running while pl is 0 or more; 0 is one sent without a preset id.
--- @param pl integer
--- @return boolean
local function playlistRunning(pl)
  return pl >= 0
end

--- Show what the controller shows in the variables, then fire the events for what changed. The
--- first report after an install or a Reset only seeds, so a start or reconnect fires nothing for
--- a state that stayed the same.
local function updateProgramming()
  local state = device.state
  if type(state) ~= "table" then
    return
  end
  local seg = mainSegment(state)
  local now = {
    fx = seg and tonumber(seg.fx) or nil,
    pal = seg and tonumber(seg.pal) or nil,
    ps = tonumber(state.ps) or -1,
    pl = tonumber(state.pl) or -1,
  }
  if lists.effects and now.fx then
    values:update("Effect", lists:effectName(now.fx) or "", "STRING")
  end
  if lists.palettes and now.pal then
    values:update("Palette", lists:paletteName(now.pal) or "", "STRING")
  end
  if lists.presets then
    values:update("Preset", now.ps > 0 and lists:presetName(now.ps) or "", "STRING")
    values:update("Playlist", now.pl > 0 and lists:playlistName(now.pl) or "", "STRING")
  end
  local was = gShown
  if was then
    -- A field moves on only once its list names it, so its event fires with its variable set.
    if not lists.effects then
      now.fx = was.fx
    end
    if not lists.palettes then
      now.pal = was.pal
    end
    if not lists.presets then
      now.ps, now.pl = was.ps, was.pl
    end
  end
  gShown = now
  if not was or now.fx ~= was.fx or now.pal ~= was.pal or now.ps ~= was.ps or now.pl ~= was.pl then
    persist:set(SHOWN_KEY, now)
  end
  if not was then
    return
  end
  if now.fx ~= was.fx then
    C4:FireEventByID(EVENT.EFFECT_CHANGED)
  end
  if now.ps > 0 and now.ps ~= was.ps then
    C4:FireEventByID(EVENT.PRESET_CHANGED)
  end
  local running, wasRunning = playlistRunning(now.pl), playlistRunning(was.pl)
  if running and (not wasRunning or now.pl ~= was.pl) then
    C4:FireEventByID(EVENT.PLAYLIST_STARTED)
  elseif wasRunning and not running then
    C4:FireEventByID(EVENT.PLAYLIST_ENDED)
  end
end

--- Show the controller's lists and the running effect's controls in the Extras menu: a new
--- setup when a list or the controls changed, else a state with the values that moved.
local function updateExtras()
  local state = device.state
  if type(state) ~= "table" or not lists.effects then
    return
  end
  local seg = mainSegment(state)
  local fx = seg and tonumber(seg.fx) or 0
  local view = {
    effects = lists.effects,
    palettes = lists.palettes or {},
    presets = lists.presets or {},
    playlists = lists.playlists or {},
    controls = Extras.controls(fx, lists:effectMeta(fx), Device.has(device.lc, Device.CAP_RGB)),
  }
  view.choices = Extras.choices(view)
  view.values = Extras.values(seg, tonumber(state.ps) or -1, tonumber(state.pl) or -1, view.choices)
  local shape = Extras.shape(view, lists.version)
  if shape ~= gExtrasShape then
    SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = Extras.setup(view) }, "NOTIFY")
    -- A state shows and hides controls in an open menu; the setup alone may wait for a reopen.
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = Extras.state(view.values, {}, view.controls) }, "NOTIFY")
    gExtrasShape, gExtrasSent, gExtrasChoices = shape, view.values, view.choices
    return
  end
  local xml = Extras.state(view.values, gExtrasSent)
  if xml then
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = xml }, "NOTIFY")
    gExtrasSent = view.values
  end
end

--- Persist keys for the cycle, kept so the buttons step at once after a reload, and for the id
--- each name in Cycle Presets last stood for, so a rename on the controller keeps its place.
local CYCLE_KEY, CYCLE_NAMES_KEY = "WledPresetCycle", "WledPresetCycleNames"

--- The presets Next Preset and Previous Preset step through.
--- @type WledListEntry[]
local gCycle = persist:get(CYCLE_KEY) or {}

--- The preset the cycle last applied, so a step after the look was changed goes on from there.
--- @type integer|nil
local gCycleLast = nil

--- The preset showing when the cycle last sent one, until a report shows another: a step before
--- the controller reports the preset it was sent goes on from that preset.
--- @type integer|nil
local gCycleSentFrom = nil

--- The preset the driver's controller shows, from its last report; nil before the first.
--- @type integer|nil
local gPresetShowing = nil

--- What the cycle was last built from: Cycle Presets and the controller's presets.
--- @type string|nil
local gCycleFrom = nil

--- The keypad LED state last told each preset link, by preset id.
--- @type table<string, boolean>
local gLinkLeds = {}

--- The Preset Is conditional's list as last registered.
--- @type string|nil
local gPresetIsItems = nil

--- The preset the controller shows, -1 for none.
--- @return integer
local function presetShowing()
  return gPresetShowing or -1
end

--- Apply a preset from the cycle; the controller applies it on its next loop.
--- @param id integer
local function applyCyclePreset(id)
  gCycleSentFrom = presetShowing()
  gCycleLast = id
  send({ ps = id })
end

--- Step the cycle forward (1) or back (-1) from the preset showing.
--- @param dir integer
local function stepCycle(dir)
  local showing = presetShowing()
  if gCycleSentFrom ~= nil and showing == gCycleSentFrom then
    -- The controller has not reported the preset it was sent yet: a quick second tap steps on.
    showing = gCycleLast
  end
  local id = Cycle.step(gCycle, showing, gCycleLast, dir)
  if not id then
    log:warn("No presets to cycle through")
    return
  end
  applyCyclePreset(id)
end

--- Answer a button link: run `action` once per tap, and tell a keypad that asks the link's LED.
--- @param bindingId integer
--- @param action fun()
--- @param led (fun(): boolean)|nil The LED state; nil for a link whose LED the driver leaves alone.
local function registerButtonLink(bindingId, action, led)
  local coalescing = false
  RFP[bindingId] = function(idBinding, strCommand)
    log:trace("RFP[%s](%s)", idBinding, strCommand)
    if strCommand == "REQUEST_BUTTON_COLORS" then
      if led then
        SendToProxy(idBinding, "MATCH_LED_STATE", { STATE = led() }, "NOTIFY", true)
      end
      return
    end
    if strCommand ~= "DO_CLICK" and strCommand ~= "DO_PUSH" then
      return
    end
    if coalescing then
      return
    end
    coalescing = true
    SetTimer("ButtonLinkCoalesce" .. bindingId, BUTTON_LINK_COALESCE_MS, function()
      coalescing = false
    end)
    action()
  end
end

registerButtonLink(NEXT_PRESET_BINDING, function()
  stepCycle(1)
end)
registerButtonLink(PREVIOUS_PRESET_BINDING, function()
  stepCycle(-1)
end)

--- A preset's own button link, which applies it and is lit while it shows.
--- @param key string The preset id.
--- @param binding Binding
local function registerPresetLink(key, binding)
  local id = tonumber(key)
  registerButtonLink(binding.bindingId, function()
    -- Before the presets are read, as after a reload, the controller ignores an id it lacks.
    if lists.presets and not Lists.byId(lists.presets, id) then
      log:warn("Preset %s is not on the controller", key)
      return
    end
    applyCyclePreset(id)
  end, function()
    return presetShowing() == id
  end)
end

--- Light each preset link's keypad LED while its preset shows.
local function updateLinkLeds()
  local showing = presetShowing()
  for key, binding in pairs(bindings:getDynamicBindings(PRESET_LINKS)) do
    local on = tonumber(key) == showing
    if gLinkLeds[key] ~= on then
      gLinkLeds[key] = on
      SendToProxy(binding.bindingId, "MATCH_LED_STATE", { STATE = on }, "NOTIFY", true)
    end
  end
end

--- @param label string
--- @return string
local function listSafe(label)
  return (label:gsub(",", " "))
end

--- Test for the preset showing, by the id in the "Name (id)" programming shows it as, so the test
--- holds after a rename on the controller.
--- @param _strConditionName string
--- @param tParams table
--- @return boolean
local function testPresetIs(_strConditionName, tParams)
  local picked = tonumber(tostring(Select(tParams, "VALUE") or ""):match("%((%d+)%)%s*$"))
  local matched = picked ~= nil and picked == presetShowing()
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return not matched
  end
  return matched
end

--- Register the Preset Is conditional with the controller's presets, when its list changed.
--- @param items string Comma-separated choices.
--- @param saved boolean|nil Re-register the conditional saved with the project, as every load must.
local function registerPresetIs(items, saved)
  -- A controller without presets gets no conditional, until it has some.
  if not saved and (items == gPresetIsItems or (items == "" and gPresetIsItems == nil)) then
    return
  end
  gPresetIsItems = items
  conditionals:upsertConditional(PROGRAMMING, "preset_is", {
    type = "LIST",
    condition_statement = "Preset Is",
    description = "the preset NAME shows is LOGIC STRING",
    list_items = items,
  }, testPresetIs)
end

--- Build the cycle from Cycle Presets and the controller's presets: a button link for each preset
--- in it, named from the controller, and the Preset Is list. A link whose preset left the cycle
--- goes, unless its preset went from the controller while a keypad is connected to it.
local function updateCycle()
  if not lists.presets then
    return
  end
  local from = tostring(Properties["Cycle Presets"] or "") .. "\n" .. table.concat(lists:presetChoices(), "\n")
  if from ~= gCycleFrom then
    gCycleFrom = from
    local cycle, unknown, named = Cycle.parse(Properties["Cycle Presets"], lists.presets, persist:get(CYCLE_NAMES_KEY))
    if #unknown > 0 then
      log:warn("Cycle Presets: the controller has no preset %s", table.concat(unknown, ", "))
    end
    gCycle = cycle
    persist:set(CYCLE_KEY, #cycle > 0 and cycle or nil)
    persist:set(CYCLE_NAMES_KEY, next(named) and named or nil)
    local labels, inCycle = {}, {}
    for _, e in ipairs(cycle) do
      local key, label = tostring(e.id), string.format("%s (%d)", e.name, e.id)
      labels[#labels + 1] = label
      inCycle[key] = true
      local old = bindings:getDynamicBinding(PRESET_LINKS, key)
      if old and old.displayName ~= label .. " Button Link" then
        -- A rename adds the link again, so the keypad is told its LED again.
        gLinkLeds[key] = nil
      end
      local binding =
        bindings:getOrAddDynamicBinding(PRESET_LINKS, key, "CONTROL", true, label .. " Button Link", "BUTTON_LINK")
      if binding then
        registerPresetLink(key, binding)
      end
    end
    local links = {}
    for key, binding in pairs(bindings:getDynamicBindings(PRESET_LINKS)) do
      links[key] = binding.bindingId
    end
    local wired = GetDeviceBindings(tointeger(C4:GetDeviceID()))
    for key, bindingId in pairs(links) do
      if not inCycle[key] then
        if not Lists.byId(lists.presets, key) and Select(wired, bindingId, "isbound") then
          log:warn("Preset %s is gone from the controller; its button link stays while a keypad uses it", key)
        else
          bindings:deleteBinding(PRESET_LINKS, key)
          gLinkLeds[key] = nil
        end
      end
    end
    UpdateProperty("Presets in Cycle", #labels > 0 and table.concat(labels, ", ") or "None")
    local items = {}
    for i, label in ipairs(lists:presetChoices()) do
      items[i] = listSafe(label)
    end
    registerPresetIs(table.concat(items, ","))
  end
  updateLinkLeds()
end

--- Whether two payloads hold the same values.
--- @param a any
--- @param b any
--- @return boolean
local function samePayload(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not samePayload(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Tell one segment light what its segment shows, or that it is not there. A report tells it
--- only a payload that differs from the last it was told; a bind or a request always tells it.
--- @param key string The segment's record key.
--- @param bindingId integer
--- @param always boolean|nil
local function pushSegment(key, bindingId, always)
  local seg = gSegmentOf[key]
  if not gConnected or not seg then
    gSegmentSent[bindingId] = nil
    SendToProxy(bindingId, "UPDATE_DISCONNECT", gConnected and { status = "Segment not found" } or {}, "NOTIFY")
    return
  end
  local payload = Segment.payload(device, seg.id)
  if not always and samePayload(payload, gSegmentSent[bindingId]) then
    return
  end
  gSegmentsTold = true
  gSegmentSent[bindingId] = payload
  SendToProxy(bindingId, "UPDATE_STATE", { segment = SerializeSafe(payload) }, "NOTIFY")
end

--- Tell every segment light what its segment shows, where that changed.
local function pushSegments()
  for key, binding in pairs(bindings:getDynamicBindings(SEGMENTS)) do
    pushSegment(key, binding.bindingId)
  end
end

--- A segment's connection: a segment light asks for its state and sends its commands over it.
--- A command goes to the controller only while its segment is still the one the light was told.
--- @param key string The segment's record key.
--- @param binding Binding
local function registerSegmentLink(key, binding)
  RFP[binding.bindingId] = function(idBinding, strCommand, tParams)
    log:trace("RFP[%s](%s, %s)", idBinding, strCommand, tParams)
    if strCommand == "REFRESH_STATE" then
      pushSegment(key, idBinding, true)
    elseif strCommand == "ENTITY_COMMAND" then
      local seg = gSegmentOf[key]
      local intent = DeserializeSafe(Select(tParams, "body"))
      if not seg or tonumber(Select(tParams, "segment")) ~= seg.id or type(intent) ~= "table" then
        log:warn("Segment light command not sent: its segment moved or is gone")
        pushSegment(key, idBinding, true)
        return
      end
      -- The next report tells this light its segment even unchanged: a command the controller did
      -- not take is put right.
      gSegmentSent[idBinding] = nil
      send(Segment.forward(intent, device))
    end
  end
  OBC[binding.bindingId] = function(idBinding, strClass, isBound)
    log:trace("OBC[%s](%s, %s)", idBinding, strClass, isBound)
    if isBound then
      pushSegment(key, idBinding, true)
    elseif gSegmentsGone[key] then
      -- Only a report since this load counts: the stored live flag outlives a reload, and Director
      -- may unbind and rebind at a controller start.
      bindings:deleteBinding(SEGMENTS, key)
      gSegmentsGone[key] = nil
      gSegmentRecords[key] = nil
      gSegmentSent[idBinding] = nil
      persist:set(SEGMENT_RECORDS_KEY, next(gSegmentRecords) and gSegmentRecords or nil)
    end
  end
end

--- A record key no segment uses yet.
--- @return string
local function newSegmentKey()
  local n = 1
  while gSegmentRecords["seg" .. n] do
    n = n + 1
  end
  return "seg" .. n
end

--- Find each segment connection's segment again after a change of layout: a renumbered or resized
--- segment keeps its connection, a new one gets one, and one whose segment is gone shows "Segment
--- not found" while a segment light is connected to it and is removed otherwise.
local function updateSegments()
  local matched, unmatched = Segment.match(gSegmentRecords, device.segments)
  for _, seg in ipairs(unmatched) do
    local key = newSegmentKey()
    gSegmentRecords[key] = { id = seg.id, start = seg.start, stop = seg.stop, name = seg.name }
    matched[key] = seg
  end
  local wired = GetDeviceBindings(tointeger(C4:GetDeviceID()))
  local keys = {}
  for key in pairs(gSegmentRecords) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local seg = matched[key]
    if seg then
      gSegmentRecords[key] = { id = seg.id, start = seg.start, stop = seg.stop, name = seg.name }
      gSegmentsGone[key] = nil
      local binding = bindings:getOrAddDynamicBinding(SEGMENTS, key, "PROXY", true, Segment.name(seg), Segment.CLASS)
      if binding then
        registerSegmentLink(key, binding)
      end
    else
      local binding = bindings:getDynamicBinding(SEGMENTS, key)
      if binding and Select(wired, binding.bindingId, "isbound") then
        gSegmentRecords[key].live = false
        gSegmentsGone[key] = true
        log:warn("Segment %s is gone from the controller; its segment light shows Segment not found", key)
      else
        if binding then
          bindings:deleteBinding(SEGMENTS, key)
        end
        gSegmentsGone[key] = nil
        gSegmentRecords[key] = nil
      end
    end
  end
  gSegmentOf = matched
  persist:set(SEGMENT_RECORDS_KEY, next(gSegmentRecords) and gSegmentRecords or nil)
end

local function wantAllLists()
  for _, kind in ipairs(LIST_KINDS) do
    gListsWanted[kind] = true
  end
end

--- Read the lists that are wanted, one read at a time, then show their names.
local function readLists()
  if gListsReading or next(gListsWanted) == nil then
    return
  end
  local what = gListsWanted
  gListsWanted = {}
  local reading = lists:refresh(what)
  gListsReading = reading
  reading:next(function(failed)
    if gListsReading ~= reading then
      return
    end
    gListsReading = nil
    readLists()
    -- The next report reads a failed list again; reading it at once could loop.
    for kind in pairs(failed or {}) do
      gListsWanted[kind] = true
    end
    -- Events wait for the names they read: never while a list read is under way.
    if not gListsReading then
      updateProgramming()
      updateExtras()
      updateCycle()
    end
  end, function(err)
    -- A read that failed must not hold back every read after it.
    if gListsReading == reading then
      gListsReading = nil
    end
    log:warn("WLED lists not read: %s", tostring(err))
  end)
end

--- Send segment fields to every segment the controller has, as a Control4 color does.
--- @param fields table Segment fields, e.g. { fx = 9 }.
local function sendToSegments(fields)
  local segs = {}
  for _, s in ipairs(device.segments or {}) do
    local seg = { id = s.id }
    for key, value in pairs(fields) do
      seg[key] = value
    end
    segs[#segs + 1] = seg
  end
  send({ seg = #segs > 0 and segs or fields })
end

-- ─── Finding the controller ───────────────────────────────────────────────

--- @return string
local function ipAddress()
  return ((Properties["IP Address"] or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Connect to the controller the properties name, or say what is missing.
local function connect()
  local ip = ipAddress()
  lists:cancel()
  gListsReading = nil
  wantAllLists()
  client:stop()
  gWrongMac = nil
  if ip == "" then
    setConnected(false, "Set the IP Address to the WLED controller's address")
    return
  end
  setStatus("Connecting")
  client:start(ip, tointeger(Properties["Port"]) or 80)
end

local FOUND_CONTROLLERS = "Found Controllers"

--- The idle item of Found Controllers, so the same controller can be picked again.
local SELECT_OPTION = "(Select)"

--- While the driver's controller cannot be reached, how often to look for it at another address.
local FOLLOW_MS = 30 * ONE_SECOND
local FOLLOW_TIMER = "WledFollow"

--- The controllers the last search found, by the item Found Controllers shows for each.
--- @type table<string, MdnsService>
local gFound = {}

--- Whether IP Address and Port may follow the driver's controller to a new address. Not after
--- the installer names an address, until the driver's controller answers there.
local gFollow = false

--- Whether the driver's controller was lost: it stopped answering, or another answers at its
--- address. Until then, even while a first connection is under way, there is nothing to follow.
local gLost = false

--- Whether the follow timer runs.
local gFollowing = false

--- @param controller MdnsService
--- @return string
local function foundItem(controller)
  local address = controller.ip
  if controller.port ~= 80 then
    address = address .. ":" .. controller.port
  end
  -- Composer splits the list at commas.
  return (string.format("%s (%s)", controller.name, address):gsub(",", " "))
end

--- Show what a search found in Found Controllers, hidden while it found nothing.
--- @param found MdnsService[]
local function showFound(found)
  gFound = {}
  local items = { SELECT_OPTION }
  for _, controller in ipairs(found) do
    local item = foundItem(controller)
    if not gFound[item] then
      gFound[item] = controller
      items[#items + 1] = item
    end
  end
  UpdatePropertyList(FOUND_CONTROLLERS, table.concat(items, ","))
  UpdateProperty(FOUND_CONTROLLERS, SELECT_OPTION)
  C4:SetPropertyAttribs(FOUND_CONTROLLERS, #items > 1 and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
end

--- Point IP Address and Port at where the driver's controller answered, once it was lost where
--- it was. A host name in IP Address is the installer's, and is kept.
--- @param found MdnsService[]
local function follow(found)
  local mac = persist:get(MAC_KEY)
  local ip, port = ipAddress(), tostring(Properties["Port"])
  if not gFollow or not gLost or IsEmpty(mac) or not ip:match("^%d+%.%d+%.%d+%.%d+$") then
    return
  end
  local moved
  for _, controller in ipairs(found) do
    if controller.mac == mac then
      -- One announced at the address in use, among others, stays there.
      if controller.ip == ip and tostring(controller.port) == port then
        return
      end
      moved = moved or controller
    end
  end
  if moved then
    log:info("The WLED controller answers at %s port %d now; following it", moved.ip, moved.port)
    UpdateProperty("IP Address", moved.ip)
    UpdateProperty("Port", tostring(moved.port))
    connect()
  end
end

--- Look for WLED controllers, show them in Found Controllers, and follow the driver's controller.
--- @return Deferred
local function search()
  return Discovery.search():next(function(found)
    showFound(found)
    follow(found)
    return found
  end, function(err)
    log:warn("Could not look for WLED controllers: %s", tostring(err))
    return {}
  end)
end

local function stopFollowing()
  gFollowing = false
  CancelTimer(FOLLOW_TIMER)
end

--- Look for the driver's controller now and every FOLLOW_MS while it cannot be reached.
local function startFollowing()
  if gFollowing or not gFollow or IsEmpty(persist:get(MAC_KEY)) then
    return
  end
  gFollowing = true
  search()
  SetTimer(FOLLOW_TIMER, FOLLOW_MS, function()
    search()
  end, true)
end

--- @param state table|nil
--- @param info table|nil
local function onState(state, info)
  local changes = device:update(state, info)
  if changes.mac or gWrongMac then
    if not isOurController() then
      gWrongMac = device.mac
      setConnected(
        false,
        string.format(
          "A different WLED controller (%s) answers at this address; run Reset Driver to use it",
          device:macDisplay() or "unknown"
        )
      )
      -- The driver's controller may have moved, and this one taken its address.
      gLost = true
      startFollowing()
      return
    end
    gWrongMac = nil
  end
  gFollow, gLost = true, false
  stopFollowing()
  if changes.identity or changes.mac or changes.leds or changes.segments then
    updateDeviceInfo()
  end
  setConnected(true, connectedStatus())
  if state ~= nil then
    gPresetShowing = tonumber(state.ps) or -1
    if gCycleSentFrom ~= nil and gPresetShowing ~= gCycleSentFrom then
      gCycleSentFrom = nil
    end
  end
  if state ~= nil then
    light.state(wledLight:entity(), wledLight:state())
    if changes.segments or changes.first or next(gSegmentOf) == nil then
      updateSegments()
    end
    pushSegments()
  end
  for _, kind in ipairs(LIST_KINDS) do
    -- New firmware can rename an effect or palette without changing a count.
    if changes[kind] or changes.identity then
      gListsWanted[kind] = true
    end
  end
  readLists()
  if not gListsReading then
    updateProgramming()
    updateExtras()
    updateCycle()
  end
end

local function onOnline()
  -- Connected waits for the first state, which carries the MAC to check.
  setStatus("Connecting")
  -- The controller may have changed its lists while it could not be reached.
  wantAllLists()
end

--- @param reason string
local function onOffline(reason)
  if gWrongMac then
    return
  end
  setConnected(false, "Not connected: " .. reason)
  gLost = true
  startFollowing()
end

client = Client:new({ onState = onState, onOnline = onOnline, onOffline = onOffline })

-- ─── Updates ───────────────────────────────────────────────────────────────

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(
      DRIVER_GITHUB_REPO,
      require("lib.driver-filenames"),
      Properties["Update Channel"] == "Prerelease",
      forceUpdate
    )
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("Driver update failed: %s", err)
    end)
end
--#endif

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  -- Clear stale WebSocket binding addresses from earlier runs, whose delayed release KillAllTimers
  -- ends. Address only: a NetDisconnect would drive an orphaned socket into a reconnect.
  for i = 6100, 6199 do
    pcall(C4.SetBindingAddress, C4, i, "")
  end
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  values:restoreValues()
  -- Early, so Director keeps the keypads connected to the preset links.
  bindings:restoreBindings()
  for key, binding in pairs(bindings:getDynamicBindings(PRESET_LINKS)) do
    registerPresetLink(key, binding)
  end
  for key, binding in pairs(bindings:getDynamicBindings(SEGMENTS)) do
    registerSegmentLink(key, binding)
  end
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok then
      log:error("OnPropertyChanged('%s') failed: %s", p, tostring(err))
      --#ifdef DRIVERCENTRAL
      diagnostics:captureError(tostring(err), nil, "WLED.OnPropertyChanged")
      --#endif
    end
  end

  --#ifndef DRIVERCENTRAL
  -- Only the lowest WLED instance checks, at most every 30 min, and only when
  -- Automatic Updates is On. The DriverCentral build lets cloud-client-byte own updates.
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    local isLeader = Select(getWledDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  -- Shown off until the controller answers; the proxy keeps its last level meanwhile.
  values:update("Connected", false, "BOOL")
  ensureVariables()
  -- Test functions live in memory: Preset Is answers from its saved list until the presets are read.
  local saved = Select(conditionals:getConditionals(), PROGRAMMING, "preset_is", "list_items")
  if saved then
    registerPresetIs(saved, true)
  end
  gInitialized = true
  light.lateInit()
  -- The address saved with the project is where the driver's controller was, so it may follow it.
  gFollow = true
  connect()
  showFound({})
  search()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  client:stop()
  Discovery.stop()
  -- Ramps, scene steps, echo waits and fade legs are all named timers.
  KillAllTimers()
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status(%s)", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version(%s)", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level(%s)", propertyValue)
  log:setLogLevel(propertyValue)
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode(%s)", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

--- An address the installer names is kept, until the driver's controller answers there.
local function addressChanged()
  if gInitialized then
    gFollow = false
    stopFollowing()
    connect()
  end
end

function OPC.IP_Address(propertyValue)
  log:trace("OPC.IP_Address(%s)", propertyValue)
  addressChanged()
end

function OPC.Port(propertyValue)
  log:trace("OPC.Port(%s)", propertyValue)
  addressChanged()
end

--- Picking a found controller sets IP Address and Port to its address.
function OPC.Found_Controllers(propertyValue)
  log:trace("OPC.Found_Controllers(%s)", propertyValue)
  if not gInitialized or IsEmpty(propertyValue) or propertyValue == SELECT_OPTION then
    return
  end
  local controller = gFound[propertyValue]
  UpdateProperty(FOUND_CONTROLLERS, SELECT_OPTION)
  if not controller then
    return
  end
  log:info("Using the WLED controller %s", propertyValue)
  UpdateProperty("IP Address", controller.ip)
  UpdateProperty("Port", tostring(controller.port))
  addressChanged()
end

--- A new white point moves the light's color temperature range.
local function whitePointChanged()
  if gInitialized and light.isOnline() then
    light.state(wledLight:entity(), wledLight:state())
  end
end

function OPC.Warm_White_K(propertyValue)
  log:trace("OPC.Warm_White_K(%s)", propertyValue)
  whitePointChanged()
end

function OPC.Cool_White_K(propertyValue)
  log:trace("OPC.Cool_White_K(%s)", propertyValue)
  whitePointChanged()
end

function OPC.Cycle_Presets(propertyValue)
  log:trace("OPC.Cycle_Presets(%s)", propertyValue)
  if gInitialized then
    updateCycle()
  end
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates(%s)", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel(%s)", propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end

--- Turns Cloud Monitoring on or off.
--- @param propertyValue string
function OPC.Cloud_Monitoring(propertyValue)
  log:trace("OPC.Cloud_Monitoring(%s)", propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
  log:trace("EC.DiagnosticsSnapshot()")
  diagnostics:dumpSnapshot()
end
--#endif

-- ─── Conditionals (TC dispatch) ────────────────────────────────────────────

--- Test condition for the controller's connection, the state the Connected events follow.
--- @param strConditionName string
--- @param tParams table
--- @return boolean
function TC.CONTROLLER_CONNECTED(strConditionName, tParams)
  log:trace("TC.CONTROLLER_CONNECTED(%s, %s)", strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Connected"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= gConnected
  end
  return test == gConnected
end

--- Test condition for a running playlist, the state the Playlist events follow.
--- @param strConditionName string
--- @param tParams table
--- @return boolean
function TC.PLAYLIST_RUNNING(strConditionName, tParams)
  log:trace("TC.PLAYLIST_RUNNING(%s, %s)", strConditionName, tParams)
  local running = gShown ~= nil and playlistRunning(gShown.pl)
  local test = Select(tParams, "VALUE") == "Running"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= running
  end
  return test == running
end

-- ─── Programming commands (EC and GCPL dispatch) ───────────────────────────

--- The effects the controller offers, by name.
--- @return string[]
function GCPL.Set_Effect(_paramName)
  return lists:effectNames()
end

--- Run an effect on every segment, by name or id, from the effect's own defaults as WLED's page
--- starts it; power and level stay as they are.
--- @param params table
function EC.Set_Effect(params)
  log:trace("EC.Set_Effect(%s)", params)
  local id = lists:effectId(Select(params, "Effect"))
  if not id then
    log:warn("Set Effect: the controller has no effect %s", tostring(Select(params, "Effect")))
    return
  end
  sendToSegments({ fx = id, fxdef = true })
end

--- A 0-255 slider value from a command parameter.
--- @param value any
--- @return integer|nil
local function byte(value)
  return InRange(tointeger(value), 0, 255)
end

--- Set the effect speed on every segment, 0 to 255.
--- @param params table
function EC.Set_Effect_Speed(params)
  log:trace("EC.Set_Effect_Speed(%s)", params)
  local sx = byte(Select(params, "Speed"))
  if sx then
    sendToSegments({ sx = sx })
  end
end

--- Set the effect intensity on every segment, 0 to 255.
--- @param params table
function EC.Set_Effect_Intensity(params)
  log:trace("EC.Set_Effect_Intensity(%s)", params)
  local ix = byte(Select(params, "Intensity"))
  if ix then
    sendToSegments({ ix = ix })
  end
end

--- The palettes the controller offers, by name.
--- @return string[]
function GCPL.Set_Palette(_paramName)
  return lists:paletteNames()
end

--- Use a palette on every segment, by name or id; power and level stay as they are.
--- @param params table
function EC.Set_Palette(params)
  log:trace("EC.Set_Palette(%s)", params)
  local id = lists:paletteId(Select(params, "Palette"))
  if not id then
    log:warn("Set Palette: the controller has no palette %s", tostring(Select(params, "Palette")))
    return
  end
  sendToSegments({ pal = id })
end

--- The presets the controller holds, as "Name (id)".
--- @return string[]
function GCPL.Apply_Preset(_paramName)
  return lists:presetChoices()
end

--- Apply a preset, found by the id its choice carries.
--- @param params table
function EC.Apply_Preset(params)
  log:trace("EC.Apply_Preset(%s)", params)
  local id = lists:presetId(Select(params, "Preset"))
  if not id then
    log:warn("Apply Preset: the controller has no preset %s", tostring(Select(params, "Preset")))
    return
  end
  -- The controller applies a preset on its next loop; its next report shows the result.
  send({ ps = id })
end

--- The playlists the controller holds, as "Name (id)".
--- @return string[]
function GCPL.Start_Playlist(_paramName)
  return lists:playlistChoices()
end

--- Start a playlist, found by the id its choice carries.
--- @param params table
function EC.Start_Playlist(params)
  log:trace("EC.Start_Playlist(%s)", params)
  local id = lists:playlistId(Select(params, "Playlist"))
  if not id then
    log:warn("Start Playlist: the controller has no playlist %s", tostring(Select(params, "Playlist")))
    return
  end
  send({ ps = id })
end

--- Unload the running playlist; the current look stays.
local function stopPlaylist()
  -- An empty playlist object unloads the running one, as WLED's own app stops it; an empty
  -- array would be ignored, so the object is marked for the encoder.
  send({ playlist = JSON:newObject() })
end

--- Stop the running playlist; the current look stays.
function EC.Stop_Playlist(_params)
  log:trace("EC.Stop_Playlist()")
  stopPlaylist()
end

--- Apply the next preset in the cycle: the one after the preset showing, or after the one the
--- cycle last applied.
function EC.Next_Preset(_params)
  log:trace("EC.Next_Preset()")
  stepCycle(1)
end

--- Apply the previous preset in the cycle.
function EC.Previous_Preset(_params)
  log:trace("EC.Previous_Preset()")
  stepCycle(-1)
end

-- ─── Extras menu (RFP dispatch) ────────────────────────────────────────────

--- What each list in the Extras menu sends for the id of the entry picked. Each returns the id it
--- sent, or nil for an id the controller does not have.
--- @type table<string, fun(value: any): integer|nil>
local EXTRA_LISTS = {
  fx = function(value)
    local id = Lists.byId(lists.effects, value)
    if id then
      sendToSegments({ fx = id, fxdef = true })
    end
    return id
  end,
  pal = function(value)
    local id = Lists.byId(lists.palettes, value)
    if id then
      sendToSegments({ pal = id })
    end
    return id
  end,
  ps = function(value)
    local id = Lists.byId(lists.presets, value)
    if id then
      send({ ps = id })
    end
    return id
  end,
  pl = function(value)
    if tonumber(value) == Extras.NO_PLAYLIST then
      stopPlaylist()
      return Extras.NO_PLAYLIST
    end
    local id = Lists.byId(lists.playlists, value)
    if id then
      send({ ps = id })
    end
    return id
  end,
}

--- Set one Extras control on every segment and show it in the menu: a list pick by the text the
--- last setup gave its entry, a slider clamped to its range, or a check. The controller's next
--- report shows what it did.
--- @param id string The control's id, as the menu names it (fx, sx, c1, o1, ...).
--- @param picked any
local function setExtra(id, picked)
  if gWrongMac then
    log:warn("Extras: not sent, a different controller answers at this address")
    return
  end
  local kind = Extras.KINDS[id or ""]
  -- What was sent, as the menu shows it.
  local value
  if kind == "list" then
    -- A text the menu was not given, an id among them, picks nothing.
    local entry = Select(gExtrasChoices, id, "id", tostring(picked))
    if entry == nil then
      log:warn("Extras: the menu has no %s %s", tostring(id), tostring(picked))
      return
    end
    local sent = EXTRA_LISTS[id](entry)
    value = sent and (Select(gExtrasChoices, id, "text", sent) or tostring(sent))
  elseif kind == "bool" then
    local on = toboolean(picked)
    sendToSegments({ [id] = on })
    value = on and "true" or "false"
  elseif type(kind) == "table" and tonumber(picked) then
    value = InRange(round(tonumber(picked)), kind.min, kind.max)
    sendToSegments({ [id] = value })
  end
  if value == nil then
    log:warn("Extras: the controller has no %s %s", tostring(id), tostring(picked))
    return
  end
  if gExtrasShape then
    value = tostring(value)
    gExtrasSent[id] = value
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = Extras.state({ [id] = value }, {}) }, "NOTIFY")
  end
end

--- A pick or a slider in the light's Extras menu, sent to every segment as programming's commands
--- are. The menu shows the pick at once; the controller's next report shows what it did.
--- @param idBinding integer
--- @param strCommand string
--- @param tParams table {id = control id, value = what was picked}
function RFP.EXTRA_SET(idBinding, strCommand, tParams)
  log:trace("RFP.EXTRA_SET(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  setExtra(Select(tParams, "id"), Select(tParams, "value"))
end

--- The running effect's Custom sliders and Check options, by the names the menu and programming
--- show, as the controls they set.
local EFFECT_CUSTOM = { ["Custom 1"] = "c1", ["Custom 2"] = "c2", ["Custom 3"] = "c3" }
local EFFECT_OPTIONS = { ["Check 1"] = "o1", ["Check 2"] = "o2", ["Check 3"] = "o3" }

--- Set one of the running effect's Custom sliders on every segment, as the Extras menu does:
--- 0 to 255, Custom 3 0 to 31.
--- @param params table {Control = "Custom 1"|"Custom 2"|"Custom 3", Value = 0-255}
function EC.Set_Effect_Custom_Value(params)
  log:trace("EC.Set_Effect_Custom_Value(%s)", params)
  local id = EFFECT_CUSTOM[Select(params, "Control") or ""]
  if not id then
    log:warn("Set Effect Custom Value: no control %s", tostring(Select(params, "Control")))
    return
  end
  setExtra(id, Select(params, "Value"))
end

--- Turn one of the running effect's Check options on or off on every segment, as the Extras menu
--- does.
--- @param params table {Option = "Check 1"|"Check 2"|"Check 3", State = "On"|"Off"}
function EC.Set_Effect_Option(params)
  log:trace("EC.Set_Effect_Option(%s)", params)
  local id = EFFECT_OPTIONS[Select(params, "Option") or ""]
  if not id then
    log:warn("Set Effect Option: no option %s", tostring(Select(params, "Option")))
    return
  end
  setExtra(id, Select(params, "State") == "On")
end

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

--- Settable properties a reset returns to their defaults; IP Address and Port are kept.
--- @type table<string, string>
local RESET_PROPERTY_VALUES = {
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
  ["Automatic Updates"] = "On",
  --#ifndef DRIVERCENTRAL
  ["Update Channel"] = "Production",
  --#endif
  ["Warm White (K)"] = tostring(DEFAULT_WARM),
  ["Cool White (K)"] = tostring(DEFAULT_COOL),
  ["Cycle Presets"] = "",
  --#ifdef DRIVERCENTRAL
  ["Cloud Monitoring"] = "Enabled",
  --#endif
}

--- Look for WLED controllers and list them in Found Controllers.
function EC.Find_Controllers()
  log:trace("EC.Find_Controllers()")
  search():next(function(found)
    log:print("Found %d WLED controller(s)", #found)
  end)
end

--- Return the driver to its first load and connect again, taking whichever controller answers.
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")
  persist:delete(MAC_KEY)
  stopFollowing()
  -- Tell the proxy and programming before the light's state is cleared. The controller is still
  -- there, so its lights keep their level: no Light Off for a light that did not change.
  setConnected(false, "Connecting", true)
  values:reset()
  -- As an unbind does: a fresh install has no white of its own remembered.
  light.reset(false)
  device = Device:new()
  wledLight.device = device
  lists.device = device
  lists:clear()
  gShown = nil
  persist:delete(SHOWN_KEY)
  gExtrasShape, gExtrasSent, gExtrasChoices = nil, {}, nil
  -- A fresh install has no keypad wired to a button link; the light's own proxy stays bound.
  local wired = GetDeviceBindings(tointeger(C4:GetDeviceID()))
  for _, id in ipairs(BUTTON_LINKS) do
    for _, consumer in pairs(Select(wired, id, "boundconsumers") or {}) do
      C4:Unbind(tointeger(consumer.deviceid), tointeger(consumer.bindingid))
    end
  end
  bindings:reset()
  conditionals:reset()
  gCycle, gCycleLast, gCycleSentFrom, gCycleFrom, gLinkLeds, gPresetIsItems = {}, nil, nil, nil, {}, nil
  gPresetShowing = nil
  gSegmentRecords, gSegmentsGone, gSegmentOf, gSegmentsTold, gSegmentSent = {}, {}, {}, false, {}
  persist:delete(SEGMENT_RECORDS_KEY)
  persist:delete(CYCLE_KEY)
  persist:delete(CYCLE_NAMES_KEY)
  SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = "<extras_setup><extra></extra></extras_setup>" }, "NOTIFY")
  values:update("Connected", false, "BOOL")
  ensureVariables()
  for name, value in pairs(RESET_PROPERTY_VALUES) do
    UpdateProperty(name, value, true)
  end
  for name, value in pairs(GetPropertyResetValues({ "Driver Version" })) do
    UpdateProperty(name, value, true)
  end
  connect()
end
