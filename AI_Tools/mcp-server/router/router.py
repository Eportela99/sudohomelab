#!/usr/bin/env python3
"""sudo homelab model router: one OpenAI-compatible address for every AI node.

It starts EMPTY. An AI node (SudoHomelab Script 2) joins with the join token:

  POST /nodes/register   Authorization: Bearer <JOIN_TOKEN>
  {"name": "gaming-pc", "base_url": "http://100.x.y.z:8080/v1", "api_key": "...",
   "models": [{"id": "qwen3.6-35b", "context": 65536, "tags": ["tools"]}],
   "hardware": "...", "wake": {"mac": "aa:bb:..", "broadcast": "192.168.1.255"}}
  -> {"node_id": "...", "node_token": "..."}

The join token can ONLY register nodes. Clients use MCP_TOKEN:
  GET  /v1/models                 every model as "model@node", plus "default"
  POST /v1/chat/completions       (and /v1/completions, /v1/embeddings) forwarded,
                                  streaming included, to the node that has the model
  GET  /nodes                     nodes with status; DELETE /nodes/{id} removes one
  POST /nodes/{id}/default        make that node's first model the default
A node can PUT /nodes/{id} (update its models) or DELETE itself with its node token.
"""
import asyncio
import contextlib
import hmac
import json
import os
import secrets
import time

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

DATA = os.environ.get("DATA_DIR", "/data")
STATE = os.path.join(DATA, "nodes.json")
TOKEN = os.environ.get("MCP_TOKEN", "").strip()
JOIN_TOKEN = os.environ.get("JOIN_TOKEN", "").strip()
CHECK_EVERY = int(os.environ.get("ROUTER_CHECK_SECONDS", "60"))

if not TOKEN or not JOIN_TOKEN:
    raise SystemExit("MCP_TOKEN and JOIN_TOKEN must be set (see /opt/sudohomelab/mcp/.env)")

client = httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=10.0))
_lock = asyncio.Lock()


def load():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {"nodes": {}, "default": None}


def save(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, STATE)


state = load()


def bearer(request):
    auth = request.headers.get("authorization", "")
    return auth[7:].strip() if auth.lower().startswith("bearer ") else ""


def same(a, b):
    return bool(a) and bool(b) and hmac.compare_digest(a, b)


def err(status, msg):
    return JSONResponse({"error": {"message": msg}}, status_code=status)


def public(node):
    """A node without its secrets, each model marked if it is the default."""
    n = {k: v for k, v in node.items() if k not in ("api_key", "node_token", "models")}
    n["models"] = [dict(m, default=state.get("default") == "%s@%s" % (m["id"], node["name"]))
                   for m in node.get("models", [])]
    return n


def model_table():
    """{"model@node": (node, model_id)} for every online-or-unknown node."""
    out = {}
    for node in state["nodes"].values():
        for m in node.get("models", []):
            out["%s@%s" % (m["id"], node["name"])] = (node, m["id"])
    return out


def resolve(name):
    table = model_table()
    if name in (None, "", "default"):
        name = state.get("default")
    if name in table:
        return table[name]
    # A bare model id works when exactly one node has it.
    hits = [v for k, v in table.items() if k.split("@", 1)[0] == name]
    return hits[0] if len(hits) == 1 else (None, None)


# ── node registration ─────────────────────────────────────────────────────────

def clean_models(models):
    out = []
    for m in models or []:
        mid = str(m.get("id") if isinstance(m, dict) else m).strip()
        if mid:
            out.append({"id": mid, "context": int((m or {}).get("context") or 0) if isinstance(m, dict) else 0,
                        "tags": list((m or {}).get("tags") or []) if isinstance(m, dict) else []})
    return out


async def register(request: Request):
    if not same(bearer(request), JOIN_TOKEN):
        return err(401, "a valid join token is required")
    try:
        body = await request.json()
    except Exception:
        return err(400, "JSON body required")
    name = "".join(c for c in str(body.get("name") or "").lower() if c.isalnum() or c in "-_.")[:40]
    base = str(body.get("base_url") or "").rstrip("/")
    models = clean_models(body.get("models"))
    if not name or not base.startswith(("http://", "https://")) or not models:
        return err(400, "name, base_url (http/https) and at least one model are required")
    async with _lock:
        # Re-joining with the same name replaces the old entry (new token).
        for nid, n in list(state["nodes"].items()):
            if n["name"] == name:
                del state["nodes"][nid]
        nid, ntok = secrets.token_hex(6), secrets.token_urlsafe(32)
        state["nodes"][nid] = {
            "id": nid, "name": name, "base_url": base, "api_key": str(body.get("api_key") or ""),
            "node_token": ntok, "models": models, "hardware": str(body.get("hardware") or "")[:500],
            "wake": body.get("wake") or {}, "status": "unknown", "joined": int(time.time()),
            "last_seen": None,
        }
        if not state.get("default") or state["default"] not in model_table():
            state["default"] = "%s@%s" % (models[0]["id"], name)
        save(state)
    asyncio.create_task(check_node(nid))
    return JSONResponse({"node_id": nid, "node_token": ntok,
                         "models": ["%s@%s" % (m["id"], name) for m in models],
                         "default": state["default"]})


def node_or_client(request, nid):
    node = state["nodes"].get(nid)
    tok = bearer(request)
    if node and same(tok, node.get("node_token")):
        return node, True
    if same(tok, TOKEN):
        return node, True
    return node, False


