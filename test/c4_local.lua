--- What this driver's suites need from Control4 that the template's c4_shim.lua does not model.
--- Requiring it installs the methods on C4 and returns the helpers.
---
--- The global tohex, which the vendored WebSocket module calls for frames over 125 bytes.
---
--- A C4:GetProjectProperty stub, which reads every project property as 000000.
---
--- Director's side of a driver reload that ShimUpdateDriver and ShimRestartDirector leave out: the
--- new load's fresh Lua state, and the dynamic bindings Director drops.
---
--- Usage:
---   require("c4_local")

require("c4_shim")

local T = require("testlib")

local M = {}

function C4:GetProjectProperty()
  return "000000"
end

-- Hex string to bytes, as Control4's tohex.
tohex = tohex
  or function(s)
    return (tostring(s):gsub("%x%x", function(cc)
      return string.char(tonumber(cc, 16))
    end))
  end

--- The dispatch tables drivers-common-public's handlers create, plus GCPL from lib.utils.
local DISPATCH = { "EC", "GCPL", "OBC", "OCS", "ODE", "OPC", "OSE", "OVC", "OWVC", "RFN", "RFP", "TC", "UIR" }

--- A driver reload starts a fresh Lua state. Every lib.* module and each module `patterns` names is
--- unloaded, so the next require rebuilds it from what storage holds rather than from memory.
--- Every handler the old instance put in a dispatch table goes, the ones its load defines and the
--- ones it added at run time (a binding's RFP and OBC, a conditional's TC, a variable's OVC), and
--- so does the property state the handlers module keeps per load (PropertyConfig, PropertyLists).
--- A module a test stands in for, such as lib.http, is the caller's to put back.
--- @param patterns string[]|nil Lua patterns for the driver's own modules.
function M.freshLuaState(patterns)
  T.unload("^lib%.", unpack(patterns or {}))
  for _, name in ipairs(DISPATCH) do
    local handlers = _G[name]
    if type(handlers) == "table" then
      for key in pairs(handlers) do
        handlers[key] = nil
      end
      if name ~= "GCPL" then
        handlers.suppressDebug = {}
      end
    end
  end
  PropertyConfig, PropertyLists = nil, nil
end

--- Director at a driver reload, which neither ShimUpdateDriver nor ShimRestartDirector models:
--- the driver's dynamic bindings are gone until its new load adds them again, while the
--- connections made to them wait and come back when it does. Cleared in place, as the shim keeps
--- the table a test holds from ShimDynamicBindings live.
function M.dropDynamicBindings()
  local dynamic = ShimDynamicBindings()
  for id in pairs(dynamic) do
    dynamic[id] = nil
  end
end

return M
