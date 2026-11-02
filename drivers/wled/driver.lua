-- WLED controller.
--
-- Owns the one connection to a WLED controller (src/wled/client.lua), keeps the controller's
-- model (src/wled/device.lua) and shows it in Composer. The controller's light is the light_v2
-- proxy on binding 5001, run by the light model (src/wled/light.lua) through the WLED adapter
-- (src/wled/light_wled.lua). Its Extras menu is src/wled/extras.lua.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
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
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

local Client = require("wled.client")
local Device = require("wled.device")
local Extras = require("wled.extras")
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

local device = Device.new()

--- @type WledClient
local client

--- Installer white points, the ends of WLED's CCT range.
local DEFAULT_WARM, DEFAULT_COOL = 2700, 6500

--- Send a state command; its result arrives in the controller's next report.
--- @param json table
local function send(json)
  client:send(json):next(nil, function(err)
    log:warn("WLED command not sent: %s", type(err) == "table" and (err.error or "failed") or tostring(err))
  end)
end

local wledLight = LightAdapter.new({
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

local lists = Lists.new({
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

--- What programming last saw: the main segment's effect and palette, the preset and the
--- playlist. Nil until the first report after a load, which seeds it without events.
--- @type {fx: integer|nil, pal: integer|nil, ps: integer, pl: integer}|nil
local gShown = nil

--- What the Extras menu last told the proxy: the setup's shape and the values sent since. Nil
--- until the first setup after a load or reset.
--- @type string|nil
local gExtrasShape = nil
--- @type table<string, string>
local gExtrasSent = {}

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
local function setConnected(connected, status)
  setStatus(status)
  if not connected and light.isOnline() then
    light.disconnect(false)
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
--- first report after a load only seeds, so a start or reconnect fires nothing for a state that
--- stayed the same.
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
  gShown = now
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
    values = Extras.values(seg, tonumber(state.ps) or -1, tonumber(state.pl) or -1),
  }
  local shape = Extras.shape(view, lists.version)
  if shape ~= gExtrasShape then
    SendToProxy(PROXY_BINDING, "EXTRAS_SETUP_CHANGED", { XML = Extras.setup(view) }, "NOTIFY")
    gExtrasShape, gExtrasSent = shape, view.values
    return
  end
  local xml = Extras.state(view.values, gExtrasSent)
  if xml then
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = xml }, "NOTIFY")
    gExtrasSent = view.values
  end
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
  reading:next(function()
    if gListsReading ~= reading then
      return
    end
    gListsReading = nil
    readLists()
    -- Events wait for the names they read: never while a list read is under way.
    if not gListsReading then
      updateProgramming()
      updateExtras()
    end
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
      return
    end
    gWrongMac = nil
  end
  if changes.identity or changes.mac or changes.leds or changes.segments then
    updateDeviceInfo()
  end
  setConnected(true, connectedStatus())
  if state ~= nil then
    light.state(wledLight:entity(), wledLight:state())
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
end

client = Client.new({ onState = onState, onOnline = onOnline, onOffline = onOffline })

--- Connect to the controller the properties name, or say what is missing.
local function connect()
  local ip = Properties["IP Address"] or ""
  ip = ip:gsub("^%s+", ""):gsub("%s+$", "")
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
  gInitialized = true
  light.lateInit()
  connect()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  client:stop()
  -- Ramps, scene steps, echo waits and fade legs are all named timers.
  KillAllTimers()
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.IP_Address(_v)
  if gInitialized then
    connect()
  end
end

function OPC.Port(_v)
  if gInitialized then
    connect()
  end
end

--- A new white point moves the light's color temperature range.
local function whitePointChanged()
  if gInitialized and light.isOnline() then
    light.state(wledLight:entity(), wledLight:state())
  end
end

function OPC.Warm_White_K(_v)
  whitePointChanged()
end

function OPC.Cool_White_K(_v)
  whitePointChanged()
end

function OPC.Automatic_Updates(propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
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
  diagnostics:setEnabled(propertyValue == "Enabled")
end

--- Prints a diagnostics report, and sends it while Cloud Monitoring is on.
function EC.DiagnosticsSnapshot()
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

--- Run an effect on every segment, by name or id; power and level stay as they are.
--- @param params table
function EC.Set_Effect(params)
  log:trace("EC.Set_Effect(%s)", params)
  local id = lists:effectId(Select(params, "Effect"))
  if not id then
    log:warn("Set Effect: the controller has no effect %s", tostring(Select(params, "Effect")))
    return
  end
  sendToSegments({ fx = id })
end

--- A 0-255 slider value from a command parameter.
--- @param value any
--- @return integer|nil
local function byte(value)
  local n = tonumber(value)
  return n and math.max(0, math.min(255, math.floor(n + 0.5))) or nil
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

-- ─── Extras menu (RFP dispatch) ────────────────────────────────────────────

--- What each list in the Extras menu sends for the id picked, or false for an id the controller
--- does not have.
--- @type table<string, fun(value: any): boolean>
local EXTRA_LISTS = {
  fx = function(value)
    local id = lists:effectId(value)
    if id then
      sendToSegments({ fx = id })
    end
    return id ~= nil
  end,
  pal = function(value)
    local id = lists:paletteId(value)
    if id then
      sendToSegments({ pal = id })
    end
    return id ~= nil
  end,
  ps = function(value)
    local id = lists:presetId(value)
    if id then
      send({ ps = id })
    end
    return id ~= nil
  end,
  pl = function(value)
    if tonumber(value) == Extras.NO_PLAYLIST then
      stopPlaylist()
      return true
    end
    local id = lists:playlistId(value)
    if id then
      send({ ps = id })
    end
    return id ~= nil
  end,
}

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
  local id, value = Select(tParams, "id"), Select(tParams, "value")
  local kind = Extras.KINDS[id or ""]
  local sent
  if kind == "list" then
    sent = EXTRA_LISTS[id](value)
  elseif kind == "bool" then
    value = toboolean(value)
    sendToSegments({ [id] = value })
    sent, value = true, value and "true" or "false"
  elseif type(kind) == "table" and tonumber(value) then
    value = math.max(kind.min, math.min(kind.max, math.floor(tonumber(value) + 0.5)))
    sendToSegments({ [id] = value })
    sent = true
  end
  if not sent then
    log:warn("Extras: the controller has no %s %s", tostring(id), tostring(value))
    return
  end
  if gExtrasShape then
    value = tostring(value)
    gExtrasSent[id] = value
    SendToProxy(PROXY_BINDING, "EXTRAS_STATE_CHANGED", { XML = Extras.state({ [id] = value }, {}) }, "NOTIFY")
  end
end

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
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
}

--- Return the driver to its first load and connect again, taking whichever controller answers.
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")
  persist:delete(MAC_KEY)
  -- Tell the proxy and programming before the light's state is cleared.
  setConnected(false, "Connecting")
  values:reset()
  light.reset(true)
  device = Device.new()
  wledLight.device = device
  lists.device = device
  lists:clear()
  gShown = nil
  gExtrasShape, gExtrasSent = nil, {}
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
