#!/usr/bin/env python3
"""Build models.json (the SudoHomelab model catalog) from the curated picks below.

The picks (which model goes in which hardware tier) are chosen by hand. This script
asks Hugging Face for the exact GGUF files, sizes, checksums and model metadata so
those numbers are never typed by hand.

    python3 build-catalog.py            # writes models.json next to this file

Stdlib only. Re-run whenever a pick changes or a new model is added.
"""
import json
import os
import re
import struct
import sys
import urllib.request
from datetime import date

HF = "https://huggingface.co"

# id: (repo, quant, family, active params in B for MoE or None, roles, notes)
MODELS = {
    "qwen3.5-2b-q4km":        ("unsloth/Qwen3.5-2B-GGUF", "Q4_K_M", "Qwen3.5", None, ["chat"], "Smallest useful model. Low-RAM CPU boxes."),
    "qwen3.5-4b-q4km":        ("unsloth/Qwen3.5-4B-GGUF", "Q4_K_M", "Qwen3.5", None, ["chat"], ""),
    "qwen3.5-4b-q8":          ("unsloth/Qwen3.5-4B-GGUF", "Q8_0", "Qwen3.5", None, ["chat"], "Near-lossless 4B; best quality that fits 6 GB with room for context."),
    "gemma-4-e2b-q4km":       ("unsloth/gemma-4-E2B-it-GGUF", "Q4_K_M", "Gemma 4", None, ["chat"], ""),
    "gemma-4-e4b-q4km":       ("unsloth/gemma-4-E4B-it-GGUF", "Q4_K_M", "Gemma 4", None, ["chat"], ""),
    "qwen3.5-9b-q4km":        ("unsloth/Qwen3.5-9B-GGUF", "Q4_K_M", "Qwen3.5", None, ["chat", "code"], ""),
    "qwen3.5-9b-q6k":         ("unsloth/Qwen3.5-9B-GGUF", "Q6_K", "Qwen3.5", None, ["chat", "code"], ""),
    "qwen3.5-9b-q8":          ("unsloth/Qwen3.5-9B-GGUF", "Q8_0", "Qwen3.5", None, ["chat", "code"], ""),
    "gemma-4-12b-iq4xs":      ("unsloth/gemma-4-12b-it-GGUF", "IQ4_XS", "Gemma 4", None, ["chat"], "IQ quants run slower on AMD Vulkan than K quants."),
    "gemma-4-12b-q4kxl":      ("unsloth/gemma-4-12b-it-GGUF", "UD-Q4_K_XL", "Gemma 4", None, ["chat"], ""),
    "gemma-4-12b-q8":         ("unsloth/gemma-4-12b-it-GGUF", "Q8_0", "Gemma 4", None, ["chat"], ""),
    "gpt-oss-20b-mxfp4":      ("ggml-org/gpt-oss-20b-GGUF", "MXFP4", "gpt-oss", 3.6, ["chat", "code"], "Native MXFP4 weights (no quality loss). Small KV cache, long context is cheap."),
    "gemma-4-26b-a4b-iq4xs":  ("unsloth/gemma-4-26B-A4B-it-GGUF", "UD-IQ4_XS", "Gemma 4", 4.0, ["chat"], "MoE: fast for its size."),
    "gemma-4-26b-a4b-q4kxl":  ("unsloth/gemma-4-26B-A4B-it-GGUF", "UD-Q4_K_XL", "Gemma 4", 4.0, ["chat"], "MoE: fast for its size."),
    "glm-4.7-flash-q3kxl":    ("unsloth/GLM-4.7-Flash-GGUF", "UD-Q3_K_XL", "GLM-4.7", 3.0, ["code", "chat"], "MoE coding model."),
    "glm-4.7-flash-q4kxl":    ("unsloth/GLM-4.7-Flash-GGUF", "UD-Q4_K_XL", "GLM-4.7", 3.0, ["code", "chat"], "MoE coding model."),
    "qwen3.8-27b-iq4xs":      ("unsloth/Qwen3.8-27B-GGUF", "UD-IQ4_XS", "Qwen3.8", None, ["chat", "code"], "Same file the reference 3090 node runs (196k ctx with q8_0 KV)."),
    "qwen3.8-27b-q4kxl":      ("unsloth/Qwen3.8-27B-GGUF", "UD-Q4_K_XL", "Qwen3.8", None, ["chat", "code"], ""),
    "qwen3.8-27b-q6kxl":      ("unsloth/Qwen3.8-27B-GGUF", "UD-Q6_K_XL", "Qwen3.8", None, ["chat", "code"], ""),
    "qwen3.8-27b-q8":         ("unsloth/Qwen3.8-27B-GGUF", "Q8_0", "Qwen3.8", None, ["chat", "code"], ""),
    "qwen3.6-35b-a3b-iq4xs":  ("unsloth/Qwen3.6-35B-A3B-GGUF", "UD-IQ4_XS", "Qwen3.6", 3.0, ["chat", "code"], "MoE: about 3x faster than the 27B dense model."),
    "qwen3.6-35b-a3b-q4ks":   ("unsloth/Qwen3.6-35B-A3B-GGUF", "UD-Q4_K_S", "Qwen3.6", 3.0, ["chat", "code"], "MoE: about 3x faster than the 27B dense model."),
    "qwen3.6-35b-a3b-q5kxl":  ("unsloth/Qwen3.6-35B-A3B-GGUF", "UD-Q5_K_XL", "Qwen3.6", 3.0, ["chat", "code"], ""),
    "qwen3.6-35b-a3b-q8":     ("unsloth/Qwen3.6-35B-A3B-GGUF", "Q8_0", "Qwen3.6", 3.0, ["chat", "code"], ""),
    "gemma-4-31b-q4kxl":      ("unsloth/gemma-4-31B-it-GGUF", "UD-Q4_K_XL", "Gemma 4", None, ["chat"], ""),
    "qwen3-coder-30b-a3b-q4kxl": ("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "UD-Q4_K_XL", "Qwen3-Coder", 3.3, ["code"], "Coding only."),
    "qwen3-coder-next-q3kxl": ("unsloth/Qwen3-Coder-Next-GGUF", "UD-Q3_K_XL", "Qwen3-Coder", 3.0, ["code"], "80B MoE coding model."),
    "qwen3-coder-next-q4kxl": ("unsloth/Qwen3-Coder-Next-GGUF", "UD-Q4_K_XL", "Qwen3-Coder", 3.0, ["code"], "80B MoE coding model."),
    "gpt-oss-120b-mxfp4":     ("ggml-org/gpt-oss-120b-GGUF", "MXFP4", "gpt-oss", 5.1, ["chat", "code"], "Runs well with experts in system RAM (--n-cpu-moe)."),
    "qwen3.5-122b-a10b-q3kxl": ("unsloth/Qwen3.5-122B-A10B-GGUF", "UD-Q3_K_XL", "Qwen3.5", 10.0, ["chat", "code"], ""),
    "qwen3.5-122b-a10b-q4kxl": ("unsloth/Qwen3.5-122B-A10B-GGUF", "UD-Q4_K_XL", "Qwen3.5", 10.0, ["chat", "code"], ""),
    "qwen3.8-flash-next-iq3xxs": ("unsloth/Qwen3.8-Flash-Next-GGUF", "UD-IQ3_XXS", "Qwen3.8", None, ["chat", "code"], "177B MoE. Qwen community license (check terms before commercial use)."),
}

# Measured with AI_Tools/linux/ai-node.sh --test (chat speed, VRAM in use, context, MCP tools via
# the router). Keyed by GPU name; the installer shows these instead of its estimate on that GPU.
TESTED = {
    "qwen3.5-4b-q4km":       {"RTX 3090": {"tg": 87.2, "pp": 191, "vram_gb": 3.0, "ctx": 16384, "mcp": True, "date": "2026-11-03"}},
    "qwen3.5-4b-q8":         {"RTX 3090": {"tg": 89.5, "pp": 305, "vram_gb": 5.0, "ctx": 32768, "mcp": True, "date": "2026-11-03"}},
    "qwen3.5-9b-q4km":       {"RTX 3090": {"tg": 123.1, "pp": 299, "vram_gb": 6.5, "ctx": 65536, "mcp": True, "date": "2026-11-03"}},
    "qwen3.5-9b-q6k":        {"RTX 3090": {"tg": 102.9, "ctx": 65536, "mcp": True, "date": "2026-11-03"}},
    "gemma-4-12b-q4kxl":     {"RTX 3090": {"tg": 82.0, "pp": 264, "vram_gb": 8.9, "ctx": 131072, "mcp": True, "date": "2026-11-03"}},
    "gemma-4-26b-a4b-iq4xs": {"RTX 3090": {"tg": 118.6, "pp": 183, "vram_gb": 14.9, "ctx": 131072, "mcp": True, "date": "2026-11-03"}},
    "qwen3.8-27b-iq4xs":     {"RTX 3090": {"tg": 47.4, "pp": 230, "vram_gb": 17.9, "ctx": 131072, "mcp": True, "date": "2026-11-03"}},
    "qwen3.6-35b-a3b-q4ks":  {"RTX 3090": {"tg": 151.2, "pp": 78, "vram_gb": 21.1, "ctx": 131072, "mcp": True, "date": "2026-11-03"}},
    "qwen3.8-27b-q4kxl":     {"RTX 3090": {"tg": 42.8, "pp": 197, "vram_gb": 20.8, "ctx": 131072, "mcp": True, "date": "2026-11-03"}},
}

# Tiers by usable GPU memory (VRAM, or the GPU share of unified memory on AMD APUs).
# ctx = target context; llama.cpp --fit shrinks it (never below fit_ctx) if it does not fit.
TIERS = [
    {"id": "vram-4",  "vram_gb": 4,  "ctx": 16384,  "examples": {"nvidia": ["GTX 1650", "RTX 3050 Laptop 4GB"], "amd": ["RX 6500 XT"]},
     "default": "qwen3.5-4b-q4km", "alternatives": ["gemma-4-e2b-q4km", "qwen3.5-2b-q4km"]},
    {"id": "vram-6",  "vram_gb": 6,  "ctx": 32768,  "examples": {"nvidia": ["RTX 3060 Laptop", "RTX 2060", "GTX 1660"], "amd": ["RX 5600 XT", "RX 7600M"]},
     "default": "qwen3.5-4b-q8", "alternatives": ["gemma-4-e4b-q4km", "qwen3.5-4b-q4km"]},
    {"id": "vram-8",  "vram_gb": 8,  "ctx": 32768,  "examples": {"nvidia": ["RTX 3070", "RTX 4060", "Quadro M4000"], "amd": ["RX 6600", "RX 7600"]},
     "default": "qwen3.5-9b-q4km", "alternatives": ["gemma-4-12b-iq4xs", "gemma-4-e4b-q4km"]},
    {"id": "vram-10", "vram_gb": 10, "ctx": 32768,  "examples": {"nvidia": ["RTX 3080 10GB", "RTX 2080 Ti (11GB)"], "amd": ["RX 6700 (10GB)"]},
     "default": "qwen3.5-9b-q6k", "alternatives": ["gemma-4-12b-q4kxl"]},
    {"id": "vram-12", "vram_gb": 12, "ctx": 65536,  "examples": {"nvidia": ["RTX 3060 12GB", "RTX 4070", "RTX 5070"], "amd": ["RX 6700 XT", "RX 7700 XT"]},
     "default": "gemma-4-12b-q4kxl", "alternatives": ["qwen3.5-9b-q8", "qwen3.5-9b-q6k"]},
    {"id": "vram-16", "vram_gb": 16, "ctx": 65536,  "examples": {"nvidia": ["RTX 4060 Ti 16GB", "RTX 5060 Ti 16GB", "RTX A4000"], "amd": ["RX 7800 XT", "RX 9070 XT", "RX 6800"]},
     "default": "gemma-4-26b-a4b-iq4xs", "alternatives": ["gpt-oss-20b-mxfp4", "glm-4.7-flash-q3kxl", "gemma-4-12b-q8"]},
    {"id": "vram-20", "vram_gb": 20, "ctx": 65536,  "examples": {"nvidia": ["RTX 4000 Ada (20GB)"], "amd": ["RX 7900 XT"]},
     "default": "qwen3.8-27b-iq4xs", "alternatives": ["qwen3.6-35b-a3b-iq4xs", "gemma-4-26b-a4b-q4kxl", "gpt-oss-20b-mxfp4"]},
    {"id": "vram-24", "vram_gb": 24, "ctx": 131072, "examples": {"nvidia": ["RTX 3090", "RTX 4090"], "amd": ["RX 7900 XTX"]},
     "default": "qwen3.8-27b-q4kxl", "alternatives": ["qwen3.6-35b-a3b-q4ks", "qwen3.8-27b-iq4xs", "gemma-4-31b-q4kxl", "qwen3-coder-30b-a3b-q4kxl", "glm-4.7-flash-q4kxl"]},
    {"id": "vram-32", "vram_gb": 32, "ctx": 131072, "examples": {"nvidia": ["RTX 5090"], "amd": ["Radeon AI PRO R9700", "Radeon PRO W7800"]},
     "default": "qwen3.8-27b-q6kxl", "alternatives": ["qwen3.6-35b-a3b-q5kxl", "qwen3.8-27b-q4kxl"]},
    {"id": "vram-48", "vram_gb": 48, "ctx": 131072, "examples": {"nvidia": ["2x RTX 3090", "RTX A6000"], "amd": ["2x RX 7900 XTX", "Radeon PRO W7900"]},
     "default": "qwen3.8-27b-q8", "alternatives": ["qwen3.6-35b-a3b-q8", "qwen3-coder-next-q3kxl"]},
    {"id": "vram-64", "vram_gb": 64, "ctx": 131072, "examples": {"nvidia": ["2x RTX 5090"], "amd": ["Ryzen AI Max+ 395 with 64 GB GPU share"]},
     "default": "qwen3.5-122b-a10b-q3kxl", "alternatives": ["qwen3-coder-next-q4kxl", "qwen3.6-35b-a3b-q8"]},
    {"id": "vram-96", "vram_gb": 96, "ctx": 131072, "examples": {"nvidia": ["RTX PRO 6000", "4x RTX 3090"], "amd": ["Ryzen AI Max+ 395 128GB (96 GB GPU share)"]},
     "default": "gpt-oss-120b-mxfp4", "alternatives": ["qwen3.5-122b-a10b-q4kxl", "qwen3-coder-next-q4kxl"]},
]

# No usable GPU: picks by system RAM. Only small/MoE models are pleasant on CPU.
CPU_TIERS = [
    {"id": "cpu-8",  "ram_gb": 8,  "ctx": 8192,  "default": "qwen3.5-2b-q4km", "alternatives": []},
    {"id": "cpu-16", "ram_gb": 16, "ctx": 16384, "default": "qwen3.5-4b-q4km", "alternatives": ["gemma-4-e4b-q4km", "qwen3.5-2b-q4km"]},
    {"id": "cpu-32", "ram_gb": 32, "ctx": 32768, "default": "gpt-oss-20b-mxfp4", "alternatives": ["qwen3.5-4b-q8", "qwen3.5-9b-q4km"],
     "notes": "MoE models (few active parameters) are the fastest choice on CPU."},
    {"id": "cpu-64", "ram_gb": 64, "ctx": 32768, "default": "qwen3.6-35b-a3b-q4ks", "alternatives": ["gpt-oss-20b-mxfp4", "glm-4.7-flash-q4kxl"]},
]

# GPU + lots of system RAM: big MoE models with some experts kept in RAM (--n-cpu-moe).
HYBRID_TIERS = [
    {"id": "moe-ram-64",  "min_vram_gb": 8,  "min_ram_gb": 64,  "ctx": 65536, "default": "gpt-oss-120b-mxfp4", "alternatives": ["qwen3-coder-next-q3kxl"]},
    {"id": "moe-ram-96",  "min_vram_gb": 16, "min_ram_gb": 96,  "ctx": 65536, "default": "qwen3.5-122b-a10b-q4kxl", "alternatives": ["gpt-oss-120b-mxfp4", "qwen3-coder-next-q4kxl"]},
    {"id": "moe-ram-128", "min_vram_gb": 24, "min_ram_gb": 128, "ctx": 65536, "default": "qwen3.8-flash-next-iq3xxs", "alternatives": ["qwen3.5-122b-a10b-q4kxl"]},
]

# Memory bandwidth (GB/s) by GPU name, used to estimate generation speed before a download.
# First match wins (case-insensitive substring), so specific names go before shorter ones.
GPUS = [
    ["RTX PRO 6000", 1792], ["RTX 6000 Ada", 960], ["RTX 5000 Ada", 576], ["RTX 4500 Ada", 432],
    ["RTX 4000 Ada", 360], ["RTX A6000", 768], ["RTX A5000", 768], ["RTX A4500", 640], ["RTX A4000", 448],
    ["RTX A2000", 288], ["A100", 1555], ["H100", 3350], ["L40S", 864], ["L4", 300], ["T4", 320],
    ["V100", 900], ["P100", 732], ["P40", 346], ["Quadro P4000", 243], ["Quadro P2200", 200],
    ["Quadro M4000", 192], ["TITAN RTX", 672],
    ["5090 Laptop", 896], ["5080 Laptop", 896], ["5070 Ti Laptop", 448], ["5070 Laptop", 384], ["5060 Laptop", 384],
    ["4090 Laptop", 576], ["4080 Laptop", 432], ["4070 Laptop", 256], ["4060 Laptop", 256], ["4050 Laptop", 192],
    ["3080 Ti Laptop", 512], ["3080 Laptop", 448], ["3070 Ti Laptop", 448], ["3070 Laptop", 448],
    ["3060 Laptop", 336], ["3050 Ti Laptop", 192], ["3050 Laptop", 192],
    ["RTX 5090", 1792], ["RTX 5080", 960], ["RTX 5070 Ti", 896], ["RTX 5070", 672], ["RTX 5060 Ti", 448], ["RTX 5060", 448],
    ["RTX 4090", 1008], ["RTX 4080 SUPER", 736], ["RTX 4080", 717], ["RTX 4070 Ti SUPER", 672], ["RTX 4070 Ti", 504],
    ["RTX 4070 SUPER", 504], ["RTX 4070", 504], ["RTX 4060 Ti", 288], ["RTX 4060", 272],
    ["RTX 3090 Ti", 1008], ["RTX 3090", 936], ["RTX 3080 Ti", 912], ["RTX 3080", 760], ["RTX 3070 Ti", 608],
    ["RTX 3070", 448], ["RTX 3060 Ti", 448], ["RTX 3060", 360], ["RTX 3050", 224],
    ["RTX 2080 Ti", 616], ["RTX 2080", 448], ["RTX 2070", 448], ["RTX 2060", 336],
    ["GTX 1660 Ti", 288], ["GTX 1660", 192], ["GTX 1650", 128], ["GTX 1080 Ti", 484], ["GTX 1080", 320], ["GTX 1070", 256],
    ["MI300X", 5300], ["MI250", 3277], ["MI210", 1638], ["MI100", 1229],
    ["AI PRO R9700", 640], ["PRO W7900", 864], ["PRO W7800", 576], ["PRO W6800", 512],
    ["RX 9070 XT", 640], ["RX 9070", 640], ["RX 9060 XT", 320],
    ["RX 7900 XTX", 960], ["RX 7900 XT", 800], ["RX 7900 GRE", 576], ["RX 7800 XT", 624], ["RX 7700 XT", 432],
    ["RX 7600 XT", 288], ["RX 7600M", 256], ["RX 7600", 288],
    ["RX 6950 XT", 576], ["RX 6900 XT", 512], ["RX 6800 XT", 512], ["RX 6800", 512], ["RX 6750 XT", 432],
    ["RX 6700 XT", 384], ["RX 6700", 320], ["RX 6650 XT", 280], ["RX 6600 XT", 256], ["RX 6600", 224], ["RX 6500 XT", 144],
    ["RX 5700 XT", 448], ["RX 5600 XT", 336],
    ["Radeon 8060S", 256], ["Radeon 8050S", 256], ["Radeon 890M", 120], ["Radeon 880M", 120], ["Radeon 780M", 90],
]

BACKENDS = {
    "nvidia": {
        "default": "cuda",
        "options": {
            "cuda": "CUDA 12.x build. Works from Maxwell (GTX 900 / Quadro M) up; CUDA 13 drops Maxwell/Pascal/Volta, so the script stays on 12.x for those. Needs an NVIDIA driver; on WSL the Windows driver provides it (do not install a Linux driver inside WSL).",
            "vulkan": "Fallback when CUDA is not available.",
        },
    },
    "amd": {
        "default": "rocm",
        "options": {
            "rocm": "Linux only, supported GPUs: RDNA2 (gfx1030), RDNA3 (gfx1100/1101/1102), RDNA3.5 APUs (gfx1150/1151), RDNA4 (gfx1200/1201), Instinct (gfx90a/gfx942). Other cards use Vulkan.",
            "vulkan": "Works on every AMD GPU (Mesa RADV). Often as fast as ROCm for generation; prefer K quants (IQ quants are slower here). Default for unsupported ROCm cards and AMD APUs.",
        },
        "windows": "AMD on Windows: use the NATIVE Windows Vulkan build, not WSL (inside WSL, Vulkan only goes through the slow D3D12 translation layer and ROCm-on-WSL covers only a few RDNA3/4 cards).",
    },
    "cpu": {"default": "cpu", "options": {"cpu": "AVX2 build (any x86-64 CPU since ~2015) or ARM NEON."}},
}

# Arguments shared by every model. --fit lets llama.cpp shrink context/offload to fit memory.
LLAMA_ARGS = ["--jinja", "-fa", "on", "-ctk", "q8_0", "-ctv", "q8_0", "--fit", "on", "--fit-ctx", "8192"]


# ── GGUF header (read from the start of the file, nothing else is downloaded) ──
_T = {0: ("B", 1), 1: ("b", 1), 2: ("H", 2), 3: ("h", 2), 4: ("I", 4), 5: ("i", 4), 6: ("f", 4),
      7: ("?", 1), 10: ("Q", 8), 11: ("q", 8), 12: ("d", 8)}


def gguf_header(url):
    """Metadata key/values of a GGUF file (arrays of strings are skipped)."""
    f = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "sudohomelab"}), timeout=120)

    def rd(n):
        b = b""
        while len(b) < n:
            c = f.read(n - len(b))
            if not c:
                raise EOFError(url)
            b += c
        return b

    def u(fmt, n):
        return struct.unpack("<" + fmt, rd(n))[0]

    def val(t):
        if t == 8:
            return rd(u("Q", 8)).decode("utf-8", "replace")
        if t == 9:
            et, n = u("I", 4), u("Q", 8)
            if et == 8:
                for _ in range(n):
                    rd(u("Q", 8))
                return None
            fmt, sz = _T[et]
            data = rd(sz * n)
            return list(struct.unpack("<" + fmt * n, data)) if n <= 4096 else None
        fmt, sz = _T[t]
        return u(fmt, sz)

    try:
        if rd(4) != b"GGUF":
            raise ValueError("not a GGUF file: " + url)
        u("I", 4), u("Q", 8)
        kv = {}
        for _ in range(u("Q", 8)):
            k = rd(u("Q", 8)).decode()
            kv[k] = val(u("I", 4))
        return kv
    finally:
        f.close()


