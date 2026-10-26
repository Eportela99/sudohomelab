#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Private DNS Stack (Pi-hole + Unbound + Nginx Proxy Manager)
#  for TrueNAS SCALE 24.10+
#  https://github.com/Eportela99/sudohomelab
#
#  The Ubuntu/Debian installer, loaded as a library: same questions, lists,
#  checks and app names. The differences:
#    · Everything runs as one TrueNAS Custom App ("pihole"), settings in the
#      dataset <pool>/apps/pihole. Nothing is installed on the TrueNAS OS.
#    · TrueNAS's own web interface holds ports 80/443, which the app names
#      need. It offers to move it (default 8000/8443), checks that it answers
#      there and moves it back if not. Uninstall puts it back.
#    · The daily blocklist update is a TrueNAS cron job.
#
#  Usage (TrueNAS shell): download first, then run the file.
#    curl -fsSL <url>/AdBlock_DNS_Proxy/truenas/pihole.sh -o /tmp/pihole.sh && sudo bash /tmp/pihole.sh
#  (Not `sudo bash -c "$(curl …)"`: TrueNAS enables sudo's log_subcmds, and
#  sudo 1.9.13 kills a command whose text is the whole script: envp mismatch, exit 137.)
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

TN_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy"
LIB_URL="$TN_REPO_RAW/linux/pihole.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
tn_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$1" 2>/dev/null && grep -q '^refresh_scheduled()' "$1"; }
tn_load_core() {
  local here="" lib
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/pihole.sh ]]; then
    lib="$here/../linux/pihole.sh"
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
SCRIPT_URL="$TN_REPO_RAW/truenas/pihole.sh"
LOG_FILE="$LOG_DIR/pihole-truenas-$(date +%Y%m%d-%H%M%S).log"
APP_NAME=pihole                 # the TrueNAS app
PROJECT="ix-$APP_NAME"          # its compose project: the core's `dc ps/exec` find the containers by it
INSTALL_DIR=""                  # /mnt/<pool>/apps/pihole, set once the pool is known
POOL=""
MOVE_UI=""                      # yes | no: move TrueNAS's web interface off 80/443
UI_HTTP=""; UI_HTTPS=""         # where it is now
TN_NEW_HTTP=8000; TN_NEW_HTTPS=8443
TN_CRON_DESC="sudo homelab: update Pi-hole blocklists"

run_hint() { echo "curl -fsSL $SCRIPT_URL -o /tmp/pihole.sh && sudo bash /tmp/pihole.sh${1:+$1}"; }

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
  printf '    %s❯%s %sPi-hole + Unbound + Nginx Proxy Manager%s %sv%s · TrueNAS SCALE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash pihole.sh \[action\] \[options\]/Usage: sudo bash pihole.sh [action] [options]   (TrueNAS SCALE)/; /--install-dir=PATH/d'
  cat <<EOF

TrueNAS options:
  --pool=NAME                        Pool for the settings dataset <pool>/apps/pihole
                                     (default: the Apps pool)
  --move-ui | --keep-ui              Move TrueNAS's web interface to ports $TN_NEW_HTTP/$TN_NEW_HTTPS so the app
                                     names get 80/443 (default: asked, move), or leave it
                                     (app names then need a port, like https://jellyfin.home:8443)
EOF
}

copy_fn parse_args core_parse_args
parse_args() {
  local rest=() arg
  for arg in "$@"; do
    case $arg in
      --pool=*) POOL=${arg#*=} ;;
      --move-ui) MOVE_UI=yes ;;
      --keep-ui) MOVE_UI=no ;;
      --install-dir=*) echo "On TrueNAS the settings go in <pool>/apps/pihole: use --pool=NAME" >&2; exit 2 ;;
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
    INSTALL_DIR=/nonexistent/sudohomelab-pihole   # nothing installed yet
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
  ok "$(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"

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
      die "A TrueNAS app named '$APP_NAME' already exists and wasn't installed by this script (catalog Pi-hole?). Remove it in Apps, then re-run."
    fi
  fi

  TZ_NAME=$(mid system.general.config | pyj 'd.get("timezone") or "Etc/UTC"'); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "NAS IP: $HOST_IP"
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n $dev ]] && ip -4 addr show dev "$dev" 2>/dev/null | grep -q "inet $HOST_IP/.* dynamic"; then
    DYNAMIC_IP=1
    warn "$HOST_IP comes from DHCP. A DNS server needs a fixed address: reserve it on your router (or set a static IP in Network)."
  fi
}

