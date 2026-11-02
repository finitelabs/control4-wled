import asyncio

import aiohttp

from conftest import advance, nothing, receive_json
from mock_wled.__main__ import load_profile
from mock_wled.server import Instance


async def test_button_toggles_and_pushes(mock, clock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/button")
    await advance(inst, clock, 20)
    assert (await receive_json(ws))["state"]["on"] is False


async def test_button_preset(mock, clock):
    inst, client = await mock()
    await client.post("/_mock/button", json={"preset": 2})
    await advance(inst, clock, 40)
    assert inst.device.serialize_state()["ps"] == 2


async def test_another_client_change_is_pushed(mock, clock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/client", json={"seg": [{"id": 0, "fx": 9}]})
    await advance(inst, clock, 20)
    assert (await receive_json(ws))["state"]["seg"][0]["fx"] == 9


async def test_live_data_is_not_pushed_and_lights_an_off_strip(mock, clock):
    inst, client = await mock()
    await client.post("/json/state", json={"on": False, "tt": 0})
    await advance(inst, clock, 1100)
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/live", json={"mode": "ddp", "ip": "192.0.2.50"})
    await advance(inst, clock, 1100)
    info = await (await client.get("/json/info")).json()
    assert info["live"] is True and info["lm"] == "DDP" and info["lip"] == "192.0.2.50"
    assert (await (await client.get("/json/state")).json())["on"] is False
    assert (await (await client.get("/_mock/output")).json())["bri"] == 128
    assert await nothing(ws)
    await client.post("/json/state", json={"lor": 1})
    await client.post("/_mock/live_stop")
    await advance(inst, clock, 2000)
    assert (await (await client.get("/json/info")).json())["live"] is True
    await advance(inst, clock, 600)
    info = await (await client.get("/json/info")).json()
    state = await (await client.get("/json/state")).json()
    assert info["live"] is False and state["lor"] == 0


async def test_white_mode_change_shows_in_capabilities(mock):
    inst, client = await mock("esp32-rgbw-015")
    await client.post("/_mock/white", json={"bus": 0, "rgbwm": 1})
    info = await (await client.get("/json/info")).json()
    assert info["leds"]["lc"] == 1


async def test_busy_control(mock):
    inst, client = await mock("esp32-rgbw-015")
    await client.post("/_mock/busy", json={"ms": 4000})
    assert (await client.get("/json/state")).status == 503


async def test_reboot_drops_sockets_and_resets_state():
    profile = load_profile("esp32-rgbw-pwm-16")
    inst = Instance(profile, host="127.0.0.1", port=0, tick_ms=5)
    await inst.start()
    base = f"http://127.0.0.1:{inst.port}"
    try:
        async with aiohttp.ClientSession() as s:
            await s.post(f"{base}/json/state", json={"bri": 30, "psave": 20, "ib": True})
            await asyncio.sleep(0.05)
            ws = await s.ws_connect(f"{base}/ws")
            await ws.receive(timeout=1)
            await s.post(f"{base}/_mock/reboot", json={"down_ms": 300})
            msg = await ws.receive(timeout=2)
            assert msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR)
            await asyncio.sleep(0.1)
            try:
                await s.get(f"{base}/json/state")
                refused = False
            except aiohttp.ClientConnectionError:
                refused = True
            assert refused
            await asyncio.sleep(0.4)
            state = await (await s.get(f"{base}/json/state")).json()
            info = await (await s.get(f"{base}/json/info")).json()
            presets = await (await s.get(f"{base}/presets.json")).json()
            assert state["bri"] == 128 and info["uptime"] == 0 and "20" in presets
    finally:
        await inst.stop()


async def test_drop_kills_sockets_without_a_close_frame(mock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/drop")
    msg = await ws.receive(timeout=1)
    assert msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR)
