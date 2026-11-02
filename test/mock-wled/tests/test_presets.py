from conftest import settle


def test_preset_applies_on_a_later_tick(device, clock):
    d = device()
    d.deserialize_state({"ps": 2})
    assert d.serialize_state()["ps"] == -1 and d.segments[0].mode == 0
    clock.advance(10)
    d.tick()
    st = d.serialize_state()
    assert st["ps"] == 2 and st["seg"][0]["fx"] == 9 and st["bri"] == 200


def test_any_change_clears_ps(device, clock):
    d = device()
    d.deserialize_state({"ps": 1})
    settle(d, clock, 100)
    d.deserialize_state({"seg": [{"id": 0, "sx": 10}]})
    assert d.serialize_state()["ps"] == -1


def test_missing_preset_reports_error_12_once(device, clock):
    d = device()
    d.deserialize_state({"ps": 99})
    settle(d, clock, 100)
    assert d.serialize_state().get("error") == 12
    assert "error" not in d.serialize_state()


def test_psave_stores_state_and_moves_pmt(device, clock):
    d = device()
    assert d.serialize_info()["fs"]["pmt"] == 0
    clock.advance(5000)
    d.deserialize_state({"psave": 9, "n": "Mock Saved", "ql": "S", "ib": True, "sb": True})
    assert "9" not in d.presets
    d.tick()
    p = d.presets["9"]
    assert p["n"] == "Mock Saved" and p["ql"] == "S" and p["bri"] == 128 and "seg" in p
    assert d.serialize_info()["fs"]["pmt"] > 0


def test_api_preset_saved_at_once(device):
    d = device()
    d.deserialize_state({"psave": 10, "o": True, "seg": {"fx": 3}})
    assert d.presets["10"] == {"seg": {"fx": 3}, "n": "Preset 10"}


def test_pdel(device, clock):
    d = device()
    clock.advance(3000)
    d.deserialize_state({"pdel": 1})
    assert "1" not in d.presets and d.serialize_info()["fs"]["pmt"] > 0


def test_saved_preset_deletes_segments_it_lacks(device, clock):
    d = device()
    d.deserialize_state({"psave": 11, "ib": True, "sb": True})
    d.tick()
    assert {"stop": 0} in d.presets["11"]["seg"]
    d.deserialize_state({"seg": [{"id": 2, "start": 5, "stop": 9}]})
    assert len(d.serialize_state()["seg"]) == 3
    d.deserialize_state({"ps": 11})
    settle(d, clock, 100)
    assert [s["id"] for s in d.serialize_state()["seg"]] == [0, 1]


def test_playlist_steps_through_entries(device, clock):
    d = device()
    d.deserialize_state({"ps": 3})
    settle(d, clock, 100)
    st = d.serialize_state()
    assert st["pl"] == 3 and st["ps"] == 1
    settle(d, clock, 3100)
    st = d.serialize_state()
    assert st["pl"] == 3 and st["ps"] == 2


def test_playlist_pauses_while_off(device, clock):
    d = device()
    d.deserialize_state({"ps": 3})
    settle(d, clock, 100)
    d.deserialize_state({"on": False})
    settle(d, clock, 6000)
    assert d.serialize_state()["ps"] in (1, -1) and d.current_playlist == 3


def test_effect_change_stops_the_playlist(device, clock):
    d = device()
    d.deserialize_state({"ps": 3})
    settle(d, clock, 100)
    d.deserialize_state({"seg": [{"id": 0, "fx": 5}]})
    assert d.serialize_state()["pl"] == -1


def test_direct_playlist_reports_pl_0(device, clock):
    d = device()
    d.deserialize_state({"playlist": {"ps": [1, 2], "dur": 20}})
    settle(d, clock, 100)
    assert d.serialize_state()["pl"] == 0


def test_015_playlist_duration_zero_is_ten_seconds(device, clock):
    d = device(
        "esp32-rgbw-015",
        presets={
            "1": {"n": "A", "on": True, "seg": [{"id": 0, "fx": 1}]},
            "2": {"n": "B", "on": True, "seg": [{"id": 0, "fx": 2}]},
            "3": {"n": "P", "on": True, "playlist": {"ps": [1, 2], "dur": [0, 0]}},
        },
    )
    d.deserialize_state({"ps": 3})
    settle(d, clock, 100)
    assert d.serialize_state()["ps"] == 1
    settle(d, clock, 9000)
    assert d.serialize_state()["ps"] == 1
    settle(d, clock, 1500)
    assert d.serialize_state()["ps"] == 2


def test_presets_survive_a_reboot(device, clock):
    d = device()
    d.deserialize_state({"psave": 12, "ib": True})
    d.tick()
    d.boot()
    assert "12" in d.presets and d.serialize_info()["fs"]["pmt"] == 0
