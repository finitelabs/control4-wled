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


# ---- fades -----------------------------------------------------------------------------------


def run(d, clock, ms):
    for _ in range(ms // 10):
        clock.advance(10)
        d.tick()


@pytest.mark.parametrize("name", DIG2GO)
def test_a_fade_sent_while_one_runs_jumps_on_16(device, clock, name):
    # Measured 2026-11-11 on camera: a 5 s fade sent a second before another ends jumps on 16.0.1.
    d = device(name)
    d.deserialize_state({"on": True, "bri": 5, "tt": 0})
    run(d, clock, 100)
    d.deserialize_state({"bri": 27, "tt": 50})
    run(d, clock, 4000)
    d.deserialize_state({"bri": 51, "tt": 50})
    run(d, clock, 10)
    if d.v16:
        assert d.output()["bri"] == 51
    else:
        assert 20 < d.output()["bri"] < 30


def test_a_change_without_bri_or_tt_mid_fade_leaves_the_fade_running_on_16(device, clock):
    d = device("dig2go-rgbw-16")
    d.deserialize_state({"on": True, "bri": 5, "tt": 0})
    run(d, clock, 100)
    d.deserialize_state({"bri": 51, "tt": 50})
    run(d, clock, 2000)
    d.deserialize_state({"seg": [{"id": 0, "fx": 9}]})
    run(d, clock, 10)
    assert 15 < d.output()["bri"] < 35


def test_a_fade_sent_after_one_ends_fades_on_16(device, clock):
    # Measured the same day: sent 100 ms or 250 ms after the end, it fades.
    d = device("dig2go-rgbw-16")
    d.deserialize_state({"on": True, "bri": 5, "tt": 0})
    run(d, clock, 100)
    d.deserialize_state({"bri": 27, "tt": 50})
    run(d, clock, 5100)
    assert d.output()["bri"] == 27
    d.deserialize_state({"bri": 51, "tt": 50})
    run(d, clock, 2500)
    assert 30 < d.output()["bri"] < 45


def color(d, i=0):
    return d.output()["colors"][i]


def blue_share(c):
    return c[2] / max(1, c[0] + c[2])


@pytest.mark.parametrize("name", DIG2GO)
def test_a_level_call_mid_color_fade_puts_the_color_at_its_target_on_16(device, clock, name):
    # Measured 2026-11-12 on the dig2go's live view: on 16.0.1 a level-only call 2 s into a 10 s
    # color fade put the color at its target at once; 0.15 lets the color fade on.
    d = device(name)
    d.deserialize_state(
        {"on": True, "bri": 255, "seg": [{"id": 0, "col": [[255, 0, 0, 0]]}], "tt": 0}
    )
    run(d, clock, 100)
    d.deserialize_state({"seg": [{"id": 0, "col": [[0, 0, 255, 0]]}], "tt": 100})
    run(d, clock, 2000)
    assert 0.15 < blue_share(color(d)) < 0.25
    d.deserialize_state({"bri": 128, "tt": 20})
    run(d, clock, 10)
    if d.v16:
        assert color(d) == [0, 0, 255, 0]
        assert d.color_jumps == 1
    else:
        assert blue_share(color(d)) < 0.3
        assert d.color_jumps == 0


def test_a_color_call_mid_level_fade_shows_its_color_at_once_on_16(device, clock):
    # The same day: a 2 s color call during a running level fade showed its color at once.
    d = device("dig2go-rgbw-16")
    d.deserialize_state(
        {"on": True, "bri": 255, "seg": [{"id": 0, "col": [[255, 0, 0, 0]]}], "tt": 0}
    )
    run(d, clock, 100)
    d.deserialize_state({"bri": 26, "tt": 100})
    run(d, clock, 2000)
    d.deserialize_state({"seg": [{"id": 0, "col": [[0, 255, 0, 0]]}], "tt": 20})
    run(d, clock, 10)
    assert color(d) == [0, 255, 0, 0]


def test_a_new_color_mid_fade_on_015_jumps_and_keeps_the_old_timer(device, clock):
    # FX_fcn.cpp:271@v0.15.4: a segment already in transition keeps its start values and timer, until
    # the strip's transition ends.
    d = device("dig2go-rgbw-015")
    d.deserialize_state(
        {"on": True, "bri": 255, "seg": [{"id": 0, "col": [[255, 0, 0, 0]]}], "tt": 0}
    )
    run(d, clock, 100)
    d.deserialize_state({"seg": [{"id": 0, "col": [[0, 0, 255, 0]]}], "tt": 100})
    run(d, clock, 2000)
    d.deserialize_state({"seg": [{"id": 0, "col": [[0, 255, 0, 0]]}], "tt": 20})
    run(d, clock, 10)
    c = color(d)
    assert c[2] == 0 and 30 < c[1] < 80
    run(d, clock, 1000)
    assert 0 < color(d)[0] < 255
    # The strip's transition ends with the new call's 2 s, and every segment with it.
    run(d, clock, 1100)
    assert color(d) == [0, 255, 0, 0]


def test_a_freeze_then_a_fade_shows_no_jump_on_16(device, clock):
    # Measured 2026-11-12: a 0 ms call where the fade had got to, then the next call 150 ms later,
    # held the color without a jump and faded on from there.
    d = device("dig2go-rgbw-16")
    d.deserialize_state(
        {"on": True, "bri": 255, "seg": [{"id": 0, "col": [[255, 0, 0, 0]]}], "tt": 0}
    )
    run(d, clock, 100)
    d.deserialize_state({"seg": [{"id": 0, "col": [[0, 0, 255, 0]]}], "tt": 100})
    run(d, clock, 2000)
    held = color(d)
    d.deserialize_state({"seg": [{"id": 0, "col": [held]}], "tt": 0})
    run(d, clock, 150)
    assert color(d) == held
    d.deserialize_state({"bri": 128, "seg": [{"id": 0, "col": [[0, 0, 255, 0]]}], "tt": 20})
    run(d, clock, 1000)
    assert blue_share(held) < blue_share(color(d)) < 0.95
    assert d.color_jumps == 0


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
    # Measured on 0.15.4 over /json/cfg.
    d = device("dig2go-rgbw-015")
    d.set_bus(0, 2, at_restart=True)
    leds = d.serialize_info()["leds"]
    assert leds["lc"] == 3 and leds["rgbw"] is False
    d.boot()
    leds = d.serialize_info()["leds"]
    assert leds["lc"] == 1 and leds["rgbw"] is True


def test_saving_the_same_white_mode_leaves_the_rgbw_flag_alone(device):
    d = device("dig2go-rgbw-015")
    d.set_bus(0, 0, at_restart=True)
    assert d.serialize_info()["leds"]["rgbw"] is True


def test_global_white_mode_change_survives_a_restart(device, clock):
    d = device("dig2go-rgbw-015")
    d.set_white(rgbwm=2)
    assert d.serialize_info()["leds"]["lc"] == 1
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
        {
            "seg": [
                {"id": 0, "start": 0, "stop": 120},
                {"id": 1, "start": 120, "stop": 200},
            ]
        }
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
    stored = d.presets["7"]["playlist"]
    assert stored["ps"] == [1, 2]
    # Written by the save path, not posted: a dig2go stored "r": 0 as a number.
    assert stored["end"] == 0 and stored["r"] == 0 and not isinstance(stored["r"], bool)
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


# ---- the button (measured on 0.15.4) ------------------------------------------------------


def test_long_press_picks_a_new_color_keeps_white_and_leaves_power_alone(device, clock):
    d = device("dig2go-rgbw-015")
    d.deserialize_state({"on": False, "seg": [{"id": 0, "col": [[10, 20, 30, 200]]}]})
    settle(d, clock)
    d.press_button(kind="long")
    settle(d, clock)
    st = d.serialize_state()
    col = st["seg"][0]["col"][0]
    assert st["on"] is False and col[:3] != [10, 20, 30] and col[3] == 200


def test_long_press_gives_every_selected_segment_the_first_ones_white(device, clock):
    d = device("dig2go-rgbw-015")
    seg = [
        {"id": 0, "start": 0, "stop": 150, "sel": True, "col": [[10, 20, 30, 200]]},
        {"id": 1, "start": 150, "stop": 300, "sel": True, "col": [[40, 50, 60, 0]]},
    ]
    d.deserialize_state({"seg": seg})
    settle(d, clock)
    d.press_button(kind="long")
    settle(d, clock)
    a, b = (s["col"][0] for s in d.serialize_state()["seg"])
    assert a == b and a[3] == 200


async def test_double_press_toggles_twice_and_pushes_each_a_second_apart(mock, clock):
    inst, client = await mock("dig2go-rgbw-015")
    await post(client, {"on": False})
    await advance(inst, clock, 1500)
    ws = await client.ws_connect("/ws")
    await receive_json(ws)
    await client.post("/_mock/button", data=json.dumps({"kind": "double"}))
    await advance(inst, clock, 60)
    assert (await receive_json(ws))["state"]["on"] is True
    await advance(inst, clock, 700)
    assert await nothing(ws)
    await advance(inst, clock, 400)
    assert (await receive_json(ws))["state"]["on"] is False
