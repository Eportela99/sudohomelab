#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · MCP Server: the brain + tools for your local AI (Debian / Ubuntu)
#  https://github.com/Eportela99/sudohomelab
#
#  Installs, as Docker containers on this machine:
#    · gateway    one MCP address + one token for every tool you pick
#    · router     OpenAI-compatible model router, EMPTY until an AI node joins
#                 (SudoHomelab Script 2) with the join code printed at the end
#    · knowledge  Postgres + pgvector, with bge-m3 embeddings + reranker on CPU
#    · search     SearXNG (private web search) + Valkey
#    · webui      Open WebUI (default on): every model that joins the router shows
#                 up there by itself, with the MCP tools already turned on
#  No chat model is installed here: models live on AI nodes and join the router.
#
#  Usage (no options = a menu when it's already installed):
#    sudo bash -c "$(curl -fsSL <url>/AI_Tools/linux/mcp-server.sh)"
#    sudo bash mcp-server.sh --install --profile=standard --tailscale=none --yes
#    sudo bash mcp-server.sh --info | --status | --rotate | --update
#    sudo bash mcp-server.sh --webui=install|sync|remove
#    sudo bash mcp-server.sh --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.0"
REPO="Eportela99/sudohomelab"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/main/AI_Tools/linux/mcp-server.sh"
SRC_TARBALL="https://codeload.github.com/$REPO/tar.gz/refs/heads/main"
INSTALL_DIR="/opt/sudohomelab/mcp"
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/mcp-server-$(date +%Y%m%d-%H%M%S).log"
PROJECT="sudohomelab-mcp"

PG_IMAGE="pgvector/pgvector:pg17"
LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server"
SEARXNG_IMAGE="searxng/searxng:latest"
VALKEY_IMAGE="valkey/valkey:8-alpine"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
EMBED_GGUF="bge-m3-Q8_0.gguf"
EMBED_GGUF_URL="https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/$EMBED_GGUF"
RERANK_GGUF="bge-reranker-v2-m3-Q8_0.gguf"
RERANK_GGUF_URL="https://huggingface.co/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/$RERANK_GGUF"

P_MCP=8790; P_ROUTER=8791; P_WEBUI=3000

# Tool groups. core, search and knowledge are always on; the rest are picked.
# RULE: every new tool group is added here AND to GROUPS in gateway/app/server.py.
ALWAYS_TOOLS="core,search,knowledge"
TOOL_IDS=(files vault)
tool_label() {
  case $1 in
    files) echo "files     fs_* tools, limited to $INSTALL_DIR/files" ;;
    vault) echo "vault     encrypted secrets store (vault_*)" ;;
  esac
}
profile_tools() { # profile → optional tools
  case $1 in
    minimal) echo "" ;;
    standard|full) local IFS=,; echo "${TOOL_IDS[*]}" ;;
  esac
}

ACTION=""; PROFILE=""; TOOLS=""; TAILSCALE=""; TS_AUTHKEY=""; ASSUME_YES=0; PURGE=0
M_URL=""; M_NAME=""; M_IDS=""; M_KEY=""; M_REF=""   # model menu options
WEBUI=""                                             # Open WebUI: on | none (install) · sync | remove (later)
SRC_DIR="${SHL_SRC:-}"

# ── UI ────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_CYAN=$'\e[36m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_GRAY=$'\e[90m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi
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
  printf '    %s❯%s %sMCP Server: brain + tools for your local AI%s %sv%s%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

