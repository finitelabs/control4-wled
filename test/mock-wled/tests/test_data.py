import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import gen_data  # noqa: E402
from mock_wled.announce import node_packet  # noqa: E402

FX_H = """
#define FX_MODE_STATIC 0
#define FX_MODE_A 1
#define FX_MODE_B 2
#define FX_MODE_C 3
#define MODE_COUNT 5
"""

FX_CPP = """
static const char _data_FX_MODE_STATIC[] PROGMEM = "Solid";
static const char _data_RESERVED[] PROGMEM = "RSVD";
static const char _data_FX_MODE_A[] PROGMEM = "Alpha@!,!;!,!;!;01;sx=24";
static const char _data_FX_MODE_B[] PROGMEM = "Beta@!;!;!;2v";
static const char _data_FX_MODE_C[] PROGMEM = "Gamma@!;;;1f";
void WS2812FX::setupEffectData() {
  addEffect(FX_MODE_A, &mode_a, _data_FX_MODE_A);
#ifndef WLED_DISABLE_2D
  addEffect(FX_MODE_B, &mode_b, _data_FX_MODE_B);
#else
  addEffect(255, &mode_c, _data_FX_MODE_C);
#endif
#if defined(WLED_X) || defined(WLED_Y)
  addEffect(FX_MODE_C, &mode_c, _data_FX_MODE_C);
#endif
  addEffect(FX_MODE_A, &mode_a2, _data_FX_MODE_C); // taken slot is not overwritten
}
"""


def test_replay_follows_defines_and_slot_rules():
    table = gen_data.build_effect_table(FX_CPP, FX_H, set())
    assert table == ["Solid", "Alpha@!,!;!,!;!;01;sx=24", "Beta@!;!;!;2v", "RSVD", "RSVD"]
    table = gen_data.build_effect_table(FX_CPP, FX_H, {"WLED_DISABLE_2D", "WLED_Y"})
    gamma = "Gamma@!;;;1f"
    assert table == ["Solid", "Alpha@!,!;!,!;!;01;sx=24", gamma, gamma, "RSVD"]


def test_flags():
    assert gen_data.parse_flags("!;!;!;2v") == ([2], "volume")
    assert gen_data.parse_flags("!;!;!;12f") == ([1, 2], "frequency")
    assert gen_data.parse_flags("!,!") == ([1], None)


def test_particle_defines():
    out = gen_data.derive_defines({"WLED_DISABLE_PARTICLESYSTEM2D"})
    assert "WLED_PS_DONT_REPLACE_2D_FX" in out and "WLED_PS_DONT_REPLACE_1D_FX" not in out


def test_committed_data_is_aligned():
    for version, count, pals in (("16.0.1", 220, 72), ("0.15.4", 187, 71)):
        for target in ("esp32", "esp8266"):
            doc = json.loads((ROOT / "data" / version / f"{target}.json").read_text("utf-8"))
            assert doc["source"]["tag"] == f"v{version}"
            assert len(doc["eff"]) == len(doc["fxdata"]) == len(doc["fxmeta"]) == count
            assert len(doc["pal"]) == pals and doc["eff"][0] == "Solid"
            for name, data, meta in zip(doc["eff"], doc["fxdata"], doc["fxmeta"]):
                assert meta["reserved"] == (name == "RSVD")
                if name == "RSVD":
                    assert data == ""


def test_node_packet_layout(device):
    d = device()
    pkt = node_packet(d, "192.0.2.10")
    assert len(pkt) == 44 and pkt[:2] == b"\xff\x01" and pkt[2:6] == bytes([192, 0, 2, 10])
    assert pkt[6:38].rstrip(b"\0").decode() == d.name
    assert pkt[38] == 32 | 0x80 and pkt[39] == 10
    assert struct.unpack("<I", pkt[40:44])[0] == 2605010
    d.deserialize_state({"on": False})
    assert node_packet(d, "192.0.2.10")[38] == 32
