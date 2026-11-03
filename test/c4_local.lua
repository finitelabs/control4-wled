--- What this driver's suites need from Control4 that the template's c4_shim.lua does not model.
--- Requiring it installs the methods on C4 and returns the helpers.
---
--- Color conversions, which the shim has none of: CIE 1931 xy to and from HSV through sRGB (D65),
--- Kelvin to xy on the Planckian locus (Kim et al.'s cubic fit, 1667 K to 25000 K) and xy to Kelvin
--- (McCamy's formula), installed as C4:ColorXYtoHSV, C4:ColorHSVtoXY, C4:ColorCCTtoXY and
--- C4:ColorXYtoCCT.
---
--- The global tohex, which the vendored WebSocket module calls for frames over 125 bytes.
---
--- Director's side of a driver reload that ShimUpdateDriver and ShimRestartDirector leave out: the
--- new load's fresh Lua state, and the dynamic bindings Director drops.
---
--- Usage:
---   require("c4_local")

require("c4_shim")

local T = require("testlib")

local M = {}

local function gamma(c)
  return c <= 0.0031308 and 12.92 * c or 1.055 * c ^ (1 / 2.4) - 0.055
end

local function linear(c)
  return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

local function rgbToHsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  return (h + 360) % 360, mx > 0 and d / mx * 100 or 0, mx * 100
end

local function hsvToRgb(h, s, v)
  s, v = s / 100, v / 100
  local c = v * s
  local hh = (h / 60) % 6
  local x = c * (1 - math.abs(hh % 2 - 1))
  local r, g, b
  if hh < 1 then
    r, g, b = c, x, 0
  elseif hh < 2 then
    r, g, b = x, c, 0
  elseif hh < 3 then
    r, g, b = 0, c, x
  elseif hh < 4 then
    r, g, b = 0, x, c
  elseif hh < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  local m = v - c
  return r + m, g + m, b + m
end

function M.xyToHsv(x, y)
  local Y = 1
  local X, Z = Y / y * x, Y / y * (1 - x - y)
  local r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
  local g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
  local b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z
  r, g, b = math.max(0, r), math.max(0, g), math.max(0, b)
  local mx = math.max(r, g, b)
  if mx <= 0 then
    return 0, 0, 0
  end
  local h, s = rgbToHsv(gamma(r / mx), gamma(g / mx), gamma(b / mx))
  return h, s, 100
end

function M.hsvToXy(h, s)
  local r, g, b = hsvToRgb(h, s, 100)
  r, g, b = linear(r), linear(g), linear(b)
  local X = 0.4124 * r + 0.3576 * g + 0.1805 * b
  local Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  local Z = 0.0193 * r + 0.1192 * g + 0.9505 * b
  local sum = X + Y + Z
  if sum <= 0 then
    return 0.3127, 0.3290
  end
  return X / sum, Y / sum
end

function M.cctToXy(k)
  k = math.max(1667, math.min(25000, k))
  local x
  if k <= 4000 then
    x = -0.2661239e9 / k ^ 3 - 0.2343589e6 / k ^ 2 + 0.8776956e3 / k + 0.179910
  else
    x = -3.0258469e9 / k ^ 3 + 2.1070379e6 / k ^ 2 + 0.2226347e3 / k + 0.240390
  end
  local y
  if k <= 2222 then
    y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
  elseif k <= 4000 then
    y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
  else
    y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483
  end
  return x, y
end

function M.xyToCct(x, y)
  local n = (x - 0.3320) / (0.1858 - y)
  return math.floor(449 * n ^ 3 + 3525 * n ^ 2 + 6823.3 * n + 5520.33 + 0.5)
end

function C4:ColorXYtoHSV(x, y)
  return M.xyToHsv(x, y)
end

function C4:ColorHSVtoXY(h, s)
  return M.hsvToXy(h, s)
end

function C4:ColorCCTtoXY(k)
  return M.cctToXy(k)
end

function C4:ColorXYtoCCT(x, y)
  return M.xyToCct(x, y)
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
