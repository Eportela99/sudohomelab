#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · AI Node: runs a local AI model on this machine (Debian / Ubuntu / WSL)
#  https://github.com/Eportela99/sudohomelab
#
#  · scans the hardware (NVIDIA / AMD GPUs, RAM, disk) and suggests the best
#    models from the shared catalog, with how each one will run here
#  · installs llama.cpp (prebuilt for CUDA, Vulkan, ROCm or CPU) behind llama-swap
#    as one OpenAI-compatible address, with an API key
#  · joins an MCP server (SudoHomelab Script 1) with its join code, so every app
#    using the MCP gets this model, and the model gets the MCP tools
#  · optional: OpenCode (coding agent) on this machine, wired to the model + MCP
#
#  Usage (no options = a menu when it's already installed):
#    sudo bash -c "$(curl -fsSL <url>/AI_Tools/linux/ai-node.sh)"
#    sudo bash ai-node.sh --suggest                  # scan + suggestions, changes nothing
#    sudo bash ai-node.sh --install --model=ID --join=shl-join:... --yes
#    sudo bash ai-node.sh --add-model | --remove-model | --test | --status | --info
#    sudo bash ai-node.sh --uninstall [--purge]      # --purge also deletes the downloaded models
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.0"
REPO="Eportela99/sudohomelab"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/main/AI_Tools/linux/ai-node.sh"
CATALOG_URL="https://raw.githubusercontent.com/$REPO/main/AI_Tools/models/models.json"
INSTALL_DIR="/opt/sudohomelab/node"
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/ai-node-$(date +%Y%m%d-%H%M%S).log"
SERVICE="sudohomelab-node"
SVC_USER="sudohomelab"
WSL_VM_ID="{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"   # WSL's Hyper-V firewall id

ACTION=""; MODEL=""; VRAM=""; CTX=""; PORT=""; NODE_NAME=""; JOIN=""; MCP_URL=""; MCP_TOKEN=""
OPENCODE=""; TARGET_USER="${SUDO_USER:-}"; CATALOG_SRC=""; BACKEND=""; LLAMA_TAG=""
ASSUME_YES=0; PURGE=0