def kv_shape(h):
    """KV cache size per token, in elements, split into full-context and sliding-window layers.

    bytes(ctx) = bytes_per_elem * (full * ctx + swa * min(ctx, window + 512))
    Covers plain attention, hybrid models (only every Nth layer has attention),
    sliding-window layers, shared KV layers (Gemma E models) and MLA (DeepSeek/GLM).
    """
    a = h["general.architecture"]
    g = lambda k, d=None: h.get(f"{a}.{k}", d)
    n = g("block_count")
    per = lambda v, i: v[i] if isinstance(v, list) else v
    hkv, kl, vl = g("attention.head_count_kv"), g("attention.key_length"), g("attention.value_length")
    if kl is None:  # older archs: head size = embedding / heads
        kl = vl = g("embedding_length") // per(g("attention.head_count"), 0)
    kl_swa, vl_swa = g("attention.key_length_swa", kl), g("attention.value_length_swa", vl)
    window = g("attention.sliding_window") or 0
    pattern = g("attention.sliding_window_pattern")
    interval = g("full_attention_interval")
    shared = g("attention.shared_kv_layers") or 0
    mla = g("attention.kv_lora_rank") is not None
    full = swa = 0
    for i in range(n - shared):
        if interval and (i + 1) % interval:
            continue  # recurrent (linear attention) layer: small fixed state, no KV cache
        h_i = per(hkv, i)
        if h_i == 0:
            continue
        is_swa = bool(window) and (pattern[i] if isinstance(pattern, list)
                                   else (a == "gpt-oss" and i % 2 == 0))
        if mla:
            full += kl  # compressed latent + rope part; V is read from the same cache
        elif is_swa:
            swa += h_i * (kl_swa + vl_swa)
        else:
            full += h_i * (kl + vl)
    return {"layers": n, "full": full, "swa": swa, "window": window if swa else 0}