async def node_item(request: Request):
    nid = request.path_params["nid"]
    node, allowed = node_or_client(request, nid)
    if not allowed:
        return err(401, "node token or MCP token required")
    if not node:
        return err(404, "no such node")
    async with _lock:
        if request.method == "DELETE":
            del state["nodes"][nid]
            if state.get("default") not in model_table():
                state["default"] = next(iter(model_table()), None)
            save(state)
            return JSONResponse({"removed": nid})
        body = await request.json()
        if body.get("models"):
            node["models"] = clean_models(body["models"])
        for k in ("base_url", "api_key", "hardware", "wake"):
            if k in body:
                node[k] = body[k]
        if state.get("default") not in model_table():
            state["default"] = next(iter(model_table()), None)
        save(state)
    return JSONResponse(public(node))


async def set_default(request: Request):
    if not same(bearer(request), TOKEN):
        return err(401, "MCP token required")
    node = state["nodes"].get(request.path_params["nid"])
    if not node:
        return err(404, "no such node")
    body = {}
    try:
        body = await request.json()
    except Exception:
        pass
    mid = body.get("model") or node["models"][0]["id"]
    if mid not in [m["id"] for m in node["models"]]:
        return err(404, "%s has no model %r" % (node["name"], mid))
    async with _lock:
        state["default"] = "%s@%s" % (mid, node["name"])
        save(state)
    return JSONResponse({"default": state["default"]})


async def list_nodes(request: Request):
    if not same(bearer(request), TOKEN):
        return err(401, "MCP token required")
    return JSONResponse({"nodes": [public(n) for n in state["nodes"].values()],
                         "default": state.get("default")})


# ── health checks ─────────────────────────────────────────────────────────────

async def check_node(nid):
    node = state["nodes"].get(nid)
    if not node:
        return
    headers = {"Authorization": "Bearer " + node["api_key"]} if node.get("api_key") else {}
    try:
        r = await client.get(node["base_url"] + "/models", headers=headers, timeout=8.0)
        node["status"] = "online" if r.status_code < 500 else "error"
        node["last_seen"] = int(time.time())
    except Exception:
        # A node that has wake info and stopped answering is most likely asleep.
        node["status"] = "asleep" if (node.get("wake") or {}).get("mac") else "offline"


async def checker():
    while True:
        for nid in list(state["nodes"]):
            await check_node(nid)
        async with _lock:
            save(state)
        await asyncio.sleep(CHECK_EVERY)


# ── OpenAI-compatible client API ──────────────────────────────────────────────

async def models(request: Request):
    if not same(bearer(request), TOKEN):
        return err(401, "MCP token required")
    data = [{"id": k, "object": "model", "owned_by": n["name"],
             "meta": {"status": n["status"], "context": next(
                 (m["context"] for m in n["models"] if m["id"] == mid), 0)}}
            for k, (n, mid) in model_table().items()]
    if state.get("default"):
        data.insert(0, {"id": "default", "object": "model", "owned_by": "router",
                        "meta": {"points_to": state["default"]}})
    return JSONResponse({"object": "list", "data": data})


async def forward(request: Request):
    if not same(bearer(request), TOKEN):
        return err(401, "MCP token required")
    try:
        body = await request.json()
    except Exception:
        return err(400, "JSON body required")
    node, mid = resolve(body.get("model"))
    if not node:
        if not state["nodes"]:
            return err(503, "no models yet: the router is empty until an AI node joins "
                            "(SudoHomelab Script 2, with the join code)")
        return err(404, "unknown model %r; see GET /v1/models" % body.get("model"))
    body["model"] = mid
    url = node["base_url"] + request.url.path[len("/v1"):]
    headers = {"Content-Type": "application/json"}
    if node.get("api_key"):
        headers["Authorization"] = "Bearer " + node["api_key"]
    try:
        upstream = await client.send(client.build_request("POST", url, json=body, headers=headers),
                                     stream=True)
    except Exception as e:
        node["status"] = "offline"
        return err(502, "node %s is not answering (%s)" % (node["name"], type(e).__name__))
    node["status"], node["last_seen"] = "online", int(time.time())

    async def relay():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()

    ctype = upstream.headers.get("content-type", "application/json")
    return StreamingResponse(relay(), status_code=upstream.status_code, media_type=ctype)


async def health(_request):
    return JSONResponse({"status": "ok", "nodes": len(state["nodes"]),
                         "models": len(model_table()), "default": state.get("default")})


@contextlib.asynccontextmanager
async def lifespan(_app):
    task = asyncio.create_task(checker())
    yield
    task.cancel()


app = Starlette(routes=[
    Route("/health", health),
    Route("/v1/models", models),
    Route("/v1/chat/completions", forward, methods=["POST"]),
    Route("/v1/completions", forward, methods=["POST"]),
    Route("/v1/embeddings", forward, methods=["POST"]),
    Route("/nodes", list_nodes),
    Route("/nodes/register", register, methods=["POST"]),
    Route("/nodes/{nid}", node_item, methods=["PUT", "DELETE"]),
    Route("/nodes/{nid}/default", set_default, methods=["POST"]),
], lifespan=lifespan)

if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    uvicorn.run(app, host=os.environ.get("ROUTER_HOST", "0.0.0.0"),
                port=int(os.environ.get("ROUTER_PORT", "8791")), log_level="warning")