# ── UI ────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_CYAN=$'\e[36m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi
export C_RESET C_BOLD C_GREEN C_CYAN C_YELLOW C_RED C_GRAY
log()  { [[ -d $LOG_DIR ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" || true; }
say()  { printf '%s\n' "$*"; log "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK   $*"; }
info() { printf '  %s›%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log "INFO $*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN $*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "ERR  $*"; }
die()  { err "$*"; [[ -f $LOG_FILE ]] && err "Log: $LOG_FILE"; exit 1; }
STEP=0; TOTAL_STEPS=8
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s%s%s\n' "$C_GRAY" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; log "STEP $STEP $*"; }
run()  { log "RUN  $*"; "$@" >>"$LOG_FILE" 2>&1; }

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sAI Node: a local AI model for your homelab%s %sv%s%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

has_tty() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }
interactive() { [[ $ASSUME_YES == 0 ]] && has_tty; }
ask() { # ask "question" default
  local a
  if ! interactive; then echo "$2"; return; fi
  read -r -p "  $1 [${2}]: " a </dev/tty || true
  echo "${a:-$2}"
}
ask_secret() {
  local a=""
  has_tty && { read -r -s -p "  $1: " a </dev/tty || true; echo >/dev/tty; }
  echo "$a"
}
confirm() { # confirm "question" (default yes)
  local a
  interactive || return 0
  read -r -p "  $1 [Y/n]: " a </dev/tty || true
  [[ -z $a || $a =~ ^[Yy] ]]
}
confirm_no() { # confirm "question" (default no)
  local a
  interactive || return 1
  read -r -p "  $1 [y/N]: " a </dev/tty || true
  [[ $a =~ ^[Yy] ]]
}
menu() { # menu "title" default "label" ... → chosen index (1-based)
  local title=$1 def=$2 i a; shift 2
  if ! interactive; then echo "$def"; return; fi
  printf '\n  %s%s%s\n' "$C_BOLD" "$title" "$C_RESET" >/dev/tty
  i=1; for a in "$@"; do printf '    %d) %s\n' "$i" "$a" >/dev/tty; i=$((i + 1)); done
  while :; do
    read -r -p "  Choice [$def]: " a </dev/tty || true
    a=${a:-$def}
    [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= $# )) && { echo "$a"; return; }
  done
}

usage() {
  cat <<EOF
Usage: sudo bash ai-node.sh [action] [options]

Actions (no action = install, or a menu if it's already installed):
  --suggest            Scan the hardware and show the suggested models (changes nothing)
  --install            Install the node with one model
  --add-model          Add another model (llama-swap loads one at a time, on demand)
  --remove-model       Remove a model and delete its files (--model=ID)
  --test               Chat, tool call and speed test of each model, plus the MCP
                       tools through the router when the node is connected
  --connect            Join an MCP server (--join=CODE, optional --mcp-url/--mcp-token-file)
  --disconnect         Leave the MCP server's router
  --opencode           OpenCode for --user: install it if needed, point it at this node's
                       models and link it to the MCP tools (--mcp-url, --mcp-token-file)
  --status | --info    Service state | addresses, API key, models
  --update             Newest llama.cpp and llama-swap; keeps models and settings
  --uninstall          Remove the node; the downloaded models stay (--purge deletes them too)

Options:
  --model=ID           Catalog model id (see --suggest); skips the picker
  --vram=GB            Plan for this much GPU memory instead of the whole card (leave room
                       for other programs, or test what a smaller card would get)
  --ctx=N              Context length in tokens (default: the most that fits, up to 131072)
  --port=N             Port of the node (default 8080, or the next free one)
  --name=NAME          Machine name in the router (default: hostname)
  --join=CODE | --join-file=F   Join code printed by the MCP server (Script 1)
  --mcp-url=URL --mcp-token-file=F   MCP address + token, so OpenCode here gets the MCP
                       tools and the test can use them (optional)
  --opencode=yes|no    Install OpenCode for --user and point it at the model + MCP
  --user=NAME          Linux user for OpenCode (default: the one who ran sudo)
  --backend=NAME       cuda-13.4 | cuda-12.8 | vulkan | rocm | cpu (default: picked from the hardware)
  --llama-tag=bNNNN    llama.cpp release (default: newest with a build for this machine)
  --catalog=FILE|URL   Model catalog (default: the one on GitHub)
  -y, --yes            Accept defaults, no questions
EOF
}

parse_args() {
  local a
  for a in "$@"; do
    case $a in
      --suggest|--install|--add-model|--remove-model|--test|--connect|--disconnect|--status|--info|--update|--uninstall|--opencode)
        ACTION=${a#--} ;;
      --model=*) MODEL=${a#*=} ;;
      --vram=*) VRAM=${a#*=} ;;
      --ctx=*) CTX=${a#*=} ;;
      --port=*) PORT=${a#*=} ;;
      --name=*) NODE_NAME=${a#*=} ;;
      --join=*) JOIN=${a#*=} ;;
      --join-file=*) [[ -r ${a#*=} ]] || { echo "Can't read ${a#*=}" >&2; exit 2; }; JOIN=$(head -n1 "${a#*=}" | tr -d '\r\n') ;;
      --mcp-url=*) MCP_URL=${a#*=} ;;
      --mcp-token-file=*) [[ -r ${a#*=} ]] || { echo "Can't read ${a#*=}" >&2; exit 2; }; MCP_TOKEN=$(head -n1 "${a#*=}" | tr -d '\r\n') ;;
      --opencode=*) OPENCODE=${a#*=} ;;
      --user=*) TARGET_USER=${a#*=} ;;
      --backend=*) BACKEND=${a#*=} ;;
      --llama-tag=*) LLAMA_TAG=${a#*=} ;;
      --catalog=*) CATALOG_SRC=${a#*=} ;;
      --purge) PURGE=1 ;;
      --keep-models) PURGE=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $a (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ -z $VRAM || $VRAM =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--vram: a number of GB" >&2; exit 2; }
  [[ -z $CTX || $CTX =~ ^[0-9]+$ ]] || { echo "--ctx: a number of tokens" >&2; exit 2; }
  [[ -z $PORT || $PORT =~ ^[0-9]+$ ]] || { echo "--port: a number" >&2; exit 2; }
  [[ -z $OPENCODE || $OPENCODE =~ ^(yes|no)$ ]] || { echo "--opencode: yes or no" >&2; exit 2; }
  [[ -z $BACKEND || $BACKEND =~ ^(cuda-13.4|cuda-12.8|vulkan|rocm|cpu)$ ]] || { echo "--backend: cuda-13.4, cuda-12.8, vulkan, rocm or cpu" >&2; exit 2; }
  [[ -z $JOIN || $JOIN == shl-join:* ]] || { echo "--join: the code starts with shl-join:" >&2; exit 2; }
}

# ── Helper (Python, stdlib only): hardware, catalog math, router, tests ────────
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE="$INSTALL_DIR/node.json"
CATALOG="$WORK/models.json"
HW="$WORK/hw.json"
installed() { [[ -f $STATE && -f /etc/systemd/system/$SERVICE.service ]]; }
py() { SHL_VRAM="$VRAM" SHL_CTX="$CTX" python3 "$WORK/node.py" "$@"; }
sget() { py state-get "$STATE" "$1"; }

write_helper() {
cat >"$WORK/node.py" <<'PY'
#!/usr/bin/env python3
"""sudo homelab AI node helper: hardware scan, model suggestions and stats,
llama-swap config, router join, model tests. Stdlib only."""
import base64, datetime, glob, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request

GiB = 1024 ** 3
KV_BYTES = 34 / 32            # q8_0 KV cache: 34 bytes per 32 values
HEADROOM = 0.5                # GiB left free on each GPU (desktop, driver)
CPU_RESERVE = 3.0             # GiB of RAM left for the system when running on CPU
CTX_STEPS = [8192, 16384, 32768, 65536, 131072, 262144]
EFF_GPU, EFF_CPU = 0.95, 0.55  # share of memory bandwidth reached while generating
LAYER_GPU_S, LAYER_CPU_S = 8e-5, 5e-5  # fixed cost per layer per token (kernels)
LAYER_MOE_S = 1.5e-4                   # MoE layers on a GPU: expert routing + many small kernels
# GPU numbers calibrated 2026-11-03 on an RTX 3090: Qwen3.5-9B Q4_K_M 123 tok/s, Q6_K 103 tok/s,
# Gemma 4 12B 82 tok/s, MoE: Gemma 4 26B-A4B 119 tok/s, Qwen3.6-35B-A3B 151 tok/s.
E = os.environ
B, G, Y, R, GR, X = (E.get(k, "") for k in ("C_BOLD", "C_GREEN", "C_YELLOW", "C_RED", "C_GRAY", "C_RESET"))


def sh(*cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def read(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return ""


def load(p, default=None):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(p, d):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


# ── hardware ──────────────────────────────────────────────────────────────────
def nvidia_smi():
    return shutil.which("nvidia-smi") or next((p for p in ("/usr/lib/wsl/lib/nvidia-smi",) if os.path.exists(p)), None)


def nvidia_used():
    smi = nvidia_smi()
    if not smi:
        return None
    out = sh(smi, "--query-gpu=memory.used", "--format=csv,noheader,nounits").split()
    return sum(int(x) for x in out if x.isdigit()) / 1024 if out else None


def ram_bandwidth(cpu):
    """(GB/s, label) from the DIMMs (dmidecode); a rough default when unknown."""
    out = sh("dmidecode", "-t", "17")
    speeds, kinds = [], set()
    for blk in out.split("\n\n"):
        if "Size: No Module" in blk or "Size:" not in blk:
            continue
        m = re.search(r"Configured (?:Memory|Clock) Speed:\s*(\d+)", blk) or re.search(r"\n\s*Speed:\s*(\d+)", blk)
        t = re.search(r"\n\s*Type:\s*(\S+)", blk)
        if m:
            speeds.append(int(m.group(1)))
        if t:
            kinds.add(t.group(1))
    if not speeds:
        return 50.0, "unknown, ~50 GB/s assumed"
    server = re.search(r"EPYC|Xeon|Threadripper", cpu or "")
    channels = len(speeds) if server else min(len(speeds), 2)
    bw = min(speeds) * 8 * channels / 1000
    return round(bw, 1), "%s-%d x%d, ~%d GB/s" % ("/".join(sorted(kinds)) or "RAM", min(speeds), channels, bw)


def amd_gfx():
    for p in glob.glob("/sys/class/kfd/kfd/topology/nodes/*/properties"):
        m = re.search(r"gfx_target_version\s+(\d+)", read(p))
        if m and int(m.group(1)):
            v = int(m.group(1))
            return "gfx%d%d%x" % (v // 10000, v // 100 % 100, v % 100)
    return ""


def amd_name(dev):
    n = read(dev + "/product_name")
    if n:
        return n
    slot = os.path.basename(os.path.realpath(dev))
    out = sh("lspci", "-s", slot)
    m = re.search(r"\[(Radeon[^\]]*)\]", out) or re.search(r": (.*)", out)
    return ("AMD " + m.group(1).strip()) if m else "AMD GPU"


def scan():
    hw = {"arch": os.uname().machine, "wsl": "microsoft" in read("/proc/version").lower()}
    osr = dict(l.split("=", 1) for l in read("/etc/os-release").splitlines() if "=" in l)
    hw["os"] = osr.get("PRETTY_NAME", "Linux").strip('"')
    cpuinfo = read("/proc/cpuinfo")
    m = re.search(r"model name\s*:\s*(.+)", cpuinfo)
    hw["cpu"] = m.group(1).strip() if m else hw["arch"]
    hw["threads"] = os.cpu_count() or 1
    hw["avx2"] = " avx2" in cpuinfo or hw["arch"] != "x86_64"
    mi = {}
    for l in read("/proc/meminfo").splitlines():
        p = l.split()
        if len(p) >= 2 and p[1].isdigit():
            mi[p[0].rstrip(":")] = int(p[1])
    hw["ram_gib"] = round(mi.get("MemTotal", 0) / 1048576, 1)
    hw["ram_free_gib"] = round(mi.get("MemAvailable", mi.get("MemFree", 0)) / 1048576, 1)
    hw["ram_bw"], hw["ram_label"] = ram_bandwidth(hw["cpu"])
    gpus = []
    smi = nvidia_smi()
    if smi:
        out = sh(smi, "--query-gpu=index,name,memory.total,memory.used,compute_cap,driver_version",
                 "--format=csv,noheader,nounits")
        for line in out.strip().splitlines():
            p = [x.strip() for x in line.split(",")]
            if len(p) >= 6 and p[2].isdigit():
                gpus.append({"vendor": "nvidia", "name": p[1], "total_gib": round(int(p[2]) / 1024, 2),
                             "used_gib": round(int(p[3]) / 1024, 2), "cc": p[4], "driver": p[5]})
    for dev in sorted(glob.glob("/sys/class/drm/card[0-9]*/device")):
        if read(dev + "/vendor") != "0x1002" or re.search(r"card\d+-", dev):
            continue
        vram, gtt = int(read(dev + "/mem_info_vram_total") or 0), int(read(dev + "/mem_info_gtt_total") or 0)
        if not vram:
            continue
        apu = vram < 4 * GiB and gtt > vram   # integrated GPU: uses system RAM (GTT)
        gpus.append({"vendor": "amd", "name": amd_name(dev), "apu": apu, "gfx": amd_gfx(),
                     "total_gib": round((gtt if apu else vram) / GiB, 2),
                     "used_gib": round(int(read(dev + "/mem_info_vram_used") or 0) / GiB, 2)})
    hw["gpus"] = gpus
    if hw["wsl"] and not gpus and os.path.exists("/dev/dxg"):
        hw["note"] = "wsl-non-nvidia"
    return hw


def gpu_bw(g, cat):
    name = g["name"].lower()
    for pat, bw in cat.get("gpus", []):
        if pat.lower() in name:
            return float(bw), True
    return 120.0 + 25.0 * g["total_gib"], False   # rough guess from the memory size


def backend(hw):
    g = hw["gpus"]
    arch = "arm64" if hw["arch"] in ("aarch64", "arm64") else "x64"
    if not g:
        return "cpu", "no supported GPU found, runs on the CPU"
    vendors = {x["vendor"] for x in g}
    if len(vendors) > 1:
        return "vulkan", "NVIDIA and AMD together: Vulkan drives both"
    if "nvidia" in vendors:
        cc = min(float(x["cc"] or 0) for x in g)
        drv = int((g[0]["driver"] or "0").split(".")[0])
        if drv >= 580 and cc >= 7.5:
            return "cuda-13.4", "CUDA 13.4 (driver %s, compute %.1f)" % (g[0]["driver"], cc)
        if drv >= 525 and cc >= 5.0 and arch == "x64":
            return "cuda-12.8", "CUDA 12.8 (driver %s, compute %.1f)" % (g[0]["driver"], cc)
        return "vulkan", "Vulkan (driver %s is too old for CUDA 12; update it for more speed)" % g[0]["driver"]
    return "vulkan", "Vulkan (works on every AMD GPU; --backend=rocm to try ROCm)"


def assets(be, tag, arch):
    a = "arm64" if arch in ("aarch64", "arm64") else "x64"
    if be == "cpu":
        return ["llama-%s-bin-ubuntu-%s.tar.gz" % (tag, a)]
    if be == "vulkan":
        return ["llama-%s-bin-ubuntu-vulkan-%s.tar.gz" % (tag, a)]
    if be == "rocm":
        return ["llama-%s-bin-ubuntu-rocm-10.0-x64.tar.gz" % tag]
    v = be.split("-")[1]
    return ["llama-%s-bin-ubuntu-cuda-%s-%s.tar.gz" % (tag, v, a), "cudart-llama-%s-bin-ubuntu-cuda-%s-%s.tar.gz" % (tag, v, a)]


# ── catalog math ──────────────────────────────────────────────────────────────
def gib(gb):
    return gb * 1e9 / GiB


def kv_gib(m, ctx):
    k = m["kv"]
    return KV_BYTES * (k["full"] * ctx + k["swa"] * min(ctx, k["window"] + 512)) / GiB


def overhead(m):
    return m.get("overhead_gib") or (0.45 + 0.03 * gib(m["file_gb"]))


def budget(hw, cat):
    v = float(E.get("SHL_VRAM") or 0)
    g = hw["gpus"]
    if g:
        bws = [gpu_bw(x, cat) for x in g]
        bw, known = min(b[0] for b in bws), all(b[1] for b in bws)
        total = v or sum(x["total_gib"] for x in g)
        return {"mode": "gpu", "total": total, "usable": total - HEADROOM * (1 if v else len(g)),
                "tier_gb": round(total), "bw": bw, "bw_known": known, "limited": bool(v),
                "busy": sum(x["used_gib"] for x in g)}
    total = v or hw["ram_gib"]
    return {"mode": "cpu", "total": total, "usable": total - CPU_RESERVE, "tier_gb": round(total),
            "bw": hw["ram_bw"], "bw_known": "assumed" not in hw["ram_label"], "limited": bool(v), "busy": 0}


def plan(m, hw, b, ctx_want=None):
    w, ovh = gib(m["file_gb"]), overhead(m)
    cap = min(int(ctx_want or E.get("SHL_CTX") or 131072), m.get("ctx_max") or 32768)
    steps = [c for c in CTX_STEPS if c <= cap] or [cap]
    if ctx_want or E.get("SHL_CTX"):
        steps = [cap]
    p = {"weights": w, "ovh": ovh}
    if b["mode"] == "gpu":
        for c in reversed(steps):
            if w + kv_gib(m, c) + ovh <= b["usable"]:
                p.update(ctx=c, where="gpu", frac=1.0)
                break
        else:
            c = steps[0]
            frac = max(0.0, min(1.0, (b["usable"] - kv_gib(m, c) - ovh) / w))
            p.update(ctx=c, where="split" if frac > 0.05 else "cpu", frac=frac)
            if (1 - frac) * w > hw["ram_gib"] - CPU_RESERVE:
                p["where"] = "nofit"
    else:
        for c in reversed(steps):
            if w + kv_gib(m, c) + ovh <= b["usable"]:
                p.update(ctx=c, where="cpu", frac=0.0)
                break
        else:
            p.update(ctx=steps[0], where="nofit", frac=0.0)
    p["kv"] = kv_gib(m, p["ctx"])
    on_gpu = b["mode"] == "gpu"
    p["gpu_use"] = (w * p["frac"] + p["kv"] + ovh) if on_gpu and p["frac"] > 0 else 0.0
    p["ram_use"] = w * (1 - p["frac"]) + (0 if on_gpu and p["frac"] > 0 else p["kv"] + ovh)
    active = w * (m["active_params_b"] / m["params_b"]) if m.get("moe") else w
    gbw = b["bw"] if on_gpu else 0
    sec = (active * GiB * p["frac"]) / (gbw * 1e9 * EFF_GPU) if p["frac"] else 0
    sec += (active * GiB * (1 - p["frac"])) / (hw["ram_bw"] * 1e9 * EFF_CPU)
    sec += m["kv"]["layers"] * ((LAYER_MOE_S if m.get("moe") else LAYER_GPU_S) if on_gpu and p["frac"] else LAYER_CPU_S)
    p["tps"] = 1 / sec if sec else 0
    meas = measured(m, hw)
    if meas:
        p["tps_measured"] = meas
    return p


def measured(m, hw):
    """Generation speed measured on this exact GPU in an earlier test, if any."""
    names = [g["name"] for g in hw["gpus"]] or ["cpu"]
    for k, t in (m.get("tested") or {}).items():
        if any(k.lower() in n.lower() for n in names) and isinstance(t, dict) and t.get("tg"):
            return t["tg"]
    return None


def nice_name(mid, m):
    base = m["repo"].split("/")[-1].replace("-GGUF", "").replace("-it", "").replace("-Instruct", "")
    return "%s %s" % (base, m["quant"].replace("UD-", ""))


def fmt_ctx(c):
    return "%dk" % (c // 1024)


def speed_word(tps):
    return "fast" if tps >= 30 else "good" if tps >= 12 else "slow" if tps >= 5 else "very slow"


def where_text(p, b):
    if p["where"] == "gpu":
        return "all on the GPU"
    if p["where"] == "split":
        return "%d%% on the GPU, the rest on the CPU (slower)" % round(p["frac"] * 100)
    if p["where"] == "cpu":
        return "CPU" + (" (does not fit the GPU)" if b["mode"] == "gpu" else "")
    return "does NOT fit this machine"


def tier_for(cat, b):
    if b["mode"] == "gpu":
        ts = [t for t in cat["tiers"] if t["vram_gb"] <= b["tier_gb"] + 0.01]
        if ts:
            return ts[-1], cat["tiers"]
    ts = [t for t in cat["cpu_tiers"] if t["ram_gb"] <= b["tier_gb"] + 0.01] or cat["cpu_tiers"][:1]
    return ts[-1], cat["cpu_tiers"]


def candidates(cat, hw, b):
    t, tiers = tier_for(cat, b)
    i = tiers.index(t)
    rows = [(t["default"], "recommended")] + [(a, "alternative") for a in t["alternatives"]]
    if i > 0:
        rows.append((tiers[i - 1]["default"], "smaller, faster"))
    if i + 1 < len(tiers):
        rows.append((tiers[i + 1]["default"], "bigger, slower"))
    seen, out = set(), []
    for mid, why in rows:
        if mid in seen or mid not in cat["models"]:
            continue
        seen.add(mid)
        p = plan(cat["models"][mid], hw, b)
        if why == "bigger, slower" and p["where"] != "gpu":
            why = "bigger, partly on the CPU"
        if p["where"] != "nofit":
            out.append((mid, why, p))
    return t, out


def table(cat, rows, b):
    print("    %s#   %-30s %-9s %-23s %-8s %s%s" % (GR, "MODEL", "DOWNLOAD", "MEMORY", "CONTEXT", "SPEED (est.)", X))
    for n, (mid, why, p) in enumerate(rows, 1):
        m = cat["models"][mid]
        if p["where"] == "gpu":
            mem = "%.1f of %.1f GB GPU" % (p["gpu_use"], b["usable"])
        elif p["where"] == "split":
            mem = "%.1f GPU + %.1f RAM" % (p["gpu_use"], p["ram_use"])
        else:
            mem = "%.1f GB RAM" % p["ram_use"]
        tps = p.get("tps_measured") or p["tps"]
        tag = {"recommended": G + "★ recommended" + X}.get(why, GR + why + X)
        print("    %-3s %-30s %-9s %-23s %-8s ~%-4d tok/s  %s" % (
            "%d)" % n, nice_name(mid, m)[:30], "%.1f GB" % m["file_gb"], mem, fmt_ctx(p["ctx"]), tps, tag))


def hwinfo(hw, cat, b):
    print("  %sHardware%s" % (B, X))
    sysline = "%s%s · %s · %d threads · %.1f GB RAM (%s)" % (
        hw["os"], " (WSL on Windows)" if hw["wsl"] else "", hw["cpu"], hw["threads"], hw["ram_gib"], hw["ram_label"])
    print("    system  " + sysline)
    for i, g in enumerate(hw["gpus"], 1):
        bw, known = gpu_bw(g, cat)
        extra = ("compute %s, driver %s" % (g["cc"], g["driver"])) if g["vendor"] == "nvidia" else \
            ("%s%s" % (g.get("gfx") or "AMD", ", shares system RAM" if g.get("apu") else ""))
        print("    gpu %d   %s · %.1f GB (%.1f GB in use now) · %s · %d GB/s%s" % (
            i, g["name"], g["total_gib"], g["used_gib"], extra, bw, "" if known else " (guess)"))
    if not hw["gpus"]:
        print("    gpu     none usable" + (" (AMD/Intel in WSL: use the Windows version instead)" if hw.get("note") else ""))
    be, why = backend(hw)
    print("    engine  llama.cpp, " + why)
    if b["limited"]:
        print("    %splan    limited to %.1f GB (--vram)%s" % (Y, b["total"], X))


def cmd_suggest(hwf, catf):
    hw, cat = load(hwf), load(catf)
    b = budget(hw, cat)
    hwinfo(hw, cat, b)
    t, rows = candidates(cat, hw, b)
    print()
    print("  %sSuggested models%s for %s %s(tier %s)%s" % (
        B, X, ("%.0f GB of GPU memory" % b["total"]) if b["mode"] == "gpu" else ("%.0f GB RAM, CPU only" % b["total"]),
        GR, t["id"], X))
    table(cat, rows, b)
    with open(E["SHL_OUT"], "w") as f:
        f.write("\n".join(r[0] for r in rows))


def cmd_all(hwf, catf):
    hw, cat = load(hwf), load(catf)
    b = budget(hw, cat)
    rows = []
    for mid, m in sorted(cat["models"].items(), key=lambda kv: kv[1]["file_gb"]):
        p = plan(m, hw, b)
        rows.append((mid, "" if p["where"] == "gpu" else ("won't fit" if p["where"] == "nofit" else "partly CPU"), p))
    print("  %sEvery model in the catalog%s (smallest first)" % (B, X))
    table(cat, rows, b)
    with open(E["SHL_OUT"], "w") as f:
        f.write("\n".join(r[0] for r in rows))


def cmd_card(mid, hwf, catf):
    """The confirmation card: how this model will run here. Writes the plan to SHL_OUT."""
    hw, cat = load(hwf), load(catf)
    if mid not in cat["models"]:
        print("unknown model id: " + mid, file=sys.stderr)
        sys.exit(2)
    m, b = cat["models"][mid], budget(hw, cat)
    p = plan(m, hw, b)
    disk = shutil.disk_usage(E.get("SHL_DISK", "/")).free / 1e9
    tps = p.get("tps_measured") or p["tps"]
    print()
    print("  %s%s%s  %s· %s · %s%s" % (B, nice_name(mid, m), X, GR, m["family"], m["license"], X))
    print("    download      %.1f GB  (%.0f GB free, %.0f GB left after)" % (m["file_gb"], disk, disk - m["file_gb"]))
    if b["mode"] == "gpu" and p["where"] in ("gpu", "split"):
        print("    GPU memory    %.1f of %.1f GB  (model %.1f + context %.1f + work %.1f)" % (
            p["gpu_use"], b["usable"], p["weights"] * p["frac"], p["kv"], p["ovh"]))
    if p["ram_use"] > 0.05:
        print("    RAM           %.1f GB of %.1f GB" % (p["ram_use"], hw["ram_gib"]))
    print("    runs          " + where_text(p, b))
    print("    context       %s tokens (about %s words of conversation + files)" % (
        format(p["ctx"], ","), format(int(p["ctx"] * 0.75), ",")))
    src = "measured on this GPU" if p.get("tps_measured") else "estimate"
    print("    speed         ~%d tokens/s (~%d words/s, %s) · %s" % (tps, tps * 0.75, speed_word(tps), src))
    if m.get("moe"):
        print("    type          mixture of experts: %.0fB total, %.1fB active per token (fast for its size)" % (
            m["params_b"], m["active_params_b"]))
    else:
        print("    type          %.0fB parameters" % m["params_b"])
    tools = m.get("tool_calling") == "template"
    print("    tool calling  %s" % ("yes: it can use the MCP tools" if tools else "no: chat only, no MCP tools"))
    print("    good for      " + ", ".join(m["roles"]))
    if m.get("notes"):
        print("    note          " + m["notes"])
    if p["where"] == "nofit":
        print("    %s! It does not fit: needs about %.0f GB of memory.%s" % (R, p["weights"] + p["kv"] + p["ovh"], X))
    elif p["where"] != "gpu" and b["mode"] == "gpu":
        print("    %s! Part of it runs on the CPU, so it is much slower than the ones that fit.%s" % (Y, X))
    if disk < m["file_gb"] + 2:
        print("    %s! Not enough free disk.%s" % (R, X))
    with open(E["SHL_OUT"], "w") as f:
        json.dump({"id": mid, "ctx": p["ctx"], "where": p["where"], "file_gb": m["file_gb"],
                   "fits_disk": disk >= m["file_gb"] + 2, "est_tps": round(p["tps"], 1)}, f)


# ── state, llama-swap config ──────────────────────────────────────────────────
def state_get(sf, key):
    d = load(sf, {}) or {}
    for k in key.split("/"):
        d = d.get(k) if isinstance(d, dict) else None
    print("" if d is None else (json.dumps(d) if isinstance(d, (dict, list)) else d))


def state_set(sf, key, value):
    d = load(sf, {}) or {}
    try:
        v = json.loads(value)
    except ValueError:
        v = value
    cur = d
    ks = key.split("/")
    for k in ks[:-1]:
        cur = cur.setdefault(k, {})
    if v is None:
        cur.pop(ks[-1], None)
    else:
        cur[ks[-1]] = v
    save(sf, d)


def swap_config(sf, catf):
    s, cat = load(sf), load(catf)
    root = s["install_dir"]
    out = ["# Written by the sudo homelab AI node installer. Re-run it to change models.",
           "healthCheckTimeout: 1200", "logLevel: info", "logToStdout: both", "startPort: 10001",
           "apiKeys:", '  - "%s"' % s["api_key"], "models:"]
    for mid, mm in s.get("models", {}).items():
        m = cat["models"].get(mid) or mm.get("meta", {})
        path = os.path.join(root, "models", mm["files"][0])
        args = ["%s/llama/current/llama-server" % root, "--host 127.0.0.1 --port ${PORT}", "-m " + path,
                "--alias " + mid, "-c %d" % mm["ctx"], "-np 1", " ".join(cat.get("llama_args", []))]
        if mm.get("fit_target_mib"):
            args.append("--fit-target %d" % mm["fit_target_mib"])
        out += ['  "%s":' % mid, '    name: "%s"' % nice_name(mid, m) if m.get("repo") else '    name: "%s"' % mid,
                "    cmd: >", "      " + " ".join(args), "    ttl: %d" % int(s.get("ttl", 0))]
    print("\n".join(out))


# ── router (MCP server) ───────────────────────────────────────────────────────
def http(method, url, token=None, body=None, timeout=30):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, method=method, headers=h,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt.strip() else {})
    except urllib.error.HTTPError as e:
        txt = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(txt)
        except ValueError:
            return e.code, {"error": {"message": txt[:300]}}


def decode_join(code):
    raw = code.split(":", 1)[1]
    d = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    return d["router"].rstrip("/"), d["token"]


def node_models(s):
    return [{"id": mid, "context": mm["ctx"], "tags": ["tools"] if mm.get("tools") else []}
            for mid, mm in s.get("models", {}).items()]


def router_join(sf, code, name, base_url, hardware):
    s = load(sf)
    router, tok = decode_join(code)
    st, d = http("POST", router + "/nodes/register", tok, {
        "name": name, "base_url": base_url, "api_key": s["api_key"], "models": node_models(s),
        "hardware": hardware})
    if st != 200:
        print("router said %s: %s" % (st, (d.get("error") or {}).get("message", d)), file=sys.stderr)
        sys.exit(1)
    s["router"] = {"url": router, "name": name, "node_id": d["node_id"], "node_token": d["node_token"],
                   "base_url": base_url}
    s["join"] = {"code": code, "name": name, "base_url": base_url, "hardware": hardware}
    save(sf, s)
    print(" ".join(d["models"]))


def router_update(sf):
    s = load(sf)
    r = s.get("router")
    if not r:
        j = s.get("join")
        if j and node_models(s):   # the node left when its last model went; models are back
            router_join(sf, j["code"], j["name"], j["base_url"], j["hardware"])
        return
    ms = node_models(s)
    if not ms:
        return router_leave(sf)
    st, d = http("PUT", "%s/nodes/%s" % (r["url"], r["node_id"]), r["node_token"], {"models": ms})
    if st != 200:
        print("router said %s: %s" % (st, d), file=sys.stderr)
        sys.exit(1)


def router_leave(sf, forget=False):
    s = load(sf)
    if forget:
        s.pop("join", None)
    r = s.get("router")
    if not r:
        return
    st, d = http("DELETE", "%s/nodes/%s" % (r["url"], r["node_id"]), r["node_token"])
    if st not in (200, 404):
        print("router said %s: %s" % (st, d), file=sys.stderr)
    s.pop("router", None)
    save(sf, s)


def router_status(sf):
    s = load(sf)
    r, mcp = s.get("router"), s.get("mcp") or {}
    if not r:
        print("not connected")
        return
    if not mcp.get("token"):
        print("joined as %s (add the MCP token to see its status)" % r["name"])
        return
    st, d = http("GET", r["url"] + "/nodes", mcp["token"])
    for n in d.get("nodes", []):
        if n["id"] == r["node_id"]:
            print("%s · %s" % (n["status"], ", ".join("%s@%s" % (m["id"], n["name"]) for m in n["models"])))
            return
    print("not in the router any more (removed there?)")


# ── tests ─────────────────────────────────────────────────────────────────────
class MCP:
    def __init__(self, url, token):
        self.url, self.sid, self.i = url, None, 0
        self.h = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
                  "Accept": "application/json, text/event-stream"}

    def rpc(self, method, params, notify=False):
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            self.i += 1
            body["id"] = self.i
        h = dict(self.h)
        if self.sid:
            h["mcp-session-id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=h, method="POST")
        with urllib.request.urlopen(req, timeout=180) as r:
            self.sid = r.headers.get("mcp-session-id") or self.sid
            txt = r.read().decode()
        if notify:
            return None
        if "data:" in txt:
            txt = [l[5:] for l in txt.splitlines() if l.startswith("data:")][-1]
        d = json.loads(txt)
        if "error" in d:
            raise RuntimeError(d["error"].get("message", d["error"]))
        return d["result"]

    def start(self):
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "sudohomelab-node-test", "version": "1"}})
        try:
            self.rpc("notifications/initialized", {}, notify=True)
        except Exception:
            pass
        return self.rpc("tools/list", {})["tools"]

    def call(self, name, args):
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        text = " ".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        return (not res.get("isError")), text


def chat(base, key, model, messages, timeout=900, **kw):
    st, d = http("POST", base + "/chat/completions", key, dict(model=model, messages=messages, **kw), timeout)
    if st != 200:
        raise RuntimeError("HTTP %s: %s" % (st, (d.get("error") or {}).get("message", d) if isinstance(d, dict) else d))
    return d


def log_facts(since):
    """What llama-server printed while loading: layers on the GPU, KV and compute buffer sizes."""
    out = sh("journalctl", "-u", "sudohomelab-node", "--since", since, "-o", "cat", "--no-pager", timeout=20)
    f = {}
    m = re.findall(r"offloaded (\d+)/(\d+) layers to GPU", out)
    if m:
        f["layers_gpu"] = "%s/%s" % m[-1]
    kv = [float(x) for x in re.findall(r"KV(?: cache)? buffer size\s*=\s*([\d.]+) MiB", out)]
    if kv:
        f["kv_mib"] = round(sum(kv))
    cb = re.findall(r"(\w+) compute buffer size\s*=\s*([\d.]+) MiB", out)
    if cb:
        f["compute_gpu_mib"] = round(sum(float(v) for d, v in cb if not d.startswith("CPU")))
        f["compute_cpu_mib"] = round(sum(float(v) for d, v in cb if d.startswith("CPU")))
    m = re.findall(r"n_ctx(?:_seq|_slot)?\s*=\s*(\d+)", out)
    if m:
        f["n_ctx"] = int(m[-1])
    fit = re.findall(r"(llama_params_fit[^\n]*)", out)
    if fit:
        f["fit"] = fit[-1][:200]
    return f


def test_model(s, mid, catf, out_dir):
    cat = load(catf) or {}
    base, key = "http://127.0.0.1:%s/v1" % s["port"], s["api_key"]
    res = {"model": mid, "when": datetime.datetime.now().isoformat(timespec="seconds"),
           "est_tps": s["models"][mid].get("est_tps"), "ctx": s["models"][mid]["ctx"],
           "vram_limit_gb": s["models"][mid].get("vram_gb")}
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    sh("curl", "-s", "-m", "30", "-H", "Authorization: Bearer " + key, "http://127.0.0.1:%s/unload" % s["port"])
    time.sleep(2)
    before = nvidia_used()
    print("  › loading %s and chatting (the first load reads the whole file from disk)…" % mid, flush=True)
    t0 = time.time()
    try:
        d = chat(base, key, mid, [{"role": "user", "content":
                 "In about 150 words, explain why people run AI models at home."}], max_tokens=1500)
        msg = d["choices"][0]["message"]
        text = (msg.get("content") or "").strip()
        res["chat"] = bool(text or msg.get("reasoning_content"))
        res["first_answer_s"] = round(time.time() - t0, 1)
        t = d.get("timings") or {}
        res["tg"] = round(t.get("predicted_per_second", 0), 1)
        res["pp"] = round(t.get("prompt_per_second", 0), 1)
        res["tokens"] = t.get("predicted_n")
        print("  %s✓%s chat: %d tokens at %.1f tok/s (estimate was ~%s); first answer after %.0f s incl. load" % (
            G, X, res["tokens"] or 0, res["tg"], res["est_tps"], res["first_answer_s"]))
    except Exception as e:
        res["chat"] = False
        res["error"] = str(e)[:300]
        print("  %s✗%s chat failed: %s" % (R, X, res["error"]))
    after = nvidia_used()
    if before is not None and after is not None:
        res["vram_used_gb"] = round(after - before, 2)
    res.update(log_facts(since))
    if "layers_gpu" in res:
        print("    loaded: %s layers on the GPU, KV cache %s MiB, GPU work buffer %s MiB, VRAM used %s GB" % (
            res["layers_gpu"], res.get("kv_mib", "?"), res.get("compute_gpu_mib", "?"), res.get("vram_used_gb", "?")))
    if res["chat"]:
        tools = [{"type": "function", "function": {
            "name": "get_weather", "description": "Current weather for a city",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
        try:
            d = chat(base, key, mid, [{"role": "user", "content": "What's the weather in Miami right now?"}],
                     tools=tools, max_tokens=1500)
            calls = d["choices"][0]["message"].get("tool_calls") or []
            res["tool_call"] = bool(calls and calls[0]["function"]["name"] == "get_weather" and
                                    "miami" in calls[0]["function"].get("arguments", "").lower())
        except Exception as e:
            res["tool_call"] = False
            res["tool_error"] = str(e)[:300]
        print("  %s tool call: %s" % (G + "✓" + X if res["tool_call"] else R + "✗" + X,
                                      "asked for get_weather(Miami)" if res["tool_call"] else res.get("tool_error", "no tool call")))
    mcp = s.get("mcp") or {}
    if res["chat"] and mcp.get("url") and mcp.get("token"):
        res["mcp"] = test_mcp(s, mid, mcp)
    os.makedirs(out_dir, exist_ok=True)
    p = os.path.join(out_dir, "%s-%s.json" % (mid, time.strftime("%Y%m%d-%H%M%S")))
    save(p, res)
    print("    result saved: " + p)
    return res


def test_mcp(s, mid, mcp):
    """The model uses real MCP tools, reached through the MCP server's router when joined."""
    r = s.get("router")
    if r:
        base, key, model, via = r["url"] + "/v1", mcp["token"], "%s@%s" % (mid, r["name"]), "the MCP router"
    else:
        base, key, model, via = "http://127.0.0.1:%s/v1" % s["port"], s["api_key"], mid, "this node"
    out = {"via": via, "called": [], "ok": False}
    try:
        m = MCP(mcp["url"], mcp["token"])
        tools = m.start()
    except Exception as e:
        out["error"] = "MCP: %s" % e
        print("  %s✗%s MCP: %s" % (R, X, e))
        return out
    out["tools_offered"] = len(tools)
    oa = [{"type": "function", "function": {"name": t["name"], "description": (t.get("description") or "")[:400],
                                            "parameters": t.get("inputSchema") or {"type": "object", "properties": {}}}}
          for t in tools]
    note = "AI node test: %s answered through %s on %s" % (mid, via, time.strftime("%Y-%m-%d %H:%M"))
    msgs = [{"role": "system", "content": "You are a homelab assistant. Use the tools you have. Call one tool at a time."},
            {"role": "user", "content": "Use your tools for these three steps: 1) check the MCP server status, "
             "2) save this note to memory: '%s', 3) search memory for 'AI node test' and tell me in one line what "
             "you found." % note}]
    print("  › MCP: %d tools offered; asking %s (via %s) to use them…" % (len(tools), model, via), flush=True)
    t0 = time.time()
    try:
        for _ in range(10):
            d = chat(base, key, model, msgs, tools=oa, max_tokens=3000)
            msg = d["choices"][0]["message"]
            calls = msg.get("tool_calls") or []
            msgs.append({"role": "assistant", "content": msg.get("content") or "", **({"tool_calls": calls} if calls else {})})
            if not calls:
                out["answer"] = (msg.get("content") or "").strip()[:300]
                break
            for c in calls:
                name, args = c["function"]["name"], {}
                try:
                    args = json.loads(c["function"].get("arguments") or "{}")
                    good, text = m.call(name, args)
                except Exception as e:
                    good, text = False, "error: %s" % e
                out["called"].append({"tool": name, "ok": good})
                print("    %s %s(%s)" % (G + "✓" + X if good else R + "✗" + X, name,
                                         json.dumps(args)[:80]))
                msgs.append({"role": "tool", "tool_call_id": c.get("id", name), "content": text[:2000]})
    except Exception as e:
        out["error"] = str(e)[:300]
        print("  %s✗%s %s" % (R, X, out["error"]))
    out["seconds"] = round(time.time() - t0, 1)
    used = {c["tool"] for c in out["called"] if c["ok"]}
    out["ok"] = len(used) >= 2 and bool(out.get("answer"))
    print("  %s MCP tools: %d different tools used in %.0f s%s" % (
        G + "✓" + X if out["ok"] else R + "✗" + X, len(used), out["seconds"],
        (" · answer: " + out["answer"][:150]) if out.get("answer") else ""))
    return out


# ── OpenCode ──────────────────────────────────────────────────────────────────
def opencode_add(sf, home, mid):
    s = load(sf)
    p = os.path.join(home, ".config", "opencode", "opencode.json")
    created = not os.path.exists(p)
    cfg = {"$schema": "https://opencode.ai/config.json"} if created else load(p)
    if cfg is None:
        print("%s is not plain JSON; add this by hand:" % p, file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not created and not os.path.exists(p + ".bak-sudohomelab"):
        shutil.copy2(p, p + ".bak-sudohomelab")
    prov = cfg.setdefault("provider", {})
    prov["sudohomelab-node"] = {
        "npm": "@ai-sdk/openai-compatible", "name": "sudo homelab AI node",
        "options": {"baseURL": "http://127.0.0.1:%s/v1" % s["port"], "apiKey": s["api_key"]},
        "models": {m: {"name": m, "limit": {"context": mm["ctx"], "output": 16384}}
                   for m, mm in s.get("models", {}).items()}}
    mcp = s.get("mcp") or {}
    if mcp.get("url") and mcp.get("token"):
        cfg.setdefault("mcp", {})["sudohomelab"] = {"type": "remote", "url": mcp["url"], "enabled": True,
                                                    "headers": {"Authorization": "Bearer " + mcp["token"]}}
    if created or not cfg.get("model"):
        cfg["model"] = "sudohomelab-node/" + mid
    with open(p, "w") as f:
        json.dump(cfg, f, indent=2)
    oc = s.setdefault("opencode", {})
    oc.update(config=p, created_config=oc.get("created_config", created))
    save(sf, s)
    print(p)


def opencode_remove(sf):
    s = load(sf)
    oc = s.get("opencode") or {}
    p = oc.get("config")
    if not p or not os.path.exists(p):
        return
    cfg = load(p)
    if cfg is None:
        return
    (cfg.get("provider") or {}).pop("sudohomelab-node", None)
    (cfg.get("mcp") or {}).pop("sudohomelab", None)
    if str(cfg.get("model", "")).startswith("sudohomelab-node/"):
        cfg.pop("model")
    for k in ("provider", "mcp"):
        if k in cfg and not cfg[k]:
            cfg.pop(k)
    if oc.get("created_config") and set(cfg) <= {"$schema"}:
        os.remove(p)
        try:
            os.rmdir(os.path.dirname(p))
        except OSError:
            pass
    else:
        with open(p, "w") as f:
            json.dump(cfg, f, indent=2)


def main(a):
    c = a[0]
    if c == "scan":
        print(json.dumps(scan(), indent=1))
    elif c == "suggest":
        cmd_suggest(a[1], a[2])
    elif c == "all":
        cmd_all(a[1], a[2])
    elif c == "card":
        cmd_card(a[1], a[2], a[3])
    elif c == "hwinfo":
        hw, cat = load(a[1]), load(a[2])
        hwinfo(hw, cat, budget(hw, cat))
    elif c == "backend":
        print("%s|%s" % backend(load(a[1])))
    elif c == "assets":
        print("\n".join(assets(a[1], a[2], a[3])))
    elif c == "model-files":
        m = load(a[2])["models"][a[1]]
        for f in m["files"]:
            print("%s|%s|%s|%s" % (m["repo"], f["name"], f["bytes"], f.get("sha256") or ""))
    elif c == "model-meta":
        m = load(a[2])["models"][a[1]]
        print(json.dumps({"tools": m.get("tool_calling") == "template", "name": nice_name(a[1], m)}))
    elif c == "state-get":
        state_get(a[1], a[2])
    elif c == "state-set":
        state_set(a[1], a[2], a[3])
    elif c == "swap-config":
        swap_config(a[1], a[2])
    elif c == "join":
        router_join(a[1], a[2], a[3], a[4], a[5])
    elif c == "router-update":
        router_update(a[1])
    elif c == "leave":
        router_leave(a[1], forget=len(a) > 2 and a[2] == "forget")
    elif c == "router-status":
        router_status(a[1])
    elif c == "decode-join":
        print("%s|%s" % decode_join(a[1]))
    elif c == "test":
        s = load(a[1])
        ids = [a[2]] if len(a) > 2 and a[2] else list(s.get("models", {}))
        bad = 0
        for mid in ids:
            r = test_model(s, mid, a[3] if len(a) > 3 else "", os.path.join(s["install_dir"], "tests"))
            bad += not (r.get("chat") and r.get("tool_call") is not False and (r.get("mcp") or {}).get("ok", True))
        sys.exit(1 if bad else 0)
    elif c == "test-mcp":
        s = load(a[1])
        r = test_mcp(s, a[2], s.get("mcp") or {})
        p = os.path.join(s["install_dir"], "tests", "%s-mcp-%s.json" % (a[2], time.strftime("%Y%m%d-%H%M%S")))
        save(p, r)
        sys.exit(0 if r.get("ok") else 1)
    elif c == "nvidia-total":
        smi = nvidia_smi()
        print((sh(smi, "--query-gpu=memory.total", "--format=csv,noheader,nounits").split() or ["0"])[0] if smi else 0)
    elif c == "opencode-add":
        sys.exit(opencode_add(a[1], a[2], a[3]) or 0)
    elif c == "opencode-remove":
        opencode_remove(a[1])
    elif c == "nvidia-used":
        print(nvidia_used() or 0)
    else:
        sys.exit("unknown helper command " + c)


if __name__ == "__main__":
    main(sys.argv[1:])
PY
}

# ── Common ────────────────────────────────────────────────────────────────────
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
lan_cidr() { ip -4 -o addr show "$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)" 2>/dev/null |
  awk '{print $4}' | head -n1 | python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.stdin.read().strip()).network)" 2>/dev/null || echo 192.168.0.0/16; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1; }
ts_ip() { ip -4 -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' | head -n1 || true; }
gen_key() { printf 'sk-%s' "$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"; }
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || true; }
port_free() { ! ss -Hltn "sport = :$1" 2>/dev/null | grep -q . && ! { is_wsl && win_port_used "$1"; }; }
powershell() {
  local ps; ps=$(command -v powershell.exe || echo /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
  [[ -x $ps ]] || return 127
  "$ps" -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'
}
win_port_used() { [[ -n $(powershell "Get-NetTCPConnection -State Listen -LocalPort $1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty LocalPort" || true) ]]; }

get_catalog() {
  local src=${CATALOG_SRC:-$CATALOG_URL}
  if [[ -f $src ]]; then cp "$src" "$CATALOG"
  elif ! curl -fsSL -m 60 "$src" -o "$CATALOG" 2>/dev/null; then
    [[ -f $INSTALL_DIR/models.json ]] || die "Couldn't download the model catalog ($src)."
    warn "Catalog download failed; using the copy from the last install."
    cp "$INSTALL_DIR/models.json" "$CATALOG"
  fi
  python3 -c "import json,sys; json.load(open(sys.argv[1]))['models']" "$CATALOG" 2>/dev/null || die "The model catalog is not valid ($src)."
}

preflight() {
  [[ $EUID == 0 ]] || die "Run as root (sudo)."
  [[ -f /etc/os-release ]] && . /etc/os-release
  [[ ${ID:-} =~ ^(debian|ubuntu)$ || ${ID_LIKE:-} =~ (debian|ubuntu) ]] || die "This installer is for Debian or Ubuntu (found ${PRETTY_NAME:-unknown})."
  if ! command -v python3 >/dev/null || ! command -v curl >/dev/null; then
    info "Installing python3 and curl…"
    run apt-get update -y; run env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 curl ca-certificates || die "Couldn't install python3/curl."
  fi
  if is_wsl && [[ $(ps -p 1 -o comm= 2>/dev/null) != systemd ]]; then
    die "WSL is running without systemd. Add  [boot] systemd=true  to /etc/wsl.conf, run  wsl --shutdown  in Windows, then run this again."
  fi
  if ! timeout 10 getent hosts huggingface.co >/dev/null 2>&1; then
    is_wsl && die "This machine can't look up internet names (DNS). WSL's DNS forwarder is stuck: restart the WSL service in an admin PowerShell (Restart-Service WSLService) or reboot Windows, then run this again."
    die "This machine can't look up internet names (DNS). Fix the network/DNS settings, then run this again."
  fi
  write_helper
  get_catalog
  py scan >"$HW"
}

# ── Model picking: suggestions, the full list, a confirmation card each time ──
pick_model() { # → sets MODEL; the card + confirmation runs for every pick
  local ids choice c
  if [[ -n $MODEL ]]; then
    show_card "$MODEL" || die "Unknown model: $MODEL (see --suggest)"
    if [[ $(py state-get "$WORK/card.json" where) == nofit ]]; then
      interactive || die "$MODEL does not fit this machine."
    fi
    confirm "Use this model?" && return 0
    MODEL=""
  fi
  interactive || {
    SHL_OUT="$WORK/ids" py suggest "$HW" "$CATALOG" >/dev/null
    MODEL=$(head -n1 "$WORK/ids"); show_card "$MODEL"; return 0; }
  while :; do
    say ""
    SHL_OUT="$WORK/ids" py suggest "$HW" "$CATALOG"
    mapfile -t ids <"$WORK/ids"
    (( ${#ids[@]} )) || warn "Nothing in the catalog fits well; press a to see every model."
    say ""
    choice=$(ask "Pick a number, a = every model in the catalog, q = quit" "1")
    if [[ $choice == q ]]; then say "  Nothing changed."; exit 0; fi
    if [[ $choice == a ]]; then
      say ""
      SHL_OUT="$WORK/ids" py all "$HW" "$CATALOG"
      mapfile -t ids <"$WORK/ids"
      choice=$(ask "Pick a number (Enter = back)" "")
      [[ -n $choice ]] || continue
    fi
    [[ $choice =~ ^[0-9]+$ && -n ${ids[$((choice - 1))]:-} ]] || { warn "No such number."; continue; }
    c=${ids[$((choice - 1))]}
    show_card "$c"
    if [[ $(py state-get "$WORK/card.json" fits_disk) != True ]]; then warn "Free some disk first."; continue; fi
    if [[ $(py state-get "$WORK/card.json" where) == nofit ]]; then
      confirm_no "It does not fit. Install anyway?" || continue
    fi
    if confirm "Install this model?"; then MODEL=$c; return 0; fi
  done
}
show_card() {
  SHL_OUT="$WORK/card.json" SHL_DISK="$(df_dir)" py card "$1" "$HW" "$CATALOG" 2>/dev/null || return 1
}
df_dir() { local d=$INSTALL_DIR; while [[ ! -d $d ]]; do d=$(dirname "$d"); done; echo "$d"; }

# ── Install pieces ────────────────────────────────────────────────────────────
release_json() { curl -fsSL -m 60 "https://api.github.com/repos/$1/releases?per_page=${2:-15}"; }

pick_llama_release() { # → LLAMA_TAG with every asset this backend needs
  local be=$1 arch
  arch=$(uname -m)
  release_json ggml-org/llama.cpp 20 >"$WORK/rel.json" || die "Couldn't reach GitHub for llama.cpp releases."
  LLAMA_TAG=$(python3 - "$be" "$arch" "${LLAMA_TAG:-}" "$WORK/node.py" "$WORK/rel.json" <<'PY'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("n", sys.argv[4]); n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)
be, arch, want = sys.argv[1], sys.argv[2], sys.argv[3]
for r in json.load(open(sys.argv[5])):
    names = {a["name"] for a in r["assets"]}
    if (not want or r["tag_name"] == want) and all(x in names for x in n.assets(be, r["tag_name"], arch)):
        print(r["tag_name"]); break
PY
)
  [[ -n $LLAMA_TAG ]] || die "No llama.cpp release has a $be build for $arch."
}

install_llama() { # install_llama backend
  local be=$1 dir f url
  pick_llama_release "$be"
  dir="$INSTALL_DIR/llama/$LLAMA_TAG-$be"
  if [[ -x $dir/llama-server ]]; then ok "llama.cpp $LLAMA_TAG ($be) already here"
  else
    rm -rf "$dir.new"; mkdir -p "$dir.new"
    for f in $(py assets "$be" "$LLAMA_TAG" "$(uname -m)"); do
      url="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/$f"
      info "Downloading $f…"
      curl -fL --retry 4 -s "$url" | tar -xz -C "$dir.new" --strip-components=1 || die "Download failed: $url"
    done
    [[ -x $dir.new/llama-server ]] || die "llama-server is missing from the $be build."
    rm -rf "$dir"; mv "$dir.new" "$dir"
    ok "llama.cpp $LLAMA_TAG ($be)"
  fi
  ln -sfn "$dir" "$INSTALL_DIR/llama/current"
  LD_LIBRARY_PATH="$dir" "$dir/llama-server" --version >>"$LOG_FILE" 2>&1 || die "llama-server doesn't start on this machine (see log)."
  py state-set "$STATE" llama "{\"tag\":\"$LLAMA_TAG\",\"backend\":\"$be\"}"
  if [[ $be == vulkan ]] && ! ldconfig -p | grep -q libvulkan.so.1; then
    info "Installing the Vulkan loader + Mesa drivers…"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y libvulkan1 mesa-vulkan-drivers || warn "Couldn't install the Vulkan packages."
  fi
}

install_swap() {
  local tag f arch
  [[ $(uname -m) =~ ^(aarch64|arm64)$ ]] && arch=arm64 || arch=amd64
  tag=$(curl -fsSL -m 60 https://api.github.com/repos/mostlygeek/llama-swap/releases/latest |
        python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])") || die "Couldn't reach GitHub for llama-swap."
  if [[ -x $INSTALL_DIR/bin/llama-swap && $(sget swap_tag) == "$tag" ]]; then ok "llama-swap $tag already here"; return; fi
  f="llama-swap_${tag#v}_linux_$arch.tar.gz"
  mkdir -p "$INSTALL_DIR/bin"
  curl -fsSL --retry 4 "https://github.com/mostlygeek/llama-swap/releases/download/$tag/$f" | tar -xz -C "$INSTALL_DIR/bin" llama-swap ||
    die "Couldn't download llama-swap $tag."
  py state-set "$STATE" swap_tag "$tag"
  ok "llama-swap $tag"
}

download_model() { # download_model ID
  local id=$1 repo name bytes sha dest have
  while IFS='|' read -r repo name bytes sha; do
    dest="$INSTALL_DIR/models/$name"
    mkdir -p "$(dirname "$dest")"
    have=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    if [[ $have == "$bytes" && ! -f $dest.part ]]; then ok "$(basename "$name") already downloaded"; continue; fi
    info "Downloading $(basename "$name") ($(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1e9}') GB)…"
    touch "$dest.part"
    if has_tty && [[ -t 1 ]]; then
      curl -fL --retry 8 --retry-delay 5 -C - --progress-bar -o "$dest" "https://huggingface.co/$repo/resolve/main/$name" ||
        die "Download failed: $repo/$name"
    else
      curl -fL --retry 8 --retry-delay 5 -C - -s -o "$dest" "https://huggingface.co/$repo/resolve/main/$name" ||
        die "Download failed: $repo/$name"
    fi
    if [[ -n $sha ]]; then
      info "Checking the file (sha256)…"
      [[ $(sha256sum "$dest" | cut -d' ' -f1) == "$sha" ]] || { rm -f "$dest" "$dest.part"; die "Checksum mismatch for $name (deleted; run again)."; }
    fi
    rm -f "$dest.part"
    ok "$(basename "$name")"
  done < <(py model-files "$id" "$CATALOG")
}

add_model_state() { # add_model_state ID → records it (ctx, files, VRAM limit) in node.json
  local id=$1 ctx files meta fit=0 total_mib
  ctx=$(py state-get "$WORK/card.json" ctx)
  files=$(py model-files "$id" "$CATALOG" | cut -d'|' -f2 | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
  meta=$(py model-meta "$id" "$CATALOG")
  total_mib=$(py nvidia-total)
  if [[ -n $VRAM ]] && (( total_mib > 0 )); then
    # Keep the rest of the card free, as if it were a smaller GPU (llama.cpp --fit-target).
    fit=$(awk -v t="$total_mib" -v v="$VRAM" 'BEGIN{m=t-v*1024; print (m>1024? int(m) : 1024)}')
  fi
  py state-set "$STATE" "models/$id" "{\"ctx\":$ctx,\"files\":$files,\"tools\":$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])['tools']))" "$meta"),\"est_tps\":$(py state-get "$WORK/card.json" est_tps),\"vram_gb\":${VRAM:-null},\"fit_target_mib\":$fit}"
  [[ -n $(sget default) ]] || py state-set "$STATE" default "$id"
}

write_service() {
  local groups=""
  getent group video >/dev/null && groups+=" video"
  getent group render >/dev/null && groups+=" render"
  id "$SVC_USER" >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
  [[ -n $groups ]] && run usermod -aG "$(echo $groups | tr ' ' ',')" "$SVC_USER" || true
  cat >"/etc/systemd/system/$SERVICE.service" <<EOF
# Written by the sudo homelab AI node installer ($VERSION).
[Unit]
Description=sudo homelab AI node (llama-swap + llama.cpp)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
Environment=LD_LIBRARY_PATH=$INSTALL_DIR/llama/current:/usr/lib/wsl/lib
ExecStart=$INSTALL_DIR/bin/llama-swap --config $INSTALL_DIR/llama-swap.yaml --listen 0.0.0.0:$(sget port)
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable "$SERVICE"
}

apply_config() { # rewrite llama-swap.yaml from node.json and restart
  [[ $CATALOG -ef $INSTALL_DIR/models.json ]] || cp "$CATALOG" "$INSTALL_DIR/models.json"
  py swap-config "$STATE" "$INSTALL_DIR/models.json" >"$INSTALL_DIR/llama-swap.yaml.new" || die "Couldn't write the llama-swap config."
  mv "$INSTALL_DIR/llama-swap.yaml.new" "$INSTALL_DIR/llama-swap.yaml"
  chown -R root:"$SVC_USER" "$INSTALL_DIR"; chmod 750 "$INSTALL_DIR"; chmod 640 "$INSTALL_DIR/llama-swap.yaml"
  chmod 600 "$STATE"
  run systemctl restart "$SERVICE" || die "The service didn't start (journalctl -u $SERVICE)."
  local i
  for ((i = 0; i < 30; i++)); do
    [[ $(http_code -H "Authorization: Bearer $(sget api_key)" "http://127.0.0.1:$(sget port)/v1/models") == 200 ]] && { ok "Node answering on port $(sget port)"; return 0; }
    sleep 1
  done
  die "llama-swap didn't answer on port $(sget port) (journalctl -u $SERVICE)."
}

wsl_firewall() { # wsl_firewall open|close PORT — WSL blocks incoming connections by default
  is_wsl || return 0
  local port=$2 name="SudoHomelab-Node-$2" cmd b64 have
  [[ $(wslinfo --networking-mode 2>/dev/null || echo nat) == mirrored ]] || {
    [[ $1 == open ]] && warn "WSL uses NAT networking: other machines can't reach this node. Set networkingMode=mirrored in %UserProfile%\.wslconfig, run wsl --shutdown, then --connect again."
    return 0; }
  # Two layers: the Hyper-V firewall of the WSL VM, and the Windows Defender policy it merges.
  # Only the local network and Tailscale addresses (100.64.0.0/10) may connect.
  local FW_FROM="$(lan_cidr),100.64.0.0/10"
  have="@(Get-NetFirewallHyperVRule -Name '$name' -ErrorAction SilentlyContinue).Count + @(Get-NetFirewallRule -Name '$name' -ErrorAction SilentlyContinue).Count"
  if [[ $1 == open ]]; then
    [[ $(powershell "$have" || true) == 2 ]] && { ok "Windows firewall already allows port $port"; return 0; }
    cmd="if (-not (Get-NetFirewallHyperVRule -Name '$name' -ErrorAction SilentlyContinue)) { New-NetFirewallHyperVRule -Name '$name' -DisplayName 'SudoHomelab AI node ($port)' -Direction Inbound -VMCreatorId '$WSL_VM_ID' -Protocol TCP -LocalPorts $port -RemoteAddresses $FW_FROM -Action Allow }; if (-not (Get-NetFirewallRule -Name '$name' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -Name '$name' -DisplayName 'SudoHomelab AI node ($port)' -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress $FW_FROM -Action Allow -Profile Any }"
  else
    [[ $(powershell "$have" || true) =~ ^[12]$ ]] || return 0
    cmd="Remove-NetFirewallHyperVRule -Name '$name' -ErrorAction SilentlyContinue; Remove-NetFirewallRule -Name '$name' -ErrorAction SilentlyContinue"
  fi
  # Needs Windows admin rights: Windows shows a UAC prompt.
  b64=$(printf '%s' "$cmd" | iconv -t UTF-16LE | base64 -w0)
  info "Windows will ask for admin rights to $([[ $1 == open ]] && echo "open port $port for this node" || echo "remove the firewall rules")…"
  powershell "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','$b64'" >/dev/null || true
  if [[ $1 == open ]]; then
    [[ $(powershell "$have" || true) == 2 ]] && ok "Windows firewall: port $port open for the LAN" ||
      warn "Port $port is still closed in Windows (UAC declined?). In an admin PowerShell: $cmd"
  else
    [[ $(powershell "$have" || true) == 0 ]] && ok "Windows firewall rules removed" || warn "Firewall rules $name are still there."
  fi
}

# When Tailscale on Windows accepts a subnet route that covers the LAN (another
# machine advertises it), WSL (mirrored) sends replies to LAN clients out through
# the tailnet and they never arrive. A source rule keeps replies on the LAN card.
reply_route() { # reply_route ROUTER_HOST
  is_wsl || return 0
  local host=$1 dev landev
  [[ $host =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]] || return 0
  landev=$(ip -4 route show default | awk '{print $5; exit}')
  dev=$(ip -4 route get "$host" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  [[ -n $dev && $dev != "$landev" ]] || return 0
  warn "Tailscale sends your LAN traffic through the tailnet ($dev), so replies to $host would get lost."
  cat >"$INSTALL_DIR/bin/reply-route.sh" <<'EOF'
#!/bin/sh
# Replies from this machine's LAN address leave through the LAN card (sudo homelab AI node).
dev=$(ip -4 route show default | awk '{print $5; exit}')
ip=$(ip -4 -o addr show "$dev" | awk '{print $4}' | head -n1 | cut -d/ -f1)
net=$(ip -4 route show dev "$dev" scope link | awk '$1 ~ /\// {print $1; exit}')
ip rule del priority 2 2>/dev/null
ip route flush table 4242 2>/dev/null
[ "$1" = up ] && [ -n "$ip" ] && [ -n "$net" ] && ip route add "$net" dev "$dev" table 4242 && ip rule add from "$ip" lookup 4242 priority 2
exit 0
EOF
  chmod 755 "$INSTALL_DIR/bin/reply-route.sh"
  cat >"/etc/systemd/system/$SERVICE-route.service" <<EOF
# Written by the sudo homelab AI node installer ($VERSION).
[Unit]
Description=sudo homelab AI node: keep LAN replies on the LAN card (Tailscale subnet route)
After=network-online.target
Before=$SERVICE.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_DIR/bin/reply-route.sh up
ExecStop=$INSTALL_DIR/bin/reply-route.sh down

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now "$SERVICE-route" && ok "Replies to the LAN now leave through $landev (service $SERVICE-route)" ||
    warn "Couldn't add the route fix (see log)."
}

# ── MCP connection ────────────────────────────────────────────────────────────
ask_connect() { # fills JOIN / MCP_URL / MCP_TOKEN interactively
  [[ -n $JOIN ]] || {
    interactive || return 1
    say ""
    say "  ${C_BOLD}Connect to an MCP server?${C_RESET} Every app using the MCP (Open WebUI, OpenCode,"
    say "  Claude...) can then use this model, and the model gets the MCP tools."
    say "  ${C_GRAY}On the MCP server run its installer with --info to see the join code.${C_RESET}"
    JOIN=$(ask "Join code (shl-join:...; Enter = skip)" "")
    [[ -z $JOIN ]] && return 1
    [[ $JOIN == shl-join:* ]] || { warn "That is not a join code."; JOIN=""; return 1; }
  }
  if [[ -z $MCP_TOKEN ]] && interactive; then
    say "  ${C_GRAY}Optional: the MCP address + token let OpenCode here use the MCP tools and let the${C_RESET}"
    say "  ${C_GRAY}test check them. The join code alone only adds this model to the router.${C_RESET}"
    local router; router=$(py decode-join "$JOIN" | cut -d'|' -f1)
    MCP_URL=$(ask "MCP address" "${MCP_URL:-$(sed -E 's#:[0-9]+$#:8790#; s#:8443$##' <<<"$router")/mcp}")
    MCP_TOKEN=$(ask_secret "MCP token (Enter = skip)")
  fi
  return 0
}

node_address() { # the address the router uses to reach this node
  local router host ip ts
  router=$(py decode-join "$JOIN" | cut -d'|' -f1)
  host=$(sed -E 's#^https?://##; s#[:/].*##' <<<"$router")
  ip=$(lan_ip); ts=$(ts_ip)
  if [[ $host =~ ^100\. || $host == *.ts.net ]] && [[ -n $ts ]]; then echo "$ts"
  else echo "$ip"; fi
}

do_connect() {
  installed || die "Install the node first."
  [[ -n $JOIN ]] || ask_connect || { say "  Not connected."; return 0; }
  local addr name base models hw
  addr=$(node_address); [[ -n $addr ]] || die "Couldn't find this machine's IP address."
  name=${NODE_NAME:-$(sget router/name)}; name=${name:-$(hostname -s | tr 'A-Z' 'a-z')}
  name=$(tr 'A-Z' 'a-z' <<<"$name" | tr -cd 'a-z0-9._-')
  base="http://$addr:$(sget port)/v1"
  [[ -n $MCP_URL && -n $MCP_TOKEN ]] && py state-set "$STATE" mcp "{\"url\":\"$MCP_URL\",\"token\":\"$MCP_TOKEN\"}"
  wsl_firewall open "$(sget port)"
  reply_route "$(py decode-join "$JOIN" | cut -d'|' -f1 | sed -E 's#^https?://##; s#[:/].*##')"
  hw=$(python3 -c "import json,sys; h=json.load(open(sys.argv[1])); print(', '.join([g['name'] for g in h['gpus']] or ['CPU']) + ', %s GB RAM' % h['ram_gib'])" "$HW")
  info "Joining the router as $name (it will reach this node at $base)…"
  models=$(py join "$STATE" "$JOIN" "$name" "$base" "$hw") || die "The router didn't accept the join (wrong or rotated join code?)."
  ok "Joined: $models"
  if [[ -n $(sget mcp/token) ]]; then
    sleep 3
    local st; st=$(py router-status "$STATE")
    if [[ $st == online* ]]; then ok "The router reaches this node ($st)"
    else warn "The router can't reach $base yet ($st). Check the firewall between the two machines."; fi
  fi
}

do_disconnect() {
  installed || die "Not installed."
  [[ -n $(sget router/node_id) ]] || { say "  Not connected to an MCP server."; return 0; }
  py leave "$STATE" forget; ok "Left the router (the MCP server no longer lists this node's models)."
}

# ── OpenCode ──────────────────────────────────────────────────────────────────
user_home() { getent passwd "$1" | cut -d: -f6; }
setup_opencode() {
  local u=$TARGET_USER home
  [[ -n $u && $u != root ]] || { warn "OpenCode: no regular user (run with sudo from your user, or --user=NAME)."; return 0; }
  home=$(user_home "$u"); [[ -d $home ]] || { warn "OpenCode: no home folder for $u."; return 0; }
  if [[ ! -x $home/.opencode/bin/opencode ]] && ! su - "$u" -c 'command -v opencode' >/dev/null 2>&1; then
    info "Installing OpenCode for $u…"
    su - "$u" -c 'curl -fsSL https://opencode.ai/install | bash' >>"$LOG_FILE" 2>&1 || { warn "OpenCode install failed (see log)."; return 0; }
    py state-set "$STATE" opencode/installed_by_us true
  fi
  py state-set "$STATE" opencode/user "\"$u\""
  local p; p=$(py opencode-add "$STATE" "$home" "$(sget default)") || { warn "OpenCode config not changed (see above)."; return 0; }
  chown -R "$u:" "$home/.config/opencode"
  ok "OpenCode for $u: model sudohomelab-node/$(sget default)$( [[ -n $(sget mcp/token) ]] && echo " + MCP tools") ($p)"
}
do_opencode() { # install OpenCode if needed and link it to the node + the MCP tools
  installed || die "Install the node first."
  write_helper
  if [[ -z $MCP_URL || -z $MCP_TOKEN ]]; then
    MCP_URL=${MCP_URL:-$(sget mcp/url)}; MCP_TOKEN=${MCP_TOKEN:-$(sget mcp/token)}
  fi
  if interactive && [[ -z $MCP_TOKEN ]]; then
    say "  ${C_GRAY}The MCP address + token are shown by the MCP server installer (--info).${C_RESET}"
    MCP_URL=$(ask "MCP address" "${MCP_URL:-http://<mcp-server>:8790/mcp}")
    MCP_TOKEN=$(ask_secret "MCP token (Enter = no MCP tools, only the model)")
  fi
  [[ -n $MCP_URL && -n $MCP_TOKEN ]] && py state-set "$STATE" mcp "{\"url\":\"$MCP_URL\",\"token\":\"$MCP_TOKEN\"}"
  if [[ -z $TARGET_USER || $TARGET_USER == root ]] && interactive; then
    TARGET_USER=$(ask "Linux user for OpenCode" "$(sget opencode/user)")
  fi
  setup_opencode
}

remove_opencode() {
  py opencode-remove "$STATE" || true
  local u; u=$(sget opencode/user)
  if [[ $(sget opencode/installed_by_us) == True && -n $u ]]; then
    local home; home=$(user_home "$u")
    rm -rf "$home/.opencode"
    sed -i '/# opencode/d; /\.opencode\/bin/d' "$home/.bashrc" "$home/.zshrc" "$home/.profile" 2>/dev/null || true
    ok "OpenCode removed for $u"
  fi
}

# ── Actions ───────────────────────────────────────────────────────────────────
show_info() {
  local port key addr
  port=$(sget port); key=$(sget api_key); addr=$(lan_ip)
  say ""
  say "  ${C_BOLD}${C_GREEN}AI node${C_RESET}"
  say "    address   http://$addr:$port/v1   (OpenAI-compatible)"
  say "    api key   $key"
  say "    models    $(python3 -c "import json,sys; print(', '.join(json.load(open(sys.argv[1])).get('models', {})))" "$STATE")"
  say "    engine    llama.cpp $(sget llama/tag) ($(sget llama/backend)), llama-swap $(sget swap_tag)"
  say "    router    $(py router-status "$STATE")"
  [[ -n $(sget opencode/config) ]] && say "    opencode  $(sget opencode/config)"
  is_wsl && say "  ${C_GRAY}WSL: the node runs while WSL runs. Keep WSL open (or a keep-alive task) for the router to reach it.${C_RESET}"
  say ""
}

do_suggest() {
  banner; preflight
  say ""; SHL_OUT="$WORK/ids" py suggest "$HW" "$CATALOG"
  say ""
  say "  ${C_GRAY}Estimates: speed from memory bandwidth, memory from the model files. --vram=GB plans for less GPU memory.${C_RESET}"
}

do_install() {
  banner; preflight
  mkdir -p "$LOG_DIR"
  say ""; py hwinfo "$HW" "$CATALOG"
  local busy; busy=$(python3 -c "import json,sys; print(int(sum(g['used_gib'] for g in json.load(open(sys.argv[1]))['gpus'])))" "$HW")
  if (( busy >= 1 )) && [[ -z $VRAM ]]; then
    warn "$busy GB of GPU memory is in use by other programs right now."
    if interactive; then
      case $(menu "Plan for" 1 "The whole GPU (close the other program when you use this model)" "Only what is free now") in
        2) VRAM=$(python3 -c "import json,sys; g=json.load(open(sys.argv[1]))['gpus']; print(round(sum(x['total_gib']-x['used_gib'] for x in g),1))" "$HW") ;;
      esac
    fi
  fi
  pick_model
  local be why
  IFS='|' read -r be why < <(py backend "$HW")
  BACKEND=${BACKEND:-$be}
  [[ -n $PORT ]] || { PORT=8080; while ! port_free "$PORT"; do PORT=$((PORT + 1)); done; }
  if [[ -z $OPENCODE ]]; then
    if interactive; then confirm "Also install OpenCode (coding agent) for ${TARGET_USER:-your user}, using this model?" && OPENCODE=yes || OPENCODE=no
    else OPENCODE=no; fi
  fi
  [[ -n $JOIN ]] || ask_connect || true
  say ""
  say "  ${C_BOLD}Plan${C_RESET}"
  say "    model      $MODEL ($(py state-get "$WORK/card.json" file_gb) GB download, context $(py state-get "$WORK/card.json" ctx))"
  say "    engine     llama.cpp ($BACKEND) + llama-swap, port $PORT, API key"
  say "    folder     $INSTALL_DIR  (service $SERVICE)"
  say "    mcp        $([[ -n $JOIN ]] && echo "join $(py decode-join "$JOIN" | cut -d'|' -f1)" || echo "not now (--connect later)")"
  say "    opencode   $OPENCODE"
  say ""
  confirm "Install now?" || { say "  Nothing changed."; exit 0; }
  TOTAL_STEPS=7
  mkdir -p "$INSTALL_DIR"/{bin,llama,models,tests}
  [[ -f $STATE ]] || echo '{}' >"$STATE"
  py state-set "$STATE" install_dir "\"$INSTALL_DIR\""
  py state-set "$STATE" port "$PORT"
  [[ -n $(sget api_key) ]] || py state-set "$STATE" api_key "\"$(gen_key)\""
  step "llama.cpp";  install_llama "$BACKEND"
  step "llama-swap"; install_swap
  step "Model";      download_model "$MODEL"; add_model_state "$MODEL"
  step "Service";    write_service; apply_config
  step "Test"
  py test "$STATE" "$MODEL" "$CATALOG" || warn "Some checks failed (see above)."
  step "MCP"
  if [[ -n $JOIN ]]; then
    do_connect
    if [[ -n $(sget mcp/token) ]]; then
      py test-mcp "$STATE" "$MODEL" || warn "The model didn't finish the MCP tool test (see above)."
    fi
  else info "Skipped (--connect later)"; fi
  step "OpenCode"
  if [[ $OPENCODE == yes ]]; then setup_opencode; else info "Skipped"; fi
  show_info
}

do_add_model() {
  installed || die "Install the node first."
  banner; preflight
  say ""; py hwinfo "$HW" "$CATALOG"
  pick_model
  download_model "$MODEL"; add_model_state "$MODEL"; apply_config
  py router-update "$STATE" || warn "Couldn't update the router."
  py test "$STATE" "$MODEL" "$CATALOG" || warn "Some checks failed (see above)."
  [[ -n $(sget opencode/config) ]] && { py opencode-add "$STATE" "$(dirname "$(dirname "$(dirname "$(sget opencode/config)")")")" "$(sget default)" >/dev/null || true; }
  ok "Added $MODEL"
}

do_remove_model() {
  installed || die "Not installed."
  write_helper
  local ids i
  mapfile -t ids < <(python3 -c "import json,sys; print('\n'.join(json.load(open(sys.argv[1])).get('models', {})))" "$STATE")
  (( ${#ids[@]} )) || { say "  No models installed."; return 0; }
  if [[ -z $MODEL ]]; then
    interactive || die "Say which: --model=ID"
    i=$(menu "Remove which model?" 1 "${ids[@]}"); MODEL=${ids[$((i - 1))]}
  fi
  [[ " ${ids[*]} " == *" $MODEL "* ]] || die "$MODEL is not installed (installed: ${ids[*]})."
  confirm "Remove $MODEL and delete its files?" || exit 0
  local f
  for f in $(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['models'][sys.argv[2]]['files']))" "$STATE" "$MODEL"); do
    rm -f "$INSTALL_DIR/models/$f" "$INSTALL_DIR/models/$f.part"
  done
  find "$INSTALL_DIR/models" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  py state-set "$STATE" "models/$MODEL" null
  [[ $(sget default) == "$MODEL" ]] && py state-set "$STATE" default "\"$(python3 -c "import json,sys; print(next(iter(json.load(open(sys.argv[1])).get('models', {})), ''))" "$STATE")\""
  py router-update "$STATE" || warn "Couldn't update the router."
  CATALOG="$INSTALL_DIR/models.json"; apply_config
  ok "Removed $MODEL"
}

do_test() {
  installed || die "Not installed."
  write_helper
  [[ -n $MCP_URL && -n $MCP_TOKEN ]] && py state-set "$STATE" mcp "{\"url\":\"$MCP_URL\",\"token\":\"$MCP_TOKEN\"}"
  py test "$STATE" "$MODEL" "$INSTALL_DIR/models.json"
}

do_status() {
  installed || die "Not installed."
  write_helper
  say "  service   $(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  say "  loaded    $(curl -s -m 5 -H "Authorization: Bearer $(sget api_key)" "http://127.0.0.1:$(sget port)/running" | python3 -c "import json,sys; d=json.load(sys.stdin); print(', '.join('%s (%s)' % (r.get('model'), r.get('state')) for r in d.get('running', [])) or 'nothing (a model loads on the first request)')" 2>/dev/null || echo '?')"
  say "  router    $(py router-status "$STATE")"
}

do_update() {
  installed || die "Not installed."
  banner; preflight
  install_llama "$(sget llama/backend)"; install_swap; apply_config
  ok "Updated; models and settings kept."
}

do_uninstall() {
  installed || [[ -d $INSTALL_DIR ]] || { say "  Not installed."; exit 0; }
  write_helper
  local size; size=$(du -sh "$INSTALL_DIR/models" 2>/dev/null | cut -f1)
  if [[ $PURGE == 0 ]] && interactive && [[ -n $(find "$INSTALL_DIR/models" -type f 2>/dev/null | head -n1) ]]; then
    confirm_no "Also delete the downloaded models (${size:-0})?" && PURGE=1
  fi
  if [[ $PURGE == 1 ]]; then confirm "Remove the AI node AND its downloaded models (${size:-0})?" || exit 0
  else confirm "Remove the AI node? (the models in $INSTALL_DIR/models stay for a reinstall)" || exit 0; fi
  [[ -f $STATE ]] && { py leave "$STATE" forget 2>/dev/null && ok "Left the MCP router" || true; }
  run systemctl disable --now "$SERVICE" || true
  [[ -f /etc/systemd/system/$SERVICE-route.service ]] && { run systemctl disable --now "$SERVICE-route" || true; }
  rm -f "/etc/systemd/system/$SERVICE.service" "/etc/systemd/system/$SERVICE-route.service"; run systemctl daemon-reload || true
  [[ -f $STATE ]] && { wsl_firewall close "$(sget port)"; remove_opencode; }
  id "$SVC_USER" >/dev/null 2>&1 && run userdel "$SVC_USER" || true
  if [[ $PURGE == 1 ]]; then
    rm -rf "$INSTALL_DIR"; rmdir /opt/sudohomelab 2>/dev/null || true
    ok "Removed everything, models included."
  else
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} +
    ok "Removed; models kept in $INSTALL_DIR/models (--uninstall --purge deletes them)."
  fi
}

run_action() {
  case $1 in
    suggest) do_suggest ;;
    install) do_install ;;
    add-model) do_add_model ;;
    remove-model) do_remove_model ;;
    test) do_test ;;
    connect) write_helper; [[ -f $HW ]] || py scan >"$HW"; do_connect ;;
    disconnect) write_helper; do_disconnect ;;
    opencode) do_opencode ;;
    status) do_status ;;
    info) installed || die "Not installed."; write_helper; show_info ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
  esac
}

main() {
  parse_args "$@"
  mkdir -p "$LOG_DIR"
  if [[ -n $ACTION ]]; then run_action "$ACTION"; return; fi
  if ! interactive; then installed && run_action status || run_action install; return; fi
  banner
  # The menu comes back after each action. Each one runs in a subshell, so an
  # error returns here instead of closing the script; Quit leaves.
  while :; do
    if ! installed; then
      case $(menu "AI node" 1 "Install" "Only show the suggested models" "Quit") in
        1) ACTION=install ;; 2) ACTION=suggest ;; *) return 0 ;;
      esac
    else
      case $(menu "AI node is installed. What now?" 1 \
             "Status" "Add a model" "Remove a model" "Test the models (+ MCP tools)" \
             "Connect to an MCP server" "Disconnect from the MCP server" \
             "OpenCode: install / link to the MCP" "Connection info" \
             "Update llama.cpp + llama-swap" "Uninstall" "Quit") in
        1) ACTION=status ;; 2) ACTION=add-model ;; 3) ACTION=remove-model ;; 4) ACTION=test ;;
        5) ACTION=connect ;; 6) ACTION=disconnect ;; 7) ACTION=opencode ;; 8) ACTION=info ;;
        9) ACTION=update ;; 10) ACTION=uninstall ;; *) return 0 ;;
      esac
    fi
    ( run_action "$ACTION" ) || true
    [[ $ACTION == uninstall ]] && ! installed && return 0
    MODEL=""; JOIN=""; VRAM=""; CTX=""
    read -r -p "  ${C_GRAY}Enter = back to the menu${C_RESET} " _ </dev/tty || true
  done
}

[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
