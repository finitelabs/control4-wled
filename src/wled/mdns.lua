--- mDNS for finding WLED controllers: the question to ask, and the services in the answers.
---
--- A query from a port other than 5353 is a one-shot query, so each responder answers it by
--- unicast to the asking port. WLED announces _wled._tcp with one TXT key, mac: the controller's
--- MAC as 12 lowercase hex digits. Answers arrive as raw DNS messages, with names compressed.

local Mdns = {}

Mdns.ADDRESS = "224.0.0.251"
Mdns.PORT = 5353

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV = 1, 12, 16, 33
local CLASS_IN = 1

--- A name may point back into the message; more jumps than this is a loop.
local MAX_POINTERS = 32

--- The longest name DNS allows, in bytes.
local MAX_NAME = 255

--- @class MdnsName
--- @field labels string[] As sent.
--- @field key string Lowercase labels joined by dots, for matching.

--- @class MdnsRecord
--- @field name MdnsName
--- @field type integer
--- @field ttl integer
--- @field target MdnsName|nil PTR and SRV.
--- @field port integer|nil SRV.
--- @field txt table<string, string>|nil TXT, keys lowercase.
--- @field address string|nil A.

--- @class MdnsService
--- @field name string The instance name, as the controller announces it.
--- @field host string|nil The host name, without .local.
--- @field ip string
--- @field port integer
--- @field mac string|nil 12 lowercase hex digits.

--- @param n integer
--- @return string
local function u16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

