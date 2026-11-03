--- The light's Extras menu: the controller's effects, palettes, presets and playlists, and the
--- controls the running effect uses, named as the effect names them.
---
--- The proxy keeps the whole setup and answers the app from it. A setup sent again relabels the
--- controls in place and keeps the values it carries, so the setup goes out when a list or the
--- running effect's controls change, and otherwise a state with only the values that moved.
---
--- A list's items carry their names as values, made unique within the list (Extras.choices), so
--- the menu shows names in place of ids and a pick comes back as a name.

local Extras = {}

--- The command every control sends, with the control's id and the value picked.
Extras.COMMAND = "EXTRA_SET"

--- The playlist list's entry for no playlist; picking it stops the running one.
Extras.NO_PLAYLIST = -1

--- The text of the playlist list's entry for no playlist.
local NO_PLAYLIST_TEXT = "None"

--- Sliders in the order an effect's metadata names them, with WLED's own names and ranges.
local SLIDERS = {
  { id = "sx", label = "Effect speed", max = 255 },
  { id = "ix", label = "Effect intensity", max = 255 },
  { id = "c1", label = "Custom 1", max = 255 },
  { id = "c2", label = "Custom 2", max = 255 },
  { id = "c3", label = "Custom 3", max = 31 },
}

--- Checkboxes, named in the metadata after the sliders.
local CHECKS = {
  { id = "o1", label = "Check 1" },
  { id = "o2", label = "Check 2" },
  { id = "o3", label = "Check 3" },
}

--- WLED's name for the palette control.
local PALETTE_LABEL = "Color palette"

