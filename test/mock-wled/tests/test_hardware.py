"""Behavior measured on a real QuinLED dig2go (ESP32, 300 SK6812 RGBW) on 0.15.4 and 16.0.1, 2026-11-10."""

import asyncio
import json

import pytest
from conftest import advance, nothing, receive_json, settle

DIG2GO = ("dig2go-rgbw-015", "dig2go-rgbw-16")


async def state(client):
    return await (await client.get("/json/state")).json()


async def post(client, body):
    return await (await client.post("/json/state", data=json.dumps(body))).json()


async def two_sockets(client):
    a, b = await client.ws_connect("/ws"), await client.ws_connect("/ws")
    await receive_json(a)
    await receive_json(b)
    return a, b


async def drain(ws):
    try:
        while True:
            await ws.receive(timeout=0.05)
    except asyncio.TimeoutError:
        pass


# ---- profiles and boot -----------------------------------------------------------------------


@pytest.mark.parametrize("name", DIG2GO)
def test_dig2go_reports_rgbw_capabilities_and_its_power_limit(device, name):
    d = device(name)
    leds = d.serialize_info()["leds"]
    assert leds["count"] == 300 and leds["lc"] == 3 and leds["seglc"] == [3]
    assert leds["wv"] == 2 and leds["rgbw"] is True and leds["maxpwr"] == 1250


@pytest.mark.parametrize("name", DIG2GO)
def test_restart_comes_back_on_one_unnamed_orange_segment(device, clock, name):
    d = device(name)
    seg = [{"id": i, "start": i * 100, "stop": i * 100 + 100, "n": f"Run {i}"} for i in range(3)]
    d.deserialize_state({"bri": 200, "seg": seg})
    settle(d, clock)
    d.boot()
    settle(d, clock)
    st = d.serialize_state()
    assert st["bri"] == 128 and st["ps"] == -1 and len(st["seg"]) == 1
    s = st["seg"][0]
    assert s["start"] == 0 and s["stop"] == 300 and "n" not in s
    assert s["col"][0] == [255, 160, 0, 0]


def test_presets_file_time_reads_zero_after_a_16_restart(device, clock):
    d = device("dig2go-rgbw-16")
    clock.advance(5000)
    d.deserialize_state({"psave": 4, "n": "Mock Saved", "ib": True, "sb": True})
    d.tick()
    assert d.serialize_info()["fs"]["pmt"] > 0
    d.boot()
    assert d.serialize_info()["fs"]["pmt"] == 0


# ---- white modes -----------------------------------------------------------------------------


@pytest.mark.parametrize("name", DIG2GO)
@pytest.mark.parametrize("rgbwm,lc", [(0, 3), (1, 1), (2, 1), (3, 3), (4, 1)])
def test_white_mode_sets_the_capability_bits(device, clock, name, rgbwm, lc):
    d = device(name)
    d.set_bus(0, rgbwm, at_restart=True)
    d.boot()
    settle(d, clock)
    leds = d.serialize_info()["leds"]
    assert leds["lc"] == lc and leds["seglc"] == [lc] and leds["wv"] == lc & 2
    if d.v16:
        assert d.serialize_state()["seg"][0]["lc"] == lc


def test_white_mode_saved_in_settings_takes_effect_at_the_next_restart(device, clock):
    d = device("dig2go-rgbw-16")
    d.set_bus(0, 2, at_restart=True)
    assert d.serialize_info()["leds"]["lc"] == 3
    d.boot()
    assert d.serialize_info()["leds"]["lc"] == 1


def test_white_mode_change_survives_a_restart(device, clock):
    d = device("dig2go-rgbw-015")
    d.set_bus(0, 2)
    assert d.serialize_info()["leds"]["lc"] == 1
    d.boot()
    assert d.serialize_info()["leds"]["lc"] == 1


# ---- segments --------------------------------------------------------------------------------


def three_runs(d, clock):
    names = ("Left Run", "Island", "Right Run")
    seg = [{"id": i, "start": i * 100, "stop": i * 100 + 100, "n": n} for i, n in enumerate(names)]
    d.deserialize_state({"seg": seg})
    settle(d, clock)


