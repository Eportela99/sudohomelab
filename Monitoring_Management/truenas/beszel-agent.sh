#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Beszel agent for TrueNAS SCALE 24.10+
#  https://github.com/Eportela99/sudohomelab
#
#  Adds this NAS to a Beszel hub on another machine (the Monitoring Stack, or
#  any Beszel). The Linux agent script, loaded as a library: same questions and
#  checks. The differences:
#    · The agent runs as a TrueNAS Custom App ("beszel-agent"), its data in the
#      dataset <pool>/apps/beszel-agent. Nothing is installed on the TrueNAS OS.
#    · It reads the hub's key and token from files in the dataset, so the token
#      doesn't show in the app's settings page.
#
#  Usage (TrueNAS shell): download first, then run the file. It asks for the
#  hub address and your Beszel login, and fetches the key and token itself.
#    curl -fsSL <url>/Monitoring_Management/truenas/beszel-agent.sh -o /tmp/beszel-agent.sh && sudo bash /tmp/beszel-agent.sh
#  (TrueNAS's sudo logs every command line: give the token as --token-file, or
#  log in, rather than --token=.)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

TN_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management"
LIB_URL="$TN_REPO_RAW/linux/beszel-agent.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
# The guard line (no auto-run as a library) and the manage_hint hook must both be there.
tn_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$1" 2>/dev/null && grep -q '^manage_hint()' "$1"; }
tn_load_core() {
  local here="" lib
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/beszel-agent.sh ]]; then
    lib="$here/../linux/beszel-agent.sh"
  else
    lib=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$lib" || { echo "Couldn't download the agent script from $LIB_URL" >&2; exit 1; }
    # Right after a release GitHub can still serve an older copy for a few minutes.
    tn_core_ok "$lib" || curl -fsSL "$LIB_URL?t=$(date +%s)" -o "$lib" || true
  fi
  tn_core_ok "$lib" || { echo "The agent script at $LIB_URL is an older version (GitHub's cache). Try again in 5 minutes." >&2; exit 1; }
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$lib"
}
tn_load_core

# ── TrueNAS defaults (override the core's) ────────────────────────────────────
VERSION="0.1.0-truenas (core $VERSION)"
SCRIPT_URL="$TN_REPO_RAW/truenas/beszel-agent.sh"
LOG_FILE="$LOG_DIR/beszel-agent-truenas-$(date +%Y%m%d-%H%M%S).log"
APP_NAME=beszel-agent           # the TrueNAS app
PROJECT="ix-$APP_NAME"          # its compose project: the core's `dc logs` find the container by it
INSTALL_DIR=""                  # /mnt/<pool>/apps/beszel-agent, set once the pool is known
POOL=""
MODE=docker

run_hint() { echo "curl -fsSL $SCRIPT_URL -o /tmp/beszel-agent.sh && sudo bash /tmp/beszel-agent.sh${1:+$1}"; }

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }   # copy_fn existing new_name
pyj() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
mid() { midclt call "$@"; }

# Big payloads (the compose file) go to the middleware through its Python client
# and a temp file: on the command line, TrueNAS's sudo (log_subcmds) would log
# them and kill the command (exit 137).
tn_call() { # tn_call method 'JSON array of args' [job] → prints the result
  local f rc=0
  f=$(mktemp /tmp/sudohomelab-call.XXXXXX); chmod 600 "$f"; printf '%s' "$2" >"$f"
  python3 - "$1" "$f" "${3:-}" <<'PY' || rc=$?
import json, sys
try:
    from truenas_api_client import Client
except ImportError:
    from middlewared.client import Client
method, path, job = sys.argv[1], sys.argv[2], sys.argv[3] == "job"
args = json.load(open(path))
last = [None]
def progress(j):
    p = (j or {}).get("progress") or {}
    line = f'[{p.get("percent") or 0:>3}%] {p.get("description") or ""}'.rstrip()
    if line != last[0]:
        print(line, flush=True); last[0] = line
try:
    with Client() as c:
        try:
            res = c.call(method, *args, job=job, callback=progress) if job else c.call(method, *args)
        except TypeError:
            res = c.call(method, *args, job=job)
except Exception as e:
    print(f"TrueNAS {method} failed: {e}", file=sys.stderr); sys.exit(1)
if isinstance(res, dict) and "name" in res:
    print(f"→ {res.get('name')}: {res.get('state', 'ok')}")
PY
  rm -f "$f"
  return "$rc"
}
tn_job() { tn_call "$1" "$2" job; }
tn_app_exists() { [[ $(mid app.query "[[\"name\",\"=\",\"$1\"]]" | pyj 'len(d)') != 0 ]]; }

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sBeszel agent%s %sv%s · TrueNAS SCALE%s\n\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash beszel-agent.sh \[options\]/Usage: sudo bash beszel-agent.sh [options]   (TrueNAS SCALE)/; /--mode=docker|service/,/otherwise a service)/d'
  cat <<EOF

TrueNAS options:
  --pool=NAME                Pool for the dataset <pool>/apps/$APP_NAME (default: the Apps pool)