def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return json.load(r)


def resolve(repo, quant):
    info = get(f"{HF}/api/models/{repo}?blobs=true&expand[]=gguf&expand[]=cardData&expand[]=siblings")
    pat = re.compile(rf"(^|/|-){re.escape(quant)}(\.gguf|-\d{{5}}-of-\d{{5}}\.gguf)$")
    files = [s for s in info["siblings"]
             if s["rfilename"].endswith(".gguf") and "mmproj" not in s["rfilename"]
             and not s["rfilename"].split("/")[-1].lower().startswith(("mtp", "dflash"))
             and pat.search(s["rfilename"])]
    if not files:
        sys.exit(f"no {quant} file in {repo}")
    files.sort(key=lambda s: s["rfilename"])
    g = info.get("gguf") or {}
    card = info.get("cardData") or {}
    return {
        "files": [{"name": s["rfilename"], "bytes": s.get("size", 0),
                   "sha256": (s.get("lfs") or {}).get("sha256")} for s in files],
        "file_gb": round(sum(s.get("size", 0) for s in files) / 1e9, 2),
        "params_b": round((g.get("total") or 0) / 1e9, 1),
        "arch": g.get("architecture"),
        "ctx_max": g.get("context_length"),
        "tools_in_template": "tools" in (g.get("chat_template") or ""),
        "license": card.get("license_name") or card.get("license"),
        "kv": kv_shape(gguf_header(f"{HF}/{repo}/resolve/main/{files[0]['rfilename']}")),
    }