def test_new_bounds_without_a_name_clear_the_name(device, clock):
    d = device("dig2go-rgbw-015")
    three_runs(d, clock)
    d.deserialize_state(
        {"seg": [{"id": 0, "start": 0, "stop": 120}, {"id": 1, "start": 120, "stop": 200}]}
    )
    segs = d.serialize_state()["seg"]
    assert "n" not in segs[0] and "n" not in segs[1] and segs[2]["n"] == "Right Run"


def test_deleting_a_segment_keeps_the_other_ids(device, clock):
    d = device("dig2go-rgbw-015")
    three_runs(d, clock)
    d.deserialize_state({"seg": [{"id": 1, "stop": 0}]})
    settle(d, clock)
    assert [(s["id"], s["start"], s["stop"]) for s in d.serialize_state()["seg"]] == [
        (0, 0, 100),
        (2, 200, 300),
    ]


def test_a_preset_with_fewer_segments_drops_the_rest(device, clock):
    d = device("dig2go-rgbw-015")
    three_runs(d, clock)
    d.deserialize_state({"ps": 1})
    settle(d, clock)
    segs = d.serialize_state()["seg"]
    assert [(s["id"], s["start"], s["stop"]) for s in segs] == [(0, 0, 300)]


# ---- playlists -------------------------------------------------------------------------------


def test_a_posted_playlist_runs_at_once_as_playlist_0(device, clock):
    d = device("dig2go-rgbw-015")
    d.deserialize_state({"playlist": {"ps": [2, 3], "dur": [80, 80]}})
    settle(d, clock, 200)
    st = d.serialize_state()
    assert st["pl"] == 0 and st["ps"] == 2


def test_psave_with_o_stores_the_playlist_and_without_o_the_look(device, clock):
    d = device("dig2go-rgbw-015")
    pl = {"ps": [1, 2], "dur": [80, 80]}
    d.deserialize_state({"psave": 7, "n": "Mock List", "o": True, "playlist": pl})
    settle(d, clock, 200)
    assert d.presets["7"]["playlist"]["ps"] == [1, 2]
    d.deserialize_state({"psave": 8, "n": "Mock Look", "on": True, "playlist": pl})
    settle(d, clock, 200)
    assert "playlist" not in d.presets["8"] and "seg" in d.presets["8"]


def test_an_empty_playlist_stops_one_on_015(device, clock):
    d = device("dig2go-rgbw-015")
    d.deserialize_state({"ps": 5})
    settle(d, clock, 500)
    assert d.serialize_state()["pl"] == 5
    d.deserialize_state({"playlist": {}})
    settle(d, clock, 9000)
    st = d.serialize_state()
    assert st["pl"] == -1 and st["ps"] == 1


def test_an_empty_playlist_stops_one_on_16_only_until_it_has_stopped_one(device, clock):
    # The first stop records the running playlist as a parent; every later one returns early.
    d = device("dig2go-rgbw-16")
    d.deserialize_state({"ps": 5})
    settle(d, clock, 500)
    d.deserialize_state({"playlist": {}})
    settle(d, clock, 500)
    assert d.serialize_state()["pl"] == -1
    d.deserialize_state({"ps": 5})
    settle(d, clock, 500)
    d.deserialize_state({"playlist": {}})
    settle(d, clock, 1500)
    assert d.serialize_state()["pl"] == 5
    settle(d, clock, 8000)
    st = d.serialize_state()
    assert st["pl"] == 5 and st["ps"] == 2


@pytest.mark.parametrize("name", DIG2GO)
def test_setting_the_running_effect_stops_a_playlist_and_keeps_the_look(device, clock, name):
    d = device(name)
    d.deserialize_state({"ps": 5})
    settle(d, clock, 500)
    fx = d.serialize_state()["seg"][0]["fx"]
    d.deserialize_state({"seg": [{"id": 0, "fx": fx}]})
    settle(d, clock, 9000)
    st = d.serialize_state()
    assert st["pl"] == -1 and st["seg"][0]["fx"] == fx
    if d.v16:
        assert st["ps"] == 1


# ---- pushes ----------------------------------------------------------------------------------


