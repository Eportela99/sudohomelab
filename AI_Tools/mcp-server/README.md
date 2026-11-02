# MCP Server (SudoHomelab Script 1)

The brain and tools for your local AI: **one MCP address + one token** for every tool,
and an **OpenAI-compatible model router** for the models you run on your own machines.

No chat model is installed here. Models live on your AI machines (Ollama, llama.cpp,
LM Studio, vLLM...) and are connected to the router from the menu (**Add model**),
or by an AI node installer with the join code.

```
Proxmox host
 ├── /opt/sudohomelab/mcp      settings, tokens, database, files (survive a rebuild)
 └── LXC "mcp" (Debian 13, Docker inside)
      ├── gateway    MCP server :8790/mcp   (bearer token)
      ├── router     model router :8791/v1  (same token; empty until you add a model)
      ├── knowledge  Postgres + pgvector, bge-m3 embeddings + reranker on CPU
      └── search     SearXNG + Valkey (private web search)
```

## Install

Proxmox VE 8/9 (host shell, as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AI_Tools/proxmox/mcp-server.sh)"
```

Ubuntu / Debian (Docker):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AI_Tools/linux/mcp-server.sh)"
```

It asks for the tools, the network (container IP) and Tailscale (inside the container,
on the Proxmox host, or none), then prints the MCP address + token, the router address
and a join code. Needs about 4 GB RAM and 15 GB disk (Standard profile).

## Tools

| Group | Tools | |
|---|---|---|
| core | `current_datetime`, `tools`, `mcp_status`, `models_list` | always |
| search | `web_search`, `news_search`, `web_fetch`, `search_and_read` | always |
| knowledge | `memory_*`, `knowledge_*`, `kb_search/add/list/forget/ingest/stats` | always |
| files | `fs_*` (only inside `/opt/sudohomelab/mcp/files`) | Standard |
| vault | `vault_store/list/get/forget` (encrypted) | Standard |

More tool groups (monitoring, docs, code, wake-on-LAN, SSH, artifacts, GitHub) and
Open WebUI are coming.

## Menu (run the script again)

Install / repair · **List models** · **Add model** · **Remove model** · Set default model ·
Status · Connection info · Rotate tokens · Update · Uninstall (keep data, or remove everything).

Every item also works as an option, e.g. `--add-model --model-url=192.168.1.50:11434`.

### Add model: what the model server needs

- An OpenAI-compatible server: Ollama (`:11434`), llama.cpp (`:8080`), LM Studio (`:1234`), vLLM...
  Open WebUI and OpenCode are apps, not model servers: add the server behind them.
- It must listen on the network, not only localhost: Ollama `OLLAMA_HOST=0.0.0.0`,
  llama.cpp `--host 0.0.0.0`, LM Studio "Serve on Local Network".
- Its firewall must allow the port, and the MCP server must reach its address
  (same LAN, or both on Tailscale). `localhost` never works from the container.
- For the MCP tools the model must support tool calling (llama.cpp `--jinja`;
  Ollama models with "tools"). The menu tests this and warns.

## Connect an app

OpenCode (`opencode.json`):

```json
"mcp": { "sudohomelab": { "type": "remote", "url": "http://<ip>:8790/mcp",
         "headers": { "Authorization": "Bearer <token>" } } }
```

Use the router as the model provider (`http://<ip>:8791/v1`, same token) to reach every
model you added as `model@machine`, or `default`.

## Files

- `gateway/` MCP server (FastMCP); one module per tool group in `app/tools/`
- `router/` model router + `admin.py` (probe, test, add, remove models)
- `knowledge/init.sql` knowledge-base schema
- Installers: `../linux/mcp-server.sh` (core), `../proxmox/mcp-server.sh` (LXC wrapper)

Rule for contributors: a new tool group is added to `GROUPS` in `gateway/app/server.py`
**and** to `TOOL_IDS` in `linux/mcp-server.sh`.
