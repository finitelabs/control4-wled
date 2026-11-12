#!/usr/bin/env python3
"""Write the WLED answers the Lua suites serve, one folder per mock profile.

Each profile under test/mock-wled/profiles is booted in the mock's controller model (no server)
and its answers written to test/fixtures/wled/<profile>/: si.json (GET /json/si and the WebSocket's
first message), eff.json, pal.json, fxdata.json and presets.json. The mock stays the one model of
WLED's behavior; the Lua fake only replays and edits these answers.

Usage:
  python3 test/gen_wled_fixtures.py          write the fixtures
  python3 test/gen_wled_fixtures.py --check  fail if a fixture differs from a fresh generation
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MOCK = ROOT / "mock-wled"
OUT = ROOT / "fixtures" / "wled"

sys.path.insert(0, str(MOCK))

from mock_wled.device import Device, FakeClock  # noqa: E402


def answers(profile):
    """The endpoint bodies a freshly booted controller serves."""
    device = Device(profile, FakeClock())
    return {
        "si.json": {"state": device.serialize_state(), "info": device.serialize_info()},
        "eff.json": [n for n in device.eff if n],
        "pal.json": list(device.pal),
        "fxdata.json": list(device.fxdata),
        "presets.json": device.presets,
        "cfg.json": device.serialize_cfg(),
    }


def render(body):
    return json.dumps(body, indent=1, ensure_ascii=False) + "\n"


def generate():
    """Map of fixture path to its text, for every profile."""
    files = {}
    for path in sorted((MOCK / "profiles").glob("*.json")):
        profile = json.loads(path.read_text())
        for name, body in answers(profile).items():
            files[OUT / path.stem / name] = render(body)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare instead of writing")
    args = parser.parse_args()

    files = generate()
    if args.check:
        stale = [p for p, text in files.items() if not p.exists() or p.read_text() != text]
        extra = [p for p in OUT.glob("*/*.json") if p not in files]
        for p in stale:
            print(f"stale: {p.relative_to(ROOT.parent)}")
        for p in extra:
            print(f"not from a profile: {p.relative_to(ROOT.parent)}")
        if stale or extra:
            print("run: make gen-wled-fixtures")
            return 1
        print(f"WLED fixtures match the mock ({len(files)} files)")
        return 0

    for p, text in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    for p in OUT.glob("*/*.json"):
        if p not in files:
            p.unlink()
    print(f"wrote {len(files)} WLED fixtures")
    return 0


if __name__ == "__main__":
    sys.exit(main())
