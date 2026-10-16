<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# AI & Automation

Private LLMs, MCP servers and workflow automation.

Run models locally, give them tools through MCP and automate everything else.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Ollama** | Run Llama, Qwen, Mistral and friends locally with one command. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Open WebUI** | ChatGPT-style interface for local and cloud models. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **MCP Server: Full Install** | Every MCP tool server we maintain, behind one gateway. | Proxmox, Linux, TrueNAS, Windows, macOS | Original (planned) |
| **MCP Tool Selector** | Pick exactly which MCP tools to expose: files, Docker, Proxmox, Home Assistant… | Proxmox, Linux, TrueNAS, Windows, macOS | Original (planned) |
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

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
