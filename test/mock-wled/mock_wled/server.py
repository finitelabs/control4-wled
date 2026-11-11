"""HTTP and WebSocket front end for one mock controller, plus the control API.

The WLED side follows wled00/wled_server.cpp, json.cpp (serveJson) and ws.cpp at the pinned
releases. The control API lives under /_mock/, a path WLED never serves, and plays the world
outside the API: a button press, another client, live data, a settings change, a reboot, a
dropped link, a busy JSON buffer, an overloaded send buffer.
"""

import asyncio
import json
import logging

from aiohttp import WSCloseCode, WSMsgType, web

from .device import (
    CALL_MODE_DIRECT_CHANGE,
    CALL_MODE_WS_SEND,
    ERR_JSON,
    ERR_NOBUF,
    ERR_NOT_IMPL,
    JSON_LOCK_WAIT,
    Device,
)

log = logging.getLogger("mock_wled")

CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "*",
    "Access-Control-Allow-Headers": "*",
}


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)


class Client:
    def __init__(self, ws, request, seq):
        self.ws = ws
        self.request = request
        self.seq = seq


class Instance:
    """One controller on one port."""

    def __init__(self, profile, host="0.0.0.0", port=80, clock=None, autorun=True, tick_ms=5):
        self.host, self.port = host, port
        self.autorun, self.tick_ms = autorun, tick_ms
        self.clients = []
        self.announcers = []
        self.seq = 0
        self.down = False
        self.runner = None
        self.site = None
        self.loop_task = None
        self.device = Device(profile, clock, on_node_info=self._node_info)
        self.device.ws_count = lambda: len(self.clients)
        self.app = self.make_app()

    # ---- lifecycle ---------------------------------------------------------------------------

    def make_app(self):
        app = web.Application(middlewares=[self.cors_middleware])
        app.router.add_route("GET", "/json", self.get_json)
        app.router.add_route("GET", "/json/{tail:.*}", self.get_json)
        app.router.add_route("POST", "/json", self.post_json)
        app.router.add_route("POST", "/json/{tail:.*}", self.post_json)
        app.router.add_route("GET", "/presets.json", self.get_presets)
        app.router.add_route("GET", "/ws", self.websocket)
        app.router.add_route("GET", "/_mock", self.mock_help)
        app.router.add_route("GET", "/_mock/output", self.mock_output)
        app.router.add_route("GET", "/_mock/clients", self.mock_clients)
        app.router.add_route("POST", "/_mock/{action}", self.mock_action)
        app.router.add_route("OPTIONS", "/{tail:.*}", self.options)
        return app

    @web.middleware
    async def cors_middleware(self, request, handler):
        if self.down and not request.path.startswith("/_mock"):
            raise web.HTTPServiceUnavailable(text="rebooting")
        sock = request.transport.get_extra_info("sockname") if request.transport else None
        if sock and not self.device.profile.get("ip"):
            self.device.ip = sock[0]
        resp = await handler(request)
        if not resp.prepared:
            resp.headers.update(CORS)
        return resp

    async def start(self):
        self.runner = web.AppRunner(self.app, handle_signals=False)
        await self.runner.setup()
        await self.start_site()
        if self.autorun:
            self.loop_task = asyncio.create_task(self.run_loop())

    async def start_site(self):
        self.site = web.TCPSite(self.runner, self.host, self.port, reuse_address=True)
        await self.site.start()
        if self.port == 0:
            self.port = self.site._server.sockets[0].getsockname()[1]

    async def stop(self):
        if self.loop_task:
            self.loop_task.cancel()
        for a in self.announcers:
            await a.stop()
        for c in list(self.clients):
            await c.ws.close()
        if self.runner:
            await self.runner.cleanup()

    async def run_loop(self):
        while True:
            await asyncio.sleep(self.tick_ms / 1000)
            try:
                await self.step()
            except Exception:  # keep the loop alive; a test sees the log
                log.exception("tick failed")

    async def step(self):
        """One WLED main loop pass: handlers, then any due push, then client cleanup."""
        if self.down:
            return
        self.device.tick()
        await self.flush()
        await self.cleanup_clients()
        if self.device.do_reboot:
            await self.reboot(3000)

    async def flush(self):
        if self.device.push_due:
            self.device.push_due = False
            await self.send_data(None)

    # ---- the shared JSON buffer --------------------------------------------------------------

    async def lock_buffer(self, wait=True):
        """requestJSONBufferLock: waits up to 250 ms for the buffer, then gives up.

        An ESP8266 in system context (web server and WebSocket handlers) cannot wait at all.
        """
        busy = self.device.busy_for()
        if not busy:
            return True
        if not wait:
            return False
        await asyncio.sleep(min(busy, JSON_LOCK_WAIT) / 1000)
        return busy <= JSON_LOCK_WAIT

    async def lock_or_defer(self):
        """16.0.1 defers the request until the buffer is free; 0.15.4 answers 503."""
        if await self.lock_buffer(wait=self.device.chip_name != "esp8266"):
            return None
        if not self.device.v16:
            return self.json_error(503, ERR_NOBUF)
        while self.device.busy_for():
            await asyncio.sleep(0.01)
        return None

    def json_error(self, code, error):
        headers = {"Retry-After": "1"} if error < ERR_NOT_IMPL else {}
        return web.Response(
            status=code,
            text=dumps({"error": error}),
            content_type="application/json",
            headers=headers,
        )

    # ---- WLED HTTP API -----------------------------------------------------------------------

    def target(self, url):
        """serveJson picks its reply by substring, in this order."""
        d = self.device
        for key, name in (
            ("state", "state"),
            ("info", "info"),
            ("si", "si"),
            ("nodes", "nodes"),
            ("eff", "eff"),
            ("palx", "palx"),
            ("fxda", "fxdata"),
            ("net", "net"),
        ):
            if url.find(key) > 0:
                return name
        if d.v16 and url.find("cfg") > 0:
            return "cfg"
        if d.v16 and url.find("pins") > 0:
            return "pins"
        if url.find("pal") > 0:
            return "pal"
        if not d.v16 and url.find("cfg") > 0:
            return "cfg_file"
        if len(url) > 6:
            return "unknown"
        return "all"

    def json_body(self, target):
        d = self.device
        if target == "state":
            return d.serialize_state()
        if target == "info":
            return d.serialize_info()
        if target == "nodes":
            return {"nodes": []}
        if target == "eff":
            return [n for n in d.eff if n]
        if target == "fxdata":
            return list(d.fxdata)
        if target == "palx":
            return {"m": 0, "p": {}}
        if target == "net":
            return {"networks": []}
        if target in ("cfg", "cfg_file"):
            return d.serialize_cfg()
        if target == "pins":
            return {"pins": []}
        body = {"state": d.serialize_state(), "info": d.serialize_info()}
        if target == "all":
            body["effects"] = [n for n in d.eff if n]
            body["palettes"] = list(d.pal)
        return body

    async def serve_json(self, request):
        target = self.target(request.path)
        if target == "unknown":
            return self.json_error(501, ERR_NOT_IMPL)
        if target == "pal":
            return self.json_response(list(self.device.pal))
        streamed = (target == "fxdata" and self.device.v16) or target == "cfg_file"
        if not streamed:
            refused = await self.lock_or_defer()
            if refused:
                return refused
        return self.json_response(self.json_body(target))

    def json_response(self, body):
        return web.Response(text=dumps(body), content_type="application/json")

    async def get_json(self, request):
        return await self.serve_json(request)

    async def post_json(self, request):
        refused = await self.lock_or_defer()
        if refused:
            return refused
        try:
            root = json.loads(await request.text())
        except ValueError:
            root = None
        if not isinstance(root, dict):
            return self.json_error(400, ERR_JSON)
        if request.path.find("cfg") > -1:
            return self.json_error(501, ERR_NOT_IMPL)  # settings writes go through /_mock/white
        verbose = self.device.deserialize_state(root, CALL_MODE_DIRECT_CHANGE)
        await self.after_command()
        if verbose:
            # wled_server.cpp: a verbose reply holds the next push back a full cooldown.
            self.device.last_interface_update = self.device.now()
            self.device.interface_update_call_mode = CALL_MODE_WS_SEND
            return self.json_response(self.json_body(self.target(request.path)))
        return self.json_response({"success": True})

    async def get_presets(self, request):
        return self.json_response(self.device.presets)

    async def options(self, request):
        return web.Response(headers={**CORS, "Access-Control-Max-Age": "7200"})

    async def after_command(self):
        if self.device.do_reboot:
            self.device.do_reboot = False
            self.later(self.reboot, 3000)

    # ---- WebSocket ---------------------------------------------------------------------------

    async def websocket(self, request):
        ws = web.WebSocketResponse(autoping=True, max_msg_size=0)
        await ws.prepare(request)
        self.seq += 1
        client = Client(ws, request, self.seq)
        self.clients.append(client)
        await self.send_data(client)
        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    await self.ws_text(client, msg.data)
        finally:
            if client in self.clients:
                self.clients.remove(client)
        return ws

    async def ws_text(self, client, text):
        """ws.cpp wsEvent for one text message."""
        d, raw = self.device, text.encode()
        if len(raw) > d.ws_frame_max:
            await client.ws.send_str('{"error":9}')  # split across packets: not handled
            return
        if 0 < len(raw) < 10 and raw[:1] == b"p":
            await client.ws.send_str("pong")
            return
        if not await self.lock_buffer(wait=d.chip_name != "esp8266"):
            await client.ws.send_str('{"error":3}')
            return
        try:
            root = json.loads(text)
        except ValueError:
            return
        if not isinstance(root, dict):
            return
        verbose = False
        if root.get("v") and len(root) == 1:
            verbose = True
        elif "lv" in root:
            pass  # live LED stream not modeled
        else:
            verbose = d.deserialize_state(root)
        await self.after_command()
        if not d.interface_update_call_mode:
            if verbose:
                await self.send_data(client)
            else:
                await client.ws.send_str('{"success":true}')

    async def send_data(self, client):
        """ws.cpp sendDataWs: state and info to one client, or to all of them."""
        targets = [client] if client else list(self.clients)
        if not self.clients:
            return
        if not await self.lock_buffer():
            for c in targets:
                await self._send(c, '{"error":3}')
            return
        payload = dumps(self.device.ws_payload())
        for c in targets:
            await self._send(c, payload)

    async def _send(self, client, text):
        try:
            await client.ws.send_str(text)
        except (ConnectionResetError, RuntimeError):
            pass

    async def cleanup_clients(self):
        """handleWs: past the chip's limit the oldest client is closed, one per loop pass."""
        live = [c for c in self.clients if not c.ws.closed]
        self.clients = live
        if len(live) > self.device.ws_clients_max:
            await close_without_status(live[0].ws)
            self.clients.remove(live[0])

    # ---- outside events ----------------------------------------------------------------------

    def _node_info(self):
        for a in self.announcers:
            notify = getattr(a, "node_changed", None)
            if notify:
                notify()

    async def drop_all(self):
        """The link goes away: every socket dies without a close frame, keep-alive ones too."""
        for c in list(self.clients):
            transport = c.request.transport
            if transport:
                transport.abort()
        self.clients = []
        server = self.runner.server if self.runner else None
        for proto in list(getattr(server, "connections", None) or []):
            transport = getattr(proto, "transport", None)
            if transport:
                transport.abort()

    def later(self, coro_fn, *args):
        """Run after the control reply has gone out."""
        asyncio.get_running_loop().call_later(0.05, lambda: asyncio.ensure_future(coro_fn(*args)))

    async def reboot(self, down_ms):
        self.device.do_reboot = False
        self.down = True
        await self.drop_all()
        await self.site.stop()
        await asyncio.sleep(down_ms / 1000)
        self.device.boot()
        await self.start_site()
        self.down = False

    async def outage(self, down_ms):
        self.down = True
        await self.drop_all()
        await self.site.stop()
        await asyncio.sleep(down_ms / 1000)
        await self.start_site()
        self.down = False

    # ---- control API -------------------------------------------------------------------------

    async def mock_help(self, request):
        return self.json_response(
            {
                "firmware": self.device.version,
                "chip": self.device.chip_name,
                "actions": {
                    "POST /_mock/button": '{"preset": 0} toggles, a preset id applies it; '
                    '{"kind": "long"} picks a random color, "double" toggles twice',
                    "POST /_mock/client": "any JSON state, applied as another client would",
                    "POST /_mock/live": '{"mode": "e131", "ip": "192.0.2.200"} starts live data',
                    "POST /_mock/live_stop": '{"immediate": false} ends it, after the timeout',
                    "POST /_mock/white": '{"bus": 0, "rgbwm": 2} or {"rgbwm", "correct_wb", '
                    '"cct_from_rgb"}; {"push": true} also pushes; {"at_restart": true} saves it '
                    "for the next restart, as /json/cfg does",
                    "POST /_mock/reboot": '{"down_ms": 3000}',
                    "POST /_mock/drop": '{"down_ms": 0} drops every socket, optionally refuses',
                    "POST /_mock/busy": '{"ms": 500} holds the JSON buffer',
                    "POST /_mock/overload": "closes every WebSocket with 1013",
                    "GET /_mock/output": "what the strip shows now",
                    "GET /_mock/clients": "connected WebSocket clients, oldest first",
                },
            }
        )

    async def mock_output(self, request):
        return self.json_response(self.device.output())

    async def mock_clients(self, request):
        return self.json_response(
            [{"seq": c.seq, "peer": str(c.request.remote)} for c in self.clients]
        )

    async def mock_action(self, request):
        action = request.match_info["action"]
        try:
            body = json.loads(await request.text() or "{}")
        except ValueError:
            return web.json_response({"error": "body is not JSON"}, status=400)
        if not isinstance(body, dict) and action != "client":
            return web.json_response({"error": "body must be an object"}, status=400)
        d = self.device
        if action == "button":
            kind = body.get("kind", "short")
            if kind not in ("short", "long", "double"):
                return web.json_response({"error": f"unknown press {kind}"}, status=400)
            d.press_button(int(body.get("preset", 0)), kind)
        elif action == "client":
            d.deserialize_state(body, CALL_MODE_DIRECT_CHANGE)
            await self.after_command()
        elif action == "live":
            try:
                d.live_start(body.get("mode", "e131"), body.get("ip", "192.0.2.200"))
            except ValueError as e:
                return web.json_response({"error": str(e)}, status=400)
        elif action == "live_stop":
            d.live_stop(bool(body.get("immediate", False)))
        elif action == "white":
            later = bool(body.get("at_restart", False))
            if "bus" in body:
                d.set_bus(int(body["bus"]), body.get("rgbwm"), later)
            else:
                d.set_white(
                    body.get("rgbwm"), body.get("correct_wb"), body.get("cct_from_rgb"), later
                )
            if body.get("push"):
                d.interface_update_call_mode = CALL_MODE_DIRECT_CHANGE
        elif action == "reboot":
            self.later(self.reboot, int(body.get("down_ms", 3000)))
        elif action == "drop":
            down = int(body.get("down_ms", 0))
            if down:
                self.later(self.outage, down)
            else:
                self.later(self.drop_all)
        elif action == "busy":
            d.make_busy(int(body.get("ms", 500)))
        elif action == "overload":
            for c in list(self.clients):
                await c.ws.close(code=WSCloseCode.TRY_AGAIN_LATER)
            self.clients = []
        else:
            return web.json_response({"error": f"unknown action {action}"}, status=404)
        return web.json_response({"ok": True})


async def close_without_status(ws):
    """AsyncWebSocketClient::close() with no code sends an empty close frame (seen as 1005)."""
    writer = getattr(ws, "_writer", None)
    send_frame = getattr(writer, "send_frame", None)
    if send_frame is None:
        await ws.close()
        return
    try:
        await send_frame(b"", WSMsgType.CLOSE)
    except (ConnectionResetError, RuntimeError):
        pass
    transport = getattr(ws, "_req", None) and ws._req.transport
    if transport:
        transport.close()
