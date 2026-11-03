#!/usr/bin/env python3
"""Open WebUI link for the sudo homelab MCP server. Runs INSIDE the router container.

Puts three things into an Open WebUI (one this installer made, or one you already run):
  · a model connection to the router  -> every model@node that joins shows up by itself
  · the MCP server as a tool server   -> id "sudohomelab"
  · default model settings            -> every model gets those tools, native function calling
Everything else in that Open WebUI is left alone, and the settings are saved to
/data/webui-backup-<time>.json before each change.

  webui.py bootstrap URL EMAIL          sign in (password on stdin), print an API key
  webui.py check URL                    version, and whether the link is there (key on stdin)
  webui.py sync URL ROUTER_V1 MCP_URL   add / refresh the link (key on stdin)
  webui.py remove URL ROUTER_V1 MCP_URL take the link out again (key on stdin)
"""
import json
import os
import sys
import time

import httpx

TOKEN = os.environ.get("MCP_TOKEN", "")
TOOL_ID = "sudohomelab"
TOOL_REF = "server:mcp:" + TOOL_ID


def out(obj):
    print(json.dumps(obj))


class WebUI:
    def __init__(self, url, key):
        self.url = url.rstrip("/")
        self.c = httpx.Client(timeout=60, headers={"Authorization": "Bearer " + key} if key else {})

    def call(self, method, path, body=None):
        r = self.c.request(method, self.url + path, json=body)
        if r.status_code == 401:
            raise SystemExit("Open WebUI refused the API key (401). Use an admin's key, and check that "
                             "API keys are enabled (Admin Settings -> General).")
        if r.status_code >= 400:
            raise SystemExit("Open WebUI %s %s -> %s: %s" % (method, path, r.status_code, r.text[:200]))
        return r.json() if r.content else {}


def bootstrap(url, email, password):
    c = httpx.Client(timeout=60)
    for _ in range(60):  # a fresh Open WebUI takes a while to start
        try:
            if c.get(url.rstrip("/") + "/health").status_code == 200:
                break
        except httpx.HTTPError:
            pass
        time.sleep(5)
    r = c.post(url.rstrip("/") + "/api/v1/auths/signin", json={"email": email, "password": password})
    if r.status_code != 200:
        raise SystemExit("Couldn't sign in to Open WebUI as %s (%s)" % (email, r.status_code))
    w = WebUI(url, r.json()["token"])
    try:
        key = w.call("GET", "/api/v1/auths/api_key").get("api_key")
    except SystemExit:
        key = None
    out({"api_key": key or w.call("POST", "/api/v1/auths/api_key")["api_key"]})


def backup(w):
    snap = {"openai": w.call("GET", "/openai/config"),
            "tool_servers": w.call("GET", "/api/v1/configs/tool_servers"),
            "models": w.call("GET", "/api/v1/configs/models")}
    p = "/data/webui-backup-%s.json" % time.strftime("%Y%m%d-%H%M%S")
    with open(p, "w") as f:
        json.dump(snap, f, indent=2)
    return snap, p


def ours_openai(url, router_v1):
    return url.rstrip("/") == router_v1.rstrip("/")


def check(url, key, router_v1="", mcp_url=""):
    w = WebUI(url, key)
    ver = httpx.get(url.rstrip("/") + "/api/version", timeout=20).json().get("version")
    oa = w.call("GET", "/openai/config")
    ts = w.call("GET", "/api/v1/configs/tool_servers").get("TOOL_SERVER_CONNECTIONS") or []
    md = (w.call("GET", "/api/v1/configs/models").get("DEFAULT_MODEL_METADATA") or {})
    out({"version": ver,
         "router": any(ours_openai(u, router_v1) for u in oa.get("OPENAI_API_BASE_URLS", [])) if router_v1 else None,
         "mcp": any((t.get("info") or {}).get("id") == TOOL_ID for t in ts),
         "default_tools": TOOL_REF in (md.get("toolIds") or [])})


