--- The transport against a fake controller on a virtual clock: the socket's first state,
--- commands, WLED's text ping, reconnect waits, HTTP while the socket is down, busy answers,
--- a 1013 close, the frame limit and one HTTP request in flight.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_wled_client.lua

local T = require("testlib")
local W = require("wled_fixtures")
local Client = require("wled.client")

-- The vendored WebSocket module logs every frame at Ultra.
DEBUG_WEBSOCKET = false

-- A new address per test: the WebSocket module keeps a socket per URL until its close finishes.
local nextHost = 10

local function newClient(profile, opts)
  W.reset()
  nextHost = nextHost + 1
  opts = opts or {}
  opts.ip = opts.ip or ("192.0.2." .. nextHost)
  local fake = W.Fake.new(profile or "esp32-rgbw-pwm-16", opts)
  local log = { states = {}, online = 0, offline = {} }
  local client = Client:new({
    http = W.http,
    onState = function(state, info)
      log.states[#log.states + 1] = { state = state, info = info, at = W.now() }
    end,
    onOnline = function()
      log.online = log.online + 1
    end,
    onOffline = function(reason)
      log.offline[#log.offline + 1] = reason
    end,
  })
  return client, fake, log
end

local function count(list, pred)
  local n = 0
  for _, v in ipairs(list) do
    if pred(v) then
      n = n + 1
    end
  end
  return n
end

local function posts(fake)
  return count(fake.requests, function(r)
    return r.method == "POST"
  end)
end

--------------------------------------------------------------------------------
T.section("The socket opens and the controller's first state arrives")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  T.eq("over the socket", client.mode, "ws")
  T.eq("online once", log.online, 1)
  T.eq("one state", #log.states, 1)
  T.eq("state carries info", log.states[1].info.mac, "02a1b2c3d402")
  T.eq("no HTTP needed", #fake.requests, 0)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A command goes over the socket and the change comes back as a push")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local sent
  client:send({ on = false }):next(function(v)
    sent = v
  end)
  W.run(10)
  T.truthy("resolved once sent", sent)
  T.eq("the controller got it", fake.commands[1] and fake.commands[1].on, false)
  W.run(1100)
  T.eq("pushed back", #log.states, 2)
  T.eq("the push shows the change", log.states[2].state.on, false)
  T.eq("not over HTTP", posts(fake), 0)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("WLED's text ping every 30 s keeps the socket")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  W.run(Client.PING_MS * 3)
  T.eq("three pings", fake.pings, 3)
  T.eq("still on the socket", client.mode, "ws")
  T.eq("connected once", fake.connects, 1)
  T.eq("never offline", #log.offline, 0)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Two unanswered pings close the socket; offline when HTTP fails too")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  -- A half-open link: the socket stays up but nothing answers, HTTP included.
  fake.ignorePings, fake.reachable = true, false
  W.run(Client.PING_MS * 2 + 100)
  T.eq("two pings unanswered, still counted connected", client.mode, "ws")
  T.eq("not offline after two", #log.offline, 0)
  W.run(Client.PING_MS)
  T.eq("third interval closes it", client.socketUp, false)
  W.run(100)
  T.eq("offline once HTTP fails", client.mode, "offline")
  T.eq("told offline once", #log.offline, 1)
  T.contains("reason names the silence", log.offline[1], "No answer")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Reconnect waits grow and stop at 30 s")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local attempts = {}
  local onConnect = fake.onConnect
  function fake:onConnect(binding)
    attempts[#attempts + 1] = W.now()
    return onConnect(self, binding)
  end
  fake.reachable = false
  fake:drop()
  W.run(200000)
  local gaps = {}
  for i = 2, #attempts do
    gaps[#gaps + 1] = attempts[i] - attempts[i - 1]
  end
  T.truthy("several attempts", #attempts >= 6, #attempts)
  local grows = true
  for i = 2, #gaps do
    if gaps[i] + 10 < gaps[i - 1] then
      grows = false
    end
  end
  T.truthy("waits never shrink", grows, table.concat(gaps, ","))
  local capped = true
  for _, g in ipairs(gaps) do
    if g > Client.RECONNECT_MAX_MS + 100 then
      capped = false
    end
  end
  T.truthy("waits capped at 30 s", capped, table.concat(gaps, ","))
  T.truthy("reaches the cap", gaps[#gaps] >= Client.RECONNECT_MAX_MS, gaps[#gaps])

  fake.reachable = true
  W.run(Client.RECONNECT_MAX_MS + 1000)
  T.eq("back on the socket", client.mode, "ws")
  local before = #attempts
  fake:drop()
  W.run(4000)
  T.eq("wait starts over after a success", #attempts, before + 1)
  T.eq("reconnected at once", client.mode, "ws")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Socket refused, HTTP answers: state by polling, commands by POST")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  fake.socketOpen = false
  client:start(fake.ip, fake.port)
  W.run(Client.OPEN_GRACE_MS + 100)
  T.eq("reached over HTTP", client.mode, "http")
  T.eq("online once", log.online, 1)
  T.eq("state from /json/si", log.states[1] and log.states[1].info.ver, "16.0.1")
  client:send({ bri = 40 })
  W.run(50)
  T.eq("command POSTed", posts(fake), 1)
  T.eq("controller took it", fake.si.state.bri, 40)
  local polls = count(fake.requests, function(r)
    return r.path == "/json/si"
  end)
  W.run(Client.POLL_MS * 2)
  T.eq(
    "polls every 10 s",
    count(fake.requests, function(r)
      return r.path == "/json/si"
    end),
    polls + 2
  )
  fake.socketOpen = true
  W.run(Client.RECONNECT_MAX_MS + 4000)
  T.eq("back on the socket", client.mode, "ws")
  local after = #fake.requests
  W.run(Client.SOCKET_POLL_MS * 2)
  T.eq("the 10 s poll stops with the socket; the 15 s one goes on", #fake.requests, after + 2)
  T.eq("never offline", #log.offline, 0)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A busy controller is retried with growing waits")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake.busy = 2
  local got, failed
  client:get("/json/eff"):next(function(v)
    got = v
  end, function(e)
    failed = e
  end)
  W.run(Client.BUSY_FIRST_MS + 20)
  T.eq("first answer busy, retried once so far", #fake.requests, 2)
  T.falsy("not yet", got)
  W.run(Client.BUSY_FIRST_MS * 2 + 20)
  T.eq("second retry", #fake.requests, 3)
  T.eq("then the list", got and got[1], "Solid")
  T.falsy("no failure", failed)

  fake.busy = 100
  got, failed = nil, nil
  client:get("/json/pal"):next(function(v)
    got = v
  end, function(e)
    failed = e
  end)
  W.run(20000)
  T.falsy("never answered", got)
  T.eq("gives up as busy", failed and failed.error, "busy")
  T.eq(
    "tried 1 + 5 times",
    count(fake.requests, function(r)
      return r.path == "/json/pal"
    end),
    1 + Client.BUSY_RETRIES
  )
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A busy answer on the socket resends the command")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake.wsBusy = 1
  client:send({ on = false })
  W.run(20)
  T.eq("first try refused", #fake.commands, 0)
  W.run(Client.BUSY_FIRST_MS + 20)
  T.eq("resent and taken", #fake.commands, 1)
  T.eq("same command", fake.commands[1].on, false)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A busy answer sends every recent command again, in order")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local bri = fake.si.state.bri
  fake.wsBusy = 1
  client:send({ bri = 40 })
  client:send({ on = true })
  W.run(20)
  T.eq("the first refused, the second taken", { #fake.commands, fake.si.state.bri }, { 1, bri })
  W.run(Client.BUSY_FIRST_MS + 20)
  T.eq("the refused one sent again and taken", fake.si.state.bri, 40)
  T.eq("then the one after it, so the latest still stands", fake.commands[#fake.commands], { on = true })
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A command sent while a busy resend waits is kept, and still comes last")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake.wsBusy = 1
  client:send({ bri = 40 })
  W.run(50)
  client:send({ bri = 80 })
  W.run(Client.BUSY_FIRST_MS + 100)
  T.eq("one taken during the wait stays the latest", fake.si.state.bri, 80)
  client:stop()

  client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake.wsBusy = 1
  client:send({ bri = 40 })
  W.run(50)
  fake.wsBusy = 1
  client:send({ bri = 80 })
  W.run(Client.BUSY_FIRST_MS + 100)
  T.eq("one refused during the wait is sent again too, last", fake.si.state.bri, 80)
  client:stop()

  -- The last busy wait (4 s) is longer than the window: a command refused early in it is still sent.
  client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake.wsBusy = 5
  client:send({ bri = 40 })
  W.run(3900)
  fake.wsBusy = 1
  client:send({ nl = { on = true } })
  W.run(2400)
  client:send({ bri = 90 })
  W.run(3000)
  local wire = {}
  for _, payload in ipairs(fake.wire) do
    wire[#wire + 1] = payload:match('"nl"') and "nl" or payload:match('"bri":(%d+)')
  end
  T.eq(
    "all three on the wire, in order, at the end",
    { wire[#wire - 2], wire[#wire - 1], wire[#wire] },
    { "40", "nl", "90" }
  )
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Commands dropped by a busy controller: its state is asked for")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local bri = fake.si.state.bri
  local before = #log.states
  fake.wsBusy = 100
  client:send({ bri = 40 })
  -- The resends give up after about 8 s, before the 15 s poll.
  W.run(12000)
  T.eq("never taken", fake.si.state.bri, bri)
  T.eq(
    "the state asked for",
    count(fake.requests, function(r)
      return r.path == "/json/si"
    end),
    1
  )
  T.eq("and reported as the controller shows it", log.states[#log.states].state.bri, bri)
  T.eq("once", #log.states, before + 1)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A poll answer asked for before a write is not reported")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  fake.socketOpen = false
  client:start(fake.ip, fake.port)
  W.run(Client.OPEN_GRACE_MS + 100)
  T.eq("over HTTP", client.mode, "http")
  local before = #log.states
  -- A poll goes out, then a write queues behind it.
  client:startPolling(client.gen)
  client:send({ bri = 40 })
  W.run(100)
  local told = {}
  for i = before + 1, #log.states do
    told[#told + 1] = log.states[i].state.bri
  end
  T.eq("only the state after the write is reported", told, { 40 })
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A socket that never finishes its upgrade is tried again")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  fake.noUpgrade = true
  client:start(fake.ip, fake.port)
  W.run(Client.CONNECT_TIMEOUT_MS - 100)
  T.eq("one try while it waits", fake.connects, 1)
  W.run(Client.RECONNECT_MAX_MS)
  T.eq("then tried again", fake.connects > 1, true)
  fake.noUpgrade = false
  W.run(Client.RECONNECT_MAX_MS + Client.CONNECT_TIMEOUT_MS)
  T.eq("and on the socket once it answers", client.mode, "ws")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Stop cancels every timer the client set")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local function mine()
    local n = 0
    for name in pairs(Timer) do
      if tostring(name):match("^WledClient") then
        n = n + 1
      end
    end
    return n
  end
  T.eq("its timers are named as its own", mine() > 0, true)
  client:stop()
  T.eq("none left after stop", mine(), 0)
end

--------------------------------------------------------------------------------
T.section("A socket that cannot be made or closed does not stop the client")
--------------------------------------------------------------------------------
do
  local function socket(url)
    local ws = { url = url }
    for _, name in ipairs({
      "SetEstablishedFunction",
      "SetProcessMessageFunction",
      "SetClosedByRemoteFunction",
      "SetOfflineFunction",
      "Start",
    }) do
      ws[name] = function() end
    end
    function ws:delete()
      error("socket gone")
    end
    return ws
  end
  W.reset()
  local client = Client:new({
    http = W.http,
    WebSocket = {
      new = function(_, url)
        return socket(url)
      end,
    },
  })
  client:start("192.0.2.200", 80)
  W.run(10)
  local closed
  local ok = pcall(function()
    client:closeSocket():next(function()
      closed = true
    end)
  end)
  T.truthy("a close that throws does not raise", ok)
  T.truthy("and still finishes", closed)
  client:stop()

  local tries = 0
  local broken = Client:new({
    http = W.http,
    WebSocket = {
      new = function()
        tries = tries + 1
        error("no sockets")
      end,
    },
  })
  T.truthy("a socket that cannot be made does not raise", pcall(broken.start, broken, "192.0.2.201", 80))
  W.run(Client.RECONNECT_MAX_MS)
  T.eq("and is tried again later", tries > 1, true)
  broken:stop()
end

--------------------------------------------------------------------------------
T.section("An error in a pushed state reaches Cloud Monitoring")
--------------------------------------------------------------------------------
do
  W.reset()
  local fake = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2.202" })
  local diagnostics = require("lib.diagnostics")
  local capture = diagnostics.captureError
  local sources = {}
  diagnostics.captureError = function(_, _message, _traceback, source)
    sources[#sources + 1] = source
  end
  local client = Client:new({
    http = W.http,
    onState = function()
      error("broken handler")
    end,
  })
  client:start(fake.ip, fake.port)
  W.run(100)
  T.eq("reported with its source", sources[1], "WLED.WsMessage")
  client:refresh()
  W.run(100)
  diagnostics.captureError = capture
  T.eq("and one in a state it asked for", sources[#sources], "WLED.Refresh")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A 1013 close reconnects after a wait, without going offline")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  fake:close(1013)
  W.run(20)
  T.eq("socket down", client.socketUp, false)
  W.run(100)
  T.eq("HTTP keeps it online", client.mode, "http")
  W.run(5000)
  T.eq("reconnected", client.mode, "ws")
  T.eq("second connection", fake.connects, 2)
  T.eq("never offline", #log.offline, 0)
  T.eq("online told once", log.online, 1)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A command too big for one ESP8266 frame goes over HTTP")
--------------------------------------------------------------------------------
do
  local client, fake = newClient("esp8266-ws2812b-015")
  client:start(fake.ip, fake.port)
  W.run(100)
  client:send({ bri = 100 })
  W.run(20)
  T.eq("short one on the socket", posts(fake), 0)
  local seg = {}
  for i = 0, 15 do
    seg[#seg + 1] = { id = i, col = { { 255, 128, 0 }, { 0, 0, 0 }, { 0, 0, 0 } } }
  end
  client:send({ seg = seg })
  W.run(50)
  T.eq("long one POSTed", posts(fake), 1)

  local big, bigFake = newClient("esp32-rgbw-pwm-16")
  big:start(bigFake.ip, bigFake.port)
  W.run(100)
  big:send({ seg = seg })
  W.run(50)
  T.eq("an ESP32 takes the same command in one frame", posts(bigFake), 0)
  big:stop()
  client:stop()
end

--------------------------------------------------------------------------------
T.section("One HTTP request in flight")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local order = {}
  client:get("/json/eff"):next(function()
    order[#order + 1] = "eff"
  end)
  client:get("/json/pal"):next(function()
    order[#order + 1] = "pal"
  end)
  client:get("/presets.json"):next(function()
    order[#order + 1] = "presets"
  end)
  T.eq("only the first sent", #fake.requests, 1)
  W.run(100)
  T.eq("all answered in order", table.concat(order, ","), "eff,pal,presets")
  T.eq("three requests", #fake.requests, 3)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Stop drops queued requests and tells nothing")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local rejected = 0
  for _ = 1, 3 do
    client:get("/json/eff"):next(nil, function(e)
      if e.error == "stopped" then
        rejected = rejected + 1
      end
    end)
  end
  client:stop()
  W.run(60000)
  T.eq("queued requests rejected", rejected, 3)
  T.eq("no offline after stop", #log.offline, 0)
  T.eq("waiting for a start", client.mode, "starting")
  T.eq("not online", client.mode ~= "ws" and client.mode ~= "http", true)
  T.eq("no reconnect", fake.connects, 1)
end

--------------------------------------------------------------------------------
T.section("A controller that never answers is reported offline, and polls never pile up")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  fake.reachable = false
  fake.timeoutMs = 10000
  client:start(fake.ip, fake.port)
  W.run(30000)
  T.eq("told offline once", #log.offline, 1)
  T.eq("never online", log.online, 0)
  T.eq("offline mode", client.mode, "offline")
  local idle = 0
  for _ = 1, 60 do
    W.run(1000)
    if not client.inFlight and #client.queue == 0 then
      idle = idle + 1
    end
  end
  T.eq("the queue empties between polls that time out", idle > 0, true)
  client:stop()
end

local function has(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function siRequests(fake)
  return count(fake.requests, function(r)
    return r.path == "/json/si"
  end)
end

--- Swap Cloud Monitoring's capture for a recorder; returns the sources seen and a restore.
local function recordCaptures()
  local diagnostics = require("lib.diagnostics")
  local capture = diagnostics.captureError
  local sources = {}
  diagnostics.captureError = function(_, _message, _traceback, source)
    sources[#sources + 1] = source
  end
  return sources, function()
    diagnostics.captureError = capture
  end
end

--------------------------------------------------------------------------------
T.section("A socket the module cannot make, start or close reaches Cloud Monitoring")
--------------------------------------------------------------------------------
do
  local function socket(url, failStart, failDelete)
    local ws = { url = url }
    for _, name in ipairs({
      "SetEstablishedFunction",
      "SetProcessMessageFunction",
      "SetClosedByRemoteFunction",
      "SetOfflineFunction",
    }) do
      ws[name] = function() end
    end
    function ws:Start()
      if failStart then
        error("no start")
      end
    end
    function ws:delete(done)
      if failDelete then
        error("socket gone")
      end
      if done then
        done()
      end
    end
    return ws
  end
  local function clientWith(new)
    W.reset()
    return Client:new({ http = W.http, WebSocket = { new = new } })
  end

  local sources, restore = recordCaptures()
  local raising = clientWith(function()
    error("no sockets")
  end)
  raising:start("192.0.2.210", 80)
  W.run(10)
  raising:stop()
  T.truthy("a socket the module cannot make", has(sources, "WLED.WsNew"))

  local declined = clientWith(function()
    return nil, "refused"
  end)
  local before = #sources
  declined:start("192.0.2.211", 80)
  W.run(10)
  declined:stop()
  T.eq("a socket the module declines is no fault", #sources, before)

  local unstarted = clientWith(function(_, url)
    return socket(url, true, false)
  end)
  unstarted:start("192.0.2.212", 80)
  W.run(10)
  unstarted:stop()
  T.truthy("a socket that cannot start", has(sources, "WLED.WsStart"))

  local unclosed = clientWith(function(_, url)
    return socket(url, false, true)
  end)
  unclosed:start("192.0.2.213", 80)
  W.run(10)
  unclosed:stop()
  restore()
  T.truthy("a socket that cannot close", has(sources, "WLED.WsDelete"))
end

--------------------------------------------------------------------------------
T.section("An error in the driver's online or offline handler is reported, and polling goes on")
--------------------------------------------------------------------------------
do
  W.reset()
  local fake = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2.214" })
  fake.socketOpen, fake.reachable = false, false
  local sources, restore = recordCaptures()
  local client = Client:new({
    http = W.http,
    onOnline = function()
      error("broken online handler")
    end,
    onOffline = function()
      error("broken offline handler")
    end,
  })
  client:start(fake.ip, fake.port)
  W.run(Client.OPEN_GRACE_MS + 100)
  T.eq("offline", client.mode, "offline")
  T.truthy("the offline handler's error is reported", has(sources, "WLED.Offline"))
  local polls = siRequests(fake)
  fake.reachable = true
  W.run(Client.POLL_MS + 100)
  restore()
  T.truthy("polling goes on", siRequests(fake) > polls)
  T.truthy("the online handler's error is reported", has(sources, "WLED.Online"))
  T.eq("and the controller is reached over HTTP", client.mode, "http")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A refresh after an outage reports the controller reachable before its state")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  fake.socketOpen, fake.reachable = false, false
  client:start(fake.ip, fake.port)
  W.run(Client.OPEN_GRACE_MS + 100)
  T.eq("offline while the controller is away", client.mode, "offline")
  local seen = {}
  client.onState = function()
    seen[#seen + 1] = { mode = client.mode, online = log.online }
  end
  fake.reachable = true
  client:refresh()
  W.run(100)
  T.eq("the refresh answers before the next poll", #seen, 1)
  T.eq("told online first", seen[1] and seen[1].online, 1)
  T.eq("reached over HTTP", seen[1] and seen[1].mode, "http")
  client:stop()
end

--------------------------------------------------------------------------------
T.section("A command too big for a frame that cannot be POSTed: its state is asked for")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  client:send({ bri = 40 })
  W.run(20)
  fake.busy = 100
  client:onMessage('{"error":9}')
  W.run(20000)
  T.eq("the POST was tried", posts(fake) > 0, true)
  T.eq("then the state asked for", siRequests(fake) > 0, true)
  client:stop()

  local stopped, stoppedFake = newClient()
  stopped:start(stoppedFake.ip, stoppedFake.port)
  W.run(100)
  stopped:send({ bri = 40 })
  W.run(20)
  stoppedFake.busy = 100
  stopped:onMessage('{"error":9}')
  W.run(10)
  stopped:stop()
  W.run(20000)
  T.eq("not after a stop", siRequests(stoppedFake), 0)
end

--------------------------------------------------------------------------------
T.section("A command asking for the state back gets it, though WLED pushes the change to no one")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  fake.si.state.pl = 3
  client:start(fake.ip, fake.port)
  W.run(100)
  local main = fake.si.state.seg[1]
  local seen = #log.states
  client:send({ seg = { { id = main.id, fx = "~0" } } })
  W.run(2000)
  T.eq("a playlist ended by an effect kept as it is is pushed to no one", #log.states, seen)
  T.eq("though it ended", fake.si.state.pl, -1)

  fake.si.state.pl = 3
  client:send({ seg = { { id = main.id, fx = "~0" } }, v = true })
  W.run(50)
  T.eq("with v the socket answers at once", #log.states, seen + 1)
  T.eq("with the ended playlist", log.states[#log.states].state.pl, -1)

  local before = #log.states
  client:send({ bri = fake.si.state.bri })
  W.run(2000)
  T.eq("a command that changes nothing is pushed to no one", #log.states, before)
  client:stop()

  local http, httpFake, httpLog = newClient()
  httpFake.socketOpen = false
  httpFake.si.state.pl = 3
  http:start(httpFake.ip, httpFake.port)
  W.run(Client.OPEN_GRACE_MS + 100)
  T.eq("reached over HTTP", http.mode, "http")
  local polled = #httpLog.states
  http:send({ seg = { { id = main.id, fx = "~0" } }, v = true })
  W.run(50)
  T.eq("over HTTP the answer is the state, before the next poll", #httpLog.states, polled + 1)
  local last = httpLog.states[#httpLog.states]
  T.eq("with the ended playlist, and no info", { last.state.pl, last.info == nil }, { -1, true })

  local answers = #httpLog.states
  httpFake.si.state.pl = 3
  http:send({ seg = { { id = main.id, fx = "~0" } }, v = true })
  http:send({ bri = 80 })
  W.run(50)
  T.eq("an answer a later write overtook is dropped", #httpLog.states, answers)
  T.eq("though the controller took both", { httpFake.si.state.pl, httpFake.si.state.bri }, { -1, 80 })
  http:stop()
end

--------------------------------------------------------------------------------
T.section("While the socket is up, the state is asked for every 15 s and reported as a push")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  local function siRequests()
    return count(fake.requests, function(r)
      return r.path == "/json/si"
    end)
  end
  client:start(fake.ip, fake.port)
  W.run(100)
  T.eq("on the socket", client.mode, "ws")
  local seen = #log.states
  -- WLED pushes nothing when live data from another system starts.
  fake:changeSilently(nil, { live = true, lm = "E1.31", lip = "192.0.2.200" })
  W.run(Client.SOCKET_POLL_MS - 200)
  T.eq("nothing asked for before 15 s", siRequests(), 0)
  W.run(400)
  T.eq("then once", siRequests(), 1)
  T.eq("and its answer reported", #log.states, seen + 1)
  T.eq("with what WLED never pushed", log.states[#log.states].info.live, true)
  W.run(Client.SOCKET_POLL_MS * 4)
  T.eq("every 15 s after", siRequests(), 5)
  T.eq("still on the socket, never offline", { client.mode, #log.offline }, { "ws", 0 })
  client:stop()
  W.run(Client.SOCKET_POLL_MS * 2)
  T.eq("none after a stop", siRequests(), 5)
end

--------------------------------------------------------------------------------
T.section("The 15 s poll waits for a request under way and a command just sent, then tries again in 2 s")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  local function siRequests()
    return count(fake.requests, function(r)
      return r.path == "/json/si"
    end)
  end
  client:start(fake.ip, fake.port)
  W.run(100)
  -- A list read that takes 20 s holds the one HTTP slot through the first poll's turn.
  fake.reachable, fake.timeoutMs = false, 20000
  client:get("/presets.json")
  W.run(Client.SOCKET_POLL_MS + 1000)
  T.eq("no poll while a request is under way", siRequests(), 0)
  -- A poll queued behind the read would go out the moment it ends, at 20.1 s.
  W.run(4500)
  T.eq("none queued behind it either", siRequests(), 0)
  fake.reachable = true
  W.run(1000)
  T.eq("polled within 2 s of the read ending, not a whole turn later", siRequests(), 1)

  -- A command a moment before the next turn, 15 s after the last answer, holds it off 2 s.
  W.run(log.states[#log.states].at + Client.SOCKET_POLL_MS - 300 - W.now())
  client:send({ bri = 60 })
  W.run(1000)
  T.eq("no poll just after a command", siRequests(), 1)
  W.run(2000)
  T.eq("then it polls", siRequests(), 2)
  client:stop()
end

--- Run in 10 ms steps until the fake has one more /json/si request than `seen`.
local function untilPoll(fake, seen)
  for _ = 1, 4000 do
    if
      count(fake.requests, function(r)
        return r.path == "/json/si"
      end) > seen
    then
      return
    end
    W.run(10)
  end
end

--------------------------------------------------------------------------------
T.section("A poll answer that a write or a push overtook is not reported")
--------------------------------------------------------------------------------
do
  local client, fake, log = newClient()
  client:start(fake.ip, fake.port)
  W.run(100)
  local old = fake.si.state.bri
  -- The answer is built when the poll asks and arrives 500 ms later.
  fake.slowGetMs = 500
  untilPoll(fake, 0)
  local seen = #log.states
  client:send({ bri = 90 })
  W.run(2000)
  local olds = 0
  for i = seen + 1, #log.states do
    if log.states[i].state and log.states[i].state.bri == old then
      olds = olds + 1
    end
  end
  T.eq("after a write, the older answer never reports the old level", olds, 0)
  T.eq("the write's push stands", log.states[#log.states].state.bri, 90)

  -- Another client's change is pushed before the poll's answer lands.
  fake.slowGetMs = 3000
  untilPoll(fake, 1)
  fake:change({ bri = 77 })
  W.run(4000)
  T.eq("after a push, the older answer does not take its place", log.states[#log.states].state.bri, 77)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("The poll waits while a busy resend waits")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  local function siRequests()
    return count(fake.requests, function(r)
      return r.path == "/json/si"
    end)
  end
  client:start(fake.ip, fake.port)
  W.run(100)
  -- Five busy answers: resends at 0.25, 0.75, 1.75, 3.75 and 7.75 s, so from 5.75 s no command
  -- is recent while the last wait runs. The poll's turn falls in that gap.
  W.run(Client.SOCKET_POLL_MS - 6500)
  fake.wsBusy = 5
  client:send({ bri = 80 })
  W.run(7000)
  T.eq("no poll during the wait", siRequests(), 0)
  W.run(5000)
  T.eq("it polls once the resend went through", siRequests(), 1)
  T.eq("and the command was taken", fake.si.state.bri, 80)
  client:stop()
end

--------------------------------------------------------------------------------
T.section("An error in the driver's handler does not end the poll")
--------------------------------------------------------------------------------
do
  W.reset()
  nextHost = nextHost + 1
  local fake = W.Fake.new("esp32-rgbw-pwm-16", { ip = "192.0.2." .. nextHost })
  local client = Client:new({
    http = W.http,
    onState = function()
      error("handler failed")
    end,
  })
  client:start(fake.ip, fake.port)
  W.run(100)
  W.run(Client.SOCKET_POLL_MS * 4 + 500)
  T.eq(
    "four polls in a minute though each answer's handler fails",
    count(fake.requests, function(r)
      return r.path == "/json/si"
    end),
    4
  )
  client:stop()
end

--------------------------------------------------------------------------------
T.section("Reconnects leave one poll running, not one per socket")
--------------------------------------------------------------------------------
do
  local client, fake = newClient()
  local function siRequests()
    return count(fake.requests, function(r)
      return r.path == "/json/si"
    end)
  end
  client:start(fake.ip, fake.port)
  W.run(100)
  for _ = 1, 3 do
    W.run(4000)
    fake:drop()
    W.run(6000)
    T.eq("back on the socket", client.mode, "ws")
  end
  local before = siRequests()
  W.run(Client.SOCKET_POLL_MS * 4)
  T.eq("four polls a minute after three reconnects", siRequests() - before, 4)
  client:stop()
end

T.finish()
