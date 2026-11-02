import asyncio
import time


async def test_endpoints(mock):
    inst, client = await mock()
    for path, kind in (
        ("/json", dict),
        ("/json/state", dict),
        ("/json/info", dict),
        ("/json/si", dict),
        ("/json/eff", list),
        ("/json/pal", list),
        ("/json/fxdata", list),
        ("/json/nodes", dict),
        ("/presets.json", dict),
        ("/json/cfg", dict),
    ):
        r = await client.get(path)
        assert r.status == 200, path
        assert isinstance(await r.json(), kind), path
        assert r.headers["Access-Control-Allow-Origin"] == "*"
    body = await (await client.get("/json")).json()
    assert set(body) == {"state", "info", "effects", "palettes"}
    assert len(body["effects"]) == 220 and len(body["palettes"]) == 72


async def test_unknown_path_and_bad_json(mock):
    inst, client = await mock()
    r = await client.get("/json/whatever")
    assert r.status == 501 and await r.json() == {"error": 4}
    r = await client.post("/json/state", data="{nope")
    assert r.status == 400 and await r.json() == {"error": 9}


async def test_post_replies(mock):
    inst, client = await mock()
    r = await client.post("/json/state", json={"bri": 50})
    assert await r.json() == {"success": True}
    r = await client.post("/json/si", json={"bri": 51, "v": True})
    assert set(await r.json()) == {"state", "info"}


async def test_015_answers_503_while_busy(mock):
    inst, client = await mock("esp32-rgbw-015")
    inst.device.make_busy(5000)
    r = await client.get("/json/state")
    assert r.status == 503 and await r.json() == {"error": 3}
    assert r.headers["Retry-After"] == "1"
    r = await client.get("/json/pal")
    assert r.status == 200


async def test_16_holds_the_request_until_the_buffer_is_free(mock, clock):
    inst, client = await mock()
    inst.device.make_busy(5000)
    task = asyncio.ensure_future(client.get("/json/state"))
    await asyncio.sleep(0.05)
    assert not task.done()
    clock.advance(5000)
    r = await asyncio.wait_for(task, 1)
    assert r.status == 200


async def test_short_busy_waits_and_answers(mock):
    inst, client = await mock("esp32-rgbw-015")
    inst.device.busy_until = inst.device.now() + 100
    r = await client.get("/json/state")
    assert r.status == 200


async def test_015_esp8266_http_refuses_at_once(mock):
    inst, client = await mock("esp8266-ws2812b-015")
    inst.device.make_busy(100)
    started = time.monotonic()
    r = await client.get("/json/state")
    assert r.status == 503 and await r.json() == {"error": 3}
    assert time.monotonic() - started < 0.1


async def test_015_esp32_waits_250_ms_before_refusing(mock):
    inst, client = await mock("esp32-rgbw-015")
    inst.device.make_busy(800)
    started = time.monotonic()
    r = await client.get("/json/state")
    assert r.status == 503 and await r.json() == {"error": 3}
    assert time.monotonic() - started >= 0.24


async def test_015_fxdata_uses_the_buffer_but_16_streams_it(mock):
    inst, client = await mock("esp32-rgbw-015")
    inst.device.make_busy(5000)
    assert (await client.get("/json/fxdata")).status == 503
    inst, client = await mock()
    inst.device.make_busy(5000)
    assert (await client.get("/json/fxdata")).status == 200


async def test_options_preflight(mock):
    inst, client = await mock()
    r = await client.options("/json/state")
    assert r.status == 200 and r.headers["Access-Control-Max-Age"] == "7200"
