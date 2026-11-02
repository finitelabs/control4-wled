#!/usr/bin/env python3
"""Generate the mock's per-firmware effect and palette data from WLED's source.

For each pinned WLED release and build target this writes data/<version>/<target>.json with
the lists a real controller serves: /json/eff (names, with "RSVD" placeholders where the build
leaves an effect out), /json/fxdata (metadata strings) and /json/pal (built-in palette names),
plus per-effect flags parsed from the metadata. Nothing is hand-listed: the effect table is
rebuilt by replaying WS2812FX::setupEffectData() in wled00/FX.cpp under the target's build
defines, and addEffect() is replayed with the same slot rules.

Usage:
  gen_data.py            regenerate data/ from WLED's source on GitHub
  gen_data.py --check    exit 1 if the committed data differs from a fresh generation
  gen_data.py --source DIR   read <DIR>/<version>/wled00/<file> instead of downloading

Stdlib only, so it runs without the mock's virtualenv.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
REPO = "wled/WLED"

RELEASES = {
    "16.0.1": "29b389df1c1aaec6ff53aea742d17063b985906c",
    "0.15.4": "9af566ff877fe2f478ec5e4ba3b0940e5a83cd77",
}

# Build defines that change the effect table, from each release's platformio.ini default
# envs: esp32dev (all ESP32 variants share esp32_all_variants) and nodemcuv2.
TARGET_DEFINES = {
    "16.0.1": {
        "esp32": {"ARDUINO_ARCH_ESP32", "WLED_PS_DONT_REPLACE_FX", "WLED_ENABLE_GIF"},
        "esp8266": {"ESP8266", "WLED_PS_DONT_REPLACE_FX", "WLED_DISABLE_PARTICLESYSTEM2D"},
    },
    "0.15.4": {
        "esp32": {"ARDUINO_ARCH_ESP32"},
        "esp8266": {"ESP8266"},
    },
}

FILES = ("wled00/FX.cpp", "wled00/FX.h", "wled00/FX_fcn.cpp")


def derive_defines(defines):
    """Apply the particle-system define chain at the top of FX.cpp (16.0.1 lines 21-42)."""
    out = set(defines)
    if not ("WLED_DISABLE_PARTICLESYSTEM2D" in out and "WLED_DISABLE_PARTICLESYSTEM1D" in out):
        if "WLED_DISABLE_PARTICLESYSTEM2D" in out:
            out.add("WLED_PS_DONT_REPLACE_2D_FX")
        if "WLED_DISABLE_PARTICLESYSTEM1D" in out:
            out.add("WLED_PS_DONT_REPLACE_1D_FX")
    else:
        out.update({"WLED_PS_DONT_REPLACE_1D_FX", "WLED_PS_DONT_REPLACE_2D_FX"})
    if "WLED_PS_DONT_REPLACE_FX" in out:
        out.update({"WLED_PS_DONT_REPLACE_1D_FX", "WLED_PS_DONT_REPLACE_2D_FX"})
    return out


def fetch(version, path, source_dir):
    if source_dir:
        return (Path(source_dir) / version / path).read_text(encoding="utf-8")
    url = f"https://raw.githubusercontent.com/{REPO}/{RELEASES[version]}/{path}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read().decode("utf-8")


def c_unescape(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def eval_condition(expr, defines):
    """Evaluate the small #if grammar used in setupEffectData: defined(), !, ||, &&."""
    expr = re.sub(r"defined\s*\(\s*(\w+)\s*\)", lambda m: str(m.group(1) in defines), expr)
    expr = expr.replace("||", " or ").replace("&&", " and ").replace("!", " not ")
    if not re.fullmatch(r"[\sA-Za-z()]*", expr) or re.search(
        r"\b(?!True|False|and|or|not)\w+", expr
    ):
        raise ValueError(f"unsupported #if expression: {expr}")
    return bool(eval(expr, {"__builtins__": {}}, {}))


