#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Monitoring Stack (Uptime Kuma + Beszel + ntfy)
#  for TrueNAS SCALE 24.10+
#  https://github.com/Eportela99/sudohomelab
#
#  The Ubuntu/Debian installer, loaded as a library: same questions, checks and
#  wiring. The differences:
#    · Everything runs as one TrueNAS Custom App ("monitoring"), settings in the
#      dataset <pool>/apps/monitoring. Nothing is installed on the TrueNAS OS.
#    · Uptime Kuma also watches TrueNAS's own web interface, and finds your
#      TrueNAS apps (catalog or custom) like any other container.
#    · The NAS's Beszel agent reads its key and token from files in the dataset,
#      so they don't show in the app's settings page.
#
#  Usage (TrueNAS shell): download first, then run the file.
#    curl -fsSL <url>/Monitoring_Management/truenas/monitoring.sh -o /tmp/monitoring.sh && sudo bash /tmp/monitoring.sh
#  (Not `sudo bash -c "$(curl …)"`: TrueNAS enables sudo's log_subcmds, and
#  sudo 1.9.13 kills a command whose text is the whole script: envp mismatch, exit 137.)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

TN_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management"
LIB_URL="$TN_REPO_RAW/linux/monitoring.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
# The guard line (no auto-run as a library) and the agent_up hook must both be there.
tn_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$1" 2>/dev/null && grep -q '^agent_up()' "$1"; }
tn_load_core() {
  local here="" lib
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/monitoring.sh ]]; then
    lib="$here/../linux/monitoring.sh"
  else
    lib=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$lib" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
    # Right after a release GitHub can still serve an older core for a few minutes;
    # an old one would run as a plain Linux installer on the NAS.
    tn_core_ok "$lib" || curl -fsSL "$LIB_URL?t=$(date +%s)" -o "$lib" || true
  fi
  tn_core_ok "$lib" || { echo "The installer core at $LIB_URL is an older version (GitHub's cache). Try again in 5 minutes." >&2; exit 1; }
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$lib"
}
tn_load_core

# ── TrueNAS defaults (override the core's) ────────────────────────────────────
VERSION="0.1.0-truenas (core $VERSION)"
SCRIPT_URL="$TN_REPO_RAW/truenas/monitoring.sh"
LOG_FILE="$LOG_DIR/monitoring-truenas-$(date +%Y%m%d-%H%M%S).log"
APP_NAME=monitoring             # the TrueNAS app
PROJECT="ix-$APP_NAME"          # its compose project: the core's `dc ps/exec` find the containers by it
INSTALL_DIR=""                  # /mnt/<pool>/apps/monitoring, set once the pool is known
POOL=""

run_hint() { echo "curl -fsSL $SCRIPT_URL -o /tmp/monitoring.sh && sudo bash /tmp/monitoring.sh${1:+$1}"; }

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
tn_ui_https() { mid system.general.config | pyj 'd["ui_httpsport"]'; }

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sMonitoring Stack: Uptime Kuma + Beszel + ntfy%s %sv%s · TrueNAS SCALE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash monitoring.sh \[action\] \[options\]/Usage: sudo bash monitoring.sh [action] [options]   (TrueNAS SCALE)/; /--install-dir=PATH/d'
  cat <<EOF

TrueNAS options:
  --pool=NAME                  Pool for the settings dataset <pool>/apps/$APP_NAME
                               (default: the Apps pool)
EOF
}

copy_fn parse_args core_parse_args
parse_args() {
  local rest=() arg
  for arg in "$@"; do
    case $arg in
      --pool=*) POOL=${arg#*=} ;;
      --install-dir=*) echo "On TrueNAS the settings go in <pool>/apps/$APP_NAME: use --pool=NAME" >&2; exit 2 ;;
      *) rest+=("$arg") ;;
    esac
  done
  core_parse_args "${rest[@]}"
}

