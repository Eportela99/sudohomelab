"""core group (always on): current_datetime, tools, mcp_status, models_list."""
import datetime as dt

from common import EMBED_URL, RERANK_URL, ROUTER_URL, SEARXNG_URL, client, env

GROUP = "core"
TOOLS = ["current_datetime", "tools", "mcp_status", "models_list"]

# Filled by server.py: {group: [tool names]} for the groups that are switched on.
ENABLED = {}

_ABOUT = {
    "core": "Basics: time, this help, health of the MCP services, models in the router",
    "search": "Web search and page reading (private SearXNG)",
    "knowledge": "Long-term memory and knowledge base (Postgres + pgvector, CPU embeddings)",
    "files": "Read and write files in the shared files folder only",
    "vault": "Encrypted secrets store",
}


def _probe(name, url, method="GET", json=None):
    try:
        r = client.request(method, url, json=json, timeout=8.0)
        return "  %-10s %s (HTTP %d)" % (name, "OK" if r.status_code < 400 else "PROBLEM", r.status_code)
    except Exception as e:
        return "  %-10s DOWN (%s)" % (name, type(e).__name__)


def register(mcp):
    @mcp.tool()
    def current_datetime() -> str:
        """The current date, time and time zone of the MCP server."""
        now = dt.datetime.now().astimezone()
        return now.strftime("%A %Y-%m-%d %H:%M:%S %Z (UTC%z)")

    @mcp.tool(name="tools")
    def help_tools() -> str:
        """List the tool groups installed on this MCP server and what each does."""
        out = ["sudo homelab MCP %s: %d tools in %d groups" % (
            env("SHL_VERSION", "dev"), sum(len(v) for v in ENABLED.values()), len(ENABLED))]
        for group, names in ENABLED.items():
            out.append("\n%s: %s\n  %s" % (group, _ABOUT.get(group, ""), ", ".join(names)))
        return "\n".join(out)

    @mcp.tool()
    def mcp_status() -> str:
        """Health check of the services behind the MCP tools."""
        out = ["MCP services:"]
        if "search" in ENABLED:
            out.append(_probe("search", SEARXNG_URL + "/healthz"))
        if "knowledge" in ENABLED:
            out.append(_probe("embed", EMBED_URL, "POST", {"input": "ping"}))
            out.append(_probe("rerank", RERANK_URL, "POST", {"query": "a", "documents": ["a"]}))
            import tools.knowledge as kb
            ok, msg = kb.health()
            out.append("  %-10s %s (%s)" % ("database", "OK" if ok else "DOWN", msg))
        out.append(_probe("router", ROUTER_URL + "/health"))
        return "\n".join(out)

    @mcp.tool()
    def models_list() -> str:
        """Models available through the router (added by AI nodes that joined)."""
        try:
            r = client.get(ROUTER_URL + "/nodes", timeout=8.0,
                           headers={"Authorization": "Bearer " + env("MCP_TOKEN")})
            r.raise_for_status()
            nodes = r.json().get("nodes") or []
        except Exception as e:
            return "models_list error: router unreachable (%s)" % type(e).__name__
        if not nodes:
            return ("No models yet. The router is empty until an AI node joins with the "
                    "join code (SudoHomelab Script 2).")
        out = ["Models in the router:"]
        for n in nodes:
            for m in n.get("models") or []:
                out.append("- %s@%s  [%s]%s" % (m.get("id"), n.get("name"), n.get("status"),
                                                "  (default)" if m.get("default") else ""))
        return "\n".join(out)
