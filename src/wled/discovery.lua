--- Finding the WLED controllers on the network by mDNS.
---
--- One UDP socket on a free port asks for _wled._tcp, twice in case a packet is lost, and
--- reads what comes back for two seconds without blocking. A search asked for while one runs
--- gets that one's answer.

local deferred = require("deferred")

local log = require("lib.logging")
local Mdns = require("wled.mdns")

require("lib.utils")
require("drivers-common-public.global.timer")

local SERVICE = "_wled._tcp.local"

--- How long answers are read, how often the socket is read, and when the question is asked again.
local WINDOW_MS, READ_MS, REPEAT_MS = 2 * ONE_SECOND, ONE_SECOND / 5, ONE_SECOND

--- Answers kept from one search. A controller answers each question once, so a few from each
--- sender hold all it says, and a site's controllers fit well within the total.
local MAX_PER_SENDER, MAX_ANSWERS = 4, 256

local TIMER = "WledDiscovery"

local Discovery = {}

--- The search under way: its socket and the deferred its callers wait on.
--- @type { udp: table, done: Deferred }|nil
local gSearch = nil

--- @param found MdnsService[]
--- @return MdnsService[]
local function sorted(found)
  table.sort(found, function(a, b)
    if a.name:lower() ~= b.name:lower() then
      return a.name:lower() < b.name:lower()
    end
    return a.ip < b.ip
  end)
  return found
end

--- @param search { udp: table }
local function close(search)
  pcall(search.udp.close, search.udp)
  CancelTimer(TIMER)
  if gSearch == search then
    gSearch = nil
  end
end

--- Look for WLED controllers.
--- @return Deferred<MdnsService[], string> The controllers that answered, by name then address.
function Discovery.search()
  if gSearch then
    return gSearch.done
  end
  local done = deferred.new()
  local ok, socket = pcall(require, "socket")
  local udp = ok and type(socket) == "table" and socket.udp and socket.udp()
  if not udp then
    return done:reject("UDP is not available")
  end
  udp:settimeout(0)
  udp:setsockname("*", 0)
  local query = Mdns.query(SERVICE)
  local sent, err = udp:sendto(query, Mdns.ADDRESS, Mdns.PORT)
  if not sent then
    pcall(udp.close, udp)
    return done:reject(tostring(err))
  end
  local search = { udp = udp, done = done }
  gSearch = search
  local answers, perSender, elapsed = {}, {}, 0
  SetTimer(TIMER, READ_MS, function()
    while true do
      local data, ip, port = udp:receivefrom()
      if not data then
        break
      end
      local from = perSender[ip] or 0
      if tonumber(port) == Mdns.PORT and from < MAX_PER_SENDER and #answers < MAX_ANSWERS then
        perSender[ip] = from + 1
        answers[#answers + 1] = { data = data, ip = ip }
      end
    end
    elapsed = elapsed + READ_MS
    if elapsed == REPEAT_MS then
      udp:sendto(query, Mdns.ADDRESS, Mdns.PORT)
    end
    if elapsed < WINDOW_MS then
      return
    end
    close(search)
    local read, found = pcall(function()
      return sorted(Mdns.services(answers, SERVICE))
    end)
    if not read then
      done:reject(tostring(found))
      return
    end
    log:debug("Found %d WLED controller(s) in %d answer(s)", #found, #answers)
    done:resolve(found)
  end, true)
  return done
end

--- End a search under way; its callers get no answer.
function Discovery.stop()
  if gSearch then
    close(gSearch)
  end
end

return Discovery
