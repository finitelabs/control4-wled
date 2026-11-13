--- The light conformance rigs for WLED's two light drivers (test/light_rig.lua's interface). Each loads
--- its driver as it ships, the OSS build, and fakes only its transport: the WLED driver talks to the Lua
--- WLED fake (test/wled_fixtures.lua) over HTTP and the WebSocket; a WLED Segment light talks to a fake
--- WLED driver on its binding, which runs the same fake controller and tells the light its segment as
--- the real one does (src/wled/segment.lua).

local Rig = require("light_rig")
local F = require("c4_fixtures")

-- The fake brings a clock of its own when first required; each case's virtual clock drives the driver
-- and the fake alike instead.
local shimGetTime = C4.GetTime
local W = require("wled_fixtures")
C4.GetTime = shimGetTime

local Color = require("lib.light.color")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local ROOT = HERE .. "/.."

package.loaded["lib.http"] = W.http

--- The WLED Segment light's binding to the WLED driver.
local CONTROLLER = 5002

local CAP_RGB, CAP_WHITE, CAP_CCT = 1, 2, 4

local function has(lc, bit)
  return math.floor((tonumber(lc) or 0) / bit) % 2 == 1
end

--- The fake's segment that stands for the light: the main one, else the first.
--- @param state table
--- @param id integer|nil A segment light's own segment.
--- @return table
local function segmentOf(state, id)
  local want = id or tonumber(state.mainseg) or 0
  for _, seg in ipairs(state.seg) do
    if tonumber(seg.id) == want then
      return seg
    end
  end
  return state.seg[1]
end

--- A color the strip shows, as the rig reads it: a full color by its xy, a white by its Kelvin.
--- @param seg table
--- @param lc integer
--- @return LightColor|nil
local function colorOf(seg, lc)
  local col = seg.col and seg.col[1] or {}
  local r, g, b, w = tonumber(col[1]) or 0, tonumber(col[2]) or 0, tonumber(col[3]) or 0, tonumber(col[4]) or 0
  local warm, cool = tonumber(Properties["Warm White (K)"]) or 2700, tonumber(Properties["Cool White (K)"]) or 6500
  local kelvin = has(lc, CAP_CCT) and (warm + (cool - warm) * (tonumber(seg.cct) or 127) / 255) or cool
  local m = math.max(r, g, b)
  if
    has(lc, CAP_RGB)
    and m > 0
    and m >= w
    and not (has(lc, CAP_CCT) and not has(lc, CAP_WHITE) and r == g and g == b)
  then
    local x, y = Color.rgbToXY(r / 255, g / 255, b / 255)
    return { x = x, y = y, mode = "xy" }
  end
  if has(lc, CAP_WHITE) or has(lc, CAP_CCT) then
    return { kelvin = math.floor(kelvin + 0.5) }
  end
  return nil
end

--- A color as the bytes another hand sets on the strip.
--- @param color LightColor
--- @param lc integer
--- @return integer[] col, integer|nil cct
local function bytesOf(color, lc)
  local warm, cool = tonumber(Properties["Warm White (K)"]) or 2700, tonumber(Properties["Cool White (K)"]) or 6500
  local white = has(lc, CAP_WHITE)
  if color.kelvin or not has(lc, CAP_RGB) then
    local k = color.kelvin or Color.kelvin(color.x, color.y) or cool
    local cct = math.floor(math.max(0, math.min(255, (k - warm) / (cool - warm) * 255)) + 0.5)
    return white and { 0, 0, 0, 255 } or { 255, 255, 255 }, cct
  end
  local r, g, b = Color.xyToRGB(color.x, color.y)
  local col = { math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5) }
  if white then
    col[4] = 0
  end
  return col, nil
end

--- Load a driver afresh on the case's clock: its modules, the fake's network, and both inits.
--- @param folder string
local function loadDriver(folder)
  for name in pairs(package.loaded) do
    if name:match("^wled%.") or name == "drivers-common-public.module.websocket" then
      package.loaded[name] = nil
    end
  end
  for _, key in ipairs({ "WledControllerMac", "WledShown", "WledSegmentRecords" }) do
    require("lib.persist"):delete(key)
  end
  F.dofileBuild(ROOT .. "/drivers/" .. folder .. "/driver.lua", "oss")
  OnDriverInit()
  ShimLateInit()
end

