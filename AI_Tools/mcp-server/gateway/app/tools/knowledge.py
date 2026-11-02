"""knowledge group: long-term memory in Postgres + pgvector.

memory_*    short facts and preferences            (kind = memory)
knowledge_* durable notes and runbooks             (kind = knowledge)
kb_*        the whole store: search, add, list, forget, ingest files, stats

Retrieval: HNSW vector recall fused with Postgres full-text (Reciprocal Rank
Fusion, in kb.search()), then the bge-reranker cross-encoder. Every stage
degrades instead of failing: no embeddings -> text-only, no reranker -> fused order.
"""
import hashlib
import json
import os
import re
import threading
import uuid

import psycopg

from common import DATA_DIR, EMBED_URL, as_int, as_bool, embed, env, rerank

GROUP = "knowledge"
TOOLS = ["memory_add", "memory_search", "memory_list", "memory_forget",
         "knowledge_add", "knowledge_search", "knowledge_list", "knowledge_forget",
         "kb_search", "kb_add", "kb_list", "kb_forget", "kb_ingest", "kb_stats"]

KB_DSN = env("KB_DSN")
DIMS = 1024                     # bge-m3
CANDIDATES = 40
BODY_CHARS = as_int(env("KB_BODY_CHARS", "700"), 700)
RERANK_CHARS = as_int(env("KB_RERANK_CHARS", "1500"), 1500)
KINDS = ("knowledge", "memory", "script", "document")
# kb_ingest may only read inside the shared files folder.
INGEST_ROOT = os.path.realpath(env("FILES_ROOT", os.path.join(DATA_DIR, "files")))

CHUNK, OVERLAP, MAX_BYTES = 1600, 200, 400_000

_lock = threading.Lock()
_conn = None


# ── connection ────────────────────────────────────────────────────────────────

def _connect():
    global _conn
    if not KB_DSN:
        raise RuntimeError("KB_DSN is not set; the knowledge base is not configured")
    if _conn is not None and not _conn.closed:
        try:
            with _conn.cursor() as cur:
                cur.execute("select 1")
            return _conn
        except Exception:
            try:
                _conn.close()
            except Exception:
                pass
    _conn = psycopg.connect(KB_DSN, autocommit=True, connect_timeout=10)
    return _conn


def health():
    try:
        with _lock, _connect().cursor() as cur:
            cur.execute("select count(*) from kb.documents")
            return True, "%d chunks stored" % cur.fetchone()[0]
    except Exception as e:
        return False, "%s: %s" % (type(e).__name__, e)


# ── helpers ───────────────────────────────────────────────────────────────────

def _vec(text):
    """pgvector literal for text, or None when the embedding service is down."""
    try:
        v = embed(text)
        if len(v) != DIMS:
            return None
        return "[" + ",".join("%.7g" % x for x in v) + "]"
    except Exception:
        return None


def _short_id():
    return uuid.uuid4().hex[:12]


def _title_of(text):
    for line in text.splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:200]
    return text.strip()[:200] or "untitled"


def _src(kind, sid):
    return "%s:%s" % (kind, sid)


def _disp_id(source):
    for k in KINDS:
        if source.startswith(k + ":"):
            return source[len(k) + 1:]
    return source


def _when(ts):
    try:
        return ts.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    except Exception:
        return str(ts)[:19]


def _tags(meta):
    t = (meta or {}).get("tags") or []
    if isinstance(t, str):
        t = t.split(",")
    return [str(x).strip() for x in t if str(x).strip()]


def _clip(body):
    return body if len(body) <= BODY_CHARS else body[:BODY_CHARS] + " …"


def _chunks(text, size=CHUNK, overlap=OVERLAP):
    """Split on blank lines where possible so a chunk is a coherent unit."""
    text = text.replace("\r\n", "\n")
    if len(text) <= size:
        return [text]
    out, cur = [], ""
    for p in re.split(r"\n\s*\n", text):
        if len(p) > size:
            if cur:
                out.append(cur)
                cur = ""
            out += [p[i:i + size] for i in range(0, len(p), size - overlap)]
        elif len(cur) + len(p) + 2 > size:
            out.append(cur)
            cur = p
        else:
            cur = (cur + "\n\n" + p) if cur else p
    if cur:
        out.append(cur)
    return [c for c in out if c.strip()]