# ── TrueNAS's web interface on 80/443 ────────────────────────────────────────
tn_ui_ports() { mid system.general.config | pyj '"%s %s" % (d["ui_port"], d["ui_httpsport"])'; }
tn_ui_host() { mid system.general.config | pyj '"127.0.0.1" if "0.0.0.0" in (d.get("ui_address") or ["0.0.0.0"]) else d["ui_address"][0]'; }
tn_port_free() { [[ -z $(ss -Htuln "sport = :$1" 2>/dev/null) ]] && [[ -z $(published_owners "$1" 2>/dev/null) ]]; }
tn_next_free() { local p=$1; while ! tn_port_free "$p" || [[ $p == "${2:-}" ]]; do p=$((p + 1)); done; echo "$p"; }

tn_ask_ui() {
  read -r UI_HTTP UI_HTTPS < <(tn_ui_ports)
  if [[ $UI_HTTP != 80 && $UI_HTTPS != 443 ]]; then
    MOVE_UI=no
    ok "TrueNAS's web interface is on ports $UI_HTTP/$UI_HTTPS: 80 and 443 are free for the app names"
    return 0
  fi
  if [[ -z $MOVE_UI ]]; then
    if (( ASSUME_YES )) || ! has_tty; then MOVE_UI=yes
    else
      printf '\n  %sTrueNAS'"'"'s web interface uses ports %s/%s%s %s(the app names need them for plain https://jellyfin.%s)%s\n' \
        "$C_BOLD" "$UI_HTTP" "$UI_HTTPS" "$C_RESET" "$C_GRAY" "$DOMAIN" "$C_RESET" >/dev/tty
      case $(menu "Move TrueNAS's web interface?" 1 \
        "Move it|TrueNAS moves to https://$HOST_IP:$TN_NEW_HTTPS (and https://truenas.$DOMAIN). Checked, and put back if it doesn't answer" \
        "Keep it|TrueNAS stays; app names then need a port, like https://jellyfin.$DOMAIN:8443") in
        1) MOVE_UI=yes ;; *) MOVE_UI=no ;;
      esac
    fi
  fi
  if [[ $MOVE_UI == yes ]]; then
    TN_NEW_HTTP=$(tn_next_free "$TN_NEW_HTTP")
    TN_NEW_HTTPS=$(tn_next_free "$TN_NEW_HTTPS" "$TN_NEW_HTTP")
    # Keep Pi-hole's own admin ports off the ones TrueNAS moves to.
    local v
    for v in P_WEB P_WEBS P_NPM; do
      [[ ${!v} == "$TN_NEW_HTTP" || ${!v} == "$TN_NEW_HTTPS" ]] && printf -v "$v" '%s' "$(next_free_port "$v")"
    done
    ok "TrueNAS's web interface will move to http://$HOST_IP:$TN_NEW_HTTP and https://$HOST_IP:$TN_NEW_HTTPS"
  fi
}

# Ports: TrueNAS's nginx on 80/443 doesn't count when it's moving away, and
# the ports it moves to do.
copy_fn conflicts core_conflicts
conflicts() {
  if [[ $MOVE_UI == yes ]]; then
    [[ $1 == "$TN_NEW_HTTP" || $1 == "$TN_NEW_HTTPS" ]] && { echo "truenas|ui|the TrueNAS web interface (moving there)"; return 0; }
    if [[ $1 == "$UI_HTTP" || $1 == "$UI_HTTPS" ]]; then core_conflicts "$@" | grep -v 'nginx' || true; return 0; fi
  fi
  core_conflicts "$@" | sed 's/service nginx.service ("nginx")/the TrueNAS web interface/'
}

copy_fn check_port53 core_check_port53
check_port53() {
  tn_ask_ui
  local o
  o=$(conflicts 53 both)
  if [[ -n $o ]]; then
    err "Port 53 (DNS) is in use on this NAS. Pi-hole needs it."
    while IFS='|' read -r _ _ label; do info "Used by: $label"; done <<<"$o"
    die "Stop or remove that app (Apps) or service first, then re-run. On TrueNAS I don't stop things for you."
  fi
  core_check_port53
}

