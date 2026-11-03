--- Finding WLED controllers: the mDNS question and the answers read from it, the search, the
--- Found Controllers list and the Find Controllers action, and IP Address following the
--- controller to a new address by its MAC, but never away from an address the installer named.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_discovery.lua

local T = require("testlib")
local W = require("wled_fake")
require("color_math").install()

DEBUG_WEBSOCKET = false

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local DRIVER = HERE .. "/../drivers/wled/driver.lua"
local XML = HERE .. "/../drivers/wled/driver.xml"

package.preload["cloud-client-byte"] = function()
  return {}
end
package.loaded["lib.http"] = W.http

local Mdns = require("wled.mdns")

local function readXml()
  local f = assert(io.open(XML, "r"))
  local xml = f:read("*a")
  f:close()
  return xml
end

local function defaultProperties()
  local props = {}
  for block in readXml():gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    if name then
      props[name] = block:match("<default>(.-)</default>") or ""
    end
  end
  return props
end

local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return "3.3.2"
  end
  if section == "config" then
    return readXml():match("<config>(.-)</config>")
  end
  return configInfo(self, section)
end

function C4:GetDevicesByC4iName()
  return {}
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

-- Composer's list and visibility for each property, as the driver last set them.
local shownList, hidden = {}, {}

function C4:UpdatePropertyList(name, csv)
  shownList[name] = csv
end

function C4:SetPropertyAttribs(name, flag)
  hidden[name] = flag == 1
end