has_tty() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }
ask() { # ask "question" default
  local a
  if [[ $ASSUME_YES == 1 ]] || ! has_tty; then echo "$2"; return; fi
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
  [[ $ASSUME_YES == 1 ]] && return 0
  has_tty || return 0
  read -r -p "  $1 [Y/n]: " a </dev/tty || true
  [[ -z $a || $a =~ ^[Yy] ]]
}
menu() { # menu "title" default "label" ... → chosen index (1-based)
  local title=$1 def=$2 i a; shift 2
  if [[ $ASSUME_YES == 1 ]] || ! has_tty; then echo "$def"; return; fi
  printf '\n  %s%s%s\n' "$C_BOLD" "$title" "$C_RESET" >/dev/tty
  i=1; for a in "$@"; do printf '    %d) %s\n' "$i" "$a" >/dev/tty; i=$((i + 1)); done
  while :; do
    read -r -p "  Choice [$def]: " a </dev/tty || true
    a=${a:-$def}
    [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= $# )) && { echo "$a"; return; }
  done
}

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: sudo bash mcp-server.sh [action] [options]

Actions (no action = install, or a menu if it's already installed):
  --install            Install or repair
  --status             Containers, health, joined models
  --info               MCP address + token, join code for AI nodes (Script 2)
  --rotate             New MCP token and join token (old ones stop working)
  --update             Newest code and images; keeps all data
  --uninstall          Remove the containers (data stays unless --purge)
  --webui=ACTION       Open WebUI later: install | sync (refresh its link to the router
                       and MCP) | remove (its chats stay in the data folder)

Models (the router; no model is installed here, you connect ones you already run):
  --models             List the models in the router
  --add-model          Connect a model server you already run (Ollama, llama.cpp,
                       LM Studio, vLLM... anything OpenAI-compatible)
                         --model-url=HOST:PORT  --model-name=MACHINE
                         --model-ids=ID,ID|all  --model-key-file=FILE (if it needs a key)
  --remove-model       --model=MACHINE or --model=MODEL@MACHINE
  --default-model      --model=MODEL@MACHINE

Install options:
  --profile=NAME       minimal (core, search, knowledge) | standard | full  (default standard)
  --tools=LIST         Optional tools, comma list: ${TOOL_IDS[*]} | all | none
  --tailscale=MODE     on (this machine joins your tailnet, HTTPS via tailscale serve) | none
  --webui=on|none      Install Open WebUI with it (default on)
  --ts-authkey-file=F  File holding a Tailscale auth key (else a login link is shown)
  --src=DIR            Use a local copy of AI_Tools/mcp-server instead of downloading
  --install-dir=PATH   Default $INSTALL_DIR
  -y, --yes            Accept defaults, no questions
EOF
}

parse_args() {
  local a
  for a in "$@"; do
    case $a in
      --install|--status|--info|--rotate|--update|--uninstall) ACTION=${a#--} ;;
      --webui) ACTION=webui ;;
      --webui=on|--webui=none) WEBUI=${a#*=} ;;
      --webui=install|--webui=sync|--webui=remove) ACTION=webui; WEBUI=${a#*=} ;;
      --webui=*) echo "--webui: on, none, install, sync or remove" >&2; exit 2 ;;
      --models|--add-model|--remove-model|--default-model) ACTION=${a#--} ;;
      --model-url=*) M_URL=${a#*=} ;;
      --model-name=*) M_NAME=${a#*=} ;;
      --model-ids=*) M_IDS=${a#*=} ;;
      --model=*) M_REF=${a#*=} ;;
      --model-key-file=*) [[ -r ${a#*=} ]] || { echo "Can't read ${a#*=}" >&2; exit 2; }
                          M_KEY=$(head -n1 "${a#*=}" | tr -d '\r\n') ;;
      --purge) PURGE=1 ;;
      --profile=*) PROFILE=${a#*=} ;;
      --tools=*) TOOLS=${a#*=} ;;
      --tailscale=*) TAILSCALE=${a#*=} ;;
      --ts-authkey-file=*) [[ -r ${a#*=} ]] || { echo "Can't read ${a#*=}" >&2; exit 2; }
                           TS_AUTHKEY=$(head -n1 "${a#*=}" | tr -d '\r\n') ;;
      --src=*) SRC_DIR=${a#*=} ;;
      --install-dir=*) INSTALL_DIR=${a#*=} ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $a (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ -z $PROFILE || $PROFILE =~ ^(minimal|standard|full)$ ]] || { echo "--profile: minimal, standard or full" >&2; exit 2; }
  [[ -z $TAILSCALE || $TAILSCALE =~ ^(on|none)$ ]] || { echo "--tailscale: on or none" >&2; exit 2; }
}

dc() { docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
installed() { [[ -f $INSTALL_DIR/.env && -f $INSTALL_DIR/docker-compose.yml ]]; }
env_get() { [[ -f $INSTALL_DIR/.env ]] && sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | tail -n1 || true; }
env_set() { # env_set KEY value  (in .env, mode 600)
  local f=$INSTALL_DIR/.env
  touch "$f"; chmod 600 "$f"
  if grep -q "^$1=" "$f"; then sed -i "s|^$1=.*|$1=$2|" "$f"; else echo "$1=$2" >>"$f"; fi
}
gen_token() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-40}"; }
fernet_key() { head -c 32 /dev/urandom | base64 | tr '+/' '-_'; }
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1; }
ts_name() { command -v tailscale >/dev/null && tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -n1 || true; }
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || true; }

wait_http() { # wait_http url seconds "what"
  local i
  for ((i = 0; i < $2; i += 3)); do
    [[ $(http_code "$1") =~ ^[2-4][0-9][0-9]$ ]] && return 0
    sleep 3
  done
  return 1
}

mcp_url() {
  local ts; ts=$(ts_name)
  if [[ $(env_get TAILSCALE) == on && -n $ts ]]; then echo "https://$ts/mcp"
  else echo "http://$(lan_ip):$P_MCP/mcp"; fi
}
router_url() {
  local ts; ts=$(ts_name)
  if [[ $(env_get TAILSCALE) == on && -n $ts ]]; then echo "https://$ts:8443"
  else echo "http://$(lan_ip):$P_ROUTER"; fi
}
join_code() {
  printf '{"router":"%s","token":"%s"}' "$(router_url)" "$(env_get JOIN_TOKEN)" | base64 -w0 | tr '+/' '-_' | tr -d '=' | sed 's/^/shl-join:/'
}

# ── Choices ───────────────────────────────────────────────────────────────────
preflight() {
  [[ $EUID == 0 ]] || die "Run as root (sudo)."
  [[ -f /etc/os-release ]] && . /etc/os-release
  [[ ${ID:-} =~ ^(debian|ubuntu)$ || ${ID_LIKE:-} =~ (debian|ubuntu) ]] || die "This installer is for Debian or Ubuntu (found ${PRETTY_NAME:-unknown})."
  [[ $(uname -m) == x86_64 ]] || warn "Tested on x86_64 only (this is $(uname -m))."
  local mem disk
  mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  disk=$(df -Pm "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 {print $4}' || df -Pm / | awk 'NR==2 {print $4}')
  info "Machine: ${PRETTY_NAME:-Linux}, $(nproc) CPU, ${mem} MB RAM, $((disk / 1024)) GB free"
  (( mem >= 3000 )) || warn "Less than 3 GB RAM: the embedding models may not fit (4 GB+ recommended)."
  (( disk >= 12000 )) || die "Need about 12 GB free disk (found $((disk / 1024)) GB)."
}

choose_options() {
  local c picks i
  if [[ -z $PROFILE && -z $TOOLS ]]; then
    c=$(menu "Which tools?" 2 \
      "Minimal   core, web search, knowledge base (memory)" \
      "Standard  + files, vault (recommended)" \
      "Custom    pick the optional tools")
    case $c in
      1) PROFILE=minimal ;;
      2) PROFILE=standard ;;
      3) PROFILE=custom
         printf '\n  Optional tools (core, search and knowledge are always installed):\n' >/dev/tty
         for i in "${!TOOL_IDS[@]}"; do printf '    %d) %s\n' $((i + 1)) "$(tool_label "${TOOL_IDS[$i]}")" >/dev/tty; done
         picks=$(ask "Numbers to add, comma separated (a = all)" "a")
         if [[ $picks == a ]]; then TOOLS=all
         else TOOLS=""; for i in ${picks//,/ }; do [[ $i =~ ^[0-9]+$ && -n ${TOOL_IDS[$((i - 1))]:-} ]] && TOOLS+="${TOOL_IDS[$((i - 1))]},"; done
              TOOLS=${TOOLS%,}; [[ -n $TOOLS ]] || TOOLS=none; fi ;;
    esac
  fi
  [[ -n $PROFILE ]] || PROFILE=standard
  case ${TOOLS:-} in
    "") TOOLS=$(profile_tools "$PROFILE") ;;
    all) local IFS=,; TOOLS="${TOOL_IDS[*]}"; unset IFS ;;
    none) TOOLS="" ;;
  esac
  local t; for t in ${TOOLS//,/ }; do [[ " ${TOOL_IDS[*]} " == *" $t "* ]] || die "Unknown tool: $t (choose from: ${TOOL_IDS[*]})"; done
  TOOLS="$ALWAYS_TOOLS${TOOLS:+,$TOOLS}"

  if [[ -z $TAILSCALE ]]; then
    c=$(menu "Reach it through Tailscale?" 2 \
      "Yes   this machine joins your tailnet; HTTPS address via tailscale serve" \
      "No    LAN only (you can add Tailscale later)")
    [[ $c == 1 ]] && TAILSCALE=on || TAILSCALE=none
  fi
  if [[ $TAILSCALE == on && -z $TS_AUTHKEY && $ASSUME_YES == 0 ]] && has_tty; then
    TS_AUTHKEY=$(ask_secret "Tailscale auth key (Enter = show a login link instead)")
  fi
  if [[ -z $WEBUI ]]; then
    WEBUI=$(env_get WEBUI)
    [[ -n $WEBUI ]] || { confirm "Install Open WebUI too? (chat in the browser; every model that joins shows up there)" && WEBUI=on || WEBUI=none; }
  fi
}