def sync(url, key, router_v1, mcp_url):
    w = WebUI(url, key)
    snap, bpath = backup(w)

    # 1. model connection to the router (replace ours if it is already there)
    oa = snap["openai"]
    urls, keys = list(oa.get("OPENAI_API_BASE_URLS") or []), list(oa.get("OPENAI_API_KEYS") or [])
    cfgs = dict(oa.get("OPENAI_API_CONFIGS") or {})
    keys += [""] * (len(urls) - len(keys))
    idx = next((i for i, u in enumerate(urls) if ours_openai(u, router_v1)), None)
    if idx is None:
        idx = len(urls)
        urls.append(router_v1)
        keys.append(TOKEN)
    else:
        keys[idx] = TOKEN
    cfg = dict(cfgs.get(str(idx)) or {})
    cfg.update({"enable": True, "connection_type": "external"})
    cfg.setdefault("tags", [{"name": "sudohomelab"}])
    cfgs[str(idx)] = cfg
    w.call("POST", "/openai/config/update", {"ENABLE_OPENAI_API": True, "OPENAI_API_BASE_URLS": urls,
                                             "OPENAI_API_KEYS": keys, "OPENAI_API_CONFIGS": cfgs})

    # 2. the MCP server as a tool server
    ts = [t for t in (snap["tool_servers"].get("TOOL_SERVER_CONNECTIONS") or [])
          if (t.get("info") or {}).get("id") != TOOL_ID]
    ts.append({"type": "mcp", "url": mcp_url, "path": "", "auth_type": "bearer", "key": TOKEN,
               "config": {"enable": True},
               "info": {"id": TOOL_ID, "name": "sudo homelab MCP",
                        "description": "Tools from the sudo homelab MCP server"}})
    w.call("POST", "/api/v1/configs/tool_servers", {"TOOL_SERVER_CONNECTIONS": ts})

    # 3. every model: those tools on by default, native function calling
    mc = dict(snap["models"])
    meta = dict(mc.get("DEFAULT_MODEL_METADATA") or {})
    meta["toolIds"] = sorted(set(meta.get("toolIds") or []) | {TOOL_REF})
    params = dict(mc.get("DEFAULT_MODEL_PARAMS") or {})
    params.setdefault("function_calling", "native")
    mc.update(DEFAULT_MODEL_METADATA=meta, DEFAULT_MODEL_PARAMS=params)
    w.call("POST", "/api/v1/configs/models", mc)

    n = len(w.call("GET", "/api/models").get("data", []))
    out({"ok": True, "backup": bpath, "models_visible": n})


def remove(url, key, router_v1, mcp_url):
    w = WebUI(url, key)
    snap, bpath = backup(w)
    oa = snap["openai"]
    urls, keys = list(oa.get("OPENAI_API_BASE_URLS") or []), list(oa.get("OPENAI_API_KEYS") or [])
    keys += [""] * (len(urls) - len(keys))
    cfgs = oa.get("OPENAI_API_CONFIGS") or {}
    keep = [i for i, u in enumerate(urls) if not ours_openai(u, router_v1)]
    w.call("POST", "/openai/config/update", {
        "ENABLE_OPENAI_API": oa.get("ENABLE_OPENAI_API", True),
        "OPENAI_API_BASE_URLS": [urls[i] for i in keep], "OPENAI_API_KEYS": [keys[i] for i in keep],
        "OPENAI_API_CONFIGS": {str(n): cfgs[str(i)] for n, i in enumerate(keep) if str(i) in cfgs}})
    ts = [t for t in (snap["tool_servers"].get("TOOL_SERVER_CONNECTIONS") or [])
          if (t.get("info") or {}).get("id") != TOOL_ID]
    w.call("POST", "/api/v1/configs/tool_servers", {"TOOL_SERVER_CONNECTIONS": ts})
    mc = dict(snap["models"])
    meta = dict(mc.get("DEFAULT_MODEL_METADATA") or {})
    meta["toolIds"] = [t for t in (meta.get("toolIds") or []) if t != TOOL_REF]
    if not meta["toolIds"]:
        meta.pop("toolIds")
    mc["DEFAULT_MODEL_METADATA"] = meta
    w.call("POST", "/api/v1/configs/models", mc)
    out({"ok": True, "backup": bpath})


def main(a):
    if not a:
        raise SystemExit(__doc__)
    secret = sys.stdin.readline().strip() if not sys.stdin.isatty() else ""
    cmd = a[0]
    if cmd == "bootstrap":
        bootstrap(a[1], a[2], secret)
    elif cmd == "check":
        check(a[1], secret, *(a[2:4]))
    elif cmd == "sync":
        sync(a[1], secret, a[2], a[3])
    elif cmd == "remove":
        remove(a[1], secret, a[2], a[3])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
