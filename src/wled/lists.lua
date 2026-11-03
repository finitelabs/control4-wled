--- The controller's own effect, palette, preset and playlist lists, as programming offers them.
---
--- Read over the client when the driver connects and whenever the controller's counters say a
--- list changed. Ids are kept as the controller numbers them: an effect or palette list skips
--- WLED's placeholders without renumbering, and a preset or playlist is offered as "Name (id)"
--- so programming finds it by id after a rename.

require("lib.utils")
local log = require("lib.logging")
local deferred = require("deferred")
local Device = require("wled.device")

--- Placeholder names WLED keeps so effect ids stay aligned in a build that leaves an effect out.
local PLACEHOLDER = { [""] = true, ["-"] = true, ["RSVD"] = true }

--- @class WledListEntry
--- @field id integer The controller's id for the entry.
--- @field name string The name the controller gives it.

--- @class WledLists
--- @field get fun(path: string): Deferred Fetches a path from the controller (the client's get).
--- @field device WledDevice The controller's model, for its version, custom palette count and matrix.
--- @field effects WledListEntry[]|nil Effects in id order, nil until read.
--- @field palettes WledListEntry[]|nil Palettes, built-in first, nil until read.
--- @field presets WledListEntry[]|nil Presets that are not playlists, nil until read.
--- @field playlists WledListEntry[]|nil Playlists, nil until read.
--- @field fxdata table|nil Each effect's metadata from /json/fxdata, indexed by id + 1; nil when not read.
--- @field version integer Bumped each time a list read finds a change.
--- @field gen integer Bumped by cancel and clear, so a read that started before is dropped.
local Lists = {}
Lists.__index = Lists

--- Creates the lists with nothing read yet.
--- @param opts {get: fun(path: string): Deferred, device: WledDevice} The client's get and the controller's model.
--- @return WledLists lists Lists that refresh fills.
function Lists:new(opts)
  local instance = setmetatable({}, self)
  instance.get = opts.get
  instance.device = opts.device
  instance.gen = 0
  instance.version = 0
  return instance
end

--- Drop a read under way, as at a reconnect; the lists read so far stay.
function Lists:cancel()
  self.gen = self.gen + 1
end

--- Forget every list, as at a reset; a read under way is dropped.
function Lists:clear()
  self:cancel()
  self.effects, self.palettes, self.presets, self.playlists, self.fxdata = nil, nil, nil, nil, nil
  self.version = self.version + 1
end

--- @param what string
--- @param err any
local function warnNotRead(what, err)
  log:warn("WLED %s list not read: %s", what, type(err) == "table" and (err.error or "failed") or tostring(err))
end

--- Whether an effect's metadata marks it 2D only: flag 2 without flag 1. Missing flags mean 1D.
--- @param fxdata any
--- @return boolean
local function twoDimensionalOnly(fxdata)
  if type(fxdata) ~= "string" or fxdata == "" then
    return false
  end
  local parts = {}
  for part in (fxdata .. ";"):gmatch("([^;]*);") do
    parts[#parts + 1] = part
  end
  local flags = parts[4]
  if flags == nil or flags == "" then
    return false
  end
  return flags:find("2", 1, true) ~= nil and flags:find("1", 1, true) == nil
end

--- The effect list: placeholders out, and 2D-only effects out on a controller without a matrix.
--- @param names any The controller's /json/eff, indexed by effect id.
--- @param fxdata any The controller's /json/fxdata, or nil when it could not be read.
--- @param matrix boolean Whether the controller has a 2D matrix.
--- @return WledListEntry[] effects The effects to offer, in id order.
function Lists.effectList(names, fxdata, matrix)
  local out = {}
  for i, name in ipairs(type(names) == "table" and names or {}) do
    local id = i - 1
    if type(name) == "string" and not PLACEHOLDER[name] then
      local meta = type(fxdata) == "table" and fxdata[i] or nil
      if matrix or not twoDimensionalOnly(meta) then
        out[#out + 1] = { id = id, name = name }
      end
    end
  end
  return out
end

--- The palette list: built-in palettes by id, then custom and usermod palettes at the ids the
--- controller's firmware gives them.
--- @param names any The controller's /json/pal (built-in palettes only), indexed by id.
--- @param info table|nil The controller's info, for the custom palette count and usermod names.
--- @param v16 boolean Whether the controller runs 16.x, which moved custom palette ids.
--- @return WledListEntry[] palettes The palettes to offer, built-in first.
function Lists.paletteList(names, info, v16)
  local out = {}
  for i, name in ipairs(type(names) == "table" and names or {}) do
    if type(name) == "string" and not PLACEHOLDER[name] then
      out[#out + 1] = { id = i - 1, name = name }
    end
  end
  info = type(info) == "table" and info or {}
  local custom = tointeger(info.cpalcount) or 0
  -- Custom palettes count down from 200 on 16.x and from 255 on 0.15.
  local top = v16 and 200 or 255
  for k = 0, custom - 1 do
    out[#out + 1] = { id = top - k, name = "Custom Palette " .. (k + 1) }
  end
  if v16 and type(info.umpalnames) == "table" then
    for k, name in ipairs(info.umpalnames) do
      if type(name) == "string" and name ~= "" then
        out[#out + 1] = { id = 255 - (k - 1), name = name }
      end
    end
  end
  return out
end

--- Presets and playlists from /presets.json, by id: an entry with a playlist object is a playlist.
--- @param file any The controller's /presets.json.
--- @return WledListEntry[] presets Presets that are not playlists, by id.
--- @return WledListEntry[] playlists Playlists, by id.
function Lists.presetLists(file)
  local presets, playlists = {}, {}
  for key, entry in pairs(type(file) == "table" and file or {}) do
    local id = tonumber(key)
    if id and id >= 1 and id <= 250 and type(entry) == "table" and next(entry) ~= nil then
      id = math.floor(id)
      local name = type(entry.n) == "string" and entry.n ~= "" and entry.n or ("Preset " .. id)
      local list = type(entry.playlist) == "table" and playlists or presets
      list[#list + 1] = { id = id, name = name }
    end
  end
  local byId = function(a, b)
    return a.id < b.id
  end
  table.sort(presets, byId)
  table.sort(playlists, byId)
  return presets, playlists
end

--- Whether two lists, or two fxdata arrays, hold the same entries.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
local function same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if type(x) == "table" and type(y) == "table" then
      if x.id ~= y.id or x.name ~= y.name then
        return false
      end
    elseif x ~= y then
      return false
    end
  end
  return true
end

--- Read the lists the change table names from the controller, one request at a time.
--- @param what {effects: boolean|nil, palettes: boolean|nil, presets: boolean|nil} The lists to read.
--- @return Deferred done Resolves once every requested list is read or has failed.
function Lists:refresh(what)
  local gen = self.gen
  local chain = deferred.new():resolve(nil)
  local function step(fn)
    chain = chain:next(function()
      if self.gen == gen then
        return fn()
      end
    end, function()
      if self.gen == gen then
        return fn()
      end
    end)
  end
  if what.effects then
    step(function()
      local names
      return self
        .get("/json/eff")
        :next(function(value)
          names = value
          -- The metadata only hides 2D-only effects; a controller that cannot send it keeps them.
          return self.get("/json/fxdata"):next(function(meta)
            return meta
          end, function()
            return nil
          end)
        end)
        :next(function(meta)
          if self.gen == gen and type(names) == "table" then
            local info = self.device.info or {}
            local matrix = type(info.leds) == "table" and type(info.leds.matrix) == "table"
            local effects, fxdata = Lists.effectList(names, meta, matrix), type(meta) == "table" and meta or nil
            if not same(effects, self.effects) or not same(fxdata, self.fxdata) then
              self.version = self.version + 1
            end
            self.effects, self.fxdata = effects, fxdata
          end
        end, function(err)
          if self.gen == gen then
            warnNotRead("effect", err)
          end
        end)
    end)
  end
  if what.palettes then
    step(function()
      return self.get("/json/pal"):next(function(names)
        if self.gen == gen and type(names) == "table" then
          local palettes = Lists.paletteList(names, self.device.info, Device.isV16(self.device.ver))
          if not same(palettes, self.palettes) then
            self.version = self.version + 1
          end
          self.palettes = palettes
        end
      end, function(err)
        if self.gen == gen then
          warnNotRead("palette", err)
        end
      end)
    end)
  end
  if what.presets then
    step(function()
      return self.get("/presets.json"):next(function(file)
        if self.gen == gen and type(file) == "table" then
          local presets, playlists = Lists.presetLists(file)
          if not same(presets, self.presets) or not same(playlists, self.playlists) then
            self.version = self.version + 1
          end
          self.presets, self.playlists = presets, playlists
        end
      end, function(err)
        if self.gen == gen then
          warnNotRead("preset", err)
        end
      end)
    end)
  end
  return chain
end

--- @param list WledListEntry[]|nil
--- @param id any
--- @return string|nil
local function nameOf(list, id)
  id = tonumber(id)
  for _, e in ipairs(list or {}) do
    if e.id == id then
      return e.name
    end
  end
  return nil
end

--- @param list WledListEntry[]|nil
--- @return string[]
local function names(list)
  local out = {}
  for _, e in ipairs(list or {}) do
    out[#out + 1] = e.name
  end
  return out
end

--- A list entry by name, else by id given as a number or as "Name (id)".
--- @param list WledListEntry[]|nil
--- @param value any
--- @return integer|nil
local function idOf(list, value)
  if value == nil then
    return nil
  end
  local text = tostring(value)
  for _, e in ipairs(list or {}) do
    if e.name == text then
      return e.id
    end
  end
  local id = tonumber(text) or tonumber(text:match("%((%d+)%)%s*$"))
  if id and nameOf(list, id) then
    return math.floor(id)
  end
  return nil
end

--- @param list WledListEntry[]|nil
--- @return string[]
local function labeled(list)
  local out = {}
  for _, e in ipairs(list or {}) do
    out[#out + 1] = string.format("%s (%d)", e.name, e.id)
  end
  return out
end

--- The effect names, as programming offers them.
--- @return string[] names Effect names in id order.
function Lists:effectNames()
  return names(self.effects)
end

--- An effect's name by id.
--- @param id any The effect id, as a number or a string.
--- @return string|nil name Nil when the list has no such effect.
function Lists:effectName(id)
  return nameOf(self.effects, id)
end

--- An effect's id by name, else by id.
--- @param value any An effect name, or its id.
--- @return integer|nil id Nil when the list has no such effect.
function Lists:effectId(value)
  return idOf(self.effects, value)
end

--- An entry's id when the list has it, from an id given as a number or a string. Unlike the
--- lookups by name, a preset named "2" never stands for preset 2.
--- @param list WledListEntry[]|nil The list to look in; nil before it is read.
--- @param value any An id, as a number or a string.
--- @return integer|nil id Nil when the list has no such id.
function Lists.byId(list, value)
  local id = tonumber(value)
  if id and nameOf(list, id) then
    return math.floor(id)
  end
  return nil
end

--- An effect's metadata, the string WLED's page reads its controls from.
--- @param id any The effect id, as a number or a string.
--- @return string|nil meta Nil when the metadata was not read or has no entry for the id.
function Lists:effectMeta(id)
  id = tonumber(id)
  local meta = id and self.fxdata and self.fxdata[id + 1]
  return type(meta) == "string" and meta or nil
end

--- The palette names, as programming offers them.
--- @return string[] names Palette names, built-in first.
function Lists:paletteNames()
  return names(self.palettes)
end

--- A palette's name by id.
--- @param id any The palette id, as a number or a string.
--- @return string|nil name Nil when the list has no such palette.
function Lists:paletteName(id)
  return nameOf(self.palettes, id)
end

--- A palette's id by name, else by id.
--- @param value any A palette name, or its id.
--- @return integer|nil id Nil when the list has no such palette.
function Lists:paletteId(value)
  return idOf(self.palettes, value)
end

--- Presets as programming offers them, "Name (id)".
--- @return string[] choices One per preset, by id.
function Lists:presetChoices()
  return labeled(self.presets)
end

--- A preset's or playlist's name by id.
--- @param id any The preset id, as a number or a string.
--- @return string|nil name Nil when neither list has the id.
function Lists:presetName(id)
  return nameOf(self.presets, id) or nameOf(self.playlists, id)
end

--- A preset by name, else by the id "Name (id)" carries, so a rename keeps programming working.
--- @param value any A preset name, "Name (id)", or an id.
--- @return integer|nil id Nil when the list has no such preset.
function Lists:presetId(value)
  return idOf(self.presets, value)
end

--- Playlists as programming offers them, "Name (id)".
--- @return string[] choices One per playlist, by id.
function Lists:playlistChoices()
  return labeled(self.playlists)
end

--- A playlist's name by id.
--- @param id any The playlist id, as a number or a string.
--- @return string|nil name Nil when the list has no such playlist.
function Lists:playlistName(id)
  return nameOf(self.playlists, id)
end

--- A playlist by name, else by the id "Name (id)" carries, so a rename keeps programming working.
--- @param value any A playlist name, "Name (id)", or an id.
--- @return integer|nil id Nil when the list has no such playlist.
function Lists:playlistId(value)
  return idOf(self.playlists, value)
end

return Lists