print_plan() {
  say ""
  say "  ${C_BOLD}Plan${C_RESET}"
  say "    tools      ${TOOLS//,/, }"
  say "    tailscale  $TAILSCALE"
  say "    open webui $([[ $WEBUI == on ]] && echo "yes, port $P_WEBUI (about 4 GB image)" || echo no)"
  say "    folder     $INSTALL_DIR  (settings, tokens, database, files)"
  say "    downloads  ~1.3 GB embedding models + ~2 GB of container images"
  say ""
}

# ── Install ───────────────────────────────────────────────────────────────────
install_deps() {
  run apt-get update -y || die "apt-get update failed."
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar gzip iproute2 \
    || die "Couldn't install the basic packages."
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker (get.docker.com)…"
    if ! curl -fsSL https://get.docker.com | run sh; then
      warn "The Docker script failed; trying the distro packages."
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 ||
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose ||
        die "Couldn't install Docker."
    fi
  fi
  run systemctl enable --now docker || true
  docker info >/dev/null 2>&1 || die "Docker isn't running. In a Proxmox LXC, enable nesting and keyctl."
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
}

get_source() {
  local tmp
  rm -rf "$INSTALL_DIR/src.new"
  if [[ -n $SRC_DIR ]]; then
    [[ -f $SRC_DIR/gateway/app/server.py ]] || die "--src=$SRC_DIR doesn't look like AI_Tools/mcp-server"
    cp -a "$SRC_DIR" "$INSTALL_DIR/src.new"
  else
    tmp=$(mktemp -d)
    curl -fsSL "$SRC_TARBALL" | tar -xz -C "$tmp" --strip-components=1 --wildcards '*/AI_Tools/mcp-server' \
      || die "Couldn't download the source from GitHub."
    mv "$tmp/AI_Tools/mcp-server" "$INSTALL_DIR/src.new"; rm -rf "$tmp"
  fi
  rm -rf "$INSTALL_DIR/src"; mv "$INSTALL_DIR/src.new" "$INSTALL_DIR/src"
  ok "Source ready ($INSTALL_DIR/src)"
}

get_models() {
  local f url
  mkdir -p "$INSTALL_DIR/models"
  for f in "$EMBED_GGUF|$EMBED_GGUF_URL" "$RERANK_GGUF|$RERANK_GGUF_URL"; do
    url=${f#*|}; f=${f%%|*}
    if [[ -s $INSTALL_DIR/models/$f && ! -f $INSTALL_DIR/models/$f.part ]]; then ok "$f (already here)"; continue; fi
    info "Downloading $f (~630 MB)…"
    touch "$INSTALL_DIR/models/$f.part"
    curl -fL --retry 5 --retry-delay 5 -C - -o "$INSTALL_DIR/models/$f" "$url" 2>>"$LOG_FILE" ||
      die "Download failed: $url"
    rm -f "$INSTALL_DIR/models/$f.part"
    ok "$f"
  done
}

write_secrets() {
  mkdir -p "$INSTALL_DIR"; touch "$INSTALL_DIR/.env"; chmod 600 "$INSTALL_DIR/.env"
  [[ -n $(env_get MCP_TOKEN) ]]   || env_set MCP_TOKEN "$(gen_token 40)"
  [[ -n $(env_get JOIN_TOKEN) ]]  || env_set JOIN_TOKEN "$(gen_token 40)"
  [[ -n $(env_get DB_PASSWORD) ]] || env_set DB_PASSWORD "$(gen_token 32)"
  [[ -n $(env_get VAULT_KEY) ]]   || env_set VAULT_KEY "$(fernet_key)"
  [[ -n $(env_get SEARXNG_SECRET) ]] || env_set SEARXNG_SECRET "$(gen_token 48)"
  if [[ $WEBUI == on ]]; then
    [[ -n $(env_get WEBUI_SECRET_KEY) ]] || env_set WEBUI_SECRET_KEY "$(gen_token 48)"
    [[ -n $(env_get WEBUI_ADMIN_EMAIL) ]] || env_set WEBUI_ADMIN_EMAIL "admin@sudohomelab.local"
    [[ -n $(env_get WEBUI_ADMIN_PASSWORD) ]] || env_set WEBUI_ADMIN_PASSWORD "$(gen_token 20)"
  fi
  env_set WEBUI "${WEBUI:-none}"
  env_set TOOLS "$TOOLS"
  env_set TAILSCALE "$TAILSCALE"
  env_set SHL_VERSION "$VERSION"
  ok "Secrets in $INSTALL_DIR/.env (root only)"
}

write_files() {
  local threads
  threads=$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))
  mkdir -p "$INSTALL_DIR"/{data/gateway,data/router,data/postgres,files,searxng}
  # The gateway and router run as uid 10001 inside their containers.
  chown -R 10001:10001 "$INSTALL_DIR/data/gateway" "$INSTALL_DIR/data/router" "$INSTALL_DIR/files"

  cat >"$INSTALL_DIR/searxng/settings.yml" <<EOF
