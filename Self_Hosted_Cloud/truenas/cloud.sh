#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Cloud Stack (Nextcloud + Office, Photos, Passwords, PDF, Notes)
#  for TrueNAS SCALE 24.10+
#  https://github.com/Eportela99/sudohomelab
#
#  The Ubuntu/Debian installer, loaded as a library: same questions, checks and
#  wiring. The differences:
#    · Everything runs as one TrueNAS Custom App ("cloud"); settings and
#      databases in the dataset <pool>/apps/cloud. Nothing is installed on the OS.
#    · Your files go in their own dataset (default <pool>/cloud), so you can
#      snapshot, replicate or share them (SMB) like any other.
#    · The nightly backup is a TrueNAS cron job (System → Advanced → Cron Jobs).
#    · With the Private DNS Stack on this NAS, the app names are added to it.
#
#  Usage (TrueNAS shell): download first, then run the file.
#    curl -fsSL <url>/Self_Hosted_Cloud/truenas/cloud.sh -o /tmp/cloud.sh && sudo bash /tmp/cloud.sh
#  (Not `sudo bash -c "$(curl …)"`: TrueNAS enables sudo's log_subcmds, and
#  sudo 1.9.13 kills a command whose text is the whole script: envp mismatch, exit 137.)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

TN_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main"
LIB_URL="$TN_REPO_RAW/Self_Hosted_Cloud/linux/cloud.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
# The guard line (no auto-run as a library) and the backup hooks must both be there.
tn_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$1" 2>/dev/null && grep -q '^backup_unschedule()' "$1"; }
tn_load_core() {
  local here="" lib
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/cloud.sh ]]; then
    lib="$here/../linux/cloud.sh"
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
SCRIPT_URL="$TN_REPO_RAW/Self_Hosted_Cloud/truenas/cloud.sh"
DNS_SCRIPT_URL="$TN_REPO_RAW/AdBlock_DNS_Proxy/truenas/pihole.sh"
LOG_FILE="$LOG_DIR/cloud-truenas-$(date +%Y%m%d-%H%M%S).log"
APP_NAME=cloud                  # the TrueNAS app
PROJECT="ix-$APP_NAME"          # its compose project: the core's `dc ps/exec` find the containers by it
INSTALL_DIR=""                  # /mnt/<pool>/apps/cloud, set once the pool is known
POOL=""
BACKUP_TAG="sudo homelab Cloud Stack backup"   # the cron job's description: how we find it again

run_hint() { echo "curl -fsSL $SCRIPT_URL -o /tmp/cloud.sh && sudo bash /tmp/cloud.sh${1:+$1}"; }

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
  printf '    %s❯%s %sCloud Stack: Nextcloud + Office, Photos, Passwords, PDF, Notes%s %sv%s · TrueNAS SCALE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash cloud.sh \[action\] \[options\]/Usage: sudo bash cloud.sh [action] [options]   (TrueNAS SCALE)/;
                    /--install-dir=PATH/d; s#(default /srv/cloud)#(default /mnt/<pool>/cloud, a dataset)#'
  cat <<EOF

TrueNAS options:
  --pool=NAME                  Pool for the settings dataset <pool>/apps/$APP_NAME and your
                               files (<pool>/cloud) (default: the Apps pool)
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
  for t in curl python3 ss docker jq openssl; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing; this doesn't look like a standard TrueNAS SCALE."; done
  docker info >/dev/null 2>&1 || die "Docker isn't reachable. Is the Apps service running?"
  ok "Apps running · Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)"
  case $(uname -m) in aarch64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac   # dpkg prints a "disabled" notice on TrueNAS
  MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
  ok "$ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  (( MEM_GB >= 12 )) || info "ZFS uses spare RAM as cache and gives it back when apps need it: the RAM estimate below counts it as used."

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
          opts+=("$p|$( [[ $p == "$docker_pool" ]] && echo "the Apps pool" || echo "pool") · $(zfs list -Ho avail "$p" 2>/dev/null) free")
          [[ $p == "$docker_pool" ]] && def=$i; i=$((i + 1))
        done <<<"$pools"
        POOL=$(sed -n "$(menu "Which pool should hold the settings and your files?" "$def" "${opts[@]}")p" <<<"$pools")
      fi
    fi
    [[ $(mid pool.query "[[\"name\",\"=\",\"$POOL\"]]" | pyj 'len(d)') != 0 ]] || die "Pool '$POOL' doesn't exist."
    INSTALL_DIR="/mnt/$POOL/apps/$APP_NAME"
    ok "Settings: $POOL/apps/$APP_NAME (new dataset)"
    if tn_app_exists "$APP_NAME"; then
      die "A TrueNAS app named '$APP_NAME' already exists and wasn't installed by this script. Remove it in Apps, then re-run."
    fi
  fi
  DATA_DEFAULT="/mnt/$POOL/cloud"

  TZ_NAME=$(mid system.general.config | pyj 'd.get("timezone") or "Etc/UTC"'); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "NAS IP: $HOST_IP"
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n $dev ]] && ip -4 addr show dev "$dev" 2>/dev/null | grep -q "inet $HOST_IP/.* dynamic"; then
    warn "$HOST_IP comes from DHCP. Your phones and the certificate use it: reserve it on your router (or set a static IP in Network)."
  fi
}

