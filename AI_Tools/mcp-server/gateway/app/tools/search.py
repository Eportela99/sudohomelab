"""search group: web_search, news_search, web_fetch, search_and_read (SearXNG)."""
import html as _html
import re

from common import SEARXNG_URL, as_int, client, http_get, rerank

GROUP = "search"
TOOLS = ["web_search", "news_search", "web_fetch", "search_and_read"]

# A failed fetch must never look like page content, and the model needs to know
# whether to retry or move on.
_STATUS_REASON = {
    401: ("authentication required", "switch source"),
    403: ("access forbidden (likely bot protection)", "switch source"),
    404: ("page does not exist", "switch source"),
    410: ("page permanently removed", "switch source"),
    429: ("rate limited by the site", "wait or switch source"),
    451: ("blocked for legal reasons", "switch source"),
}


class FetchError(RuntimeError):
    """A fetch that failed cleanly; never carries page content."""


def _searx(query, count, categories, language):
    params = {"q": query, "format": "json", "categories": categories,
              "language": language or "en", "safesearch": "0"}
    r = client.get(f"{SEARXNG_URL}/search", params=params, timeout=20.0)
    r.raise_for_status()
    n = min(20, max(1, as_int(count, 5)))
    return (r.json().get("results") or [])[:n]


def _fmt_results(results):
    if not results:
        return "No results."
    lines = []
    for i, it in enumerate(results, 1):
        title = (it.get("title") or "(no title)").strip()
        url = (it.get("url") or "").strip()
        snippet = re.sub(r"\s+", " ", (it.get("content") or "")).strip()
        engines = it.get("engines") or ([it.get("engine")] if it.get("engine") else [])
        meta = ", ".join(e for e in engines if e)
        pub = it.get("publishedDate") or ""
        if pub:
            meta = (meta + " · " + str(pub)[:10]).strip(" ·")
        lines.append(f"{i}. {title}\n   {url}" + (f"\n   {snippet}" if snippet else "")
                     + (f"\n   [{meta}]" if meta else ""))
    return "\n\n".join(lines)


def _html_to_text(raw, max_chars):
    s = re.sub(r"(?is)<(script|style|noscript|template|svg|head)[^>]*>.*?</\1>", " ", raw)
    s = re.sub(r"(?is)<!--.*?-->", " ", s)
    m = re.search(r"(?is)<title[^>]*>(.*?)</title>", raw)
    title = _html.unescape(re.sub(r"\s+", " ", m.group(1)).strip()) if m else ""
    s = re.sub(r"(?i)<(/?)(p|div|br|li|tr|h[1-6]|section|article|header|footer|ul|ol|"
               r"table|blockquote|pre)[^>]*>", "\n", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = _html.unescape(s)
    s = re.sub(r"[ \t\f\v]+", " ", s)
    s = re.sub(r"\n[ \t]+", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s).strip()
    cut = len(s) > max_chars
    return title, s[:max_chars] + ("\n\n…[truncated]" if cut else "")


def _fetch_text(url, max_chars):
    max_chars = as_int(max_chars, 8000)
    if not re.match(r"(?i)^https?://", url):
        url = "https://" + url
    r = http_get(url, timeout=20.0)
    if r.status_code >= 400:
        reason, action = _STATUS_REASON.get(
            r.status_code,
            ("server error" if r.status_code >= 500 else "request failed",
             "retry later or switch source"))
        raise FetchError(f"HTTP {r.status_code}: {reason}. No content was retrieved; {action}.")
    ctype = r.headers.get("content-type", "")
    if "html" not in ctype and ("text/" in ctype or "json" in ctype or "xml" in ctype):
        body = r.text
        return "", body[:max_chars] + ("\n\n…[truncated]" if len(body) > max_chars else "")
    return _html_to_text(r.text, max_chars)


def register(mcp):
    @mcp.tool()
    def web_search(query: str, count: int | float | str | None = 5,
                   category: str | None = "general", language: str | None = "en") -> str:
        """Search the web (private SearXNG). Returns ranked title, URL and snippet.
        category: general | news | science | it | social media."""
        try:
            results = _searx(query, count, category or "general", language or "en")
            return f"Search: {query!r} ({category or 'general'})\n\n" + _fmt_results(results)
        except Exception as e:
            return f"web_search error: {type(e).__name__}: {e}"

    @mcp.tool()
    def news_search(query: str, count: int | float | str | None = 5,
                    language: str | None = "en") -> str:
        """Search recent news (private SearXNG)."""
        try:
            return f"News: {query!r}\n\n" + _fmt_results(
                _searx(query, count, "news", language or "en"))
        except Exception as e:
            return f"news_search error: {type(e).__name__}: {e}"

    @mcp.tool()
    def web_fetch(url: str, max_chars: int | float | str | None = 8000) -> str:
        """Fetch a web page and return its readable text (HTML stripped)."""
        try:
            title, text = _fetch_text(url, max_chars)
            head = f"URL: {url}" + (f"\nTitle: {title}" if title else "")
            return head + "\n\n" + (text or "(no extractable text)")
        except FetchError as e:
            return f"FETCH FAILED for {url}\n{e}"
        except Exception as e:
            return (f"FETCH FAILED for {url}\n{type(e).__name__}: {e}. "
                    "No content was retrieved; switch source.")

    @mcp.tool()
    def search_and_read(query: str, count: int | float | str | None = 3,
                        chars_each: int | float | str | None = 2000) -> str:
        """Research in one call: search, rerank the results locally, then read
        the top pages. Use for questions that need page content, not snippets."""
        count = max(1, min(8, as_int(count, 3)))
        chars_each = as_int(chars_each, 2000)
        try:
            pool = _searx(query, min(20, count * 3), "general", "en")
        except Exception as e:
            return f"search_and_read error (search): {type(e).__name__}: {e}"
        if not pool:
            return f"No results for {query!r}."
        results, reranked = pool[:count], False
        if len(pool) > count:
            docs = [(re.sub(r"\s+", " ", it.get("title") or "").strip() + " — " +
                     re.sub(r"\s+", " ", it.get("content") or "").strip())[:1500] for it in pool]
            order = rerank(query, docs, count)
            if order:
                results = [pool[i] for i, _s in order if 0 <= i < len(pool)][:count]
                reranked = True
        out = [f"Research: {query!r}" + (" (reranked)" if reranked else "") + "\n"]
        for i, it in enumerate(results, 1):
            url = (it.get("url") or "").strip()
            block = f"── Source {i}: {(it.get('title') or '(no title)').strip()}\n   {url}\n"
            try:
                block += _fetch_text(url, chars_each)[1] or "(no extractable text)"
            except Exception as e:
                snippet = re.sub(r"\s+", " ", it.get("content") or "").strip()
                block += f"(could not fetch: {type(e).__name__}) {snippet}"
            out.append(block)
        return "\n\n".join(out)
