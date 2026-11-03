<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# AI & Automation

Private LLMs, MCP servers and workflow automation.

Run models locally, give them tools through MCP and automate everything else.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Ollama** | Run Llama, Qwen, Mistral and friends locally with one command. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Open WebUI** | ChatGPT-style interface for local and cloud models. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **MCP Server: Full Install** | One MCP address for every tool (search, memory, files, vault), a model router every AI Node joins, and Open WebUI with the tools turned on. | Proxmox, Linux, TrueNAS | Original (Beta) |
| **AI Node: Local Models** | Scans your GPU, suggests the best model with how it will run, installs it and joins your MCP Server. | Proxmox, Linux, TrueNAS, Windows | Original (Beta) |
| **MCP Tool Selector** | Pick exactly which MCP tools to expose while installing, and change them later from the menu. | Proxmox, Linux, TrueNAS | Original (Beta) |
| **OpenCode** | Open-source AI coding agent for your terminal. | Linux, Windows, macOS | Planned |
| **n8n** | Visual workflow automation with AI agent nodes. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |

## Pre-wired stack: Local AI Stack

Ollama with models pulled for your GPU, Open WebUI connected, and MCP tools registered, ready to chat with your lab.

Status: planned. Script: `AI_Tools/<platform>/ai-stack.sh`

## Layout

Scripts go in one folder per platform:

```
AI_Tools/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Published: [`AI_Tools/linux/mcp-server.sh`](linux/mcp-server.sh), [`AI_Tools/proxmox/mcp-server.sh`](proxmox/mcp-server.sh). Install, uninstall and purge commands: https://sudohomelab.vercel.app/#/c/ai

Published: [`AI_Tools/linux/ai-node.sh`](linux/ai-node.sh). Install, uninstall and purge commands: https://sudohomelab.vercel.app/#/c/ai