# Written by the sudo homelab MCP installer.
use_default_settings: true
server:
  secret_key: "$(env_get SEARXNG_SECRET)"
  limiter: false
  image_proxy: false
search:
  formats: [html, json]
valkey:
  url: valkey://valkey:6379/0
EOF

  cat >"$INSTALL_DIR/docker-compose.yml" <<EOF
# Written by the sudo homelab MCP installer ($VERSION). Re-run the installer to change it.
name: $PROJECT
services:
  gateway:
    build: ./src/gateway
    image: sudohomelab/mcp-gateway:local
    restart: unless-stopped
    env_file: .env
    environment:
      KB_DSN: "host=db dbname=kb user=mcp password=\${DB_PASSWORD}"
      FILES_ROOT: /data/files
    volumes:
      - ./data/gateway:/data
      - ./files:/data/files
    ports: ["$P_MCP:8790"]
    depends_on: [db, router, searxng, embed, rerank]
  router:
    build: ./src/router
    image: sudohomelab/mcp-router:local
    restart: unless-stopped
    environment:
      MCP_TOKEN: \${MCP_TOKEN}
      JOIN_TOKEN: \${JOIN_TOKEN}
    volumes: [./data/router:/data]
    ports: ["$P_ROUTER:8791"]
  db:
    image: $PG_IMAGE
    restart: unless-stopped
    environment:
      POSTGRES_DB: kb
      POSTGRES_USER: mcp
      POSTGRES_PASSWORD: \${DB_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./src/knowledge/init.sql:/docker-entrypoint-initdb.d/10-kb.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mcp -d kb"]
      interval: 10s
      retries: 10
  embed:
    image: $LLAMA_IMAGE
    restart: unless-stopped
    command: ["-m", "/models/$EMBED_GGUF", "--alias", "bge-m3", "--embeddings",
              "-c", "4096", "-b", "4096", "-ub", "4096", "--threads", "$threads",
              "--host", "0.0.0.0", "--port", "8080"]
    volumes: [./models:/models:ro]
  rerank:
    image: $LLAMA_IMAGE
    restart: unless-stopped
    command: ["-m", "/models/$RERANK_GGUF", "--alias", "bge-reranker-v2-m3", "--reranking",
              "--pooling", "rank", "-c", "8192", "-b", "2048", "-ub", "2048",
              "--threads", "$threads", "--host", "0.0.0.0", "--port", "8080"]
    volumes: [./models:/models:ro]
  searxng:
    image: $SEARXNG_IMAGE
    restart: unless-stopped
    volumes: [./searxng:/etc/searxng]
    depends_on: [valkey]
  valkey:
    image: $VALKEY_IMAGE
    restart: unless-stopped
    command: ["valkey-server", "--save", "", "--appendonly", "no"]
EOF
  if [[ $WEBUI == on ]]; then
    mkdir -p "$INSTALL_DIR/data/webui"
    cat >>"$INSTALL_DIR/docker-compose.yml" <<EOF
  webui:
    image: $WEBUI_IMAGE
    restart: unless-stopped
    environment:
      WEBUI_NAME: sudo homelab
      WEBUI_SECRET_KEY: \${WEBUI_SECRET_KEY}
      WEBUI_ADMIN_EMAIL: \${WEBUI_ADMIN_EMAIL}
      WEBUI_ADMIN_PASSWORD: \${WEBUI_ADMIN_PASSWORD}
      WEBUI_ADMIN_NAME: Admin
      ENABLE_SIGNUP: "False"
      ENABLE_API_KEYS: "True"
      ENABLE_OLLAMA_API: "False"
      # Models: the router (every model@node that joins). Tools: the MCP (linked after start).
      OPENAI_API_BASE_URLS: http://router:8791/v1
      OPENAI_API_KEYS: \${MCP_TOKEN}
      # Uploaded documents use the MCP's bge-m3 embeddings (no extra model download).
      RAG_EMBEDDING_ENGINE: openai
      RAG_OPENAI_API_BASE_URL: http://embed:8080/v1
      RAG_OPENAI_API_KEY: none
      RAG_EMBEDDING_MODEL: bge-m3
    volumes: [./data/webui:/app/backend/data]
    ports: ["$P_WEBUI:8080"]
    depends_on: [router, gateway, embed]
EOF
  fi
  ok "docker-compose.yml written"
}

