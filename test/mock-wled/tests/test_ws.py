import asyncio
import json

from conftest import advance, nothing, receive_json


async def test_connect_sends_state_and_info(mock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    first = await receive_json(ws)
    assert set(first) == {"state", "info"} and first["info"]["ws"] == 1


async def test_change_gets_no_reply_then_one_push_with_the_latest_state(mock, clock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await ws.send_str(json.dumps({"bri": 60}))
    await advance(inst, clock, 20)
    push = await receive_json(ws)
    assert push["state"]["bri"] == 60
    await ws.send_str(json.dumps({"bri": 70}))
    await ws.send_str(json.dumps({"bri": 80}))
    await advance(inst, clock, 500)
    assert await nothing(ws)
    await advance(inst, clock, 600)
    push = await receive_json(ws)
    assert push["state"]["bri"] == 80


async def test_no_op_gets_success_and_v_gets_state(mock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await ws.send_str(json.dumps({"bri": 128}))
    assert await receive_json(ws) == {"success": True}
    await ws.send_str('{"v":true}')
    assert set(await receive_json(ws)) == {"state", "info"}


async def test_ping(mock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await ws.send_str("p")
    assert (await ws.receive(timeout=1)).data == "pong"


async def test_message_over_one_frame_is_refused(mock):
    inst, client = await mock("esp8266-ws2812b-015")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await ws.send_str(json.dumps({"seg": [{"id": 0, "n": "x" * 600}]}))
    assert await receive_json(ws) == {"error": 9}


async def test_esp8266_keeps_three_clients_and_closes_the_oldest(mock, clock):
    inst, client = await mock("esp8266-ws2812b-015")
    sockets = []
    for _ in range(4):
        ws = await client.ws_connect("/ws")
        await receive_json(ws)
        sockets.append(ws)
    await advance(inst, clock, 20)
    msg = await sockets[0].receive(timeout=1)
    assert msg.type.name in ("CLOSE", "CLOSED", "CLOSING")
    assert len(inst.clients) == 3


async def test_busy_buffer_on_esp8266_ws_command(mock, clock):
    inst, client = await mock("esp8266-ws2812b-015")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    inst.device.make_busy(100)
    await ws.send_str(json.dumps({"bri": 10}))
    assert await receive_json(ws) == {"error": 3}


async def test_push_replaced_by_error_3_when_buffer_stays_busy(mock, clock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/client", json={"bri": 33})
    inst.device.make_busy(5000)
    await advance(inst, clock, 20)
    assert await receive_json(ws) == {"error": 3}


async def test_overload_closes_everyone_with_1013(mock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/overload")
    msg = await ws.receive(timeout=1)
    assert msg.type.name == "CLOSE" and msg.data == 1013


async def test_verbose_post_holds_the_push_back(mock, clock):
    inst, client = await mock()
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    r = await client.post("/json/state", json={"bri": 44, "v": True})
    assert (await r.json())["bri"] == 44
    await advance(inst, clock, 900)
    await asyncio.sleep(0)
    await advance(inst, clock, 200)
    push = await receive_json(ws)
    assert push["state"]["bri"] == 44
