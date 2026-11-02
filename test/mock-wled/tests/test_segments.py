from mock_wled.device import CAP_CCT, CAP_RGB, CAP_W


def ids(d):
    return [s["id"] for s in d.serialize_state()["seg"]]


def test_capabilities_per_segment_and_bus(device):
    d = device()
    st, info = d.serialize_state(), d.serialize_info()
    assert [s["lc"] for s in st["seg"]] == [CAP_RGB | CAP_W, CAP_RGB | CAP_W | CAP_CCT]
    assert info["leds"]["lc"] == 7 and info["leds"]["seglc"] == [3, 7]


def test_white_mode_flips_the_white_bit(device):
    d = device("esp32-rgbw-015")
    assert d.serialize_info()["leds"]["lc"] == CAP_RGB | CAP_W
    d.set_bus(0, rgbwm=2)
    assert d.serialize_info()["leds"]["lc"] == CAP_RGB
    d.set_white(rgbwm=0)
    assert d.serialize_info()["leds"]["lc"] == CAP_RGB | CAP_W


def test_white_balance_adds_cct_to_rgb(device):
    assert device("esp32-rgb-wb-16").serialize_info()["leds"]["lc"] == CAP_RGB | CAP_CCT


def test_single_types(device):
    lcs = {
        n: device(n).serialize_info()["leds"]["lc"]
        for n in ("esp32-white-16", "esp32-cct-16", "esp32-relay-16", "esp32-rgbw-accurate-16")
    }
    assert lcs == {
        "esp32-white-16": 2,
        "esp32-cct-16": 6,
        "esp32-relay-16": 0,
        "esp32-rgbw-accurate-16": 1,
    }


def test_add_segment_gets_the_default_color(device):
    d = device()
    d.deserialize_state({"seg": [{"id": 2, "start": 10, "stop": 20}]})
    seg = d.serialize_state()["seg"][2]
    assert (seg["start"], seg["stop"], seg["col"][0]) == (10, 20, [255, 160, 0, 0])


def test_delete_segment_hides_it_and_shifts_seglc_on_015(device):
    d = device("esp8266-ws2812b-015")
    d.deserialize_state(
        {
            "seg": [
                {"id": 0, "stop": 20},
                {"id": 1, "start": 20, "stop": 40},
                {"id": 2, "start": 40, "stop": 60},
            ]
        }
    )
    d.deserialize_state({"seg": [{"id": 1, "stop": 0}]})
    assert ids(d) == [0, 2]
    assert len(d.serialize_info()["leds"]["seglc"]) == 2


def test_deleting_half_of_more_than_three_renumbers(device):
    d = device("esp8266-ws2812b-015")
    d.deserialize_state(
        {"seg": [{"id": i, "start": i * 10, "stop": i * 10 + 10} for i in range(6)]}
    )
    d.deserialize_state({"mainseg": 5})
    d.deserialize_state({"seg": [{"id": 1, "stop": 0}, {"id": 2, "stop": 0}, {"id": 3, "stop": 0}]})
    st = d.serialize_state()
    assert ids(d) == [0, 1, 2]
    assert [s["start"] for s in st["seg"]] == [0, 40, 50]
    assert st["mainseg"] == 0


def test_segment_object_without_id_applies_to_selected(device):
    d = device()
    d.deserialize_state({"seg": [{"id": 0, "sel": True}, {"id": 1, "sel": False}]})
    d.deserialize_state({"seg": {"fx": 1}})
    assert [s["fx"] for s in d.serialize_state()["seg"]] == [1, 0]


def test_reserved_effect_moves_to_the_next_real_one(device):
    d = device()
    rsvd = d.eff.index("RSVD")
    d.deserialize_state({"seg": [{"id": 0, "fx": rsvd}]})
    fx = d.serialize_state()["seg"][0]["fx"]
    assert fx > rsvd and d.eff[fx] != "RSVD"
    d.deserialize_state({"seg": [{"id": 0, "fx": 250}]})
    assert d.serialize_state()["seg"][0]["fx"] == 0


def test_effect_defaults_load_with_fxdef(device):
    d = device()
    fx = next(i for i, m in enumerate(d.fxdata) if "sx=" in m.rsplit(";", 1)[-1])
    want = int(d.fxdata[fx].rsplit(";", 1)[-1].split("sx=")[1].split(",")[0])
    d.deserialize_state({"seg": [{"id": 0, "fx": fx, "fxdef": True}]})
    assert d.serialize_state()["seg"][0]["sx"] == want


def test_palette_ignored_without_rgb(device):
    d = device("esp32-white-16")
    d.deserialize_state({"seg": [{"id": 0, "pal": 11}]})
    assert d.serialize_state()["seg"][0]["pal"] == 0


def test_relay_segment_colors_are_white_or_black(device):
    d = device("esp32-relay-16")
    d.deserialize_state({"seg": [{"id": 0, "col": [[1, 2, 3]]}]})
    assert d.segments[0].colors[:2] == [0xFFFFFFFF, 0]


def test_segment_bri_zero_turns_it_off_and_keeps_opacity(device):
    d = device()
    d.deserialize_state({"seg": [{"id": 0, "bri": 90}]})
    d.deserialize_state({"seg": [{"id": 0, "bri": 0}]})
    seg = d.serialize_state()["seg"][0]
    assert seg["on"] is False and seg["bri"] == 90


def test_moving_bounds_without_a_name_clears_it(device):
    d = device()
    d.deserialize_state({"seg": [{"id": 0, "start": 1}]})
    assert "n" not in d.serialize_state()["seg"][0]


def test_matrix_reports_2d_fields(device):
    d = device("esp32-matrix-16")
    seg, info = d.serialize_state()["seg"][0], d.serialize_info()
    assert info["leds"]["matrix"] == {"w": 8, "h": 8}
    assert (seg["startY"], seg["stopY"]) == (0, 8) and "tp" in seg


def test_max_segments(device):
    assert device("esp8266-ws2812b-015").serialize_info()["leds"]["maxseg"] == 16
    assert device("esp32s3-64seg-16").serialize_info()["leds"]["maxseg"] == 64
    assert device("esp32-rgbw-015").serialize_info()["leds"]["maxseg"] == 32