start_stack() {
  info "Pulling images (first time takes a few minutes)…"
  run dc pull --ignore-buildable || run dc pull || die "Couldn't pull the images."
  info "Building the gateway and router…"
  run dc build --pull || die "Build failed."
  run dc up -d --remove-orphans || die "Couldn't start the containers."
  wait_http "http://127.0.0.1:$P_MCP/health" 90 || die "The gateway didn't start (dc logs gateway)."
  ok "gateway   http://127.0.0.1:$P_MCP"
  wait_http "http://127.0.0.1:$P_ROUTER/health" 60 || die "The router didn't start (dc logs router)."
  ok "router    http://127.0.0.1:$P_ROUTER (empty until an AI node joins)"
  if [[ $WEBUI == on ]]; then
    info "Starting Open WebUI (the first start takes a few minutes)…"
    wait_http "http://127.0.0.1:$P_WEBUI/health" 600 || die "Open WebUI didn't start (dc logs webui)."
    ok "webui     http://127.0.0.1:$P_WEBUI"
  fi
}

# Talks MCP to the gateway from inside its container: initialize, list tools,
# then one real call per group. Prints "name: result" lines.
self_test() {
  dc exec -T gateway python - <<'PY'
import json, os, httpx
H = {"Authorization": "Bearer " + os.environ["MCP_TOKEN"],
     "Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
U = "http://127.0.0.1:8790/mcp"
def call(method, params, i):
    r = httpx.post(U, headers=H, json={"jsonrpc": "2.0", "id": i, "method": method, "params": params}, timeout=180)
    r.raise_for_status()
    body = r.text
    if "data:" in body:
        body = [l[5:] for l in body.splitlines() if l.startswith("data:")][-1]
    return json.loads(body)["result"]
call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "installer", "version": "1"}}, 1)
tools = [t["name"] for t in call("tools/list", {}, 2)["tools"]]
print("tools: %d" % len(tools))
def text(name, args):
    res = call("tools/call", {"name": name, "arguments": args}, 3)
    return (res["content"][0]["text"] if res.get("content") else "").replace("\n", " ")[:110]
print("mcp_status: " + text("mcp_status", {}))
if "web_search" in tools:
    print("web_search: " + text("web_search", {"query": "proxmox", "count": 1}))
if "memory_add" in tools:
    print("memory_add: " + text("memory_add", {"text": "sudo homelab MCP installed", "tags": "install"}))
    print("memory_search: " + text("memory_search", {"query": "when was the MCP installed?", "limit": 1}))
PY
}

wait_backends() {
  local i ok_e=0
  info "Waiting for the embedding models to load…"
  for ((i = 0; i < 60; i++)); do
    dc exec -T gateway python -c "import httpx,sys; sys.exit(0 if httpx.get('http://embed:8080/health').status_code==200 and httpx.get('http://rerank:8080/health').status_code==200 else 1)" \
      >/dev/null 2>&1 && { ok_e=1; break; }
    sleep 3
  done
  [[ $ok_e == 1 ]] && ok "embeddings + reranker ready (CPU)" || warn "Embeddings not ready yet; memory tools will work once they load."
}

setup_tailscale() {
  [[ $TAILSCALE == on ]] || return 0
  if ! command -v tailscale >/dev/null; then
    info "Installing Tailscale…"
    curl -fsSL https://tailscale.com/install.sh | run sh || die "Couldn't install Tailscale."
  fi
  [[ -c /dev/net/tun ]] || die "/dev/net/tun is missing (in a Proxmox LXC the host must pass it through)."
  if ! tailscale status >/dev/null 2>&1; then
    if [[ -n $TS_AUTHKEY ]]; then
      run tailscale up --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-mcp}" || die "tailscale up failed (auth key?)."
    else
      say ""; info "Open the link below to add this machine to your tailnet:"
      tailscale up --hostname="${TS_HOSTNAME:-mcp}" || die "tailscale up failed."
    fi
  fi
  # HTTPS on the tailnet: 443 → MCP gateway, 8443 → model router.
  run tailscale serve --bg --https=443 "http://127.0.0.1:$P_MCP" || warn "tailscale serve (443) failed: enable HTTPS in the Tailscale admin page (DNS → HTTPS certificates)."
  run tailscale serve --bg --https=8443 "http://127.0.0.1:$P_ROUTER" || true
  [[ $WEBUI == on ]] && { run tailscale serve --bg --https=8444 "http://127.0.0.1:$P_WEBUI" || true; }
  ok "Tailscale: $(ts_name)"
}

show_info() {
  local url tok
  url=$(mcp_url); tok=$(env_get MCP_TOKEN)
  say ""
  say "  ${C_BOLD}${C_GREEN}MCP server${C_RESET}"
  say "    address   $url"
  say "    token     $tok"
  say "    tools     $(env_get TOOLS | tr ',' ' ')"
  say ""
  say "  ${C_BOLD}Model router${C_RESET} (OpenAI-compatible, same token)"
  say "    address   $(router_url)/v1"
  say ""
  if [[ $(env_get WEBUI) == on ]]; then
    say "  ${C_BOLD}Open WebUI${C_RESET} (every model in the router, MCP tools on)"
    say "    address   $(webui_url)"
    say "    login     $(env_get WEBUI_ADMIN_EMAIL) / $(env_get WEBUI_ADMIN_PASSWORD)   (change it in Settings → Account)"
    say ""
  fi
  say "  ${C_BOLD}Join code for AI nodes${C_RESET} (SudoHomelab Script 2)"
  say "    $(join_code)"
  say ""
  say "  ${C_BOLD}Connect an app${C_RESET}"
  say "    OpenCode (opencode.json):"
  say "      \"mcp\": { \"sudohomelab\": { \"type\": \"remote\", \"url\": \"$url\","
  say "                 \"headers\": { \"Authorization\": \"Bearer $tok\" } } }"
  say "    Claude Code:  claude mcp add --transport http sudohomelab $url --header \"Authorization: Bearer $tok\""
  say ""
  say "  ${C_GRAY}Keep the token private. New tokens: --rotate. This again: --info${C_RESET}"
}

