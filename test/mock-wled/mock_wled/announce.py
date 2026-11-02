"""How a controller makes itself known: mDNS and WLED's node broadcast. Both are opt-in.

mDNS follows wled.cpp: _wled._tcp and _http._tcp with one TXT key, mac. The mock announces its
own port, where a real controller always announces 80.

The node broadcast follows udp.cpp sendSysInfoUDP: 44 bytes to 255.255.255.255 on port 65506,
every 30 s and whenever the master brightness changes.
"""

import asyncio
import socket
import struct

NODE_PORT = 65506
NODE_INTERVAL = 30


def node_packet(device, ip):
    """udp.cpp sendSysInfoUDP."""
    octets = [int(x) for x in ip.split(".")] if ip else [4, 3, 2, 1]
    name = device.name.encode("utf-8")[:32].ljust(32, b"\0")
    node_type = device.chip["node_type"] | (0x80 if device.bri else 0)
    return (
        bytes([255, 1])
        + bytes(octets)
        + name
        + bytes([node_type, octets[3]])
        + struct.pack("<I", device.fw["vid"])
    )


class NodeBroadcaster:
    def __init__(self, instance, ip, port=NODE_PORT, address="255.255.255.255"):
        self.instance, self.ip, self.port, self.address = instance, ip, port, address
        self.sock = None
        self.task = None

    async def start(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.setblocking(False)
        self.task = asyncio.create_task(self.run())

    async def run(self):
        while True:
            self.send()
            await asyncio.sleep(NODE_INTERVAL)

    def send(self):
        if self.sock and not self.instance.down:
            try:
                self.sock.sendto(
                    node_packet(self.instance.device, self.ip), (self.address, self.port)
                )
            except OSError:
                pass

    def node_changed(self):
        self.send()

    async def stop(self):
        if self.task:
            self.task.cancel()
        if self.sock:
            self.sock.close()


class MdnsAnnouncer:
    def __init__(self, instance, ip):
        self.instance, self.ip = instance, ip
        self.zc = None
        self.infos = []

    async def start(self):
        from zeroconf import ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf

        d = self.instance.device
        host = f"wled-{d.mac[6:]}.local."
        props = {"mac": d.mac}
        self.zc = AsyncZeroconf()
        for kind in ("_wled._tcp.local.", "_http._tcp.local."):
            info = ServiceInfo(
                kind,
                f"wled-{d.mac[6:]}.{kind}",
                addresses=[socket.inet_aton(self.ip)],
                port=self.instance.port,
                properties=props if kind.startswith("_wled") else {},
                server=host,
            )
            await self.zc.async_register_service(info)
            self.infos.append(info)

    async def stop(self):
        if self.zc:
            for info in self.infos:
                await self.zc.async_unregister_service(info)
            await self.zc.async_close()
