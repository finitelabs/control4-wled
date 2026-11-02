--- Preset cycling: the presets the Next and Previous Preset buttons step through, and the step.

local Cycle = {}

--- @param text string
--- @return string
local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- @param presets WledListEntry[]
--- @param id integer|nil
--- @return WledListEntry|nil
local function byId(presets, id)
  for _, e in ipairs(presets) do
    if e.id == id then
      return e
    end
  end
  return nil
end

--- @param presets WledListEntry[]
--- @param item string An id, a name, or "Name (id)" as programming shows a preset. A number is an id.
--- @param remembered table<string, integer> The id each name last stood for.
--- @return WledListEntry|nil entry
--- @return boolean byName Whether the item named it.
local function find(presets, item, remembered)
  local entry = byId(presets, tonumber(item) or tonumber(item:match("%((%d+)%)$")))
  if entry then
    return entry, false
  end
  for _, e in ipairs(presets) do
    if e.name == item then
      return e, true
    end
  end
  -- A preset renamed on the controller keeps its place under the name the installer gave.
  return byId(presets, remembered[item]), true
end

--- The presets in the cycle, from the installer's list: ids or names separated by commas, in the
--- order given, each once; empty for every preset, by id.
--- @param text string|nil
--- @param presets WledListEntry[]
--- @param remembered table<string, integer>|nil The id each name last stood for, from `named`.
--- @return WledListEntry[] cycle
--- @return string[] unknown Entries the controller has no preset for.
--- @return table<string, integer> named The id each name in the list stands for now.
function Cycle.parse(text, presets, remembered)
  local cycle, unknown, named, seen = {}, {}, {}, {}
  text = trim(tostring(text or ""))
  if text == "" then
    for i, e in ipairs(presets) do
      cycle[i] = e
    end
    return cycle, unknown, named
  end
  for part in (text .. ","):gmatch("([^,]*),") do
    local item = trim(part)
    if item ~= "" then
      local entry, byName = find(presets, item, remembered or {})
      if not entry then
        unknown[#unknown + 1] = item
      else
        if byName then
          named[item] = entry.id
        end
        if not seen[entry.id] then
          seen[entry.id] = true
          cycle[#cycle + 1] = entry
        end
      end
    end
  end
  return cycle, unknown, named
end

--- The preset a step lands on: the one after (or before) the preset showing when it is in the
--- cycle, else after (or before) the one the cycle last applied, else the first (or last). The
--- cycle wraps at both ends.
--- @param cycle WledListEntry[]
--- @param showing integer|nil The preset the controller shows.
--- @param last integer|nil The preset the cycle last applied.
--- @param dir integer 1 for next, -1 for previous.
--- @return integer|nil id Nil for an empty cycle.
function Cycle.step(cycle, showing, last, dir)
  local n = #cycle
  if n == 0 then
    return nil
  end
  local at
  for _, from in ipairs({ showing, last }) do
    for i, e in ipairs(cycle) do
      if e.id == from then
        at = i
        break
      end
    end
    if at then
      break
    end
  end
  if not at then
    return dir > 0 and cycle[1].id or cycle[n].id
  end
  return cycle[(at - 1 + dir) % n + 1].id
end

return Cycle
