"""Shared settings and helpers for the sudo homelab MCP gateway.

Everything comes from environment variables (the installer writes them to
/opt/sudohomelab/mcp/.env), so nothing here is tied to one lab.
"""
import math
import os

import httpx


def env(name, default=""):
    return os.environ.get(name, default).strip()


DATA_DIR = env("DATA_DIR", "/data")
SEARXNG_URL = env("SEARXNG_URL", "http://searxng:8080").rstrip("/")
EMBED_URL = env("EMBED_URL", "http://embed:8080/v1/embeddings")
EMBED_MODEL = env("EMBED_MODEL", "bge-m3")
RERANK_URL = env("RERANK_URL", "http://rerank:8080/v1/rerank")
RERANK_MODEL = env("RERANK_MODEL", "bge-reranker-v2-m3")
ROUTER_URL = env("ROUTER_URL", "http://router:8791").rstrip("/")
EMBED_TIMEOUT = float(env("EMBED_TIMEOUT", "120"))
RERANK_TIMEOUT = float(env("RERANK_TIMEOUT", "60"))

UA = env("HTTP_UA", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
         "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
UA_FALLBACK = env("HTTP_UA_FALLBACK",
                  "sudohomelab-mcp/1.0 (+https://github.com/Eportela99/sudohomelab)")

client = httpx.Client(
    headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"},
    follow_redirects=True,
    timeout=httpx.Timeout(20.0, connect=10.0),
)


def as_int(v, default):
    """Local models often send numbers as strings ("5"); accept both."""
    try:
        return int(float(str(v).strip()))
    except Exception:
        return default


def as_bool(v, default=False):
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() in ("1", "true", "yes", "y", "on")


def http_get(url, timeout=20.0):
    """GET with a polite-bot retry when a site blocks browser-looking clients."""
    r = client.get(url, timeout=timeout)
    if r.status_code in (403, 429):
        try:
            r2 = client.get(url, timeout=timeout, headers={"User-Agent": UA_FALLBACK})
            if r2.status_code < 400:
                return r2
        except Exception:
            pass
    return r


def embed(text):
    """L2-normalised embedding (so cosine similarity == dot product)."""
    r = client.post(EMBED_URL, json={"model": EMBED_MODEL, "input": text},
                    timeout=EMBED_TIMEOUT)
    r.raise_for_status()
    v = r.json()["data"][0]["embedding"]
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def rerank(query, docs, top_n):
    """[(index, score)] best first, or [] if the reranker is unavailable."""
    try:
        r = client.post(RERANK_URL,
                        json={"model": RERANK_MODEL, "query": query, "documents": docs},
                        timeout=RERANK_TIMEOUT)
        r.raise_for_status()
        res = r.json().get("results") or []
        out = [(it["index"], float(it.get("relevance_score") or 0.0))
               for it in res if isinstance(it.get("index"), int)]
        out.sort(key=lambda t: t[1], reverse=True)
        return out[:top_n]
    except Exception:
        return []
