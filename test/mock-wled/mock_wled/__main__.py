"""Run mock WLED controllers.

Examples:
  python -m mock_wled --instance 18081=esp32-rgbw-pwm-16
  python -m mock_wled --config instances/all.json --mdns --broadcast --ip 192.0.2.10
  python -m mock_wled --list

A profile is a name from profiles/ or a path to a profile file. A config file is
{"host": "0.0.0.0", "instances": [{"port": 18081, "profile": "<name or path>"}, ...]}.

Each instance answers WLED's API on its port and the control API under /_mock/ (GET /_mock
lists the actions). --mdns announces every instance as _wled._tcp with its mac, --broadcast
sends WLED's node broadcast on UDP 65506; both need --ip, the address the instances are
reached at, and both are off by default.
"""

import argparse
import asyncio
import json
import logging
import signal
import sys
from pathlib import Path

from .announce import MdnsAnnouncer, NodeBroadcaster
from .device import ROOT
from .server import Instance

PROFILES = ROOT / "profiles"


def load_profile(ref):
    path = Path(ref)
    if not path.suffix:
        path = PROFILES / f"{ref}.json"
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def parse_args(argv):
    ap = argparse.ArgumentParser(
        prog="python -m mock_wled",
        description=__doc__.split("\n\n")[0],
        epilog="\n\n".join(__doc__.split("\n\n")[1:]),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--config", help="JSON file listing instances")
    ap.add_argument(
        "--instance",
        action="append",
        default=[],
        metavar="PORT=PROFILE",
        help="one instance; repeatable",
    )
    ap.add_argument("--host", default=None, help="address to listen on (default 0.0.0.0)")
    ap.add_argument("--ip", help="address the instances are reached at, for announcements")
    ap.add_argument("--mdns", action="store_true", help="announce each instance by mDNS")
    ap.add_argument("--broadcast", action="store_true", help="send the UDP node broadcast")
    ap.add_argument("--list", action="store_true", help="list the bundled profiles")
    ap.add_argument("-v", "--verbose", action="store_true")
    return ap.parse_args(argv)


async def run(args):
    specs, host = [], args.host
    if args.config:
        with open(args.config, encoding="utf-8") as f:
            cfg = json.load(f)
        host = host or cfg.get("host")
        specs += [(int(i["port"]), i["profile"]) for i in cfg["instances"]]
    for item in args.instance:
        port, _, ref = item.partition("=")
        specs.append((int(port), ref))
    if not specs:
        print("no instances: pass --instance or --config (see --help)", file=sys.stderr)
        return 2
    if (args.mdns or args.broadcast) and not args.ip:
        print("--mdns and --broadcast need --ip", file=sys.stderr)
        return 2
    instances = []
    for port, ref in specs:
        profile = load_profile(ref)
        if args.ip and "ip" not in profile:
            profile["ip"] = args.ip
        inst = Instance(profile, host or "0.0.0.0", port)
        await inst.start()
        if args.broadcast:
            inst.announcers.append(NodeBroadcaster(inst, args.ip))
        if args.mdns:
            inst.announcers.append(MdnsAnnouncer(inst, args.ip))
        for a in inst.announcers:
            await a.start()
        d = inst.device
        print(
            f"{port}: {Path(ref).stem} ({d.version}, {d.chip_name}, {len(d.buses)} bus, "
            f"{d.name})",
            flush=True,
        )
        instances.append(inst)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    for inst in instances:
        await inst.stop()
    return 0


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING)
    if args.list:
        for p in sorted(PROFILES.glob("*.json")):
            prof = load_profile(p)
            print(f"{p.stem:28} {prof['firmware']:7} {prof['chip']:8} {prof['name']}")
        return 0
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