do_install() {
  banner
  preflight
  mkdir -p "$LOG_DIR" "$INSTALL_DIR"
  # A non-interactive repair keeps the earlier choices; interactive runs ask again.
  if installed && [[ $ASSUME_YES == 1 || ! -r /dev/tty ]]; then
    if [[ -z $PROFILE && -z $TOOLS ]]; then
      TOOLS=$(env_get TOOLS | sed "s/^$ALWAYS_TOOLS,\{0,1\}//"); [[ -n $TOOLS ]] || TOOLS=none
    fi
    [[ -n $TAILSCALE ]] || TAILSCALE=$(env_get TAILSCALE)
  fi
  choose_options
  print_plan
  confirm "Install now?" || { say "  Nothing changed."; exit 0; }
  step "Docker";            install_deps
  step "Source code";       get_source
  step "Secrets";           write_secrets
  step "Embedding models";  get_models
  step "Settings";          write_files
  step "Start";             start_stack; wait_backends
  step "Tailscale";         if [[ $TAILSCALE == on ]]; then setup_tailscale; else info "Skipped (LAN only)"; fi
  [[ $WEBUI == on ]] && TOTAL_STEPS=9
  step "Self-test"
  local out; out=$(self_test 2>&1) || { printf '%s\n' "$out" >>"$LOG_FILE"; die "Self-test failed (see log)."; }
  printf '%s\n' "$out" | sed 's/^/    /'; log "$out"
  ok "MCP answered with the tools above"
  if [[ $WEBUI == on ]]; then step "Open WebUI"; webui_link; fi
  show_info
}

do_status() {
  installed || die "Not installed in $INSTALL_DIR."
  dc ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
  say ""
  curl -s -m 5 "http://127.0.0.1:$P_ROUTER/health" | sed 's/^/  router: /'; echo
  curl -s -m 5 -H "Authorization: Bearer $(env_get MCP_TOKEN)" "http://127.0.0.1:$P_ROUTER/v1/models" |
    tr '{' '\n' | sed -n 's/.*"id":"\([^"]*\)".*/  model: \1/p'
}

do_rotate() {
  installed || die "Not installed."
  confirm "Make a new MCP token and join token? Apps using the old token stop working." || exit 0
  env_set MCP_TOKEN "$(gen_token 40)"; env_set JOIN_TOKEN "$(gen_token 40)"
  run dc up -d --force-recreate gateway router || die "Couldn't restart."
  wait_http "http://127.0.0.1:$P_MCP/health" 60 || warn "gateway slow to restart"
  ok "New tokens. Nodes already joined keep their own node tokens."
  webui_link
  show_info
}

do_update() {
  installed || die "Not installed."
  mkdir -p "$LOG_DIR"
  TOOLS=$(env_get TOOLS); TAILSCALE=$(env_get TAILSCALE); WEBUI=$(env_get WEBUI)
  get_source; write_files; start_stack
  webui_link
  ok "Updated to the newest code; data kept."
}

do_uninstall() {
  installed || { say "  Not installed."; exit 0; }
  if [[ $PURGE == 1 ]]; then
    confirm "Remove the MCP server AND all its data (memory, vault, files) in $INSTALL_DIR?" || exit 0
  else
    confirm "Remove the MCP containers? (data in $INSTALL_DIR stays)" || exit 0
  fi
  run dc down --rmi local --remove-orphans || true
  command -v tailscale >/dev/null && [[ $(env_get TAILSCALE) == on ]] && { run tailscale serve reset || true; }
  if [[ $PURGE == 1 ]]; then rm -rf "$INSTALL_DIR"; ok "Removed everything."
  else ok "Containers removed. Data kept in $INSTALL_DIR (--uninstall --purge deletes it)."; fi
}

# ── Open WebUI ────────────────────────────────────────────────────────────────
# Models come from the router through the connection set in docker-compose, so
# every model a node adds or removes appears / disappears by itself. The MCP
# tool server and "MCP tools on by default for every model" are set with Open
# WebUI's admin API from inside the router container (router/webui.py).
webui_url() {
  local ts; ts=$(ts_name)
  if [[ $(env_get TAILSCALE) == on && -n $ts ]]; then echo "https://$ts:8444"
  else echo "http://$(lan_ip):$P_WEBUI"; fi
}
webui_py() { # webui_py SECRET args… ; the secret (key or password) travels on stdin
  local secret=$1; shift
  printf '%s\n' "$secret" | dc exec -T router python /app/webui.py "$@"
}