async def test_a_fade_pushes_once_and_nothing_while_it_runs(mock, clock):
    inst, client = await mock("dig2go-rgbw-015")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await post(client, {"bri": 30, "tt": 0})
    await advance(inst, clock, 1500)
    await drain(ws)
    await post(client, {"bri": 200, "tt": 30})
    await advance(inst, clock, 50)
    assert (await receive_json(ws))["state"]["bri"] == 200
    await advance(inst, clock, 3500)
    assert await nothing(ws)


@pytest.mark.parametrize(
    "name,stop",
    [
        ("dig2go-rgbw-015", {"playlist": {}, "v": True}),
        ("dig2go-rgbw-16", {"seg": [{"id": 0, "fx": 0}], "v": True}),
    ],
)
async def test_a_stop_with_v_answers_the_sender_alone(mock, clock, name, stop):
    inst, client = await mock(name)
    active, passive = await two_sockets(client)
    await post(client, {"seg": [{"fx": 9}]})
    await advance(inst, clock, 1200)
    await post(client, {"ps": 5})
    await advance(inst, clock, 1200)
    await drain(active)
    await drain(passive)
    await active.send_str(json.dumps(stop))
    await advance(inst, clock, 50)
    reply = await receive_json(active)
    assert reply["state"]["pl"] == -1
    await advance(inst, clock, 1500)
    assert await nothing(passive)


async def test_an_empty_playlist_stop_on_015_pushes_nothing(mock, clock):
    inst, client = await mock("dig2go-rgbw-015")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await post(client, {"ps": 5})
    await advance(inst, clock, 1200)
    await drain(ws)
    await post(client, {"playlist": {}})
    await advance(inst, clock, 1500)
    assert (await state(client))["pl"] == -1
    assert await nothing(ws)


async def test_a_playlist_that_only_moves_pl_is_not_pushed(mock, clock):
    inst, client = await mock("dig2go-rgbw-16")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await post(client, {"ps": 1})
    await advance(inst, clock, 1200)
    await drain(ws)
    await post(client, {"ps": 5})
    await advance(inst, clock, 1500)
    assert (await state(client))["pl"] == 5
    assert await nothing(ws)


async def test_saving_and_deleting_presets_push_nothing(mock, clock):
    inst, client = await mock("dig2go-rgbw-16")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await post(client, {"psave": 3, "n": "Mock Renamed", "ib": True, "sb": True})
    await advance(inst, clock, 1500)
    await post(client, {"pdel": 2})
    await advance(inst, clock, 1500)
    assert await nothing(ws)
    presets = await (await client.get("/presets.json")).json()
    assert presets["3"]["n"] == "Mock Renamed" and "2" not in presets


async def test_live_data_shows_in_info_and_pushes_nothing(mock, clock):
    inst, client = await mock("dig2go-rgbw-015")
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/live", data=json.dumps({"mode": "e131", "ip": "192.0.2.200"}))
    await advance(inst, clock, 500)
    info = await (await client.get("/json/info")).json()
    assert info["live"] is True and info["lm"] == "E1.31" and info["lip"] == "192.0.2.200"
    await client.post("/_mock/live_stop", data="{}")
    await advance(inst, clock, 2000)
    assert (await (await client.get("/json/info")).json())["live"] is True
    await advance(inst, clock, 700)
    assert (await (await client.get("/json/info")).json())["live"] is False
    assert await nothing(ws)


async def test_json_live_is_not_in_release_builds(mock):
    inst, client = await mock("dig2go-rgbw-015")
    assert await (await client.get("/json/live")).json() == {"error": 4}


# ---- the button ------------------------------------------------------------------------------


@pytest.mark.parametrize("name", DIG2GO)
def test_long_press_picks_a_new_color_and_leaves_power_alone(device, clock, name):
    d = device(name)
    d.deserialize_state({"on": False})
    settle(d, clock)
    before = d.serialize_state()["seg"][0]["col"][0]
    d.press_button(kind="long")
    settle(d, clock)
    st = d.serialize_state()
    assert st["on"] is False and st["seg"][0]["col"][0] != before


@pytest.mark.parametrize("name", DIG2GO)
def test_double_press_toggles_twice_with_no_macro(device, clock, name):
    d = device(name)
    d.press_button(kind="double")
    settle(d, clock)
    assert d.serialize_state()["on"] is True