# The Private DNS Stack's TrueNAS version keeps its settings in <pool>/apps/pihole.
dns_local_domain() {
  local f
  f=$(ls -1 /mnt/*/apps/pihole/.state 2>/dev/null | head -n1 || true)
  [[ -n $f ]] && tn_app_exists pihole && sed -n 's/^DOMAIN=//p' "$f" | tail -n1
  return 0
}

# ── TrueNAS prep (instead of installing Docker) ──────────────────────────────
tn_ensure_dataset() { # tn_ensure_dataset pool/path
  local ds=$1 parent=${1%/*}
  [[ $(mid pool.dataset.query "[[\"id\",\"=\",\"$ds\"]]" | pyj 'len(d)') != 0 ]] && return 0
  [[ $parent != "$ds" && $parent == */* ]] && tn_ensure_dataset "$parent"
  mid pool.dataset.create "{\"name\": \"$ds\", \"share_type\": \"GENERIC\"}" >/dev/null
  echo "created dataset $ds"
}

install_deps() {
  step "Preparing TrueNAS"
  run "Dataset $POOL/apps/$APP_NAME (settings and databases)" tn_ensure_dataset "$POOL/apps/$APP_NAME"
  chmod 700 "$INSTALL_DIR"
  # Your files: a dataset of their own when they're on a pool (and it doesn't exist yet).
  if [[ ! -d $DATA_DIR && $DATA_DIR =~ ^/mnt/([^/]+)/(.+)$ ]] &&
     [[ $(mid pool.query "[[\"name\",\"=\",\"${BASH_REMATCH[1]}\"]]" | pyj 'len(d)') != 0 ]]; then
    run "Dataset ${DATA_DIR#/mnt/} (your files)" tn_ensure_dataset "${DATA_DIR#/mnt/}"
  fi
  ok "$(docker compose version)"
}

# No argon2 tool on TrueNAS (and nothing gets installed on its OS): hash in a throwaway container.
vw_argon2() {
  if command -v argon2 >/dev/null 2>&1; then argon2 "$1" -id -e -k 65540 -t 3 -p 4; return; fi
  docker run --rm -i alpine:3 sh -c 'apk add -q --no-cache argon2 >/dev/null && argon2 "$1" -id -e -k 65540 -t 3 -p 4' _ "$1"
}

# ── The Custom App ────────────────────────────────────────────────────────────
# `docker compose config` copies env files into the services' settings, where the
# TrueNAS page would show the passwords: point those services back at the files.
tn_render() { # the compose file with paths resolved, as TrueNAS wants it
  docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" config --format json >"$INSTALL_DIR/.compose.json"
  python3 - "$INSTALL_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
path = os.path.join(d, ".compose.json")
c = json.load(open(path))
c.pop("name", None)                      # TrueNAS names the project ix-<app>
files = {"collabora": ".collabora.env", "immich-server": ".immich.env", "immich-machine-learning": ".immich.env",
         "immich-db": ".immich.env", "vaultwarden": ".vaultwarden.env", "stirling-pdf": ".stirling.env"}
for svc, name in files.items():
    s = c["services"].get(svc)
    f = os.path.join(d, name)
    if not s or not os.path.exists(f):
        continue
    keys = [l.split("=", 1)[0].strip() for l in open(f) if "=" in l and not l.lstrip().startswith("#")]
    env = s.get("environment") or {}
    for k in keys:
        env.pop(k, None)
    s["environment"] = env
    s["env_file"] = [f]
json.dump(c, open(path, "w"), indent=1)
PY
  chmod 600 "$INSTALL_DIR/.compose.json"
}

tn_deploy() {
  run "Rendering the compose file for TrueNAS" tn_render
  local cfg; cfg=$(<"$INSTALL_DIR/.compose.json")
  if tn_app_exists "$APP_NAME"; then
    run "Updating TrueNAS app '$APP_NAME'" tn_job app.update "[\"$APP_NAME\", {\"custom_compose_config\": $cfg}]"
  else
    run "Creating TrueNAS app '$APP_NAME' (the first start takes a few minutes)" tn_job app.create \
      "[{\"custom_app\": true, \"app_name\": \"$APP_NAME\", \"custom_compose_config\": $cfg}]"
  fi
}

start_stack() {
  step "Starting the apps"
  pull_images
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  tn_deploy
}

