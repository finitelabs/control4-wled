-- WLED controller.
--
-- Owns the one connection to a WLED controller (src/wled/client.lua), keeps the controller's
-- model (src/wled/device.lua) and shows it in Composer. The controller's light is the light_v2
-- proxy on binding 5001; it follows the connection's online state. Light commands come in a
-- later layer.

--#ifdef DRIVERCENTRAL
DC_PID = 0
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

local PROXY_BINDING = 5001
local EVENT = { CONNECTED = 1, DISCONNECTED = 2 }

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
--- change, a reconnect included; the light proxy only hears its online state here.
--- @param connected boolean
--- @param status string
local function setConnected(connected, status)
  setStatus(status)
  if connected == gConnected then
    return
  end
  gConnected = connected
  values:update("Connected", connected, "BOOL")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = connected }, "NOTIFY")
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
end

local function onOnline()
  -- Connected waits for the first state, which carries the MAC to check.
  setStatus("Connecting")
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
  gInitialized = true
  connect()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  client:stop()
  CancelTimer("UpdateCheck")
  CancelTimer("LogMode")
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

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

--- Forget the remembered controller and connect again, taking whichever controller answers.
function EC.Reset_Driver(params)
  log:trace("EC.Reset_Driver(%s)", params)
  if Select(params, "Are You Sure?") ~= "Yes" then
    return
  end
  log:print("Resetting driver to initial state")
  persist:delete(MAC_KEY)
  device = Device.new()
  for _, item in ipairs(DEVICE_INFO) do
    UpdateProperty(item[1], "N/A")
  end
  connect()
end

-- ─── Light proxy (RFP dispatch) ────────────────────────────────────────────

--- Light commands are taken by a later layer; this one only reports the connection.
RFP[PROXY_BINDING] = function(idBinding, strCommand, tParams)
  log:debug("Light command %s on binding %s not handled yet", strCommand, idBinding)
end