# An install from this script: the dataset with our state file.
tn_find_install() {
  [[ -n $INSTALL_DIR ]] && return 0
  local f
  f=$(ls -1 /mnt/*/apps/"$APP_NAME"/.state 2>/dev/null | head -n1 || true)
  if [[ -n $f ]]; then
    INSTALL_DIR=${f%/.state}; POOL=$(cut -d/ -f3 <<<"$f")
  else
    INSTALL_DIR=/nonexistent/sudohomelab-$APP_NAME   # nothing installed yet
  fi
}

tn_need_root() {
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint "${1:-}")"
  command -v midclt >/dev/null 2>&1 || die "This is the TrueNAS version, but midclt isn't here. On Ubuntu/Debian use the Linux script."
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  tn_need_root " --install"
  local ver major minor
  ver=$(mid system.version 2>/dev/null | tr -d '"') || die "Couldn't talk to the TrueNAS middleware (midclt)."
  major=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1/' <<<"$ver"); minor=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\2/' <<<"$ver")
  (( major > 24 || (major == 24 && minor >= 10) )) ||
    die "$ver uses the old Kubernetes apps. This installer needs TrueNAS SCALE 24.10 (Electric Eel) or newer."
  ok "$ver"
  [[ $(mid docker.status | pyj 'd.get("status", "")') == RUNNING ]] ||
    die "TrueNAS Apps isn't running. Open Apps → Configuration → Choose Pool, pick a pool, then re-run."
  local t
  for t in curl python3 ss docker jq; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing; this doesn't look like a standard TrueNAS SCALE."; done
  docker info >/dev/null 2>&1 || die "Docker isn't reachable. Is the Apps service running?"
  ok "Apps running · Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)"
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  ok "$ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"

  tn_find_install
  if [[ -f $INSTALL_DIR/.state ]]; then
    ok "Settings: $INSTALL_DIR (existing install)"
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
        POOL=$(sed -n "$(menu "Which pool should hold the settings ($APP_NAME dataset)?" "$def" "${opts[@]}")p" <<<"$pools")
      fi
    fi
    [[ $(mid pool.query "[[\"name\",\"=\",\"$POOL\"]]" | pyj 'len(d)') != 0 ]] || die "Pool '$POOL' doesn't exist."
    INSTALL_DIR="/mnt/$POOL/apps/$APP_NAME"
    ok "Settings: $POOL/apps/$APP_NAME (new dataset)"
    if tn_app_exists "$APP_NAME"; then
      die "A TrueNAS app named '$APP_NAME' already exists and wasn't installed by this script. Remove it in Apps, then re-run."
    fi
  fi

  TZ_NAME=$(mid system.general.config | pyj 'd.get("timezone") or "Etc/UTC"'); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "NAS IP: $HOST_IP"
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n $dev ]] && ip -4 addr show dev "$dev" 2>/dev/null | grep -q "inet $HOST_IP/.* dynamic"; then
    warn "$HOST_IP comes from DHCP. Agents and the ntfy app connect to it: reserve it on your router (or set a static IP in Network)."
  fi
}

# ── What Uptime Kuma can watch here ──────────────────────────────────────────
# Apps from the TrueNAS catalog are compose projects named ix-<app>.
copy_fn stack_of core_stack_of
stack_of() {
  case $1 in
    ix-pihole|ix-mediastack|"$PROJECT") core_stack_of "$1" ;;
    ix-*) echo "TrueNAS app" ;;
    *) core_stack_of "$1" ;;
  esac
}

# Host-network apps: our other stacks keep their settings in <pool>/apps/<stack>.
copy_fn saved_port core_saved_port
saved_port() {
  local v="" f
  case $1 in
    Pi-hole) f=$(ls -1 /mnt/*/apps/pihole/.state 2>/dev/null | head -n1 || true)
             [[ -n $f ]] && v=$(sed -n 's/^P_WEB=//p' "$f" | tail -n1) ;;
    Plex) f=$(ls -1 /mnt/*/apps/mediastack/.env 2>/dev/null | head -n1 || true)
          [[ -n $f ]] && v=$(sed -n 's/^P_PLEX=//p' "$f" | tail -n1) ;;
  esac
  [[ -n $v ]] && echo "$v" || core_saved_port "$@"
}

# TrueNAS's own web interface (wherever its port is: another stack may have moved it).
copy_fn discover core_discover
discover() {
  core_discover
  echo "x:truenas|TrueNAS web interface|url|https://$HOST_IP:$(tn_ui_https)||TrueNAS|1"
  # A stopped TrueNAS app has no containers at all (TrueNAS removes them), so
  # the scan can't see it: keep what the last scan found for it (shown as down).
  local app line
  [[ -f $INSTALL_DIR/$FOUND_FILE ]] || return 0
  for app in $(mid app.query | pyj '" ".join(a["name"] for a in d if a["state"] in ("STOPPED", "CRASHED"))'); do
    while IFS= read -r line; do
      [[ -n $line ]] && mark_found "$line" "stopped now"
    done < <(grep -E "^(c|dns):ix-$app-" "$INSTALL_DIR/$FOUND_FILE" || true)
  done
  return 0
}

# ZFS datasets each report their own size, not the pool's, so the agent's disk
# figures for them would mislead. TrueNAS alerts on pool space itself
# (80/90/95%); the agent shows the boot pool, CPU, RAM, network and temperatures.
extra_filesystems() { return 0; }

# ── Step 4: TrueNAS prep (instead of installing Docker) ──────────────────────
tn_ensure_dataset() { # tn_ensure_dataset pool/path
  local ds=$1 parent=${1%/*}
  [[ $(mid pool.dataset.query "[[\"id\",\"=\",\"$ds\"]]" | pyj 'len(d)') != 0 ]] && return 0
  [[ $parent != "$ds" && $parent == */* ]] && tn_ensure_dataset "$parent"
  mid pool.dataset.create "{\"name\": \"$ds\", \"share_type\": \"GENERIC\"}" >/dev/null
  echo "created dataset $ds"
}