--- @param name string Dotted, e.g. "_wled._tcp.local".
--- @return string
local function encodeName(name)
  local out = {}
  for label in name:gmatch("[^.]+") do
    out[#out + 1] = string.char(#label) .. label
  end
  return table.concat(out) .. "\0"
end

--- The question for every instance of a service.
--- @param service string e.g. "_wled._tcp.local".
--- @param id integer|nil The message id; a one-shot answer repeats it.
--- @return string
function Mdns.query(service, id)
  return u16(id or 0)
    .. u16(0)
    .. u16(1)
    .. u16(0)
    .. u16(0)
    .. u16(0)
    .. encodeName(service)
    .. u16(TYPE_PTR)
    .. u16(CLASS_IN)
end

--- Reads one message's bytes; every read fails on a short message instead of reading past it.
--- @class MdnsReader
--- @field data string
local Reader = {}
Reader.__index = Reader

--- @param data string
--- @return MdnsReader
local function reader(data)
  return setmetatable({ data = data }, Reader)
end

--- @param pos integer
--- @return integer|nil
function Reader:u8(pos)
  return self.data:byte(pos)
end

--- @param pos integer
--- @return integer|nil
function Reader:u16(pos)
  local hi, lo = self.data:byte(pos, pos + 1)
  if not lo then
    return nil
  end
  return hi * 256 + lo
end

--- @param pos integer
--- @return integer|nil
function Reader:u32(pos)
  local hi, lo = self:u16(pos), self:u16(pos + 2)
  if not lo then
    return nil
  end
  return hi * 65536 + lo
end

--- @param pos integer
--- @return MdnsName|nil name
--- @return integer|nil after The position after the name where it starts.
function Reader:name(pos)
  local labels, after, jumps, size = {}, nil, 0, 1
  while true do
    local len = self:u8(pos)
    if not len then
      return nil
    end
    if len == 0 then
      after = after or pos + 1
      break
    elseif len >= 192 then
      local low = self:u8(pos + 1)
      jumps = jumps + 1
      if not low or jumps > MAX_POINTERS then
        return nil
      end
      after = after or pos + 2
      pos = (len - 192) * 256 + low + 1
    elseif len >= 64 then
      return nil
    else
      local label = self.data:sub(pos + 1, pos + len)
      size = size + len + 1
      if #label < len or size > MAX_NAME then
        return nil
      end
      labels[#labels + 1] = label
      pos = pos + len + 1
    end
  end
  return { labels = labels, key = table.concat(labels, "."):lower() }, after
end

--- @param pos integer
--- @param len integer
--- @return table<string, string>
function Reader:txt(pos, len)
  local txt, stop = {}, pos + len
  while pos < stop do
    local n = self:u8(pos)
    local entry = self.data:sub(pos + 1, pos + n)
    local key, value = entry:match("^([^=]+)=(.*)$")
    if key then
      txt[key:lower()] = value
    end
    pos = pos + n + 1
  end
  return txt
end

--- @param pos integer
--- @return MdnsRecord|nil record
--- @return integer|nil after
function Reader:record(pos)
  local name, at = self:name(pos)
  if not name or not at then
    return nil
  end
  local rtype, ttl, len = self:u16(at), self:u32(at + 4), self:u16(at + 8)
  local data = at + 10
  if not len or data + len - 1 > #self.data then
    return nil
  end
  local record = { name = name, type = rtype, ttl = ttl }
  if rtype == TYPE_PTR then
    record.target = self:name(data)
  elseif rtype == TYPE_SRV then
    record.port = self:u16(data + 4)
    record.target = self:name(data + 6)
  elseif rtype == TYPE_TXT then
    record.txt = self:txt(data, len)
  elseif rtype == TYPE_A and len == 4 then
    record.address = table.concat({ self.data:byte(data, data + 3) }, ".")
  end
  return record, data + len
end

--- Every resource record in an answer, from all its sections. A question or a message cut
--- short gives nothing.
--- @param data string
--- @return MdnsRecord[]
function Mdns.records(data)
  local r = reader(data)
  local flags = r:u16(3)
  if not flags or flags < 32768 then
    return {}
  end
  local questions = r:u16(5)
  local count = (r:u16(7) or 0) + (r:u16(9) or 0) + (r:u16(11) or 0)
  local pos = 13
  for _ = 1, questions or 0 do
    local _, after = r:name(pos)
    if not after then
      return {}
    end
    pos = after + 4
  end
  local records = {}
  for _ = 1, count do
    local record, after = r:record(pos)
    if not record or not after then
      break
    end
    records[#records + 1] = record
    pos = after
  end
  return records
end

--- @param value string|nil
--- @return string|nil
local function macOf(value)
  value = value and value:lower()
  if value and #value == 12 and not value:find("%X") then
    return value
  end
  return nil
end

--- The instances of a service in a set of answers. Each sender's records are read together,
--- so two controllers given the same name are both found: the address from the host's A
--- record, else the sender's.
--- @param answers { data: string, ip: string }[]
--- @param service string e.g. "_wled._tcp.local".
--- @return MdnsService[]
function Mdns.services(answers, service)
  service = service:lower()
  local suffix = "." .. service
  local senders, order = {}, {}
  for _, answer in ipairs(answers) do
    local sender = senders[answer.ip]
    if not sender then
      sender = { ip = answer.ip, instances = {}, order = {}, srv = {}, txt = {}, a = {} }
      senders[answer.ip] = sender
      order[#order + 1] = sender
    end
    for _, rec in ipairs(Mdns.records(answer.data)) do
      local key = rec.name.key
      local target = rec.target and rec.target.key
      if
        rec.type == TYPE_PTR
        and key == service
        and rec.ttl > 0
        and target
        and #target > #suffix
        and target:sub(-#suffix) == suffix
      then
        local instance = target
        if not sender.instances[instance] then
          sender.instances[instance] = rec.target.labels
          sender.order[#sender.order + 1] = instance
        end
      elseif rec.type == TYPE_SRV and rec.target then
        sender.srv[key] = sender.srv[key] or rec
      elseif rec.type == TYPE_TXT then
        sender.txt[key] = sender.txt[key] or rec.txt
      elseif rec.type == TYPE_A and rec.address then
        sender.a[key] = sender.a[key] or {}
        table.insert(sender.a[key], rec.address)
      end
    end
  end
  local found = {}
  for _, sender in ipairs(order) do
    for _, instance in ipairs(sender.order) do
      local s = sender.srv[instance]
      local addresses = s and sender.a[s.target.key] or {}
      local ip = addresses[1] or sender.ip
      for _, address in ipairs(addresses) do
        -- A controller on Ethernet and Wi-Fi lists both; the one that answered is reachable.
        if address == sender.ip then
          ip = address
        end
      end
      found[#found + 1] = {
        name = sender.instances[instance][1],
        host = s and s.target.labels[1] or nil,
        ip = ip,
        port = s and s.port and s.port > 0 and s.port or 80,
        mac = macOf((sender.txt[instance] or {}).mac),
      }
    end
  end
  return found
end

return Mdns