# Vaultwarden reads its env file again when TrueNAS redeploys the app.
vw_lock() {
  local h
  h=$(vw_hash)
  ( umask 077; vw_env false "$h" >"$INSTALL_DIR/.vaultwarden.env" )
  tn_job app.redeploy "[\"$APP_NAME\"]"
}

# ── Backups: a TrueNAS cron job ───────────────────────────────────────────────
tn_cron_id() { mid cronjob.query "[[\"description\",\"=\",\"$BACKUP_TAG\"]]" | pyj 'd[0]["id"] if d else ""'; }
backup_schedule() { # backup_schedule script
  local body id
  body=$(jq -nc --arg c "$1" --arg d "$BACKUP_TAG" \
    '{command: $c, description: $d, user: "root", enabled: true, stdout: false, stderr: true,
      schedule: {minute: "30", hour: "3", dom: "*", month: "*", dow: "*"}}')
  id=$(tn_cron_id)
  if [[ -n $id ]]; then mid cronjob.update "$id" "$body" >/dev/null; echo "updated cron job $id"
  else mid cronjob.create "$body" >/dev/null; echo "created cron job \"$BACKUP_TAG\""; fi
}
backup_scheduled() { [[ -n $(tn_cron_id) ]] && echo "TrueNAS cron job, 3:30 every night"; }
backup_unschedule() { local id; id=$(tn_cron_id); [[ -z $id ]] || mid cronjob.delete "$id" >/dev/null; }

manage_hint() {
  printf '    %sManage:%s    TrueNAS → Apps → %s. Settings: %s\n' "$C_GRAY" "$C_RESET" "$APP_NAME" "$INSTALL_DIR"
}

copy_fn load_install core_load_install
load_install() {
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "Nothing is installed yet. Install first:  $(run_hint " --install")"
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
  [[ -f $INSTALL_DIR/.state ]] || die "No Cloud Stack from this script found on this NAS."
  DATA_DIR=$(state_get DATA_DIR)
  local mode data_ds=""
  mode=$(state_get HTTPS_MODE)
  [[ -n $DATA_DIR && $(mid pool.dataset.query "[[\"mountpoint\",\"=\",\"$DATA_DIR\"]]" | pyj 'len(d)') != 0 ]] && data_ds=${DATA_DIR#/mnt/}
  warn "This removes Nextcloud and the other apps of the Cloud Stack (TrueNAS app '$APP_NAME')."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|settings, databases and your files stay: re-run the installer to bring it all back" \
      "Delete settings|delete the $POOL/apps/$APP_NAME dataset (databases…); keep your files in ${DATA_DIR:-?}" \
      "Delete all|also delete your files: ${data_ds:-${DATA_DIR:-?}}") in
      2) PURGE=1 ;;
      3) PURGE=1; DELETE_FILES=1 ;;
    esac
  fi
  if (( DELETE_FILES )) && [[ -n $DATA_DIR ]]; then
    warn "Your files in $DATA_DIR (Documents, Notes, Photos, Immich uploads, backups) will be DELETED."
    if (( ! ASSUME_YES )) && has_tty; then
      [[ $(ask "Type DELETE to confirm" "") == DELETE ]] || { info "Cancelled. Nothing was changed."; exit 0; }
    fi
  elif (( PURGE )); then
    warn "The dataset $POOL/apps/$APP_NAME will be deleted (calendars, contacts, Immich albums, your vault…)."
    info "Your files in $DATA_DIR stay."
  else
    info "Everything stays in $INSTALL_DIR and $DATA_DIR."
  fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  if tn_app_exists "$APP_NAME"; then
    run "Removing TrueNAS app '$APP_NAME'" tn_job app.delete "[\"$APP_NAME\", {\"remove_images\": false}]"
  fi
  run "Removing the nightly backup job" backup_unschedule
  if (( PURGE )); then
    run "Deleting dataset $POOL/apps/$APP_NAME" mid pool.dataset.delete "$POOL/apps/$APP_NAME" '{"recursive": true}'
  fi
  if (( DELETE_FILES )) && [[ -n $DATA_DIR ]]; then
    if [[ -n $data_ds ]]; then run "Deleting dataset $data_ds" mid pool.dataset.delete "$data_ds" '{"recursive": true}'
    elif [[ $DATA_DIR != / ]]; then run "Deleting $DATA_DIR" rm -rf "$DATA_DIR"; fi
  fi
  [[ $mode == dns ]] && info "The app names (cloud.…) stay in the DNS stack: delete them from its menu."
  ok "Uninstalled."
}

# ── Menu + actions: the core's, after finding the install ────────────────────
copy_fn run_action core_run_action
run_action() { tn_find_install; core_run_action; }
copy_fn choose_action core_choose_action
choose_action() { tn_find_install; core_choose_action; }

main "$@"