install_deps() {
  step "Preparing TrueNAS"
  run "Dataset $POOL/apps/$APP_NAME (settings)" tn_ensure_dataset "$POOL/apps/$APP_NAME"
  chmod 700 "$INSTALL_DIR"
  ok "$(docker compose version)"
}

# ── Step 5: the Custom App ───────────────────────────────────────────────────
# The agent reads its key and token from files: an env_file would be copied
# into the app's settings, where anyone with the TrueNAS page could read the token.
copy_fn write_agent_env core_write_agent_env
write_agent_env() {
  core_write_agent_env
  mkdir -p "$INSTALL_DIR/beszel-agent"
  ( umask 077
    printf '%s\n' "$BESZEL_KEY" >"$INSTALL_DIR/beszel-agent/key"
    printf '%s\n' "$BESZEL_TOKEN" >"$INSTALL_DIR/beszel-agent/token" )
}
agent_up() { dc restart beszel-agent; }   # same app settings, new key/token files

# TrueNAS's Docker is dual-stack, so host-gateway gives Kuma an IPv6 address
# first, and apps that only listen on IPv4 inside (Tdarr) look down. The IPv4
# gateway is what host-gateway means on IPv4 (re-run if you change the Apps
# address pool).
tn_gateway4() { docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1 || true; }

tn_render() { # the compose file with paths resolved, as TrueNAS wants it
  docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" config --format json >"$INSTALL_DIR/.compose.json"
  python3 - "$INSTALL_DIR/.compose.json" "$(tn_gateway4)" <<'PY'
import json, sys
path, gw = sys.argv[1], sys.argv[2]
c = json.load(open(path))
c.pop("name", None)                      # TrueNAS names the project ix-<app>
k = c["services"].get("kuma")
if k and gw:
    h = k.get("extra_hosts")
    if isinstance(h, dict):
        h["host.docker.internal"] = gw
    else:
        k["extra_hosts"] = [x for x in (h or []) if not x.startswith("host.docker.internal")] + ["host.docker.internal=" + gw]
a = c["services"].get("beszel-agent")
if a:
    a.pop("env_file", None)
    env = a.setdefault("environment", {})
    env.pop("KEY", None); env.pop("TOKEN", None)
    env["KEY_FILE"] = "/var/lib/beszel-agent/key"
    env["TOKEN_FILE"] = "/var/lib/beszel-agent/token"
json.dump(c, open(path, "w"), indent=1)
PY
  chmod 600 "$INSTALL_DIR/.compose.json"
}