local events = {}
function C4:FireEventByID(id)
  events[#events + 1] = id
end

local function eventCount(id)
  local n = 0
  for _, e in ipairs(events) do
    if e == id then
      n = n + 1
    end
  end
  return n
end

local function items()
  local list = {}
  for item in ((shownList["Found Controllers"] or "") .. ","):gmatch("(.-),") do
    list[#list + 1] = item
  end
  return list
end

--- Pick an item in Found Controllers, as Composer does.
local function pick(item)
  Properties["Found Controllers"] = item
  OnPropertyChanged("Found Controllers")
end

--- The installer types into a property.
local function set(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end

local function loadDriver()
  T.unload("^drivers%-common%-public%.module%.websocket$", "^wled%.")
  -- Composer's lists start empty at each load; the helper's memory of them goes with the Lua state.
  PropertyLists, shownList, hidden = nil, {}, {}
  events = {}
  dofile(DRIVER)
  ShimLateInit()
end

--- A fresh project with the IP Address set to the first fake, and every fake made.
--- @param fakes { profile: string, ip: string, port: integer|nil }[]
--- @return WledFake[]
local function fresh(fakes)
  W.reset()
  require("lib.persist"):delete("WledControllerMac")
  for k, v in pairs(defaultProperties()) do
    Properties[k] = v
  end
  local made = {}
  for i, f in ipairs(fakes) do
    made[i] = W.Fake.new(f.profile, { ip = f.ip, port = f.port })
  end
  Properties["IP Address"] = made[1] and made[1].ip or ""
  loadDriver()
  return made
end

--- The controller at an address stops answering, there and to mDNS.
local function goDark(fake)
  fake.reachable = false
  fake:drop()
end

local RGBW = "esp32-rgbw-pwm-16" -- 02a1b2c3d402, instance wled-c3d402
local STRIP = "esp8266-ws2812b-015" -- 02a1b2c3d401, instance wled-c3d401

--------------------------------------------------------------------------------
T.section("The question asks every _wled._tcp instance")
--------------------------------------------------------------------------------
do
  local q = Mdns.query("_wled._tcp.local", 258)
  T.eq("length", #q, 34)
  T.eq("id", q:sub(1, 2), "\1\2")
  T.eq("a query, one question, no records", q:sub(3, 12), "\0\0\0\1\0\0\0\0\0\0")
  T.eq("the name in labels", q:sub(13, 30), "\5_wled\4_tcp\5local\0")
  T.eq("PTR, class IN", q:sub(31, 34), "\0\12\0\1")
end

--------------------------------------------------------------------------------
T.section("An answer gives the instance, its host, address, port and MAC")
--------------------------------------------------------------------------------
do
  local answer = W.mdnsAnswer({
    instance = "wled-c3d402",
    host = "wled-c3d402",
    port = 80,
    mac = "02a1b2c3d402",
    ip = "192.0.2.50",
  })
  local found = Mdns.services({ { data = answer, ip = "192.0.2.50" } }, "_wled._tcp.local")
  T.eq("one controller", #found, 1)
  T.eq("name", found[1].name, "wled-c3d402")
  T.eq("host", found[1].host, "wled-c3d402")
  T.eq("address", found[1].ip, "192.0.2.50")
  T.eq("port", found[1].port, 80)
  T.eq("MAC", found[1].mac, "02a1b2c3d402")

  local records = Mdns.records(answer)
  T.eq("PTR, SRV, TXT and A read past the question", #records, 4)
  T.eq("a compressed name read whole", records[2].name.key, "wled-c3d402._wled._tcp.local")
  T.eq("the SRV target, compressed onto local", records[2].target.key, "wled-c3d402.local")

  local renamed =
    W.mdnsAnswer({ instance = "Kitchen Shelf", host = "kitchen", port = 8080, mac = "02A1B2C3D4FF", ip = "192.0.2.51" })
  local k = Mdns.services({ { data = renamed, ip = "192.0.2.51" } }, "_wled._tcp.local")[1]
  T.eq("a name with a space, as announced", k.name, "Kitchen Shelf")
  T.eq("another port", k.port, 8080)
  T.eq("an uppercase MAC is lowercased", k.mac, "02a1b2c3d4ff")
end

--------------------------------------------------------------------------------
T.section("An answer missing records still gives what it can")
--------------------------------------------------------------------------------
do
  local base = { instance = "wled-1", host = "wled-1", port = 81, mac = "02a1b2c3d401", ip = "192.0.2.60" }
  local function one(over, from)
    local a = {}
    for k, v in pairs(base) do
      a[k] = v
    end
    for k, v in pairs(over) do
      a[k] = v
    end
    return Mdns.services({ { data = W.mdnsAnswer(a), ip = from or "192.0.2.61" } }, "_wled._tcp.local")
  end
  T.eq("no A record: the address that answered", one({ withoutA = true })[1].ip, "192.0.2.61")
  local noSrv = one({ withoutSrv = true })[1]
  T.eq("no SRV: the address that answered", noSrv.ip, "192.0.2.61")
  T.eq("no SRV: port 80", noSrv.port, 80)
  T.eq("no SRV: no host", noSrv.host, nil)
  T.eq("no SRV: the MAC still read", noSrv.mac, "02a1b2c3d401")
  T.eq("no TXT: no MAC", one({ withoutTxt = true })[1].mac, nil)
  T.eq("a MAC that is not 12 hex digits is none", one({ mac = "02:a1:b2:c3:d4:01" })[1].mac, nil)
  T.eq("port 0 is taken as 80", one({ port = 0 })[1].port, 80)
  T.eq("two addresses: the one that answered", one({ ips = { "10.0.0.5", "192.0.2.61" } })[1].ip, "192.0.2.61")
  T.eq(
    "two addresses, neither answered: the first",
    one({ ips = { "10.0.0.5", "10.0.0.6" } }, "192.0.2.62")[1].ip,
    "10.0.0.5"
  )
  T.eq("a goodbye (TTL 0) is not a controller", #one({ ttl = 0 }), 0)
end

--------------------------------------------------------------------------------
T.section("Malformed answers give nothing and never raise")
--------------------------------------------------------------------------------
do
  local answer =
    W.mdnsAnswer({ instance = "wled-1", host = "wled-1", port = 80, mac = "02a1b2c3d401", ip = "192.0.2.60" })
  local raised = 0
  for n = 0, #answer - 1 do
    local ok = pcall(Mdns.services, { { data = answer:sub(1, n), ip = "192.0.2.60" } }, "_wled._tcp.local")
    if not ok then
      raised = raised + 1
    end
  end
  T.eq("every cut-short answer read without an error", raised, 0)
  -- The PTR record runs from byte 35 to 55.
  local cut = Mdns.services({ { data = answer:sub(1, 50), ip = "192.0.2.60" } }, "_wled._tcp.local")
  T.eq("cut inside the PTR: nothing", #cut, 0)
  local whole = Mdns.services({ { data = answer:sub(1, 55), ip = "192.0.2.60" } }, "_wled._tcp.local")
  T.eq("cut after it: the controller, at the address that answered", whole[1] and whole[1].ip, "192.0.2.60")

  -- The question's name points at itself.
  local loop = answer:sub(1, 12) .. "\192\12" .. answer:sub(15)
  T.eq("a pointer loop: nothing", #Mdns.services({ { data = loop, ip = "192.0.2.60" } }, "_wled._tcp.local"), 0)
  -- A query may carry the answers it knows; it is still a question.
  local known = answer:sub(1, 2) .. "\0\0" .. answer:sub(5)
  T.eq(
    "a query carrying answers is not an answer",
    #Mdns.services({ { data = known, ip = "192.0.2.60" } }, "_wled._tcp.local"),
    0
  )
  T.eq("another service is not WLED", #Mdns.services({ { data = answer, ip = "192.0.2.60" } }, "_http._tcp.local"), 0)

  -- A message is read for at most 32 records and 32 questions.
  local service = "\5_wled\4_tcp\5local\0"
  local ptrs = {}
  for i = 1, 40 do
    local target = string.char(#tostring(i) + 1) .. "w" .. i .. service
    ptrs[i] = service .. "\0\12\0\1\0\0\0\10" .. string.char(0, #target) .. target
  end
  local forty = "\0\0\132\0\0\0\0\40\0\0\0\0" .. table.concat(ptrs)
  T.eq("40 records: 32 read", #Mdns.records(forty), 32)
  --- A message with n questions, each the service, then one PTR to an instance of it.
  local function asking(n)
    local q = "\0\12\0\1"
    local msg = "\0\0\132\0\0" .. string.char(n) .. "\0\1\0\0\0\0" .. service .. q
    for _ = 2, n do
      msg = msg .. "\192\12" .. q
    end
    return msg .. "\192\12\0\12\0\1\0\0\0\10\0\4\1w\192\12"
  end
  T.eq("32 questions, then the answer read", #Mdns.records(asking(32)), 1)
  T.eq("33 questions: nothing read", #Mdns.records(asking(33)), 0)

  -- A PTR for the service must name an instance of it.
  local function ptrTo(target)
    local service = "\5_wled\4_tcp\5local\0"
    return "\0\0\132\0\0\0\0\1\0\0\0\0"
      .. service
      .. "\0\12\0\1\0\0\0\10"
      .. string.char(math.floor(#target / 256), #target % 256)
      .. target
  end
  local function read(data)
    local ok, found = pcall(Mdns.services, { { data = data, ip = "192.0.2.60" } }, "_wled._tcp.local")
    return ok and #found or "raised"
  end
  T.eq("a PTR to the root name: nothing", read(ptrTo("\0")), 0)
  T.eq("a PTR to the service itself: nothing", read(ptrTo("\5_wled\4_tcp\5local\0")), 0)
  T.eq("a PTR to another service's instance: nothing", read(ptrTo("\1x\5_http\4_tcp\5local\0")), 0)
  T.eq("a PTR to an instance: one", read(ptrTo("\1x\5_wled\4_tcp\5local\0")), 1)
  local label60 = "\60" .. string.rep("a", 60)
  local suffix = "\1x\5_wled\4_tcp\5local\0"
  T.eq("a name of 264 bytes: nothing", read(ptrTo(string.rep(label60, 4) .. suffix)), 0)
  T.eq("a name of 203 bytes is read", read(ptrTo(string.rep(label60, 3) .. suffix)), 1)
end

--------------------------------------------------------------------------------
T.section("A search asks twice and reads two seconds of answers")
--------------------------------------------------------------------------------
do
  fresh({ { profile = RGBW, ip = "192.0.2.41" }, { profile = STRIP, ip = "192.0.2.42", port = 8080 } })
  W.run(3000)
  local Discovery = require("wled.discovery")
  local udp0 = #W.sockets
  local found
  Discovery.search():next(function(f)
    found = f
  end)
  local again
  Discovery.search():next(function(f)
    again = f
  end)
  T.eq("one socket for both callers", #W.sockets, udp0 + 1)
  local udp = W.sockets[#W.sockets]
  T.eq("bound to a free port", udp.bound[2], 0)
  T.eq("reads never block", udp.timeout, 0)
  T.eq("asked the mDNS group", udp.sent[1].ip .. ":" .. udp.sent[1].port, "224.0.0.251:5353")
  W.run(1100)
  T.eq("asked again after a second", #udp.sent, 2)
  T.eq("no answer before two seconds", found, nil)
  W.run(1000)
  T.truthy("answered", found)
  found = found or {}
  T.eq("both controllers, once each", #found, 2)
  T.eq("by name", (found[1] or {}).name, "wled-c3d401")
  T.eq("then the next", (found[2] or {}).name, "wled-c3d402")
  T.eq("the strip's port", (found[1] or {}).port, 8080)
  T.eq("the strip's address", (found[1] or {}).ip, "192.0.2.42")
  T.eq("the second caller got the same", again, found)
  T.truthy("socket closed", udp.closed)

  -- An answer from another port is not mDNS.
  local seen
  Discovery.search():next(function(f)
    seen = f
  end)
  local s = W.sockets[#W.sockets]
  s.inbox[#s.inbox + 1] = {
    W.mdnsAnswer({ instance = "stray", host = "stray", port = 80, mac = "02a1b2c3d4aa", ip = "192.0.2.70" }),
    "192.0.2.70",
    40000,
  }
  W.run(2100)
  T.eq("an answer from another port is left out", seen and #seen, 2)

  -- An answer that names no instance does not stop the search from answering.
  local settled
  Discovery.search():next(function(f)
    settled = f
  end)
  local r = W.sockets[#W.sockets]
  local root = "\0\0\132\0\0\0\0\1\0\0\0\0\5_wled\4_tcp\5local\0\0\12\0\1\0\0\0\10\0\1\0"
  r.inbox[#r.inbox + 1] = { root, "192.0.2.71", 5353 }
  W.run(2100)
  T.eq("a search with a nameless answer still answers", settled and #settled, 2)

  --- A search fed answers as they arrive: { name, address, sender } with the sender the address
  --- unless given, each sent `times` times.
  local function searchWith(list, times)
    local result
    Discovery.search():next(function(f)
      result = f
    end)
    local inbox = W.sockets[#W.sockets].inbox
    for _ = 1, times do
      for _, a in ipairs(list) do
        inbox[#inbox + 1] = {
          W.mdnsAnswer({ instance = a[1], host = a[1], port = 80, mac = "02a1b2c3d4aa", ip = a[2] }),
          a[3] or a[2],
          5353,
        }
      end
    end
    W.run(2100)
    return result
  end
  local site = {}
  for i = 1, 40 do
    site[i] = { "wled-" .. i, "198.51.100." .. i }
  end
  -- The section's two fakes answer as well.
  T.eq("40 controllers answering both questions are all found", #searchWith(site, 2), 42)

  -- A reflector on another network sends every controller's answer from its own address.
  local reflected = {}
  for i = 1, 10 do
    reflected[i] = { "vlan-" .. i, "198.51.100." .. (100 + i), "192.0.2.250" }
  end
  local behind = {}
  for _, c in ipairs(searchWith(reflected, 2)) do
    if c.name:match("^vlan%-") then
      behind[#behind + 1] = c
    end
  end
  T.eq("10 controllers behind a reflector, all found", #behind, 10)
  T.eq("each at its own address", behind[1] and behind[1].ip:match("^198%.51%.100%.1%d%d$") ~= nil, true)

  local many = {}
  for i = 1, 300 do
    many[i] = { "wled-" .. i, "10." .. math.floor(i / 256) .. "." .. (i % 256) .. ".1" }
  end
  T.eq("and every search at 256 answers", #searchWith(many, 1), 256)

  W.sendFails = "permission denied"
  local refused
  Discovery.search():next(nil, function(e)
    refused = e
  end)
  W.sendFails = nil
  T.eq("a refused send says why", refused, "permission denied")
  T.truthy("and closes its socket", W.sockets[#W.sockets].closed)

  local stopped
  Discovery.search():next(function()
    stopped = true
  end)
  local last = W.sockets[#W.sockets]
  Discovery.stop()
  W.run(3000)
  T.truthy("stop closes the socket", last.closed)
  T.eq("and answers nobody", stopped, nil)
end

--------------------------------------------------------------------------------
T.section("Without UDP a search says so")
--------------------------------------------------------------------------------
do
  fresh({ { profile = RGBW, ip = "192.0.2.41" } })
  W.run(3000)
  local socket = package.loaded["socket"]
  local udp = socket.udp
  socket.udp = function()
    return nil
  end
  local err
  require("wled.discovery").search():next(nil, function(e)
    err = e
  end)
  socket.udp = udp
  T.eq("rejected with the reason", err, "UDP is not available")
end

--------------------------------------------------------------------------------
T.section("Found Controllers lists what answered, and a pick sets the address")
--------------------------------------------------------------------------------
do
  local fakes = fresh({ { profile = RGBW, ip = "192.0.2.41" }, { profile = STRIP, ip = "192.0.2.42", port = 8080 } })
  T.eq("hidden until a search finds one", hidden["Found Controllers"], true)
  W.run(3000)
  T.eq(
    "idle item first, then by name",
    table.concat(items(), "|"),
    "(Select)|wled-c3d401 (192.0.2.42:8080)|wled-c3d402 (192.0.2.41)"
  )
  T.eq("shown", hidden["Found Controllers"], false)
  T.eq("idle", Properties["Found Controllers"], "(Select)")
  T.eq("connected to the address set", Properties["Driver Status"], "Connected")

  pick("(Select)")
  T.eq("the idle item does nothing", Properties["IP Address"], "192.0.2.41")

  -- The strip is a different controller from the one this driver remembers.
  pick("wled-c3d401 (192.0.2.42:8080)")
  T.eq("IP Address set", Properties["IP Address"], "192.0.2.42")
  T.eq("Port set", Properties["Port"], "8080")
  T.eq("back to idle, so it can be picked again", Properties["Found Controllers"], "(Select)")
  W.run(3000)
  T.contains("a different controller is not driven without Reset Driver", Properties["Driver Status"], "Reset Driver")
  W.run(65000)
  T.eq("and the pick is kept, though ours answers elsewhere", Properties["IP Address"], "192.0.2.42")

  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  -- The fake never answers a close frame, so the socket to the same address takes up to 30 s.
  W.run(35000)
  T.eq("after Reset Driver it is", Properties["Driver Status"], "Connected")
  T.eq("its MAC", Properties["MAC Address"], "02:A1:B2:C3:D4:01")
  T.eq("the address kept", Properties["IP Address"], "192.0.2.42")

  pick("nothing like this")
  T.eq("an item no search found changes nothing", Properties["IP Address"], "192.0.2.42")
  T.eq("and goes back to idle", Properties["Found Controllers"], "(Select)")

  -- Find Controllers sees what joined and what left.
  goDark(fakes[1])
  local joined = W.Fake.new("esp32-cct-16", { ip = "192.0.2.43" })
  joined.mdnsName = "Cabinet, left"
  EC.Find_Controllers()
  W.run(3000)
  T.eq(
    "a new one listed, a dark one gone, a comma made a space",
    table.concat(items(), "|"),
    "(Select)|Cabinet  left (192.0.2.43)|wled-c3d401 (192.0.2.42:8080)"
  )
  pick("Cabinet  left (192.0.2.43)")
  T.eq("the renamed one picks by its item", Properties["IP Address"], "192.0.2.43")

  joined.reachable, fakes[2].reachable = false, false
  EC.Find_Controllers()
  W.run(3000)
  T.eq("nothing answered: hidden", hidden["Found Controllers"], true)
  T.eq("only the idle item", table.concat(items(), "|"), "(Select)")

  EC.Find_Controllers()
  local searching = W.sockets[#W.sockets]
  OnDriverDestroyed()
  T.truthy("a search under way ends with the driver", searching.closed)
end

--------------------------------------------------------------------------------
T.section("IP Address follows the controller to a new address")
--------------------------------------------------------------------------------
do
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  T.eq("connected", Properties["Driver Status"], "Connected")
  local q0 = W.mdnsQueries()
  W.run(120000)
  T.eq("no searching while it answers", W.mdnsQueries(), q0)

  -- DHCP gives the controller a new address.
  goDark(old)
  W.Fake.new(RGBW, { ip = "192.0.2.99" })
  events = {}
  W.run(5000)
  T.eq("IP Address follows it", Properties["IP Address"], "192.0.2.99")
  T.eq("connected there", Properties["Driver Status"], "Connected")
  T.eq("Connected event", eventCount(1), 1)
  local q1 = W.mdnsQueries()
  W.run(120000)
  T.eq("searching stops once it answers", W.mdnsQueries(), q1)
end

--------------------------------------------------------------------------------
T.section("It keeps looking while the controller is away, then follows")
--------------------------------------------------------------------------------
do
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  goDark(old)
  W.run(5000)
  local q0 = W.mdnsQueries()
  W.run(61000)
  T.eq("asks every 30 s, twice each", W.mdnsQueries() - q0, 4)
  T.eq("the address kept meanwhile", Properties["IP Address"], "192.0.2.41")
  W.Fake.new(RGBW, { ip = "192.0.2.98", port = 8080 })
  W.run(33000)
  T.eq("followed when it came back elsewhere", Properties["IP Address"], "192.0.2.98")
  T.eq("its port too", Properties["Port"], "8080")
  T.eq("connected", Properties["Driver Status"], "Connected")
end

--------------------------------------------------------------------------------
T.section("When another controller takes its address, it follows ours")
--------------------------------------------------------------------------------
do
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  old.si.info.mac = "02a1b2c3d4ee"
  old.mdnsName = "wled-c3d4ee"
  old:drop()
  W.Fake.new(RGBW, { ip = "192.0.2.97" })
  W.run(10000)
  T.eq("followed ours", Properties["IP Address"], "192.0.2.97")
  T.eq("connected", Properties["Driver Status"], "Connected")
  T.eq("its MAC", Properties["MAC Address"], "02:A1:B2:C3:D4:02")
end

--------------------------------------------------------------------------------
T.section("An address the installer names is kept")
--------------------------------------------------------------------------------
do
  local fakes = fresh({ { profile = RGBW, ip = "192.0.2.41" }, { profile = STRIP, ip = "192.0.2.42" } })
  W.run(3000)
  set("IP Address", "192.0.2.42")
  W.run(5000)
  T.contains("a different controller there", Properties["Driver Status"], "Reset Driver")
  W.run(65000)
  T.eq("not moved back to ours", Properties["IP Address"], "192.0.2.42")

  set("IP Address", "192.0.2.41")
  W.run(5000)
  T.eq("ours again", Properties["Driver Status"], "Connected")
  -- Once ours answers at the installer's address, it may follow again.
  goDark(fakes[1])
  W.Fake.new(RGBW, { ip = "192.0.2.96" })
  W.run(5000)
  T.eq("following again after it answered", Properties["IP Address"], "192.0.2.96")

  -- Another controller answers on the Port the installer sets.
  W.Fake.new(STRIP, { ip = "192.0.2.96", port = 8081 })
  set("Port", "8081")
  W.run(5000)
  T.contains("a different controller on that port", Properties["Driver Status"], "Reset Driver")
  W.run(65000)
  T.eq("a Port the installer sets is kept too", Properties["Port"], "8081")
  T.eq("and the address", Properties["IP Address"], "192.0.2.96")
end

--------------------------------------------------------------------------------
T.section("A controller that answers is never moved")
--------------------------------------------------------------------------------
do
  fresh({ { profile = RGBW, ip = "192.0.2.41" } })
  W.run(3000)
  -- The same controller announced at a second address, as one on Ethernet and Wi-Fi can be.
  -- It sorts first, so a move would take it.
  W.Fake.new(RGBW, { ip = "192.0.2.40" })
  EC.Find_Controllers()
  W.run(3000)
  T.eq("listed at both", #items(), 3)
  T.eq("still at the address it answers", Properties["IP Address"], "192.0.2.41")
  T.eq("connected", Properties["Driver Status"], "Connected")

  -- Lost once and followed, then announced only at another address while it answers.
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  goDark(old)
  local here = W.Fake.new(RGBW, { ip = "192.0.2.99" })
  W.run(5000)
  T.eq("followed", Properties["IP Address"], "192.0.2.99")
  here.mdns = false
  W.Fake.new(RGBW, { ip = "192.0.2.40" })
  EC.Find_Controllers()
  W.run(3000)
  T.eq("listed only elsewhere", table.concat(items(), "|"), "(Select)|wled-c3d402 (192.0.2.40)")
  T.eq("still where it answers", Properties["IP Address"], "192.0.2.99")
end

--------------------------------------------------------------------------------
T.section("A load follows a controller that moved while the driver was off")
--------------------------------------------------------------------------------
do
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  OnDriverDestroyed()
  old.reachable = false
  W.Fake.new(RGBW, { ip = "192.0.2.95" })
  loadDriver()
  W.run(5000)
  T.eq("followed at the load", Properties["IP Address"], "192.0.2.95")
  T.eq("connected", Properties["Driver Status"], "Connected")
end

--------------------------------------------------------------------------------
T.section("Nothing to follow without a MAC to follow")
--------------------------------------------------------------------------------
do
  -- Never connected: no MAC remembered.
  local fakes = fresh({ { profile = RGBW, ip = "192.0.2.41" } })
  goDark(fakes[1])
  W.Fake.new(RGBW, { ip = "192.0.2.94" })
  W.run(65000)
  T.eq("a driver that never connected stays put", Properties["IP Address"], "192.0.2.41")

  -- A controller that announces no MAC is listed but never followed.
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  goDark(old)
  local quiet = W.Fake.new(RGBW, { ip = "192.0.2.93" })
  quiet.mdnsName = "quiet"
  local answerTo = quiet.mdnsAnswerTo
  function quiet:mdnsAnswerTo(query)
    local a = answerTo(self, query)
    return a
      and W.mdnsAnswer({
        id = 0,
        instance = "quiet",
        host = "quiet",
        port = 80,
        mac = "",
        ip = self.ip,
        withoutTxt = true,
      })
  end
  W.run(65000)
  T.eq("listed", items()[2], "quiet (192.0.2.93)")
  T.eq("not followed", Properties["IP Address"], "192.0.2.41")

  -- After Reset Driver the MAC is forgotten, so nothing is followed until one answers.
  local fresh1 = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  goDark(fresh1)
  W.run(5000)
  EC.Reset_Driver({ ["Are You Sure?"] = "Yes" })
  W.Fake.new(RGBW, { ip = "192.0.2.92" })
  local q0 = W.mdnsQueries()
  W.run(65000)
  T.eq("not followed after Reset Driver", Properties["IP Address"], "192.0.2.41")
  T.eq("and no more searching for it", W.mdnsQueries(), q0)
end

--------------------------------------------------------------------------------
T.section("A first connection still under way is not moved")
--------------------------------------------------------------------------------
do
  local fake = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  OnDriverDestroyed()
  -- After the reload it answers only at 3 s, after the first search, and only ours at .40 announces.
  fake.connectDelayMs, fake.mdns = 3000, false
  W.Fake.new(RGBW, { ip = "192.0.2.40" })
  loadDriver()
  W.run(5000)
  T.eq("kept at its address", Properties["IP Address"], "192.0.2.41")
  T.eq("connected there", Properties["Driver Status"], "Connected")
end

--------------------------------------------------------------------------------
T.section("A controller announced at the address in use is not moved")
--------------------------------------------------------------------------------
do
  local old = fresh({ { profile = RGBW, ip = "192.0.2.41" } })[1]
  W.run(3000)
  -- Its web server stops answering; it still announces here, and at a second address that sorts first.
  W.Fake.new(RGBW, { ip = "192.0.2.40" })
  old.mdns = "always"
  goDark(old)
  W.run(65000)
  T.eq("kept at the address it announces", Properties["IP Address"], "192.0.2.41")
end

--------------------------------------------------------------------------------
T.section("A host name in IP Address is kept")
--------------------------------------------------------------------------------
do
  local named = fresh({ { profile = RGBW, ip = "wled-shelf.local" } })[1]
  named.mdns = false
  W.run(3000)
  T.eq("connected by name", Properties["Driver Status"], "Connected")
  goDark(named)
  W.Fake.new(RGBW, { ip = "192.0.2.91" })
  W.run(65000)
  T.eq("the name kept", Properties["IP Address"], "wled-shelf.local")
end

T.finish()
