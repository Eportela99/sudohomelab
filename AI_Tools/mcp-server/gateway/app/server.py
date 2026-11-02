#!/usr/bin/env python3
"""sudo homelab MCP gateway: one address, one token, every tool group you picked.

TOOLS (env) is the comma list of groups to switch on; "core" is always on.
Every request needs `Authorization: Bearer <MCP_TOKEN>` except GET /health.
"""
import functools
import hmac
import importlib
import inspect
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import anyio.to_thread  # noqa: E402
import uvicorn  # noqa: E402
from mcp.server.fastmcp import FastMCP  # noqa: E402
from mcp.server.transport_security import TransportSecuritySettings  # noqa: E402

from common import env  # noqa: E402

logging.basicConfig(level=env("MCP_LOG_LEVEL", "WARNING").upper(),
                    format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("gateway")

HOST = env("MCP_HOST", "0.0.0.0")
PORT = int(env("MCP_PORT", "8790"))
TOKEN = env("MCP_TOKEN")
# Every group the gateway knows. RULE: a new tool group goes here AND in the
# installer's tool list (AI_Tools/linux/mcp-server.sh, TOOL_IDS).
GROUPS = ["core", "search", "knowledge", "files", "vault"]

if not TOKEN:
    sys.exit("MCP_TOKEN is not set. The installer writes it to /opt/sudohomelab/mcp/.env.")

mcp = FastMCP(
    "sudohomelab-mcp", host=HOST, port=PORT, stateless_http=True,
    # Reached through LAN IPs, Tailscale names and `tailscale serve`, so the Host
    # header can be anything; the bearer token is what protects the endpoint.
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

wanted = {g.strip() for g in env("TOOLS", ",".join(GROUPS)).split(",") if g.strip()} | {"core"}
core = importlib.import_module("tools.core")
for group in GROUPS:
    if group not in wanted:
        continue
    mod = core if group == "core" else importlib.import_module("tools." + group)
    mod.register(mcp)
    core.ENABLED[group] = list(mod.TOOLS)
log.warning("tool groups on: %s", ", ".join(core.ENABLED))


def _off_loop(m):
    """Run sync tools in worker threads, so a slow fetch or embedding call never
    stalls the other clients. FastMCP would otherwise call them on the event loop."""
    def wrap(fn):
        @functools.wraps(fn)
        async def threaded(**kw):
            return await anyio.to_thread.run_sync(functools.partial(fn, **kw))
        return threaded
    for t in m._tool_manager.list_tools():
        if not t.is_async and not inspect.iscoroutinefunction(t.fn):
            t.fn, t.is_async = wrap(t.fn), True


_off_loop(mcp)


class BearerAuth:
    """Checks the token on every HTTP request; /health stays open for probes."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path") == "/health":
            if scope["type"] == "http" and scope.get("path") == "/health":
                return await self._send(send, 200, b'{"status":"ok"}')
            return await self.app(scope, receive, send)
        auth = dict(scope.get("headers") or []).get(b"authorization", b"").decode()
        given = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        if not given or not hmac.compare_digest(given, TOKEN):
            return await self._send(send, 401, b'{"error":"missing or wrong bearer token"}')
        return await self.app(scope, receive, send)

    @staticmethod
    async def _send(send, status, body):
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"),
                                (b"content-length", str(len(body)).encode())]})
        await send({"type": "http.response.body", "body": body})


if __name__ == "__main__":
    uvicorn.run(BearerAuth(mcp.streamable_http_app()), host=HOST, port=PORT,
                log_level="warning", proxy_headers=True)