# Moves the web interface and checks it answers there; if not, moves it back.
# It runs as its own systemd unit, so it finishes (or rolls back) even if this
# shell is the TrueNAS web shell and gets cut off while the interface restarts.
tn_ui_set() { # tn_ui_set http https
  local h=$1 s=$2 oh os host f=/tmp/sudohomelab-ui-move.sh st=/tmp/sudohomelab-ui-move.status i
  read -r oh os < <(tn_ui_ports)
  [[ $oh == "$h" && $os == "$s" ]] && { echo "Already on $h/$s"; return 0; }
  host=$(tn_ui_host)
  rm -f "$st"
  cat >"$f" <<EOF
#!/bin/bash
# sudo homelab: move the TrueNAS web interface to $h/$s, back to $oh/$os if it doesn't answer.
up() { local i c; for i in \$(seq 1 45); do c=\$(curl -sk -o /dev/null -m 3 -w '%{http_code}' "https://$host:\$1/"); [[ \$c != 000 ]] && return 0; sleep 2; done; return 1; }
if midclt call system.general.update '{"ui_port": $h, "ui_httpsport": $s}' >/dev/null && midclt call system.general.ui_restart >/dev/null && up $s; then
  echo moved >$st
else
  midclt call system.general.update '{"ui_port": $oh, "ui_httpsport": $os}' >/dev/null
  midclt call system.general.ui_restart >/dev/null
  up $os && echo "rolled back" >$st || echo "rolled back, not answering" >$st
fi
rm -f "$f"
EOF
  chmod 700 "$f"
  systemd-run --unit="sudohomelab-ui-move-$$" --collect --quiet /bin/bash "$f"
  for i in $(seq 1 120); do [[ -s $st ]] && break; sleep 1; done
  [[ -s $st ]] || { echo "No answer from the move after 2 minutes (journalctl -u sudohomelab-ui-move-$$)"; return 1; }
  echo "Web interface: $(<"$st") ($(tn_ui_ports | tr ' ' /))"
  [[ $(<"$st") == moved ]]
}

tn_wait_free() { # tn_wait_free port... : the old nginx can hold a port a moment after a restart
  local p i
  for p in "$@"; do
    for i in $(seq 1 30); do tn_port_free "$p" && break; sleep 1; done
  done
}

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
  if [[ $MOVE_UI == yes ]]; then
    [[ -n $(state_get TN_UI_ORIG) ]] || state_set TN_UI_ORIG "$UI_HTTP,$UI_HTTPS"
    info "Moving TrueNAS's web interface. In the TrueNAS web shell this page reconnects; if it doesn't,"
    info "open https://$HOST_IP:$TN_NEW_HTTPS and run the same command again (it picks up where it stopped)."
    if run "Moving TrueNAS's web interface to $TN_NEW_HTTP/$TN_NEW_HTTPS" tn_ui_set "$TN_NEW_HTTP" "$TN_NEW_HTTPS"; then
      tn_wait_free "$UI_HTTP" "$UI_HTTPS"
      ok "TrueNAS is now at https://$HOST_IP:$TN_NEW_HTTPS"
    else
      die "TrueNAS's web interface didn't answer on $TN_NEW_HTTPS, so it was moved back to $UI_HTTP/$UI_HTTPS. Re-run and choose Keep it."
    fi
  fi
  run "Downloading Pi-hole" docker pull "$IMAGE"
  [[ $UPSTREAM == unbound ]] && run "Downloading Unbound" docker pull "$UNBOUND_IMAGE"
  run "Downloading Nginx Proxy Manager (about 1.9 GB on disk)" docker pull "$NPM_IMAGE"
  return 0
}

# ── Step 6: the Custom App ───────────────────────────────────────────────────
tn_render() { # the compose file with paths resolved, as TrueNAS wants it
  docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" config --format json >"$INSTALL_DIR/.compose.json"
  python3 - "$INSTALL_DIR/.compose.json" <<'PY'
import json, sys
path = sys.argv[1]
c = json.load(open(path))
c.pop("name", None)                      # TrueNAS names the project ix-<app>
json.dump(c, open(path, "w"), indent=1)
PY
}

start_pihole() {
  step "Starting Pi-hole"
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  run "Rendering the compose file for TrueNAS" tn_render
  LOGS_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local cfg; cfg=$(<"$INSTALL_DIR/.compose.json")
  if tn_app_exists "$APP_NAME"; then
    run "Updating TrueNAS app '$APP_NAME'" tn_job app.update "[\"$APP_NAME\", {\"custom_compose_config\": $cfg}]"
  else
    run "Creating TrueNAS app '$APP_NAME' (Pi-hole, Unbound, proxy)" tn_job app.create \
      "[{\"custom_app\": true, \"app_name\": \"$APP_NAME\", \"custom_compose_config\": $cfg}]"
  fi
  local first=""
  [[ -f $INSTALL_DIR/etc-pihole/gravity.db ]] || first=" (first start downloads the blocklists: a few minutes)"
  run "Waiting for Pi-hole$first" wait_pihole
}

