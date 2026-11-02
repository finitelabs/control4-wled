--- A WLED segment as its own Control4 light, between the WLED driver and a WLED Segment light.
---
--- The WLED driver keeps the one connection to the controller. It tells each segment light what
--- the controller reports for its segment (Segment.payload). A segment light runs the same light
--- adapter as the controller's light, over a controller that holds just its segment (Segment.view),
--- and sends what its commands mean for its segment (Segment.intent). The WLED driver decides what
--- the master does against its own model when it sends one on (Segment.forward), and keeps that
--- model current between reports (Segment.note), so two lights commanded at once both see it.
---
--- WLED behavior this follows: the master power and level apply on top of every segment's own,
--- a segment's `on` and `bri` fade with the command's `tt`, segment ids can be renumbered when
--- segments are deleted or a preset is applied, and a segment's LED range is `start` to `stop`.

local Segment = {}

--- The connection class between the WLED driver and its segment lights.
Segment.CLASS = "WLED_SEGMENT"

--- Fields of a reported segment a segment light reads.
local FIELDS = { "id", "start", "stop", "n", "on", "bri", "col", "fx", "cct", "lc" }

--- @class WledSegmentRecord
--- @field id integer The segment's WLED id when last found.
--- @field start integer Its first LED.
--- @field stop integer One past its last LED.
--- @field name string|nil Its WLED name.
--- @field live boolean|nil False once a report no longer has it.

--- Record keys in a fixed order, by the number in them: seg2 before seg10.
--- @param records table<string, WledSegmentRecord>
--- @return string[]
local function sortedKeys(records)
  local keys = {}
  for key in pairs(records) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    local x, y = tonumber(a:match("%d+")) or 0, tonumber(b:match("%d+")) or 0
    if x ~= y then
      return x < y
    end
    return a < b
  end)
  return keys
end

--- The segment each record stands for now: one with the same id and LED range, else one with the
--- same range (renumbered), else one with the same id (resized). Within each rule, records whose
--- segment was there at the last report go first, and a record whose segment was gone matches by
--- range only, so it never takes over a segment that only has its old id. Segments with the same
--- range go to the record with their name. Each segment goes to one record.
--- @param records table<string, WledSegmentRecord> By record key.
--- @param segments WledSegment[] The controller's segments.
--- @return table<string, WledSegment> matched By record key; a record with no segment is absent.
--- @return WledSegment[] unmatched Segments no record stands for, in the controller's order.
function Segment.match(records, segments)
  local matched, taken = {}, {}
  local live, dead = {}, {}
  for _, key in ipairs(sortedKeys(records)) do
    local list = records[key].live == false and dead or live
    list[#list + 1] = key
  end
  local function sameRange(r, s)
    return r.start == s.start and r.stop == s.stop
  end
  local rules = {
    {
      same = function(r, s)
        return r.id == s.id and sameRange(r, s)
      end,
      keys = { live, dead },
    },
    { same = sameRange, keys = { live, dead }, byName = true },
    {
      same = function(r, s)
        return r.id == s.id
      end,
      keys = { live },
    },
  }
  for _, rule in ipairs(rules) do
    for _, group in ipairs(rule.keys) do
      for _, key in ipairs(group) do
        local r = records[key]
        if not matched[key] then
          local pick
          for i, s in ipairs(segments) do
            if not taken[i] and rule.same(r, s) then
              if not rule.byName or s.name == r.name then
                pick = i
                break
              end
              pick = pick or i
            end
          end
          if pick then
            matched[key], taken[pick] = segments[pick], true
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
--- capability bits, and the master power and level.
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
  return {
    segment = out,
    master = { on = device.on == true, bri = device.bri },
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
--- segment's: power, level, color and effect go to the segment. The WLED driver decides what the
--- master does when it sends it on (Segment.forward).
--- @param json table The adapter's JSON.
--- @param id integer The segment's WLED id.
--- @return table intent
function Segment.intent(json, id)
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
  return { tt = json.tt, seg = { own } }
end

--- A segment light's command as the controller gets it, decided against the WLED driver's model
--- of the controller. Lighting the segment while the controller is off turns the controller on with
--- only this segment lit. Turning off the last lit segment turns the controller off alone: the
--- segment keeps its own power and level, so a fade does not run twice over, and the controller
--- light's On brings it back.
--- @param intent table From Segment.intent.
--- @param device WledDevice The WLED driver's model, as Segment.note keeps it.
--- @return table json
function Segment.forward(intent, device)
  local own = {}
  for key, value in pairs(type(intent.seg) == "table" and intent.seg[1] or {}) do
    own[key] = value
  end
  local out = { tt = intent.tt, seg = { own } }
  local othersLit = false
  for _, s in ipairs(device.segments or {}) do
    othersLit = othersLit or (s.id ~= own.id and s.on ~= false)
  end
  if own.on == true and device.on ~= true then
    out.on = true
    for _, s in ipairs(device.segments or {}) do
      if s.id ~= own.id then
        out.seg[#out.seg + 1] = { id = s.id, on = false }
      end
    end
  elseif own.on == false and device.on == true and not othersLit then
    out.on = false
    own.on, own.bri = nil, nil
    local fields = 0
    for _ in pairs(own) do
      fields = fields + 1
    end
    if fields == 1 then
      out.seg = nil
    end
  end
  return out
end

--- Take a command the WLED driver sent into its model of the controller at once: the master's
--- power and each segment's, so the next command before the controller reports sees them. The
--- controller's next report replaces them.
--- @param json table
--- @param device WledDevice
function Segment.note(json, device)
  if type(json.on) == "boolean" then
    device.on = json.on
  end
  local seg = json.seg
  if type(seg) ~= "table" then
    return
  end
  if seg[1] == nil then
    -- One entry without an id applies to every segment.
    if type(seg.on) == "boolean" then
      for _, s in ipairs(device.segments or {}) do
        s.on = seg.on
      end
    end
    return
  end
  for _, entry in ipairs(seg) do
    local s = type(entry) == "table" and type(entry.on) == "boolean" and device:segment(tonumber(entry.id))
    if s then
      s.on = entry.on
    end
  end
end

return Segment
