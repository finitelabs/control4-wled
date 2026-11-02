import asyncio
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mock_wled.__main__ import load_profile  # noqa: E402
from mock_wled.device import Device, FakeClock  # noqa: E402
from mock_wled.server import Instance  # noqa: E402


@pytest.fixture
def clock():
    return FakeClock()


@pytest.fixture
def device(clock):
    def make(name="esp32-rgbw-pwm-16", **overrides):
        profile = load_profile(name)
        profile.update(overrides)
        d = Device(profile, clock)
        settle(d, clock)
        return d

    return make


def settle(d, clock, ms=2000):
    """Run the loop past the boot fade and any cooldown."""
    for _ in range(ms // 50):
        clock.advance(50)
        d.tick()
    d.push_due = False


@pytest.fixture
def mock(aiohttp_client, clock):
    """An instance on the aiohttp test server, driven by the fake clock (no background loop)."""

    async def make(name="esp32-rgbw-pwm-16", **overrides):
        profile = load_profile(name)
        profile.update(overrides)
        inst = Instance(profile, clock=clock, autorun=False)
        settle(inst.device, clock)
        client = await aiohttp_client(inst.app)
        return inst, client

    return make


async def advance(inst, clock, ms, step=20):
    await asyncio.sleep(0.02)  # let the server read what the test just sent
    for _ in range(max(1, ms // step)):
        clock.advance(step)
        await inst.step()


async def receive_json(ws, timeout=1.0):
    msg = await ws.receive(timeout=timeout)
    return json.loads(msg.data)


async def nothing(ws, timeout=0.05):
    try:
        msg = await ws.receive(timeout=timeout)
    except asyncio.TimeoutError:
        return True
    raise AssertionError(f"unexpected message {msg}")
