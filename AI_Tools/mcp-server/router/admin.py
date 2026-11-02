#!/usr/bin/env python3
"""Model admin for the sudo homelab router. Runs INSIDE the router container,
so every check sees the network exactly the way the router does.

  admin.py probe URL [--key K]           find the engine and its models (JSON)
  admin.py test URL MODEL [--key K]      chat test + tool-calling test (JSON)
  admin.py add NAME URL MODELS [--key K] register (MODELS = comma list) via the join token
  admin.py list                          one line per model: node_id|node|model|status|context|default
  admin.py remove NODE [MODEL]           remove a machine, or one model from it
  admin.py default MODEL@NODE            make it the default model

Used by the installer menu (AI_Tools/linux/mcp-server.sh); also handy by hand:
  docker compose -p sudohomelab-mcp exec router python /app/admin.py list
"""
import json
import os
import re
import sys
import time

import httpx

ROUTER = "http://127.0.0.1:%s" % os.environ.get("ROUTER_PORT", "8791")
TOKEN = os.environ.get("MCP_TOKEN", "")
JOIN = os.environ.get("JOIN_TOKEN", "")

# Default ports → (engine, hint shown when it can't be reached)
KNOWN = {
    11434: ("ollama", "Ollama listens on localhost only by default: set OLLAMA_HOST=0.0.0.0 "
                      "(Windows: a user environment variable) and restart Ollama."),
    1234: ("lmstudio", "In LM Studio, Developer → Settings: turn on \"Serve on Local Network\"."),
    8080: ("llama.cpp", "Start llama-server with --host 0.0.0.0 (it listens on 127.0.0.1 by default)."),
}
FIREWALL = ("Check the firewall on that machine (Windows Defender Firewall blocks new ports), "
            "and that this MCP server can reach its address (same LAN, or both on Tailscale).")


def out(obj):
    print(json.dumps(obj))


def hdr(key):
    return {"Authorization": "Bearer " + key} if key else {}


def normalize(url):
    url = url.strip().rstrip("/")
    if not re.match(r"(?i)^https?://", url):
        url = "http://" + url
    if not re.search(r":\d+(/|$)", url.split("//", 1)[1]) and url.startswith("http://"):
        url += ":11434"                                  # bare host: assume Ollama
    if not url.endswith("/v1"):
        url = re.sub(r"/v1/.*$", "/v1", url)
        if not url.endswith("/v1"):
            url += "/v1"
    return url


def port_of(url):
    m = re.search(r":(\d+)(/|$)", url.split("//", 1)[1])
    return int(m.group(1)) if m else (443 if url.startswith("https") else 80)


def root_of(base):
    return base[:-3] if base.endswith("/v1") else base


def detect(base, key):
    """(engine, {model_id: context})"""
    root, ctx = root_of(base), {}
    c = httpx.Client(timeout=6.0, headers=hdr(key))
    try:
        r = c.get(root + "/api/version")
        if r.status_code == 200 and "version" in r.text:
            for m in (c.get(root + "/api/tags").json().get("models") or []):
                try:
                    info = c.post(root + "/api/show", json={"model": m["name"]}).json()
                    mi = info.get("model_info") or {}
                    ctx[m["name"]] = next((int(v) for k, v in mi.items() if k.endswith(".context_length")), 0)
                except Exception:
                    pass
            return "ollama", ctx
    except Exception:
        pass
    try:
        r = c.get(root + "/props")
        if r.status_code == 200 and "default_generation_settings" in r.text:
            p = r.json()
            n = int((p.get("default_generation_settings") or {}).get("n_ctx") or 0)
            alias = p.get("model_alias") or ""
            if alias:
                ctx[alias] = n
            ctx["*"] = n
            return "llama.cpp", ctx
    except Exception:
        pass
    try:
        r = c.get(root + "/api/v0/models")
        if r.status_code == 200:
            for m in r.json().get("data") or []:
                ctx[m.get("id")] = int(m.get("max_context_length") or 0)
            return "lmstudio", ctx
    except Exception:
        pass
    return KNOWN.get(port_of(base), ("openai-compatible", ""))[0], ctx


def probe(url, key=""):
    base = normalize(url)
    try:
        r = httpx.get(base + "/models", headers=hdr(key), timeout=8.0)
    except (httpx.ConnectError, httpx.ConnectTimeout) as e:
        hint = KNOWN.get(port_of(base), (None, ""))[1]
        return {"ok": False, "base_url": base, "error": "can't connect (%s)" % type(e).__name__,
                "hint": " ".join(x for x in (hint, FIREWALL) if x)}
    except Exception as e:
        return {"ok": False, "base_url": base, "error": "%s: %s" % (type(e).__name__, e), "hint": FIREWALL}
    if r.status_code in (401, 403):
        return {"ok": False, "base_url": base, "error": "HTTP %d: this server needs an API key" % r.status_code,
                "hint": "Run Add model again and give the API key.", "needs_key": True}
    if r.status_code >= 400:
        return {"ok": False, "base_url": base, "error": "HTTP %d from %s/models" % (r.status_code, base),
                "hint": "Is this an OpenAI-compatible server? (Ollama, llama.cpp, LM Studio, vLLM…)"}
    try:
        ids = [m["id"] for m in r.json().get("data") or [] if m.get("id")]
    except Exception:
        return {"ok": False, "base_url": base, "error": "not an OpenAI-compatible /models answer", "hint": ""}
    if not ids:
        return {"ok": False, "base_url": base, "error": "the server has no models loaded or installed",
                "hint": "Download or load a model there first."}
    engine, ctx = detect(base, key)
    models = [{"id": i, "context": ctx.get(i) or ctx.get("*") or 0} for i in ids]
    return {"ok": True, "base_url": base, "engine": engine, "models": models}


