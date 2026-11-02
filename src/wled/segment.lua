--- A WLED segment as its own Control4 light, between the WLED driver and a WLED Segment light.
---
--- The WLED driver keeps the one connection to the controller. It tells each segment light what
--- the controller reports for its segment (Segment.payload), and sends on the WLED JSON a segment
--- light's commands become (Segment.command). The segment light runs the same light adapter as
--- the controller's light, over a controller that holds just its segment (Segment.view).
---
--- WLED behavior this follows: the master power and level apply on top of every segment's own,
--- a segment's `on` and `bri` fade with the command's `tt`, segment ids can be renumbered when
--- segments are deleted or a preset is applied, and a segment's LED range is `start` to `stop`.

local Segment = {}

--- The connection class between the WLED driver and its segment lights.
Segment.CLASS = "WLED_SEGMENT"

--- Fields of a reported segment a segment light reads.
local FIELDS = { "id", "start", "stop", "n", "on", "bri", "col", "fx", "cct", "lc" }

--- @param records table<string, {id: integer, start: integer, stop: integer}>
--- @return string[] keys The record keys in a fixed order.
local function sortedKeys(records)
  local keys = {}
  for key in pairs(records) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

--- The segment each record stands for now: one with the same id and LED range, else one with the
--- same range (renumbered), else one with the same id (resized). Each segment goes to one record.
--- @param records table<string, {id: integer, start: integer, stop: integer}> By record key.
--- @param segments WledSegment[] The controller's segments.
--- @return table<string, WledSegment> matched By record key; a record with no segment is absent.
--- @return WledSegment[] unmatched Segments no record stands for, in the controller's order.
function Segment.match(records, segments)
  local matched, taken = {}, {}
  local keys = sortedKeys(records)
  local rules = {
    function(r, s)
      return r.id == s.id and r.start == s.start and r.stop == s.stop
    end,
    function(r, s)
      return r.start == s.start and r.stop == s.stop
    end,
    function(r, s)
      return r.id == s.id
    end,
  }
  for _, same in ipairs(rules) do
    for _, key in ipairs(keys) do
      if not matched[key] then
        for i, s in ipairs(segments) do
          if not taken[i] and same(records[key], s) then
            matched[key], taken[i] = s, true
            break
          end
        end
      end
    end
  end
  local unmatched = {}
  for i, s in ipairs(segments) do
    if not taken[i] then
      unmatched[#unmatched + 1] = s
    end
  end
  return matched, unmatched
end

--- The name a segment's connection shows: its WLED name, else its id.
--- @param seg WledSegment
--- @return string
function Segment.name(seg)
  return seg.name or ("Segment " .. seg.id)
end

--- What the WLED driver tells a segment light: its segment as the controller reports it, its
--- capability bits, the master power and level, and whether each other segment is on.
--- @param device WledDevice The controller's model.
--- @param id integer The segment's WLED id now.
--- @return table|nil payload Nil when the controller has no such segment.
function Segment.payload(device, id)
  local seg = device:segment(id)
  if not seg then
    return nil
  end
  local raw = {}
  for _, s in ipairs(type(device.state) == "table" and type(device.state.seg) == "table" and device.state.seg or {}) do
    if type(s) == "table" and tonumber(s.id) == id then
      raw = s
      break
    end
  end
  local out = { lc = seg.lc, on = seg.on, bri = seg.bri, id = id, start = seg.start, stop = seg.stop }
  for _, field in ipairs(FIELDS) do
    if out[field] == nil and raw[field] ~= nil then
      out[field] = raw[field]
    end
  end
  local others = {}
  for _, s in ipairs(device.segments) do
    if s.id ~= id then
      others[#others + 1] = { id = s.id, on = s.on }
    end
  end
  return {
    segment = out,
    master = { on = device.on == true, bri = device.bri },
    others = others,
  }
end

--- The controller as a segment light's adapter reads it: one segment, whose power is on only
--- while the master is on too, at the segment's own level.
--- @param payload table|nil From Segment.payload; nil for a segment light that has none yet.
--- @return table view Shaped like the WledDevice fields the adapter reads.
function Segment.view(payload)
  if type(payload) ~= "table" or type(payload.segment) ~= "table" then
    return { on = false, bri = 0, lc = 0, segments = {}, state = {} }
  end
  local seg = payload.segment
  local on = seg.on ~= false
  return {
    on = payload.master.on == true and on,
    bri = tonumber(seg.bri) or 255,
    lc = tonumber(seg.lc) or 0,
    segments = { { id = seg.id, start = seg.start, stop = seg.stop, on = on, bri = seg.bri, lc = seg.lc } },
    state = { seg = { seg }, mainseg = seg.id },
  }
end

--- A segment light's command, as the adapter wrote it for the whole controller, made its
--- segment's: power and level go to the segment. Lighting the segment while the controller is
--- off turns the controller on with only this segment lit; turning off the last lit segment
--- turns the controller off too.
--- @param json table The adapter's JSON.
--- @param payload table The segment light's last payload.
--- @return table json
function Segment.command(json, payload)
  local id = payload.segment.id
  local own = {}
  if type(json.seg) == "table" then
    for _, entry in ipairs(json.seg[1] and json.seg or { json.seg }) do
      for key, value in pairs(entry) do
        own[key] = value
      end
    end
  end
  own.id = id
  if json.on ~= nil then
    own.on = json.on
  end
  if json.bri ~= nil then
    own.bri = json.bri
  end
  local out = { tt = json.tt, seg = { own } }
  local othersLit = false
  for _, other in ipairs(payload.others or {}) do
    othersLit = othersLit or other.on ~= false
  end
  if own.on == true and not payload.master.on then
    out.on = true
    for _, other in ipairs(payload.others or {}) do
      out.seg[#out.seg + 1] = { id = other.id, on = false }
    end
  elseif own.on == false and payload.master.on and not othersLit then
    out.on = false
  end
  return out
end

return Segment