# ── Daily blocklist update: a TrueNAS cron job ───────────────────────────────
tn_cron_id() { mid cronjob.query "[[\"description\",\"=\",\"$TN_CRON_DESC\"]]" | pyj 'd[0]["id"] if d else ""'; }
set_refresh() {
  local id body
  id=$(tn_cron_id)
  if [[ $REFRESH == daily ]]; then
    body=$(jq -nc --arg c "docker exec $PROJECT-pihole-1 pihole -g" --arg d "$TN_CRON_DESC" \
      '{command: $c, description: $d, user: "root", enabled: true, stdout: true, stderr: false,
        schedule: {minute: "17", hour: "4", dom: "*", month: "*", dow: "*"}}')
    if [[ -n $id ]]; then mid cronjob.update "$id" "$body" >/dev/null; else mid cronjob.create "$body" >/dev/null; fi
    echo "TrueNAS cron job: every day at 04:17 (System → Advanced → Cron Jobs)"
  else
    remove_refresh
    echo "Weekly: Pi-hole's built-in schedule"
  fi
}
remove_refresh() { local id; id=$(tn_cron_id); [[ -z $id ]] || mid cronjob.delete "$id" >/dev/null; return 0; }
refresh_scheduled() { [[ -n $(tn_cron_id) ]] && echo "daily at 04:17, TrueNAS cron job"; }

# ── truenas.<ending> → the web interface, when it's off 443 ─────────────────
copy_fn ensure_default_hosts core_ensure_default_hosts
ensure_default_hosts() {
  core_ensure_default_hosts
  local s line gw
  read -r _ s < <(tn_ui_ports)
  [[ $s != "$P_HTTPS" ]] || return 0
  gw=$(state_get GATEWAY_IP)
  line=$(host_line "truenas.$DOMAIN")
  if [[ -z $line ]]; then
    add_host "truenas.$DOMAIN" https "$gw" "$s" && echo "truenas.$DOMAIN → TrueNAS's web interface (port $s)"
  elif [[ $(cut -f4 <<<"$line") != "$s" ]]; then
    npm_api PUT "/nginx/proxy-hosts/${line%%$'\t'*}" "$(jq -nc --arg h "$gw" --argjson p "$s" '{forward_scheme: "https", forward_host: $h, forward_port: $p}')" >/dev/null &&
      echo "truenas.$DOMAIN now goes to port $s"
  fi
  return 0
}

manage_hint() {
  printf '    %sManage:%s    TrueNAS → Apps → %s. Settings: %s\n' "$C_GRAY" "$C_RESET" "$APP_NAME" "$INSTALL_DIR"
}

copy_fn summary core_summary
summary() {
  core_summary
  local o
  o=$(state_get TN_UI_ORIG)
  if [[ -n $o ]]; then
    printf '  %sTrueNAS'"'"'s web interface%s moved from %s to %s: %shttps://%s:%s%s  %s(or %s)%s\n' "$C_BOLD" "$C_RESET" \
      "${o/,//}" "$(tn_ui_ports | tr ' ' /)" "$C_CYAN" "$HOST_IP" "$(tn_ui_ports | awk '{print $2}')" "$C_RESET" "$C_GRAY" "$(name_url "truenas.$DOMAIN")" "$C_RESET"
    printf '  %sUninstall moves it back.%s\n\n' "$C_GRAY" "$C_RESET"
  fi
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  (( BANNER_SHOWN )) || banner
  tn_need_root " --uninstall"
  [[ -f $INSTALL_DIR/.state ]] || die "No Pi-hole from this script found on this NAS."
  warn "This removes Pi-hole, Unbound and the proxy (TrueNAS app '$APP_NAME'). Devices using it for DNS lose name"
  warn "lookups until you point your router back to another DNS server, and the app names stop working."
  local orig
  orig=$(state_get TN_UI_ORIG)
  [[ -n $orig ]] && info "TrueNAS's web interface goes back to ports ${orig/,//}."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the settings?" 1 \
      "Keep them|settings, lists, app names and certificates stay in $INSTALL_DIR for a reinstall" \
      "Delete them|also delete the $POOL/apps/$APP_NAME dataset: settings, app names, certificates, query history") in
      2) PURGE=1 ;;
    esac
  fi
  if (( PURGE )); then warn "The dataset $POOL/apps/$APP_NAME (settings, lists, app names, certificates, query history) will be deleted."
  else info "The data stays in $INSTALL_DIR (re-run the installer to bring everything back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  if tn_app_exists "$APP_NAME"; then
    run "Removing TrueNAS app '$APP_NAME'" tn_job app.delete "[\"$APP_NAME\", {\"remove_images\": false}]"
  fi
  run "Removing the daily blocklist update" remove_refresh
  if [[ -n $orig ]]; then
    local oh=${orig%,*} os=${orig#*,}
    tn_wait_free "$oh" "$os"
    if run "Moving TrueNAS's web interface back to $oh/$os" tn_ui_set "$oh" "$os"; then
      state_set TN_UI_ORIG ""
    else
      warn "It stayed on $(tn_ui_ports | tr ' ' /). Change it in System → General → GUI if you want 80/443 back."
    fi
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
