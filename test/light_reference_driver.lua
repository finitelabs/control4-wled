--- A test driver around src/wled/light.lua whose device eases its fades and
--- answers on a binding of its own, as the device the light model was first
--- written for does. The light acceptance suites drive it through that
--- binding's UPDATE_STATE, UPDATE_DISCONNECT and binding change, and read the
--- commands it sends there as ENTITY_COMMAND.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local light = require("wled.light")

local PROXY_BINDING = 5001
local DEVICE_BINDING = 5002

light.attach({
  send = function(cmd)
    cmd.preOn = nil
    SendToProxy(DEVICE_BINDING, "ENTITY_COMMAND", { body = SerializeSafe(cmd) })
  end,
  -- The WLED light's Extras, which drivers/wled/driver.xml lists too.
  capabilities = { has_extras = true },
})

local function updateStatus(status, connected)
  UpdateProperty("Driver Status", status)
  values:update("Connected", connected, "BOOL")
end

function OnDriverInit()
  C4:AllowExecute(true)
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  values:restoreValues()
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  updateStatus("Disconnected", false)
  SendToProxy(DEVICE_BINDING, "REFRESH_STATE", {}, "NOTIFY")
  light.lateInit()
end

function RFP.UPDATE_STATE(idBinding, _strCommand, tParams)
  if idBinding ~= DEVICE_BINDING then
    return
  end
  local wasOnline = light.isOnline()
  light.state(DeserializeSafe(Select(tParams, "entity")), DeserializeSafe(Select(tParams, "state")))
  if not wasOnline and light.isOnline() then
    updateStatus("Connected", true)
  end
end

function RFP.UPDATE_DISCONNECT(idBinding, _strCommand, tParams)
  if idBinding ~= DEVICE_BINDING then
    return
  end
  updateStatus("Disconnected", false)
  light.disconnect(toboolean(Select(tParams, "suspended")))
end

OBC[DEVICE_BINDING] = function(_idBinding, _strClass, isBound)
  if not isBound then
    updateStatus("Disconnected", false)
  end
  light.reset(isBound)
end

return PROXY_BINDING
