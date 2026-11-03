# AI Node (SudoHomelab Script 2)

Runs a local AI model on a machine with a GPU (or just a CPU) and joins it to your
**MCP Server** (Script 1), so Open WebUI, OpenCode and every other app on the MCP can use
it, and the model gets the MCP tools.

Script: [`../linux/ai-node.sh`](../linux/ai-node.sh) (Ubuntu / Debian, and Windows through WSL).
Model catalog: [`../models/`](../models/).

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AI_Tools/linux/ai-node.sh)"
sudo bash ai-node.sh --suggest          # scan + suggested models, changes nothing
```

## What it does

1. **Scans the hardware**: NVIDIA (VRAM, what already uses it, compute capability, driver),
   AMD (VRAM, gfx version, APU), CPU, RAM speed, disk; picks the engine build
   (CUDA 13.4 / 12.8, Vulkan, ROCm, CPU).
2. **Suggests models** from the catalog for that hardware: recommended, alternatives, one
   smaller and one bigger, with download size, memory use, context and speed.
3. **A confirmation card for every pick**: download and disk left, GPU memory (model +
   context + work), GPU / split / CPU, context in tokens and words, speed (*measured on
   this GPU* when we tested it, otherwise an estimate), MoE or dense, tool calling, license.
4. **Installs** a prebuilt llama.cpp release + llama-swap as the service `sudohomelab-node`
   (one OpenAI-compatible port, API key; models load on demand). Downloads resume and are
   checked with SHA-256.
5. **Tests** each model: chat (real speed vs estimate, VRAM used), a tool call, and the model
   using real MCP tools through the router (status → save a memory → search memory).
6. **Joins the MCP Server** with the join code: models show up in the router as
   `model@machine` and in its Open WebUI by themselves. Adding or removing models updates it;
   after the last model is removed and a new one added, the node rejoins on its own.
7. **OpenCode** (optional): installs it for your user and points it at the node's models and
   the MCP tools, without overwriting your config.

Options worth knowing: `--model=ID`, `--vram=GB` (plan for less than the whole card),
`--ctx=N`, `--join=CODE`, `--mcp-url=URL --mcp-token-file=F`, `--opencode=yes|no`, `-y`.

## Menu (run it again)

Status · Add a model · Remove a model · Test (+ MCP tools) · Connect / Disconnect MCP ·
OpenCode: install / link to the MCP · Connection info · Update llama.cpp + llama-swap ·
Uninstall · Quit. The menu comes back after every action.

`--uninstall` keeps the downloaded models for a reinstall; `--uninstall --purge` deletes
them too. Both leave the router and remove the services, the WSL firewall rules and the
OpenCode entries (OpenCode itself only if the script installed it).

## Windows (WSL)

- Ubuntu in WSL with systemd on; NVIDIA works through the Windows driver.
- Use mirrored networking (`networkingMode=mirrored` in `.wslconfig`) so the MCP Server can
  reach the node. The script opens the port in the Windows firewall (Hyper-V + Defender
  rules, LAN and Tailscale only; Windows asks for admin rights).
- If Tailscale on Windows routes your LAN (another machine advertises it), replies would
  leave through the tailnet: the script adds `sudohomelab-node-route` to keep them on the
  LAN card.
- The node runs while WSL runs. AMD GPUs on Windows: a native Windows version is planned.

## Tested (RTX 3090, each tier simulated with `--vram`)

| Tier | Model | Speed | VRAM | Context |
|---|---|---|---|---|
| 4 GB | Qwen3.5-4B Q4_K_M | 87 tok/s | 3.0 GB | 16k |
| 6 GB | Qwen3.5-4B Q8_0 | 89 tok/s | 5.0 GB | 32k |
| 8 GB | Qwen3.5-9B Q4_K_M | 123 tok/s | 6.5 GB | 64k |
| 10 GB | Qwen3.5-9B Q6_K | 103 tok/s | ~8.7 GB | 64k |
| 12 GB | Gemma 4 12B Q4_K_XL | 82 tok/s | 8.9 GB | 128k |
| 16 GB | Gemma 4 26B-A4B IQ4_XS | 119 tok/s | 14.9 GB | 128k |
| 20 GB | Qwen3.8-27B IQ4_XS | 47 tok/s | 17.9 GB | 128k |
| 24 GB | Qwen3.8-27B Q4_K_XL | 43 tok/s | 20.8 GB | 128k |
| 24 GB alt | Qwen3.6-35B-A3B Q4_K_S | 151 tok/s | 21.1 GB | 128k |

All passed chat, tool calling and the MCP tools through the router. Not tested yet:
32–96 GB tiers, CPU-only, GPU + RAM (MoE), AMD, plain Linux (non-WSL).