--- Controls an effect can hide, in setup order, and the same as a set.
local HIDEABLE_IDS = {}
for _, s in ipairs(SLIDERS) do
  HIDEABLE_IDS[#HIDEABLE_IDS + 1] = s.id
end
for _, c in ipairs(CHECKS) do
  HIDEABLE_IDS[#HIDEABLE_IDS + 1] = c.id
end
HIDEABLE_IDS[#HIDEABLE_IDS + 1] = "pal"
local HIDEABLE = {}
for _, id in ipairs(HIDEABLE_IDS) do
  HIDEABLE[id] = true
end

--- Id ranges by control, for commands from the app.
--- @type table<string, {min: integer, max: integer}|"bool"|"list">
Extras.KINDS = { fx = "list", pal = "list", ps = "list", pl = "list" }
for _, s in ipairs(SLIDERS) do
  Extras.KINDS[s.id] = { min = 0, max = s.max }
end
for _, c in ipairs(CHECKS) do
  Extras.KINDS[c.id] = "bool"
end

--- @param text string
--- @param sep string One character.
--- @return string[]
local function split(text, sep)
  local out = {}
  for part in (text .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    out[#out + 1] = part
  end
  return out
end

--- The controls an effect shows and their names, decided from its metadata as WLED's own page
--- decides them. The metadata reads `<sliders,checks>;<colors>;<palette>;...`: "!" keeps WLED's
--- name, an empty entry hides the control. An effect without metadata shows speed and intensity
--- (all five sliders from id 128 up, the sound-reactive range) and the palette.
--- @param id integer The effect id.
--- @param meta any The effect's /json/fxdata entry; nil when it was not read.
--- @param rgb boolean Whether the strip has color LEDs, which a palette needs.
--- @return table<string, string> controls The name of each control shown, by id ("sx" to "c3", "o1" to "o3", "pal").
function Extras.controls(id, meta, rgb)
  if id == 0 then
    -- WLED's page gives Solid its colors and nothing else.
    meta = ";!;"
  end
  meta = type(meta) == "string" and meta or ""
  local defined = meta ~= ""
  local parts = defined and split(meta, ";") or {}
  local named = (parts[1] or "") ~= "" and split(parts[1], ",") or {}
  local palette = (parts[3] or "") ~= "" and split(parts[3], ",")[1] or nil
  local shown = {}
  local unnamedSliders = id < 128 and 2 or #SLIDERS
  for i, s in ipairs(SLIDERS) do
    local name = named[i]
    if (not defined and i <= unnamedSliders) or (name ~= nil and name ~= "") then
      shown[s.id] = (name ~= nil and name ~= "" and name ~= "!") and name or s.label
    end
  end
  for i, c in ipairs(CHECKS) do
    local name = named[#SLIDERS + i]
    if name ~= nil and name ~= "" then
      shown[c.id] = name ~= "!" and name or c.label
    end
  end
  -- A number in the palette entry is a palette the effect picks itself, with no control.
  if rgb and (not defined or (palette ~= nil and palette ~= "" and tonumber(palette) == nil)) then
    local name = palette and palette:gsub("=.*$", "") or "!"
    shown.pal = (name ~= "" and name ~= "!") and name or PALETTE_LABEL
  end
  return shown
end

--- @param value any
--- @return string
local function attr(value)
  return XMLEncode(tostring(value == nil and "" or value))
end

--- @class WledExtrasChoice
--- @field id integer The controller's id for the entry.
--- @field text string What the menu shows for it and sends back when it is picked.

--- @class WledExtrasChoices
--- @field items WledExtrasChoice[] The entries in list order.
--- @field text table<integer, string> Each entry's text, by id.
--- @field id table<string, integer> Each entry's id, by text.

--- @param e {id: integer, name: string|nil}
--- @return string
local function baseText(e)
  return (e.name == nil or e.name == "") and tostring(e.id) or e.name
end

--- A list's entries with a text for each that no other entry in the list has: its name, with its
--- id after it when the name repeats. A fixed first entry keeps its own text.
--- @param entries WledListEntry[]|nil
--- @param first {id: integer, name: string}|nil An entry ahead of the controller's.
--- @return WledExtrasChoices
local function choicesOf(entries, first)
  local all = {}
  if first then
    all[1] = first
  end
  for _, e in ipairs(entries or {}) do
    all[#all + 1] = e
  end
  local count = {}
  for _, e in ipairs(all) do
    local text = baseText(e)
    count[text] = (count[text] or 0) + 1
  end
  local out = { items = {}, text = {}, id = {} }
  for i, e in ipairs(all) do
    local text = baseText(e)
    if count[text] > 1 and not (first and i == 1) then
      text = string.format("%s (%d)", text, e.id)
    end
    -- A name that already reads like another entry's "Name (id)" takes its own id too.
    while out.id[text] ~= nil do
      text = string.format("%s (%d)", text, e.id)
    end
    out.items[#out.items + 1] = { id = e.id, text = text }
    out.text[e.id] = text
    out.id[text] = e.id
  end
  return out
end

--- What each list control offers, by control id. Values are the entries' texts, not their ids:
--- once a setup reaches an open menu, the app matches a list's value to its items only by text.
--- @param lists {effects: WledListEntry[]|nil, palettes: WledListEntry[]|nil, presets: WledListEntry[]|nil, playlists: WledListEntry[]|nil}
--- @return table<string, WledExtrasChoices> choices For fx, pal, ps and pl.
function Extras.choices(lists)
  return {
    fx = choicesOf(lists.effects),
    pal = choicesOf(lists.palettes),
    ps = choicesOf(lists.presets),
    pl = choicesOf(lists.playlists, { id = Extras.NO_PLAYLIST, name = NO_PLAYLIST_TEXT }),
  }
end

--- @param choices WledExtrasChoices
--- @return string
local function items(choices)
  local out = {}
  for _, c in ipairs(choices.items) do
    out[#out + 1] = string.format('<item text="%s" value="%s"/>', attr(c.text), attr(c.text))
  end
  return table.concat(out)
end

--- @param id string
--- @param label string
--- @param value any
--- @param hidden boolean
--- @param body string
--- @return string
local function list(id, label, value, hidden, body)
  return string.format(
    '<object type="list" id="%s" label="%s" command="%s" value="%s" hidden="%s">'
      .. '<list maxselections="1" minselections="1">%s</list></object>',
    id,
    attr(label),
    Extras.COMMAND,
    attr(value),
    tostring(hidden),
    body
  )
end

--- @class WledExtrasView
--- @field effects WledListEntry[]
--- @field palettes WledListEntry[]
--- @field presets WledListEntry[]
--- @field playlists WledListEntry[]
--- @field choices table<string, WledExtrasChoices> From Extras.choices on the same lists.
--- @field controls table<string, string> From Extras.controls.
--- @field values table<string, string> Each control's value as the setup and state carry it.

--- @param choices WledExtrasChoices|nil
--- @param id any
--- @return string text The entry's text, or the id itself for an entry the list does not have.
local function textOf(choices, id)
  id = tonumber(id)
  if id == nil then
    return ""
  end
  return Select(choices, "text", id) or tostring(id)
end

--- The values the controls show for a report: the main segment's effect, its controls and
--- palette, the preset showing and the running playlist; a list's value is its entry's text.
--- @param seg table|nil The main segment of the controller's state.
--- @param ps integer The preset showing, -1 for none.
--- @param pl integer The running playlist, -1 for none.
--- @param choices table<string, WledExtrasChoices>|nil From Extras.choices.
--- @return table<string, string> values Each control's value, by id.
function Extras.values(seg, ps, pl, choices)
  seg = type(seg) == "table" and seg or {}
  local v = {
    fx = textOf(Select(choices, "fx"), seg.fx),
    pal = textOf(Select(choices, "pal"), seg.pal),
    ps = ps > 0 and textOf(Select(choices, "ps"), ps) or "",
    pl = pl > 0 and textOf(Select(choices, "pl"), pl) or NO_PLAYLIST_TEXT,
  }
  for _, s in ipairs(SLIDERS) do
    v[s.id] = tostring(tonumber(seg[s.id]) or 0)
  end
  for _, c in ipairs(CHECKS) do
    v[c.id] = seg[c.id] == true and "true" or "false"
  end
  return v
end

--- The setup the proxy keeps: effects with their controls, then presets and playlists when the
--- controller has any. A control the effect does not use is sent hidden, so a state can show it.
--- @param view WledExtrasView The lists, controls and values to show.
--- @return string xml The extras_setup document.
function Extras.setup(view)
  local c, v, choices = view.controls, view.values, view.choices
  local out = { "<extras_setup><extra>", '<section label="Effect">' }
  out[#out + 1] = list("fx", "Effect", v.fx, false, items(choices.fx))
  for _, s in ipairs(SLIDERS) do
    out[#out + 1] = string.format(
      '<object type="slider" id="%s" label="%s" command="%s" value="%s" hidden="%s" readonly="false"'
        .. ' min="0" max="%d" resolution="1"></object>',
      s.id,
      attr(c[s.id] or s.label),
      Extras.COMMAND,
      attr(v[s.id]),
      tostring(c[s.id] == nil),
      s.max
    )
  end
  for _, ch in ipairs(CHECKS) do
    out[#out + 1] = string.format(
      '<object type="checkbox" id="%s" label="%s" command="%s" value="%s" hidden="%s"></object>',
      ch.id,
      attr(c[ch.id] or ch.label),
      Extras.COMMAND,
      attr(v[ch.id]),
      tostring(c[ch.id] == nil)
    )
  end
  out[#out + 1] = list("pal", c.pal or PALETTE_LABEL, v.pal, c.pal == nil, items(choices.pal))
  out[#out + 1] = "</section>"
  if #view.presets > 0 or #view.playlists > 0 then
    out[#out + 1] = '<section label="Presets">'
    if #view.presets > 0 then
      out[#out + 1] = list("ps", "Preset", v.ps, false, items(choices.ps))
    end
    if #view.playlists > 0 then
      out[#out + 1] = list("pl", "Playlist", v.pl, false, items(choices.pl))
    end
    out[#out + 1] = "</section>"
  end
  out[#out + 1] = "</extra></extras_setup>"
  return table.concat(out)
end

--- What the setup's shape depends on, apart from values: a change in it needs a new setup.
--- @param view WledExtrasView The lists, controls and values to show.
--- @param listsVersion integer Bumped each time a list is read.
--- @return string shape Equal for two views that need the same setup.
function Extras.shape(view, listsVersion)
  local parts = { tostring(listsVersion) }
  for _, id in ipairs(HIDEABLE_IDS) do
    parts[#parts + 1] = id .. "=" .. tostring(view.controls[id])
  end
  return table.concat(parts, "\n")
end

--- A state with the values that differ from those last sent, or nil when none do. Given the
--- controls, it also shows or hides every control an effect can hide, the way a state is known
--- to change an open menu.
--- @param values table<string, string> Each control's value now, from Extras.values.
--- @param sent table<string, string> The values last sent.
--- @param controls table<string, string>|nil From Extras.controls.
--- @return string|nil xml The extras_state document, or nil when there is nothing to send.
function Extras.state(values, sent, controls)
  local out = {}
  local ids = {}
  for id in pairs(values) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if controls and HIDEABLE[id] then
      out[#out + 1] =
        string.format('<object id="%s" value="%s" hidden="%s"/>', id, attr(values[id]), tostring(controls[id] == nil))
    elseif values[id] ~= sent[id] then
      out[#out + 1] = string.format('<object id="%s" value="%s"/>', id, attr(values[id]))
    end
  end
  if #out == 0 then
    return nil
  end
  return "<extras_state><extra>" .. table.concat(out) .. "</extra></extras_state>"
end

return Extras