def _search_rows(query, kinds, limit):
    """Recall (vector + full text) -> cross-encoder rerank."""
    limit = max(1, min(50, limit))
    q = _vec(query)
    with _lock, _connect().cursor() as cur:
        cur.execute(
            "select id, kind, source, chunk_index, title, content, meta, score, created_at "
            "from kb.search(%s, %s::vector(1024), %s::text[], %s, 60, %s)",
            (query, q, list(kinds) if kinds else None, CANDIDATES, CANDIDATES))
        rows = [dict(zip(("pk", "kind", "source", "chunk_index", "title", "content",
                          "meta", "score", "created"), r)) for r in cur.fetchall()]
    if len(rows) > 1:
        order = rerank(query, [(r["content"] or "")[:RERANK_CHARS] for r in rows], len(rows))
        if order:
            rows = [rows[i] for i, _s in order if 0 <= i < len(rows)]
    return rows[:limit]


def _insert(kind, source, text, meta, title=None, upsert=False):
    """Chunk, embed and store text. Returns the number of chunks written."""
    parts = _chunks(text)
    vecs = [_vec(p) for p in parts]
    if any(v is None for v in vecs):
        raise RuntimeError("embedding service unavailable (%s); nothing was saved, "
                           "retry once it is back" % EMBED_URL)
    with _lock, _connect().cursor() as cur:
        for i, (part, v) in enumerate(zip(parts, vecs)):
            cur.execute(
                "insert into kb.documents (kind, source, chunk_index, title, content, meta, emb) "
                "values (%s,%s,%s,%s,%s,%s::jsonb,%s::vector(1024)) "
                "on conflict (kind, source, chunk_index) do update set title=excluded.title, "
                "content=excluded.content, meta=excluded.meta, emb=excluded.emb",
                (kind, source, i, title or _title_of(text), part,
                 json.dumps(dict(meta, chunk_index=i, chunks=len(parts))), v))
        if upsert:
            cur.execute("delete from kb.documents where kind=%s and source=%s and chunk_index>=%s",
                        (kind, source, len(parts)))
    return len(parts)


# ── memory_* / knowledge_* (one store each, same shape) ───────────────────────

def _store_add(kind, text, tags):
    text = (text or "").strip()
    if not text:
        return "Nothing to save (empty text)."
    sid = _short_id()
    meta = {"tags": [t.strip() for t in (tags or "").split(",") if t.strip()],
            "origin": "%s_add" % kind}
    try:
        n = _insert(kind, _src(kind, sid), text, meta)
    except Exception as e:
        return "%s_add error: %s" % (kind, e)
    return "Saved %s %s%s%s." % (kind, sid, " [%s]" % tags if tags else "",
                                 "" if n == 1 else " in %d chunks" % n)


def _store_search(kind, query, limit):
    query = (query or "").strip()
    if not query:
        return "Provide a search query."
    try:
        rows = _search_rows(query, [kind], as_int(limit, 5))
    except Exception as e:
        return "%s_search error: %s: %s" % (kind, type(e).__name__, e)
    if not rows:
        return "No %s entries matched %r." % (kind, query)
    out = ["%s matches for %r:" % (kind.title(), query)]
    for r in rows:
        t = _tags(r["meta"])
        out.append("- (%s) %s%s  (id %s)" % (_when(r["created"]), _clip(r["content"] or ""),
                                            " [%s]" % ",".join(t) if t else "",
                                            _disp_id(r["source"])))
    return "\n".join(out)


def _store_list(kind, limit):
    limit = max(1, min(200, as_int(limit, 20)))
    try:
        with _lock, _connect().cursor() as cur:
            cur.execute("select source, content, meta, created_at from kb.documents "
                        "where kind=%s and chunk_index=0 order by created_at desc limit %s",
                        (kind, limit))
            rows = cur.fetchall()
            cur.execute("select count(distinct source) from kb.documents where kind=%s", (kind,))
            total = cur.fetchone()[0]
    except Exception as e:
        return "%s_list error: %s: %s" % (kind, type(e).__name__, e)
    if not rows:
        return "No %s entries stored yet." % kind
    out = ["%d %s entries stored (showing %d, newest first):" % (total, kind, len(rows))]
    for source, content, meta, created in rows:
        t = _tags(meta)
        out.append("- %s%s  (id %s, %s)" % (_clip(content or ""), " [%s]" % ",".join(t) if t else "",
                                           _disp_id(source), _when(created)))
    return "\n".join(out)