On TrueNAS, sudo logs every command line: pass the token with --token-file,
or log in (no --key/--token), instead of --token=.
EOF
}

copy_fn parse_args core_parse_args
parse_args() {
  local rest=() arg
  for arg in "$@"; do
    case $arg in
      --pool=*) POOL=${arg#*=} ;;
      --mode=*) [[ ${arg#*=} == docker ]] || { echo "On TrueNAS the agent always runs as a TrueNAS app (no --mode=service)." >&2; exit 2; } ;;
      --token=*) TOKEN_ON_CMDLINE=1; rest+=("$arg") ;;
      *) rest+=("$arg") ;;
    esac
  done
  core_parse_args "${rest[@]}"
}
TOKEN_ON_CMDLINE=0

# An install from this script: the dataset with our settings.
tn_find_install() {
  [[ -n $INSTALL_DIR ]] && return 0
  local f
  f=$(ls -1 /mnt/*/apps/"$APP_NAME"/.env 2>/dev/null | head -n1 || true)
  if [[ -n $f ]]; then
    INSTALL_DIR=${f%/.env}; POOL=$(cut -d/ -f3 <<<"$f")
  else
    INSTALL_DIR=/nonexistent/sudohomelab-$APP_NAME   # nothing installed yet
  fi
}

# The Monitoring Stack on this same NAS already has an agent for its own hub.
HUB_STACK_DIR=$(ls -1d /mnt/*/apps/monitoring 2>/dev/null | head -n1 || true)
[[ -n $HUB_STACK_DIR ]] || HUB_STACK_DIR=/nonexistent/sudohomelab-monitoring

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint)"
  command -v midclt >/dev/null 2>&1 || die "This is the TrueNAS version, but midclt isn't here. On other Linux machines use the Linux script."
  local ver major minor
  ver=$(mid system.version 2>/dev/null | tr -d '"') || die "Couldn't talk to the TrueNAS middleware (midclt)."
  major=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1/' <<<"$ver"); minor=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\2/' <<<"$ver")
  (( major > 24 || (major == 24 && minor >= 10) )) ||
    die "$ver uses the old Kubernetes apps. This needs TrueNAS SCALE 24.10 (Electric Eel) or newer."
  ok "$ver"
  [[ $(mid docker.status | pyj 'd.get("status", "")') == RUNNING ]] ||
    die "TrueNAS Apps isn't running. Open Apps → Configuration → Choose Pool, pick a pool, then re-run."
  local t
  for t in curl jq python3 docker; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing; this doesn't look like a standard TrueNAS SCALE."; done
  ok "Apps running · Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)"
  (( TOKEN_ON_CMDLINE )) && warn "TrueNAS's sudo logged that command line, token included. Next time use --token-file, or log in instead."

  tn_find_install
  if [[ -f $INSTALL_DIR/.env ]]; then
    ok "Settings: $INSTALL_DIR (existing agent)"
  else
    if [[ -z $POOL ]]; then
      local pools n
      pools=$(mid pool.query | pyj '"\n".join(p["name"] for p in d)')
      [[ -n $pools ]] || die "No storage pool found. Create one in Storage first."
      n=$(wc -l <<<"$pools")
      if (( n == 1 )); then POOL=$pools; else
        local opts=() p def=1 i=1 docker_pool
        docker_pool=$(mid docker.config | pyj 'd.get("pool") or ""')
        while read -r p; do
          opts+=("$p|$( [[ $p == "$docker_pool" ]] && echo "the Apps pool" || echo "pool")")
          [[ $p == "$docker_pool" ]] && def=$i; i=$((i + 1))
        done <<<"$pools"
        POOL=$(sed -n "$(menu "Which pool should hold the agent's data ($APP_NAME dataset)?" "$def" "${opts[@]}")p" <<<"$pools")
      fi
    fi
    [[ $(mid pool.query "[[\"name\",\"=\",\"$POOL\"]]" | pyj 'len(d)') != 0 ]] || die "Pool '$POOL' doesn't exist."
    INSTALL_DIR="/mnt/$POOL/apps/$APP_NAME"
    if tn_app_exists "$APP_NAME"; then
      die "A TrueNAS app named '$APP_NAME' already exists and wasn't installed by this script. Remove it in Apps, then re-run."
    fi
  fi

  [[ -z $NAME ]] && NAME=$(hostname)
  [[ $NAME =~ ^[A-Za-z0-9._\ -]{1,64}$ ]] || die "Name may have letters, numbers, spaces and . _ - (got '$NAME')."
  ok "Name in the hub: $NAME · runs as TrueNAS app '$APP_NAME' (Docker stats of every app included)"
  # A Beszel agent from the catalog, or installed by hand, would report this NAS twice.
  local other
  other=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null |
    awk -F'|' -v p="$PROJECT" '$2 ~ /beszel-agent/ && $3 != p && $3 != "ix-monitoring" {print "container \"" $1 "\""; exit}')
  if [[ $'\n'$(docker ps --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null)$'\n' == *$'\n'ix-monitoring$'\n'* ]]; then
    info "This NAS also runs a Monitoring Stack: its own agent keeps reporting there, this one reports to the other hub"
  fi
  if [[ -n $other ]]; then
    warn "A Beszel agent already runs here ($other)."
    (( ASSUME_YES )) || ! has_tty || confirm "Install another one anyway? (the hub would list this NAS twice)" || { info "Cancelled."; exit 0; }
  fi
}

