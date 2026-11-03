# Model catalog

`models.json` is the shared catalog used by the AI Node script (Script 2) and the website advisor. It answers one question: **which model should this machine run?**

- **GPU tiers** (`tiers`): by usable GPU memory, 4 GB to 96 GB. Same picks for NVIDIA and AMD; only the backend differs (`backends`).
- **CPU tiers** (`cpu_tiers`): no usable GPU, picked by system RAM.
- **Hybrid tiers** (`hybrid_tiers`): a GPU plus lots of system RAM, for big MoE models with experts kept in RAM (`--n-cpu-moe`).

Each tier has a `default` model and `alternatives`. Every model entry lists the exact GGUF file(s) on Hugging Face with size and SHA-256, its license, and test results (`tested`, `kv_mib_per_1k_ctx`), which fill in as models pass the node test (chat + tool call + MCP).

## Picking a model

1. usable = total VRAM of all GPUs - 1 GB (AMD APUs: the GPU share of unified memory).
2. Take the largest tier whose `vram_gb` is <= usable, and suggest its `default` (show the alternatives too).
3. Start llama-server with the catalog's `llama_args` plus `-c <tier ctx>`. `--fit on` lowers the context (never below 8k) if the model does not fit.

## Backends

| Vendor | Linux | Windows |
|---|---|---|
| NVIDIA | CUDA 12.x (Maxwell and newer) | WSL + CUDA (the Windows driver provides it) |
| AMD | ROCm on supported cards (RDNA2/3/3.5/4, Instinct), Vulkan for the rest | Native Windows Vulkan build (not WSL) |
| None | CPU (AVX2 / ARM NEON) | WSL CPU build |

## Updating

The picks live at the top of `build-catalog.py`. Change them there, then run `python3 build-catalog.py` to rewrite `models.json` with fresh file names, sizes and checksums from Hugging Face. Never edit sizes or checksums by hand.