def _store_forget(kind, ident):
    ident = (ident or "").strip()
    if not ident:
        return "Provide an id."
    try:
        with _lock, _connect().cursor() as cur:
            cur.execute("delete from kb.documents where kind=%s and (source=%s or source=%s)",
                        (kind, ident, _src(kind, ident)))
            n = cur.rowcount
    except Exception as e:
        return "%s_forget error: %s: %s" % (kind, type(e).__name__, e)
    return ("Forgot %s %s." % (kind, ident)) if n else ("No %s entry with id %r." % (kind, ident))


# ── kb_ingest: files from the shared folder ───────────────────────────────────

_TEXT_EXT = {".sh", ".py", ".md", ".txt", ".yaml", ".yml", ".json", ".conf", ".cfg", ".ini",
             ".toml", ".service", ".timer", ".ps1", ".sql", ".rst", ".bash", ".js", ".ts",
             ".html", ".css", ".csv", ".xml", ""}
_SKIP_DIR = {".git", "node_modules", "__pycache__", "venv", ".venv", ".cache", "dist", "build"}
# Every model that can reach the MCP can search the store, so nothing that looks
# like a credential is ever ingested: by name, or by a secret-looking value inside.
_SKIP_FILE_RE = re.compile(r"(credential|secret|password|passwd|\btoken\b|\.env$|_key$|\.key$|"
                           r"\.pem$|\.p12$|id_rsa|id_ed25519|\.htpasswd)", re.I)
_SECRET_RE = re.compile(
    r"(BEGIN\s+(RSA|OPENSSH|EC|PGP|DSA)\s+PRIVATE\s+KEY)"
    r"|((?i:token|secret|password|api[_-]?key|passwd)\s*[=:]\s*['\"]?"
    r"(?=[A-Za-z0-9_\-/+=]{20,})(?=[A-Za-z0-9_\-/+=]*[0-9])(?=[A-Za-z0-9_\-/+=]*[A-Za-z])"
    r"[A-Za-z0-9_\-/+=]{20,})")


def _is_text(path):
    if os.path.splitext(path)[1].lower() not in _TEXT_EXT:
        return False
    try:
        with open(path, "rb") as fh:
            head = fh.read(4096)
        if b"\0" in head:
            return False
        head.decode("utf-8")
        return True
    except Exception:
        return False


def _ingest_file(path, kind, base):
    if _SKIP_FILE_RE.search(os.path.basename(path)):
        return 0, "skipped: name suggests credentials"
    if os.path.getsize(path) > MAX_BYTES:
        return 0, "too large"
    with open(path, encoding="utf-8", errors="replace") as fh:
        body = fh.read()
    if not body.strip():
        return 0, "empty"
    if _SECRET_RE.search(body):
        return 0, "skipped: contains what looks like a live secret"
    rel = os.path.relpath(path, INGEST_ROOT)
    digest = hashlib.sha256(body.encode()).hexdigest()
    with _lock, _connect().cursor() as cur:
        cur.execute("select meta->>'content_hash' from kb.documents "
                    "where kind=%s and source=%s and chunk_index=0", (kind, rel))
        row = cur.fetchone()
    if row and row[0] == digest:
        return 0, "unchanged"
    meta = {"path": os.path.abspath(path), "origin": "kb_ingest", "content_hash": digest}
    return _insert(kind, rel, body, meta, title=os.path.basename(path), upsert=True), None


# ── tools ─────────────────────────────────────────────────────────────────────