def test(url, model, key=""):
    base, res = normalize(url), {"model": model}
    c = httpx.Client(timeout=240.0, headers=hdr(key))
    t = time.time()
    try:
        r = c.post(base + "/chat/completions", json={
            "model": model, "max_tokens": 1024, "temperature": 0,
            "messages": [{"role": "user", "content": "Reply with the single word: ready"}]})
        r.raise_for_status()
        msg = r.json()["choices"][0]["message"]
        res["chat"] = bool((msg.get("content") or msg.get("reasoning_content") or "").strip())
        res["seconds"] = round(time.time() - t, 1)
    except Exception as e:
        res["chat"], res["error"] = False, "%s: %s" % (type(e).__name__, str(e)[:200])
        return res
    try:
        r = c.post(base + "/chat/completions", json={
            "model": model, "max_tokens": 1024, "temperature": 0,
            "messages": [{"role": "user", "content": "What time is it? Use the tool."}],
            "tools": [{"type": "function", "function": {
                "name": "current_time", "description": "Get the current time",
                "parameters": {"type": "object", "properties": {}}}}]})
        r.raise_for_status()
        calls = r.json()["choices"][0]["message"].get("tool_calls") or []
        res["tools"] = any((x.get("function") or {}).get("name") == "current_time" for x in calls)
    except Exception as e:
        res["tools"], res["tools_error"] = False, "%s: %s" % (type(e).__name__, str(e)[:200])
    return res


def api(method, path, token=TOKEN, body=None):
    r = httpx.request(method, ROUTER + path, headers=hdr(token), json=body, timeout=30.0)
    if r.status_code >= 400:
        raise SystemExit("router said HTTP %d: %s" % (r.status_code, r.text[:300]))
    return r.json()


def add(name, url, models, key=""):
    pr = probe(url, key)
    if not pr["ok"]:
        raise SystemExit("can't reach %s: %s" % (pr["base_url"], pr["error"]))
    ctx = {m["id"]: m["context"] for m in pr["models"]}
    picked = [m for m in models.split(",") if m] if models != "all" else list(ctx)
    bad = [m for m in picked if m not in ctx]
    if bad:
        raise SystemExit("not on that server: %s" % ", ".join(bad))
    body = {"name": name, "base_url": pr["base_url"], "api_key": key,
            "hardware": pr["engine"],
            "models": [{"id": m, "context": ctx[m], "tags": []} for m in picked]}
    out(api("POST", "/nodes/register", JOIN, body))


def nodes():
    return api("GET", "/nodes")


def find_node(ref):
    for n in nodes()["nodes"]:
        if ref in (n["id"], n["name"]):
            return n
    raise SystemExit("no machine called %r" % ref)


def main(argv):
    key = ""
    if "--key" in argv:
        i = argv.index("--key")
        key = argv[i + 1] if i + 1 < len(argv) else ""
        del argv[i:i + 2]
    if "--key-stdin" in argv:
        argv.remove("--key-stdin")
        key = sys.stdin.readline().strip()
    if not argv:
        raise SystemExit(__doc__)
    cmd, args = argv[0], argv[1:]
    if cmd == "probe":
        out(probe(args[0], key))
    elif cmd == "test":
        out(test(args[0], args[1], key))
    elif cmd == "add":
        add(args[0], args[1], args[2], key)
    elif cmd == "list":
        data = nodes()
        for n in data["nodes"]:
            for m in n["models"]:
                print("|".join(str(x) for x in (n["id"], n["name"], m["id"], n["status"],
                                                m.get("context") or 0, "default" if m["default"] else "",
                                                n["base_url"])))
    elif cmd == "remove":
        n = find_node(args[0])
        if len(args) > 1:
            rest = [m for m in n["models"] if m["id"] != args[1]]
            if len(rest) == len(n["models"]):
                raise SystemExit("%s has no model %r" % (n["name"], args[1]))
            if rest:
                api("PUT", "/nodes/" + n["id"], body={"models": rest})
                print("removed %s@%s" % (args[1], n["name"]))
                return
        api("DELETE", "/nodes/" + n["id"])
        print("removed machine %s" % n["name"])
    elif cmd == "default":
        model, _, node = args[0].rpartition("@")
        n = find_node(node)
        print(api("POST", "/nodes/%s/default" % n["id"], body={"model": model})["default"])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