def main():
    used = {t["default"] for t in TIERS + CPU_TIERS + HYBRID_TIERS}
    used |= {a for t in TIERS + CPU_TIERS + HYBRID_TIERS for a in t["alternatives"]}
    missing = used - MODELS.keys()
    if missing:
        sys.exit(f"tiers use unknown models: {sorted(missing)}")

    models = {}
    for mid, (repo, quant, family, active, roles, notes) in MODELS.items():
        print(f"  {mid} <- {repo} {quant}", file=sys.stderr)
        r = resolve(repo, quant)
        models[mid] = {
            "family": family, "repo": repo, "quant": quant,
            "params_b": r["params_b"], "active_params_b": active or r["params_b"], "moe": active is not None,
            "arch": r["arch"], "file_gb": r["file_gb"], "files": r["files"],
            "ctx_max": r["ctx_max"], "license": r["license"], "roles": roles,
            "tool_calling": "template" if r["tools_in_template"] else "none",
            "kv": r["kv"],               # KV cache shape from the GGUF header (see kv_shape)
            "tested": TESTED.get(mid, {}),  # measured results by GPU name (see TESTED)
            "notes": notes,
        }

    catalog = {
        "schema": 1,
        "updated": date.today().isoformat(),
        "engine": "llama.cpp (llama-server) behind llama-swap",
        "llama_args": LLAMA_ARGS,
        "sizing": {
            "rule": "usable = VRAM (sum of all GPUs) - 1 GB. Pick the largest tier <= usable, default model first. "
                    "A model fits if file_gb + KV(ctx) + ~0.8 GB compute buffer <= usable. --fit on lowers ctx (min --fit-ctx) if needed.",
            "headroom_gb": 1.0,
            "multi_gpu": "llama.cpp splits layers across GPUs of the same vendor; add their VRAM. Mixed vendors: use Vulkan.",
            "amd_apu": "Ryzen AI / Strix Halo: usable = GPU share of unified memory (BIOS UMA size or GTT limit), Vulkan backend.",
        },
        "backends": BACKENDS,
        "gpus": GPUS,
        "tiers": TIERS,
        "cpu_tiers": CPU_TIERS,
        "hybrid_tiers": HYBRID_TIERS,
        "models": models,
    }
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.json")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(catalog, f, indent=2)
        f.write("\n")
    print(f"wrote {out}: {len(models)} models, {len(TIERS)} GPU tiers, {len(CPU_TIERS)} CPU tiers, {len(HYBRID_TIERS)} hybrid tiers", file=sys.stderr)


if __name__ == "__main__":
    main()