start_stack() {
  step "Starting the apps"
  pull_images
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  run "Rendering the compose file for TrueNAS" tn_render
  local cfg; cfg=$(<"$INSTALL_DIR/.compose.json")
  if tn_app_exists "$APP_NAME"; then
    run "Updating TrueNAS app '$APP_NAME'" tn_job app.update "[\"$APP_NAME\", {\"custom_compose_config\": $cfg}]"
  else
    run "Creating TrueNAS app '$APP_NAME' (Uptime Kuma, Beszel, ntfy)" tn_job app.create \
      "[{\"custom_app\": true, \"app_name\": \"$APP_NAME\", \"custom_compose_config\": $cfg}]"
  fi
  run "Waiting for ntfy" wait_http "http://127.0.0.1:$P_NTFY/v1/health" 120 ntfy
  run "Waiting for Beszel" wait_http "http://127.0.0.1:$P_BESZEL/api/health" 120 Beszel
  run "Waiting for Uptime Kuma (first start sets up its database)" wait_http "http://127.0.0.1:$P_KUMA/api/entry-page" 300 "Uptime Kuma"
}

manage_hint() {
  printf '    %sManage:%s    TrueNAS → Apps → %s. Settings: %s\n' "$C_GRAY" "$C_RESET" "$APP_NAME" "$INSTALL_DIR"
}

copy_fn load_install core_load_install
load_install() {
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "Nothing is installed yet. Install first:  $(run_hint " --install")"
  # DEPLOYING is fine: TrueNAS shows it until ntfy's first health check (a minute after a start).
  local st=""
  tn_app_exists "$APP_NAME" && st=$(mid app.query "[[\"name\",\"=\",\"$APP_NAME\"]]" | pyj 'd[0]["state"]')
  [[ $st == RUNNING || $st == DEPLOYING ]] ||
    die "The TrueNAS app '$APP_NAME' isn't running (${st:-missing}). Start it in Apps → $APP_NAME (or re-run Install)."
  core_load_install
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  (( BANNER_SHOWN )) || banner
  tn_need_root " --uninstall"
  [[ -f $INSTALL_DIR/.state ]] || die "No Monitoring Stack from this script found on this NAS."
  warn "This removes Uptime Kuma, Beszel (hub + this NAS's agent), ntfy and the extras (TrueNAS app '$APP_NAME')."
  warn "Agents on other machines keep running but have no hub to report to (remove them with: beszel-agent.sh --uninstall)."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|monitors, history, logins and tokens stay in $INSTALL_DIR for a reinstall" \
      "Delete it|also delete the $POOL/apps/$APP_NAME dataset: monitors, history, accounts, tokens") in
      2) PURGE=1 ;;
    esac
  fi
  if (( PURGE )); then warn "The dataset $POOL/apps/$APP_NAME (monitors, history, accounts, tokens) will be deleted."
  else info "The data stays in $INSTALL_DIR (re-run the installer to bring everything back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  if tn_app_exists "$APP_NAME"; then
    run "Removing TrueNAS app '$APP_NAME'" tn_job app.delete "[\"$APP_NAME\", {\"remove_images\": false}]"
  fi
  if (( PURGE )); then
    run "Deleting dataset $POOL/apps/$APP_NAME" mid pool.dataset.delete "$POOL/apps/$APP_NAME" '{"recursive": true}'
  fi
  ok "Uninstalled."
}

# ── Menu + actions: the core's, after finding the install ────────────────────
copy_fn run_action core_run_action
run_action() { tn_find_install; core_run_action; }
copy_fn choose_action core_choose_action
choose_action() { tn_find_install; core_choose_action; }

main "$@"