def function_body(src, signature):
    start = src.index(signature)
    brace = src.index("{", start)
    depth = 0
    for i in range(brace, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[brace + 1 : i]
    raise ValueError(f"unterminated function {signature}")


def build_effect_table(fx_cpp, fx_h, defines):
    ids = {
        m.group(1): int(m.group(2)) for m in re.finditer(r"#define\s+(FX_MODE_\w+)\s+(\d+)", fx_h)
    }
    mode_count = int(re.search(r"#define\s+MODE_COUNT\s+(\d+)", fx_h).group(1))
    strings = {
        m.group(1): c_unescape(m.group(2))
        for m in re.finditer(r'const char (_data_\w+)\[\] PROGMEM = "((?:[^"\\]|\\.)*)";', fx_cpp)
    }
    body = function_body(fx_cpp, "void WS2812FX::setupEffectData()")

    # The table starts as Solid then RSVD up to MODE_COUNT; addEffect fills or appends.
    table = [strings["_data_FX_MODE_STATIC"]] + [strings["_data_RESERVED"]] * (mode_count - 1)
    reserved = strings["_data_RESERVED"]
    stack = []  # (active, taken) per #if level
    active = True
    for raw in body.splitlines():
        line = raw.split("//")[0].strip()
        if line.startswith("#"):
            word, _, rest = line[1:].strip().partition(" ")
            rest = rest.strip()
            if word in ("ifdef", "ifndef", "if"):
                if word == "ifdef":
                    cond = rest in defines
                elif word == "ifndef":
                    cond = rest not in defines
                else:
                    cond = eval_condition(rest, defines)
                stack.append((active, cond))
                active = active and cond
            elif word == "else":
                outer, taken = stack[-1]
                stack[-1] = (outer, True)
                active = outer and not taken
            elif word == "elif":
                outer, taken = stack[-1]
                cond = eval_condition(rest, defines)
                active = outer and not taken and cond
                stack[-1] = (outer, taken or cond)
            elif word == "endif":
                active, _ = stack.pop()
            continue
        if not active:
            continue
        m = re.search(r"addEffect\(\s*(\w+)\s*,\s*&?\w+\s*,\s*(\w+)\s*\)", line)
        if not m:
            continue
        ident, data_name = m.groups()
        slot = 255 if ident == "255" else ids[ident]
        data = strings[data_name]
        # WS2812FX::addEffect: 255 takes the first RSVD slot; a taken slot is not overwritten.
        if slot == 255:
            slot = next((i for i in range(1, len(table)) if table[i] == reserved), 255)
        if slot < len(table):
            if table[slot] == reserved:
                table[slot] = data
        elif len(table) < 255:
            table.append(data)
    return table


def parse_flags(fxdata):
    sections = fxdata.split(";")
    flags = sections[3] if len(sections) > 3 and sections[3] else "1"
    dims = sorted({int(c) for c in flags if c in "0123"}) or [1]
    audio = "frequency" if "f" in flags else "volume" if "v" in flags else None
    return dims, audio


def palette_names(fx_fcn):
    m = re.search(r'JSON_palette_names\[\] PROGMEM = R"=====\((.*?)\)=====";', fx_fcn, re.S)
    return json.loads(m.group(1))


def generate(source_dir=None):
    out = {}
    for version, commit in RELEASES.items():
        src = {path: fetch(version, path, source_dir) for path in FILES}
        pal = palette_names(src["wled00/FX_fcn.cpp"])
        for target, base in TARGET_DEFINES[version].items():
            defines = derive_defines(base)
            table = build_effect_table(src["wled00/FX.cpp"], src["wled00/FX.h"], defines)
            eff, fxdata, meta = [], [], []
            for i, data in enumerate(table):
                name, at, rest = data.partition("@")
                eff.append(name)
                fxdata.append(rest if at else "")
                dims, audio = parse_flags(rest) if at else ([1], None)
                meta.append({"id": i, "reserved": name == "RSVD", "dims": dims, "audio": audio})
            doc = {
                "source": {"repo": REPO, "tag": f"v{version}", "commit": commit, "files": FILES},
                "target": target,
                "defines": sorted(defines),
                "eff": eff,
                "fxdata": fxdata,
                "pal": pal,
                "fxmeta": meta,
            }
            text = json.dumps(doc, indent=1, ensure_ascii=False) + "\n"
            out[DATA / version / f"{target}.json"] = text
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="compare with the committed data")
    ap.add_argument("--source", help="read WLED source from <DIR>/<version>/wled00/")
    args = ap.parse_args()
    files = generate(args.source)
    if args.check:
        stale = [p for p, t in files.items() if not p.exists() or p.read_text("utf-8") != t]
        extra = sorted(set(DATA.glob("*/*.json")) - set(files))
        for p in stale:
            print(f"stale: {p.relative_to(HERE)}", file=sys.stderr)
        for p in extra:
            print(f"not generated: {p.relative_to(HERE)}", file=sys.stderr)
        if stale or extra:
            print("run gen_data.py to regenerate", file=sys.stderr)
            return 1
        print(f"data matches WLED source ({len(files)} files)")
        return 0
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
