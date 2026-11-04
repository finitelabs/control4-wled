-- WLED segment.
--
-- One segment of a WLED controller as its own Control4 light. It binds to the WLED driver, which
-- keeps the one connection to the controller: what the controller reports for this segment arrives
-- over that binding, and this light's commands go back over it as what they mean for its segment;
-- the WLED driver decides what the controller's master does (src/wled/segment.lua). The light is
-- the light_v2 proxy on binding 5001, run by the light model (src/wled/light.lua) through the
-- WLED adapter (src/wled/light_wled.lua).

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local updateSettings = require("lib.update-settings")
local supportCode = require("lib.support-code")
local diagnostics = require("lib.diagnostics")
--#endif

local Device = require("wled.device")
local Segment = require("wled.segment")
local light = require("wled.light")
local LightAdapter = require("wled.light_wled")

--- The binding to the WLED driver.
local CONTROLLER_BINDING = 5002

--- Installer white points, the ends of WLED's CCT range.
local DEFAULT_WARM, DEFAULT_COOL = 2700, 6500

--- Set true once OnDriverLateInit finishes; guards the property handlers from
--- firing while Composer replays the initial property values.
local gInitialized = false

--- What the WLED driver last told this light about its segment; nil while it is not there.
--- @type table|nil
local gPayload = nil

--- Show the driver's status, and whether the segment is there, to programming.
--- @param status string
--- @param connected boolean
local function setStatus(status, connected)
  UpdateProperty("Driver Status", status)
  values:update("Connected", connected, "BOOL")
end

local wledLight = LightAdapter:new({
  device = Segment.view(nil),
  extras = false,
  send = function(json)
    if not gPayload then
      log:warn("Segment command not sent: the segment is not there")
      return
    end
    SendToProxy(CONTROLLER_BINDING, "ENTITY_COMMAND", {
      body = SerializeSafe(Segment.intent(json, gPayload.segment.id)),
      segment = gPayload.segment.id,
    })
  end,
  warm = function()
    return tonumber(Properties["Warm White (K)"]) or DEFAULT_WARM
  end,
  cool = function()
    return tonumber(Properties["Cool White (K)"]) or DEFAULT_COOL
  end,
})
light.attach(wledLight:adapter())

--- The Segment property: the segment's name, LED range and what its LEDs light.
--- @param seg table
--- @return string
local function describe(seg)
  local name = type(seg.n) == "string" and seg.n ~= "" and seg.n or ("Segment " .. tostring(seg.id))
  return string.format(
    "%s: LEDs %d-%d, %s",
    name,
    tonumber(seg.start) or 0,
    (tonumber(seg.stop) or 0) - 1,
    Device.capabilityLabel(seg.lc)
  )
end

--- Ask the WLED driver for the segment's state.
local function refresh()
  SendToProxy(CONTROLLER_BINDING, "REFRESH_STATE", {}, "NOTIFY")
end

-- ─── From the WLED driver (RFP dispatch) ───────────────────────────────────

function RFP.UPDATE_STATE(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_STATE(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= CONTROLLER_BINDING then
    return
  end
  local payload = DeserializeSafe(Select(tParams, "segment"))
  if type(payload) ~= "table" or type(payload.segment) ~= "table" or type(payload.master) ~= "table" then
    log:error("Segment state not understood: %s", tParams)
    return
  end
  gPayload = payload
  wledLight.device = Segment.view(payload)
  UpdateProperty("Segment", describe(payload.segment))
  setStatus("Connected", true)
  light.state(wledLight:entity(), wledLight:state())
end

function RFP.UPDATE_DISCONNECT(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_DISCONNECT(%s, %s, %s)", idBinding, strCommand, tParams)
  if idBinding ~= CONTROLLER_BINDING then
    return
  end
  gPayload = nil
  wledLight.device = Segment.view(nil)
  setStatus(Select(tParams, "status") or "Not connected to the WLED controller", false)
  if light.isOnline() then
    -- Suspended: the WLED driver dropped the connection itself, and the segment keeps its level.
    light.disconnect(toboolean(Select(tParams, "suspended")))
  end
end

OBC[CONTROLLER_BINDING] = function(idBinding, strClass, isBound)
  log:trace("OBC[%s](%s, %s)", idBinding, strClass, isBound)
  gPayload = nil
  wledLight.device = Segment.view(nil)
  light.reset(isBound)
  if isBound then
    setStatus("Connecting", false)
    refresh()
  else
    setStatus("Bind this light to a WLED driver's segment connection", false)
  end
end

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
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
      --#ifdef DRIVERCENTRAL
      diagnostics:captureError(tostring(err), nil, "WLEDSegment.OnPropertyChanged")
      --#endif
    end
  end

  gInitialized = true
  light.lateInit()
  if (tointeger(C4:GetBoundProviderDevice(C4:GetDeviceID(), CONTROLLER_BINDING)) or 0) == 0 then
    setStatus("Bind this light to a WLED driver's segment connection", false)
    return
  end
  -- Shown off until the WLED driver tells it the segment; the proxy keeps its last level meanwhile.
  setStatus("Connecting", false)
  refresh()
end

--#ifdef DRIVERCENTRAL
OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
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

--#ifdef DRIVERCENTRAL
--- An update setting changed on another item; this light keeps only those it has.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates(%s)", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

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