# ── The Custom App ───────────────────────────────────────────────────────────
# Settings and the key/token live in the dataset (root only). The app's settings
# only point at the files: TrueNAS shows an app's environment on its page.
tn_ensure_dataset() { # tn_ensure_dataset pool/path
  local ds=$1 parent=${1%/*}
  [[ $(mid pool.dataset.query "[[\"id\",\"=\",\"$ds\"]]" | pyj 'len(d)') != 0 ]] && return 0
  [[ $parent != "$ds" && $parent == */* ]] && tn_ensure_dataset "$parent"
  mid pool.dataset.create "{\"name\": \"$ds\", \"share_type\": \"GENERIC\"}" >/dev/null
  echo "created dataset $ds"
}

install_container() {
  tn_ensure_dataset "$POOL/apps/$APP_NAME"
  mkdir -p "$INSTALL_DIR/data"; chmod 700 "$INSTALL_DIR"
  ( umask 077
    printf 'HUB_URL=%s\nKEY=%s\nTOKEN=%s\nSYSTEM_NAME=%s\n' "$HUB" "$KEY" "$TOKEN" "$NAME" >"$INSTALL_DIR/.env"
    printf '%s\n' "$KEY" >"$INSTALL_DIR/data/key"
    printf '%s\n' "$TOKEN" >"$INSTALL_DIR/data/token" )
  local f="$INSTALL_DIR/docker-compose.yml"
  # ZFS datasets report their own size, not the pool's, so no extra disks:
  # TrueNAS alerts on pool space itself. The agent shows the boot pool.
  cat >"$f" <<EOF
# sudo homelab · Beszel agent (TrueNAS app "$APP_NAME"). Re-run the script to change settings.
name: $PROJECT
services:
  beszel-agent:
    image: $AGENT_IMAGE
    network_mode: host          # real network and disk stats; it dials out, nothing listens here
    environment:
      HUB_URL: "$HUB"
      SYSTEM_NAME: "$NAME"
      KEY_FILE: /var/lib/beszel-agent/key
      TOKEN_FILE: /var/lib/beszel-agent/token
      LISTEN: /var/lib/beszel-agent/beszel.sock
    volumes:
      - ./data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
EOF
  docker pull "$AGENT_IMAGE"
  docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$f" config --format json |
    python3 -c 'import json, sys; c = json.load(sys.stdin); c.pop("name", None); json.dump(c, sys.stdout)' >"$INSTALL_DIR/.compose.json"
  chmod 600 "$INSTALL_DIR/.compose.json"
  local cfg; cfg=$(<"$INSTALL_DIR/.compose.json")
  if tn_app_exists "$APP_NAME"; then
    tn_job app.update "[\"$APP_NAME\", {\"custom_compose_config\": $cfg}]"
    # Same settings (only the key/token files changed): the app wasn't recreated.
    dc restart beszel-agent
  else
    tn_job app.create "[{\"custom_app\": true, \"app_name\": \"$APP_NAME\", \"custom_compose_config\": $cfg}]"
  fi
}

copy_fn install_agent core_install_agent
install_agent() {
  step "Installing the agent"
  if (( DRY_RUN )); then info "Dry run: would install TrueNAS app '$APP_NAME' in $POOL/apps/$APP_NAME for hub $HUB, name $NAME"; exit 0; fi
  AGENT_SINCE=$(date +%s)
  run "TrueNAS app '$APP_NAME' (Beszel agent)" install_container
  run "Waiting for the agent to connect" wait_connected
}

manage_hint() {
  printf '    %sManage:%s    TrueNAS → Apps → %s (updates: the app'"'"'s Update button). Data: %s\n' "$C_GRAY" "$C_RESET" "$APP_NAME" "$INSTALL_DIR"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint " --uninstall")"
  tn_find_install
  [[ -f $INSTALL_DIR/.env ]] || tn_app_exists "$APP_NAME" || die "No Beszel agent from this script found on this NAS."
  (( PURGE )) || info "The agent's data stays in $INSTALL_DIR (--purge deletes the $POOL/apps/$APP_NAME dataset)."
  confirm "Remove the agent (TrueNAS app '$APP_NAME')?" || { info "Cancelled."; exit 0; }
  if tn_app_exists "$APP_NAME"; then
    run "Removing TrueNAS app '$APP_NAME'" tn_job app.delete "[\"$APP_NAME\", {\"remove_images\": false}]"
  fi
  if (( PURGE )) && [[ -n $POOL ]]; then
    run "Deleting dataset $POOL/apps/$APP_NAME" mid pool.dataset.delete "$POOL/apps/$APP_NAME" '{"recursive": true}'
  fi
  ok "Uninstalled. The NAS is still listed in the hub: delete it there (⋯ → Delete) if you want."
}

main "$@"