--- A rig for the WLED driver over one fake controller.
--- @param profile string A folder under test/fixtures/wled.
--- @return LightRig
local function controllerRig(profile)
  --- @type LightRig
  local rig = {
    name = "wled over " .. profile,
    -- A lost controller is retried with a backoff that reaches 30 s.
    settleMs = 40000,
  }
  function rig.load(h, state)
    W.reset()
    local fake = W.Fake.new(profile, { ip = "192.0.2.80" })
    local lc = fake.si.info.leds.lc
    Properties["IP Address"] = fake.ip
    local function apply(values, push)
      local st = fake.si.state
      if values.on ~= nil then
        st.on = values.on
        if values.on then
          for _, seg in ipairs(st.seg) do
            seg.on = true
          end
        end
      end
      if values.level then
        st.bri = math.max(1, math.floor(values.level * 255 + 0.5))
      end
      if values.color then
        local col, cct = bytesOf(values.color, lc)
        for _, seg in ipairs(st.seg) do
          seg.col[1] = col
          seg.cct = cct or seg.cct
        end
      end
      if push then
        fake:change({})
      end
    end
    if state then
      apply(state, false)
    end
    loadDriver("wled")
    --- @type LightRigDevice
    local device = {}
    -- What the strip shows now, part way through a fade too (the fake's output model).
    function device.state()
      local st = fake.si.state
      local out = fake:output()
      local anyOn = false
      for _, seg in ipairs(st.seg) do
        anyOn = anyOn or seg.on ~= false
      end
      local main = segmentOf(st)
      local bri = out.bri >= 0.5 and anyOn and out.bri or 0
      return {
        on = bri > 0,
        level = bri > 0 and bri / 255 or (tonumber(st.bri) or 0) / 255,
        color = colorOf({ col = { out.seg[main.id].col }, cct = out.seg[main.id].cct }, lc),
      }
    end
    -- WLED pushes its whole state on a change, so a quiet change is pushed all the same.
    function device.set(values, _quiet)
      apply(values, true)
    end
    function device.drop()
      fake.reachable = false
      fake:drop()
    end
    function device.back()
      fake.reachable = true
    end
    return device
  end
  return rig
end

--- A rig for a WLED Segment light over segment `id` of one fake controller, behind a fake WLED driver.
--- @param profile string
--- @param id integer
--- @return LightRig
local function segmentRig(profile, id)
  --- @type LightRig
  local rig = { name = "wled_segment over " .. profile .. " segment " .. id, settleMs = 12000 }
  function rig.load(h, state)
    W.reset()
    local fake = W.Fake.new(profile)
    local lc = fake.si.info.leds.lc
    local Device = require("wled.device")
    local Segment = require("wled.segment")
    local model = Device:new()
    local up = true
    local function seg()
      return segmentOf(fake.si.state, id)
    end
    --- The fake WLED driver tells the light its segment, a moment after the controller changed.
    local function report()
      h.clock.at(5, function()
        if up then
          model:update(fake.si.state, fake.si.info)
          RFP.UPDATE_STATE(CONTROLLER, "UPDATE_STATE", { segment = SerializeSafe(Segment.payload(model, id)) })
        end
      end)
    end
    local function apply(values, push)
      local s = seg()
      if values.on ~= nil then
        s.on = values.on
        if values.on then
          fake.si.state.on = true
        end
      end
      if values.level then
        s.bri = math.max(1, math.floor(values.level * 255 + 0.5))
      end
      if values.color then
        local col, cct = bytesOf(values.color, lc)
        s.col[1] = col
        s.cct = cct or s.cct
      end
      if push then
        report()
      end
    end
    if state then
      apply(state, false)
    end
    local prior = C4.SendToProxy
    C4.SendToProxy = function(self, binding, command, params, ...)
      if binding ~= CONTROLLER then
        return prior(self, binding, command, params, ...)
      end
      if command == "ENTITY_COMMAND" and up then
        -- The WLED driver decides each command against its model, which takes it at once.
        local json = Segment.forward(DeserializeSafe(params.body), model)
        Segment.note(json, model)
        fake:apply(json)
        report()
      elseif command == "REFRESH_STATE" then
        report()
      end
    end
    C4:Unbind(C4:GetDeviceID(), CONTROLLER)
    C4:Bind(700, 6000, C4:GetDeviceID(), CONTROLLER, "WLED_SEGMENT")
    model:update(fake.si.state, fake.si.info)
    loadDriver("wled_segment")
    --- @type LightRigDevice
    local device = {}
    -- What the segment shows now: its own level, dimmed as far as the master's output has faded.
    function device.state()
      local s = seg()
      local out = fake:output()
      local own = out.seg[s.id]
      local masterBri = math.max(1, tonumber(fake.si.state.bri) or 255)
      local level = own.bri / 255 * math.min(1, out.bri / masterBri)
      local lit = out.bri >= 0.5 and own.bri >= 0.5
      return {
        on = lit,
        level = lit and level or (tonumber(s.bri) or 255) / 255,
        color = colorOf({ col = { own.col }, cct = own.cct }, lc),
      }
    end
    function device.set(values, _quiet)
      apply(values, true)
    end
    function device.drop()
      up = false
      RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", {})
    end
    function device.back()
      up = true
      report()
    end
    function device.suspend()
      up = false
      RFP.UPDATE_DISCONNECT(CONTROLLER, "UPDATE_DISCONNECT", { suspended = "true" })
    end
    function device.resume()
      up = true
      report()
    end
    return device
  end
  return rig
end

--- @type LightRigFile
return {
  version = Rig.VERSION,
  rigs = {
    wled = {
      controllerRig("dig2go-rgbw-16"),
      controllerRig("esp32-cct-16"),
      controllerRig("esp32-rgbw-015"),
    },
    wled_segment = {
      segmentRig("esp32-rgbw-pwm-16", 1),
    },
  },
}