webui_link() { # API key (first time), then router connection + MCP tools + defaults
  [[ $(env_get WEBUI) == on ]] || return 0
  local r
  if [[ -z $(env_get WEBUI_KEY) ]]; then
    r=$(webui_py "$(env_get WEBUI_ADMIN_PASSWORD)" bootstrap http://webui:8080 "$(env_get WEBUI_ADMIN_EMAIL)" 2>&1) ||
      { warn "Couldn't get an API key from Open WebUI: ${r##*$'\n'} (try --webui=sync later)"; return 0; }
    env_set WEBUI_KEY "$(jget 'd["api_key"]' <<<"$r")"
  fi
  r=$(webui_py "$(env_get WEBUI_KEY)" sync http://webui:8080 http://router:8791/v1 http://gateway:8790/mcp 2>&1) ||
    { warn "Open WebUI link failed: ${r##*$'\n'}"; return 0; }
  ok "Open WebUI: models from the router + MCP tools on by default ($(jget 'd["models_visible"]' <<<"$r") models now)"
}

do_webui() {
  installed || die "Not installed."
  local cur; cur=$(env_get WEBUI)
  if [[ -z $WEBUI ]]; then
    if [[ $cur == on ]]; then
      case $(menu "Open WebUI is installed ($(webui_url))" 1 "Refresh its link (router models + MCP tools)" \
             "Remove it (chats and users stay in $INSTALL_DIR/data/webui)" "Back") in
        1) WEBUI=sync ;; 2) WEBUI=remove ;; *) return 0 ;;
      esac
    else
      case $(menu "Open WebUI is not installed" 1 "Install it" "Back") in 1) WEBUI=install ;; *) return 0 ;; esac
    fi
  fi
  case $WEBUI in
    install)
      [[ $cur != on ]] || { ok "Open WebUI is already installed."; webui_link; return 0; }
      WEBUI=on; TOOLS=$(env_get TOOLS); TAILSCALE=$(env_get TAILSCALE)
      write_secrets; write_files
      info "Pulling Open WebUI (about 4 GB the first time)…"
      run dc pull webui || die "Couldn't pull $WEBUI_IMAGE."
      run dc up -d webui || die "Couldn't start Open WebUI."
      info "Starting Open WebUI (the first start takes a few minutes)…"
      wait_http "http://127.0.0.1:$P_WEBUI/health" 600 || die "Open WebUI didn't start (dc logs webui)."
      [[ $TAILSCALE == on ]] && { run tailscale serve --bg --https=8444 "http://127.0.0.1:$P_WEBUI" || true; }
      webui_link; show_info ;;
    sync) [[ $cur == on ]] || die "Open WebUI is not installed."; webui_link ;;
    remove)
      [[ $cur == on ]] || { say "  Open WebUI is not installed."; return 0; }
      confirm "Remove the Open WebUI container? (chats and users stay in $INSTALL_DIR/data/webui)" || return 0
      run dc rm -sf webui || true
      WEBUI=none; TOOLS=$(env_get TOOLS); TAILSCALE=$(env_get TAILSCALE)
      env_set WEBUI none; sed -i '/^WEBUI_KEY=/d' "$INSTALL_DIR/.env"; write_files
      command -v tailscale >/dev/null && { run tailscale serve --https=8444 off || true; }
      ok "Open WebUI removed (its data is kept)." ;;
  esac
}

# ── Models (router) ───────────────────────────────────────────────────────────
# No model is installed by this script: these connect model servers the user
# already runs. The checks run inside the router container (admin.py), so they
# see the network exactly the way the router does.
admin() { # admin args… ; the API key travels on stdin, never on a command line
  printf '%s\n' "$M_KEY" | dc exec -T router python /app/admin.py "$@" --key-stdin
}
jget() { # jget 'python expression on d' <<<json
  dc exec -T router python -c "import json,sys; d=json.load(sys.stdin); print($1)"
}
model_rows() { admin list 2>/dev/null || true; }

do_models() {
  installed || die "Not installed."
  local rows id node model status ctx def url
  rows=$(model_rows)
  say ""
  if [[ -z $rows ]]; then
    say "  No models yet. Connect one you already run: --add-model (or the menu)."
    return
  fi
  say "  ${C_BOLD}Models in the router${C_RESET}  (apps ask for model@machine, or \"default\")"
  printf '    %-44s %-9s %-8s\n' "MODEL@MACHINE" "STATUS" "CONTEXT"
  while IFS='|' read -r id node model status ctx def url; do
    printf '    %-44s %-9s %-8s %s\n' "$model@$node" "$status" "$([[ $ctx == 0 ]] && echo "?" || echo "$ctx")" \
      "${def:+${C_GREEN}<- default${C_RESET}}"
  done <<<"$rows"
  say ""
  say "  ${C_GRAY}Router: $(router_url)/v1 (same token as the MCP)${C_RESET}"
}

