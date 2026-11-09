-- A light reporting a non-finite brightness must fall back, not push the NaN to
-- the LIGHT_V2 proxy.
--
-- Run from the driver root:
--   make test
--
-- tonumber(x) or 1.0 does not fall back for a NaN, and
-- math.max(0, math.min(100, nan)) returns the NaN rather than clamping it, so a
-- NaN would reach the proxy and, since nan ~= anything, be told again at every
-- report. The light model's own arithmetic runs here, through light.state.

local T = require("testlib")

require("c4_shim")
require("lib.utils")

function C4:GetProjectProperty()
  return "000000"
end

local NAN = 0 / 0
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local BRIGHTNESS = 3

local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local s = fh:read("*a")
  fh:close()
  return s
end

local moduleSrc = readFile(root .. "/src/wled/light.lua")

--- Load the light model afresh, from `src` when given, and drive one report.
--- @param state table
--- @param src string|nil
--- @return number|nil level The last brightness told to the proxy.
local function drive(state, src)
  T.unload("^wled%.light$")
  if src then
    package.preload["wled.light"] = function()
      return assert(loadstring(src, "wled.light"))()
    end
  end
  local light = require("wled.light")
  package.preload["wled.light"] = nil
  local levels = {}
  local send = SendToProxy
  SendToProxy = function(_idBinding, strCommand, tParams)
    if strCommand == "LIGHT_BRIGHTNESS_CHANGED" then
      levels[#levels + 1] = tParams.LIGHT_BRIGHTNESS_CURRENT
    end
  end
  light.attach({ send = function() end })
  light.state({ supported_color_modes = { BRIGHTNESS } }, state)
  SendToProxy = send
  return levels[#levels]
end

--------------------------------------------------------------------------------
T.section("a non-finite brightness falls back instead of reaching the proxy")
--------------------------------------------------------------------------------

local nanLevel = drive({ state = true, brightness = NAN })
T.check("a NaN brightness is not pushed", nanLevel == nanLevel, "pushed " .. tostring(nanLevel))
T.eq("it falls back to full brightness", nanLevel, 100)
T.eq("infinity falls back the same way", drive({ state = true, brightness = math.huge }), 100)

--------------------------------------------------------------------------------
T.section("a finite brightness is still reported as measured")
--------------------------------------------------------------------------------

T.eq("42 percent", drive({ state = true, brightness = 0.42 }), 42)
T.eq("full", drive({ state = true, brightness = 1.0 }), 100)
T.eq("rounds to the nearest percent", drive({ state = true, brightness = 0.005 }), 1)
T.eq("an on light never reports zero", drive({ state = true, brightness = 0 }), 1)
T.eq("an absent brightness assumes full", drive({ state = true }), 100)
T.eq("an off light reports zero", drive({ state = false, brightness = 0.42 }), 0)

--------------------------------------------------------------------------------
T.section("reverting the fix puts the NaN case back")
--------------------------------------------------------------------------------

local revertedSrc, swaps =
  moduleSrc:gsub('tofinite%(Select%(state, "brightness"%)%)', 'tonumber(Select(state, "brightness"))')
T.eq("the revert replaced exactly one call", swaps, 1)
local revertedLevel = drive({ state = true, brightness = NAN }, revertedSrc)
T.check("the reverted source pushes a NaN", revertedLevel ~= revertedLevel, "pushed " .. tostring(revertedLevel))
T.eq("and still agrees on a finite brightness", drive({ state = true, brightness = 0.42 }, revertedSrc), 42)

T.unload("^wled%.light$")
T.finish()
