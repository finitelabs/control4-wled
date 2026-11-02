from conftest import settle

from mock_wled.device import color_from_hex


def test_bri_never_reads_zero_and_on_follows_bri(device):
    d = device()
    d.deserialize_state({"bri": 0})
    st = d.serialize_state()
    assert st["on"] is False and st["bri"] == 128


def test_bri_alone_turns_the_light_on(device, clock):
    d = device()
    d.deserialize_state({"on": False})
    d.deserialize_state({"bri": 90})
    st = d.serialize_state()
    assert st["on"] is True and st["bri"] == 90


def test_off_with_bri_stores_the_on_level(device, clock):
    d = device()
    d.deserialize_state({"on": False, "bri": 77})
    assert d.serialize_state()["on"] is False
    assert d.serialize_state()["bri"] == 77
    d.deserialize_state({"on": True})
    assert d.serialize_state()["bri"] == 77 and d.bri == 77


def test_toggle(device):
    d = device()
    d.deserialize_state({"on": "t"})
    assert d.serialize_state()["on"] is False
    d.deserialize_state({"on": "t"})
    assert d.serialize_state()["on"] is True


def test_on_needs_a_real_bool(device):
    d = device()
    d.deserialize_state({"on": 0})
    assert d.serialize_state()["on"] is True


def test_target_reported_at_once_while_output_fades(device, clock):
    d = device()
    d.deserialize_state({"bri": 28, "tt": 10})
    assert d.serialize_state()["bri"] == 28
    clock.advance(500)
    d.tick()
    assert 70 < d.output()["bri"] < 85
    clock.advance(600)
    d.tick()
    assert d.output()["bri"] == 28


def test_tt_is_restored_only_when_the_fade_ends(device, clock):
    d = device()
    d.deserialize_state({"bri": 40, "tt": 50})
    clock.advance(1000)
    d.tick()
    d.deserialize_state({"bri": 200})
    assert d.strip_transition == 5000
    settle(d, clock, 6000)
    assert d.strip_transition == 700


def test_transition_wraps_above_655_tenths(device):
    d = device()
    d.deserialize_state({"transition": 700})
    assert d.transition_delay == (70000 & 0xFFFF)
    assert d.serialize_state()["transition"] == 44


def test_crossfade_off_on_015_ignores_tt(device, clock):
    d = device("esp8266-ws2812b-015-nofade")
    d.deserialize_state({"bri": 20, "tt": 50})
    assert d.output()["bri"] == 20


def test_bri_change_clears_ps_on_16_but_not_on_015(device, clock):
    for name, expect in (("esp32-rgbw-pwm-16", -1), ("esp8266-ws2812b-015", 7)):
        d = device(name)
        d.presets["7"] = {"n": "Mock", "on": True, "bri": 100}
        d.deserialize_state({"ps": 7})
        settle(d, clock, 200)
        assert d.serialize_state()["ps"] == 7
        d.deserialize_state({"bri": 101})
        assert d.serialize_state()["ps"] == expect, name


def test_any_segment_write_clears_ps_on_015(device, clock):
    d = device("esp8266-ws2812b-015")
    d.presets["7"] = {"n": "Mock", "on": True}
    d.deserialize_state({"ps": 7})
    settle(d, clock, 200)
    d.deserialize_state({"seg": [{"id": 0}]})
    assert d.serialize_state()["ps"] == -1


def test_cct_kelvin_maps_to_0_255(device):
    d = device("esp32-cct-16")
    for k, v in ((2700, 25), (1000, 0), (12000, 255), (200, 200)):
        d.deserialize_state({"seg": [{"id": 0, "cct": k}]})
        assert d.serialize_state()["seg"][0]["cct"] == v


def test_color_forms(device):
    d = device()
    d.deserialize_state({"seg": [{"id": 0, "col": [[1, 2, 3, 4], "0A0B0C", {"g": 9}]}]})
    col = d.serialize_state()["seg"][0]["col"]
    assert col[0] == [1, 2, 3, 4] and col[1] == [10, 11, 12, 0] and col[2] == [0, 9, 0, 0]
    d.deserialize_state({"seg": [{"id": 0, "col": [2700]}]})
    assert d.serialize_state()["seg"][0]["col"][0][:3] == [255, 167, 87]


def test_eight_digit_hex_is_rrggbbww():
    assert color_from_hex("11223344") == [0x11, 0x22, 0x33, 0x44]


def test_three_channel_colors_without_a_white_bus(device):
    d = device("esp8266-ws2812b-015")
    assert len(d.serialize_state()["seg"][0]["col"][0]) == 3


def test_relative_values(device):
    d = device()
    d.deserialize_state({"bri": 100})
    d.deserialize_state({"bri": "~10"})
    assert d.bri == 110
    d.deserialize_state({"bri": "~-"})
    assert d.bri == 109


def test_info_differs_by_version(device):
    d16, d15 = device(), device("esp32-rgbw-015")
    i16, i15 = d16.serialize_info(), d15.serialize_info()
    assert i16["ver"] == "16.0.1" and i15["ver"] == "0.15.4"
    assert "cpalmax" in i16 and "cpalmax" not in i15
    assert "lc" in d16.serialize_state()["seg"][0] and "lc" not in d15.serialize_state()["seg"][0]
    assert "bs" in d16.serialize_state() and "bs" not in d15.serialize_state()
    assert i16["fxcount"] == 220 and i15["fxcount"] == 187
    assert i16["palcount"] == 72 and i15["palcount"] == 71


def test_identity(device):
    d = device()
    info = d.serialize_info()
    assert info["mac"] == "02a1b2c3d402" and len(info["deviceId"]) == 42
    assert d.serialize_cfg()["id"]["mdns"] == "wled-c3d402"


def test_nightlight_fade_reports_remaining(device, clock):
    d = device()
    d.deserialize_state({"bri": 200, "nl": {"on": True, "dur": 1, "mode": 1, "tbri": 0}})
    clock.advance(100)
    d.tick()
    clock.advance(30000)
    d.tick()
    st = d.serialize_state()
    assert st["nl"]["on"] and 25 <= st["nl"]["rem"] <= 30
    assert 90 <= d.bri <= 110
    settle(d, clock, 31000)
    assert d.serialize_state()["nl"]["rem"] == -1 and d.bri == 0