do_add_model() {
  installed || die "Not installed."
  banner
  say "  Connect a model server you ALREADY run. Nothing is installed or changed on"
  say "  that machine; the router only sends it requests."
  say ""
  say "  ${C_GRAY}Usual ports: Ollama 11434 · llama.cpp 8080 · LM Studio 1234 · vLLM 8000."
  say "  It must listen on the network (not only localhost) and its firewall must allow it.${C_RESET}"
  say ""
  [[ -n $M_URL ]] || M_URL=$(ask "Address of the model server (IP:port)" "")
  [[ -n $M_URL ]] || die "No address given."
  local pr ok
  info "Checking $M_URL from the router…"
  pr=$(admin probe "$M_URL") || die "The check didn't run."
  ok=$(jget 'd["ok"]' <<<"$pr")
  if [[ $ok != True && $(jget 'd.get("needs_key", False)' <<<"$pr") == True && -z $M_KEY ]] &&
     has_tty && [[ $ASSUME_YES == 0 ]]; then
    M_KEY=$(ask_secret "That server needs an API key")
    pr=$(admin probe "$M_URL"); ok=$(jget 'd["ok"]' <<<"$pr")
  fi
  if [[ $ok != True ]]; then
    err "$(jget 'd["error"]' <<<"$pr")"
    say "    $(jget 'd.get("hint", "")' <<<"$pr")"
    exit 1
  fi
  local base engine i picks chosen="" ids=()
  base=$(jget 'd["base_url"]' <<<"$pr"); engine=$(jget 'd["engine"]' <<<"$pr")
  mapfile -t ids < <(jget '"\n".join(m["id"] for m in d["models"])' <<<"$pr")
  ok "Found $engine at $base with ${#ids[@]} model(s):"
  for i in "${!ids[@]}"; do printf '    %d) %s\n' $((i + 1)) "${ids[$i]}"; done
  if [[ -z $M_IDS ]]; then
    picks=$(ask "Which to add (numbers, comma separated; a = all)" "a")
    if [[ $picks == a ]]; then M_IDS=all
    else
      for i in ${picks//,/ }; do [[ $i =~ ^[0-9]+$ && -n ${ids[$((i - 1))]:-} ]] && chosen+="${ids[$((i - 1))]},"; done
      M_IDS=${chosen%,}
    fi
  fi
  [[ -n $M_IDS ]] || die "No models picked."
  [[ $M_IDS == all ]] && M_IDS=$(IFS=,; echo "${ids[*]}")
  if [[ -z $M_NAME ]]; then
    M_NAME=$(ask "Name for that machine (models show as model@name)" \
      "$(sed -E 's#^https?://##; s#[:/].*##; s/\./-/g' <<<"$base")")
  fi
  M_NAME=$(tr 'A-Z' 'a-z' <<<"$M_NAME" | tr -cd 'a-z0-9._-')
  [[ -n $M_NAME ]] || die "Invalid machine name."

  local m t
  for m in ${M_IDS//,/ }; do
    info "Testing $m: a short chat, then a tool call (a big model can take a minute)…"
    t=$(admin test "$base" "$m") || { warn "The test of $m didn't run."; continue; }
    if [[ $(jget 'd.get("chat")' <<<"$t") == True ]]; then ok "$m answers ($(jget 'd.get("seconds", "?")' <<<"$t") s)"
    else warn "$m didn't answer: $(jget 'd.get("error", "")' <<<"$t")"; fi
    if [[ $(jget 'd.get("tools")' <<<"$t") == True ]]; then ok "$m can call tools, so it can use the MCP tools"
    else warn "$m didn't call the test tool: it can chat, but may not use the MCP tools (llama.cpp needs --jinja; Ollama needs a model with tool support)."; fi
  done
  confirm "Add $M_IDS from $M_NAME to the router?" || { say "  Nothing changed."; exit 0; }
  admin add "$M_NAME" "$base" "$M_IDS" >/dev/null || die "The router didn't accept it (see above)."
  ok "Added."
  do_models
}

pick_model_row() { # pick_model_row "question" → the chosen row
  local rows i=1 row node model status def
  rows=$(model_rows)
  [[ -n $rows ]] || die "The router has no models."
  while IFS='|' read -r _ node model status _ def _; do
    printf '    %d) %s@%s  [%s]%s\n' "$i" "$model" "$node" "$status" "${def:+  (default)}" >/dev/tty
    i=$((i + 1))
  done <<<"$rows"
  i=$(ask "$1 (number)" "")
  [[ $i =~ ^[0-9]+$ ]] && row=$(sed -n "${i}p" <<<"$rows") && [[ -n $row ]] || die "No such number."
  echo "$row"
}

do_remove_model() {
  installed || die "Not installed."
  local node model row n
  if [[ -z $M_REF ]]; then
    { has_tty && [[ $ASSUME_YES == 0 ]]; } || die "Say which: --model=MACHINE or --model=MODEL@MACHINE"
    row=$(pick_model_row "Remove which")
    IFS='|' read -r _ node model _ _ _ _ <<<"$row"
    n=$(model_rows | awk -F'|' -v n="$node" '$2 == n' | wc -l)
    M_REF="$model@$node"
    if (( n > 1 )) && [[ $(menu "$node has $n models" 1 "Remove only $model" "Remove the whole machine $node") == 2 ]]; then
      M_REF=$node
    fi
  fi
  confirm "Remove $M_REF from the router? (nothing changes on that machine)" || exit 0
  local why
  if [[ $M_REF == *@* ]]; then why=$(admin remove "${M_REF##*@}" "${M_REF%@*}" 2>&1) || die "Couldn't remove it: ${why##*$'
'}"
  else why=$(admin remove "$M_REF" 2>&1) || die "Couldn't remove it: ${why##*$'
'}"; fi
  ok "Removed $M_REF from the router"
  do_models
}

do_default_model() {
  installed || die "Not installed."
  local row node model
  if [[ -z $M_REF ]]; then
    { has_tty && [[ $ASSUME_YES == 0 ]]; } || die "Say which: --model=MODEL@MACHINE"
    row=$(pick_model_row "Default model")
    IFS='|' read -r _ node model _ _ _ _ <<<"$row"
    M_REF="$model@$node"
  fi
  local why; why=$(admin default "$M_REF" 2>&1) || die "Couldn't set it: ${why##*$'
'}"
  ok "Default model: $M_REF (apps that ask for \"default\" get this one)"
}

run_action() {
  case $1 in
    install) do_install ;;
    status) do_status ;;
    info) installed || die "Not installed."; show_info ;;
    rotate) do_rotate ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
    webui) do_webui ;;
    models) do_models ;;
    add-model) do_add_model ;;
    remove-model) do_remove_model ;;
    default-model) do_default_model ;;
  esac
}

main() {
  parse_args "$@"
  mkdir -p "$LOG_DIR"
  if [[ -n $ACTION ]]; then run_action "$ACTION"; return; fi
  if ! has_tty || [[ $ASSUME_YES == 1 ]]; then run_action install; return; fi
  banner
  # The menu comes back after each action. Each one runs in a subshell, so an
  # error returns here instead of closing the script; Quit leaves.
  while :; do
    if ! installed; then
      case $(menu "MCP server" 1 "Install" "Quit") in 1) ACTION=install ;; *) return 0 ;; esac
    else
      case $(menu "MCP server is installed. What now?" 2 \
             "Install / repair / change tools (keeps data)" "List models" "Add model (one you already run)" \
             "Remove model" "Set default model" "Status" "Connection info + join code" \
             "Open WebUI (install, refresh, remove)" "Rotate tokens" "Update" "Uninstall" "Quit") in
        1) ACTION=install ;; 2) ACTION=models ;; 3) ACTION=add-model ;; 4) ACTION=remove-model ;;
        5) ACTION=default-model ;; 6) ACTION=status ;; 7) ACTION=info ;; 8) ACTION=webui ;;
        9) ACTION=rotate ;; 10) ACTION=update ;; 11) ACTION=uninstall ;; *) return 0 ;;
      esac
    fi
    ( run_action "$ACTION" ) || true
    [[ $ACTION == uninstall ]] && ! installed && return 0
    WEBUI=""; M_URL=""; M_NAME=""; M_IDS=""; M_KEY=""; M_REF=""; PURGE=0
    read -r -p "  ${C_GRAY}Enter = back to the menu${C_RESET} " _ </dev/tty || true
  done
}

[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