def register(mcp):
    @mcp.tool()
    def memory_add(text: str, tags: str | None = None) -> str:
        """Remember a short fact, preference or decision for later conversations."""
        return _store_add("memory", text, tags)

    @mcp.tool()
    def memory_search(query: str, limit: int | float | str | None = 5) -> str:
        """Search remembered facts by meaning (not just keywords)."""
        return _store_search("memory", query, limit)

    @mcp.tool()
    def memory_list(limit: int | float | str | None = 20) -> str:
        """List remembered facts, newest first."""
        return _store_list("memory", limit)

    @mcp.tool()
    def memory_forget(id: str) -> str:
        """Delete one remembered fact by its id."""
        return _store_forget("memory", id)

    @mcp.tool()
    def knowledge_add(text: str, tags: str | None = None) -> str:
        """Save a durable note: a runbook, how-to, or reference you want to keep."""
        return _store_add("knowledge", text, tags)

    @mcp.tool()
    def knowledge_search(query: str, limit: int | float | str | None = 5) -> str:
        """Search saved notes and runbooks by meaning."""
        return _store_search("knowledge", query, limit)

    @mcp.tool()
    def knowledge_list(limit: int | float | str | None = 20) -> str:
        """List saved notes, newest first."""
        return _store_list("knowledge", limit)

    @mcp.tool()
    def knowledge_forget(id: str) -> str:
        """Delete one saved note by its id."""
        return _store_forget("knowledge", id)

    @mcp.tool()
    def kb_search(query: str, kind: str | None = None,
                  limit: int | float | str | None = 4) -> str:
        """Search the whole knowledge base (memory, knowledge, script, document).
        kind: optional comma list to narrow it."""
        query = (query or "").strip()
        if not query:
            return "Provide a search query."
        kinds = [k.strip() for k in (kind or "").split(",") if k.strip()] or None
        bad = [k for k in kinds or [] if k not in KINDS]
        if bad:
            return "Unknown kind(s) %s. Valid: %s." % (", ".join(bad), ", ".join(KINDS))
        try:
            rows = _search_rows(query, kinds, as_int(limit, 4))
        except Exception as e:
            return "kb_search error: %s: %s" % (type(e).__name__, e)
        if not rows:
            return "Nothing in the knowledge base matched %r." % query
        out = ["Knowledge base matches for %r:" % query]
        for r in rows:
            part = "" if not r["chunk_index"] else " (part %d)" % r["chunk_index"]
            out.append("\n### [%s] %s%s  (%s)\n%s\n_source: %s_"
                       % (r["kind"], r["title"] or r["source"], part, _when(r["created"]),
                          _clip(r["content"] or ""), r["source"]))
        return "\n".join(out)

    @mcp.tool()
    def kb_add(text: str, kind: str = "knowledge", title: str | None = None,
               source: str | None = None, tags: str | None = None) -> str:
        """Add text to the knowledge base. Re-using a source replaces that entry.
        kind: knowledge | memory | script | document."""
        text, kind = (text or "").strip(), (kind or "knowledge").strip()
        if not text:
            return "Nothing to save (empty text)."
        if kind not in KINDS:
            return "Unknown kind %r. Valid: %s." % (kind, ", ".join(KINDS))
        src = (source or "").strip() or _src(kind, _short_id())
        meta = {"tags": [t.strip() for t in (tags or "").split(",") if t.strip()],
                "origin": "kb_add"}
        try:
            n = _insert(kind, src, text, meta, title=title, upsert=True)
        except Exception as e:
            return "kb_add error: %s" % e
        return "Saved %s %r (%d chunk%s)." % (kind, src, n, "" if n == 1 else "s")

    @mcp.tool()
    def kb_list(kind: str | None = None, limit: int | float | str | None = 25,
                contains: str | None = None, offset: int | float | str | None = 0) -> str:
        """List knowledge-base sources (one line per entry), with totals per kind."""
        limit = max(1, min(200, as_int(limit, 25)))
        offset = max(0, as_int(offset, 0))
        where, args = ["chunk_index = 0"], []
        if kind:
            where.append("kind = any(%s)")
            args.append([k.strip() for k in kind.split(",") if k.strip()])
        if contains:
            where.append("(title ilike %s or source ilike %s)")
            args += ["%%%s%%" % contains] * 2
        try:
            with _lock, _connect().cursor() as cur:
                cur.execute("select kind, source, title, created_at from kb.documents where "
                            + " and ".join(where) + " order by created_at desc limit %s offset %s",
                            args + [limit + 1, offset])
                rows = cur.fetchall()
                cur.execute("select kind, count(distinct source) from kb.documents "
                            "group by kind order by kind")
                totals = cur.fetchall()
        except Exception as e:
            return "kb_list error: %s: %s" % (type(e).__name__, e)
        out = ["Knowledge base: " + (", ".join("%s=%d" % t for t in totals) or "empty")]
        for k, source, title, created in rows[:limit]:
            out.append("- [%s] %-50s %s (%s)" % (k, (title or "")[:50], source, _when(created)))
        if len(rows) > limit:
            out.append("More available; next offset=%d." % (offset + limit))
        return "\n".join(out)

    @mcp.tool()
    def kb_forget(source: str | None = None, id: str | None = None) -> str:
        """Delete an entry: by source (all its chunks) or by a memory/knowledge id."""
        try:
            with _lock, _connect().cursor() as cur:
                if source:
                    cur.execute("delete from kb.documents where source=%s", (source,))
                elif id:
                    cur.execute("delete from kb.documents where source=%s or source like %s",
                                (id, "%:" + id))
                else:
                    return "Provide source= or id=."
                return "Deleted %d chunk(s)." % cur.rowcount
        except Exception as e:
            return "kb_forget error: %s: %s" % (type(e).__name__, e)

    @mcp.tool()
    def kb_ingest(path: str = ".", kind: str = "document",
                  recursive: bool | str | None = True) -> str:
        """Add files from the shared files folder to the knowledge base (text files
        only; anything that looks like a credential is skipped). path is relative
        to the files folder. Re-running only re-embeds files that changed."""
        if kind not in KINDS:
            return "Unknown kind %r. Valid: %s." % (kind, ", ".join(KINDS))
        target = os.path.realpath(os.path.join(INGEST_ROOT, (path or ".").lstrip("/")))
        if target != INGEST_ROOT and not target.startswith(INGEST_ROOT + os.sep):
            return "kb_ingest: path must be inside the files folder."
        if not os.path.exists(target):
            return "Path not found: %s" % path
        files = [target] if os.path.isfile(target) else []
        if not files:
            for root, dirs, names in os.walk(target):
                dirs[:] = [d for d in dirs if d not in _SKIP_DIR and not d.startswith(".")]
                files += [os.path.join(root, n) for n in sorted(names) if not n.startswith(".")]
                if not as_bool(recursive, True):
                    break
        files = [f for f in files if _is_text(f)]
        done = chunks = unchanged = 0
        problems = []
        for f in files:
            try:
                n, err = _ingest_file(f, kind, INGEST_ROOT)
            except Exception as e:
                n, err = 0, "%s: %s" % (type(e).__name__, e)
            if err == "unchanged":
                unchanged += 1
            elif err:
                problems.append("%s: %s" % (os.path.relpath(f, INGEST_ROOT), err))
            else:
                done, chunks = done + 1, chunks + n
        out = ["Ingested %d changed of %d file(s) as %s -> %d chunk(s)." % (done, len(files), kind, chunks)]
        if unchanged:
            out.append("  unchanged: %d file(s)" % unchanged)
        out += ["  skipped %s" % p for p in problems[:15]]
        return "\n".join(out)

    @mcp.tool()
    def kb_stats() -> str:
        """Knowledge-base size per kind, and whether the database and embeddings work."""
        try:
            with _lock, _connect().cursor() as cur:
                cur.execute("select kind, count(*), count(distinct source) from kb.documents "
                            "group by kind order by kind")
                rows = cur.fetchall()
                cur.execute("select pg_size_pretty(pg_total_relation_size('kb.documents'))")
                size = cur.fetchone()[0]
        except Exception as e:
            return "kb_stats error: %s: %s" % (type(e).__name__, e)
        out = ["Knowledge base (PostgreSQL + pgvector):"]
        out += ["  %-10s %5d chunks from %4d source(s)" % r for r in rows] or ["  (empty)"]
        out.append("  on disk: %s" % size)
        out.append("  embeddings: %s" % ("OK" if _vec("ping") else "UNAVAILABLE (%s)" % EMBED_URL))
        return "\n".join(out)
