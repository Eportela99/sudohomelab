#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Beszel agent (any Linux machine → your Beszel hub)
#  https://github.com/Eportela99/sudohomelab
#
#  Adds this machine to a Beszel hub (from the Monitoring Stack, or any Beszel).
#  The agent dials out to the hub, so nothing on this machine is opened up.
#    · With --hub, --key and --token (the command the hub's installer printed),
#      it installs straight away.
#    · Without them it asks for the hub's address and your Beszel login, fetches
#      the key and token itself, and gives the machine the default alerts
#      (down, CPU, RAM, disk).
#  Docker installed and running → the agent runs as a container (Docker stats
#  included). No Docker → Beszel's official installer sets it up as a service
#  (systemd, OpenRC or procd; daily auto-updates). Docker is never installed
#  just for the agent.
#
#  Usage:
#    sudo bash -c "$(curl -fsSL <url>/beszel-agent.sh)"                       (asks)
#    sudo bash -c "$(curl -fsSL <url>/beszel-agent.sh)" _ --hub=http://192.168.1.50:8090 --key='ssh-ed25519 …' --token=…
#    sudo bash -c "$(curl -fsSL <url>/beszel-agent.sh)" _ --uninstall
#    sudo bash beszel-agent.sh --help
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.0"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/linux/beszel-agent.sh"
INSTALL_DIR="/opt/sudohomelab/beszel-agent"   # docker mode: compose file + agent data
HUB_STACK_DIR="/opt/sudohomelab/monitoring"   # the Monitoring Stack (it has its own agent)
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/beszel-agent-$(date +%Y%m%d-%H%M%S).log"
PROJECT="sudohomelab-beszel-agent"
AGENT_IMAGE="henrygd/beszel-agent:latest"
OFFICIAL_INSTALLER="https://get.beszel.dev"

HUB=""             # http://192.168.1.50:8090
KEY=""             # the hub's public key (ssh-ed25519 …)
TOKEN=""           # universal token
EMAIL=""           # Beszel login (option B)
PASSWORD=""
NAME=""            # name in the hub (default: this machine's hostname)
MODE=""            # docker | service (default: docker when Docker runs)
ACTION=""          # install | uninstall
ASSUME_YES=0
DRY_RUN=0
PURGE=0

# ── UI ────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'
  C_GREEN=$'\e[38;5;84m'; C_CYAN=$'\e[38;5;81m'; C_PURPLE=$'\e[38;5;141m'
  C_YELLOW=$'\e[38;5;221m'; C_RED=$'\e[38;5;203m'; C_GRAY=$'\e[38;5;245m'
  IS_TTY=1
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_CYAN=""; C_PURPLE=""
  C_YELLOW=""; C_RED=""; C_GRAY=""; IS_TTY=0
fi

STEP=0
TOTAL_STEPS=4
CURRENT_STEP="starting"

# Logs may be attached to public GitHub issues: secrets are masked, colours stripped.
log() {
  local m="$*" s
  for s in "$TOKEN" "$PASSWORD"; do [[ ${#s} -ge 4 ]] && m=${m//"$s"/***}; done
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$(sed -E 's/\x1b\[[0-9;]*m//g' <<<"$m")" >>"$LOG_FILE"
}
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "OK   $*"; }
info() { printf '  %s›%s %s\n' "$C_CYAN" "$C_RESET" "$*"; log "INFO $*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "WARN $*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "ERR  $*"; }

die() {
  err "$*"
  printf '\n  %sFull log:%s %s\n\n' "$C_GRAY" "$C_RESET" "$LOG_FILE" >&2
  exit 1
}

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sBeszel agent: add this machine to your hub%s %sv%s · Linux%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

step() {
  STEP=$((STEP + 1))
  CURRENT_STEP="$1"
  printf '\n%s━━ %s[%d/%d]%s %s%s%s\n' "$C_PURPLE" "$C_GRAY" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  log "════ STEP $STEP/$TOTAL_STEPS: $1"
}

LIVE_LINES=6
clean_output() { tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; /^[[:space:]]*$/d'; }

live_view() { # live_view pid "message" log-offset
  local pid=$1 msg=$2 off=$3 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS drawn=0 cols n k l
  local -a lines
  cols=$(tput cols 2>/dev/null || echo 100); (( cols >= 40 )) || cols=100
  printf '\e[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    mapfile -t lines < <(tail -c +"$off" "$LOG_FILE" 2>/dev/null | clean_output | tail -n "$LIVE_LINES")
    (( drawn )) && printf '\e[%dA' "$drawn"
    printf '\r\e[2K  %s%s%s %s %s%ss%s\n' "$C_CYAN" "${frames:i++%10:1}" "$C_RESET" "$msg" "$C_GRAY" "$((SECONDS - start))" "$C_RESET"
    n=1
    for l in "${lines[@]}"; do
      printf '\e[2K    %s│ %s%s\n' "$C_GRAY" "${l:0:$((cols - 8))}" "$C_RESET"
      n=$((n + 1))
    done
    for (( k = n; k < drawn; k++ )); do printf '\e[2K\n'; done
    (( n > drawn )) && drawn=$n
    sleep 0.2
  done
  printf '\e[%dA' "$drawn"
  for (( k = 0; k < drawn; k++ )); do printf '\e[2K\n'; done
  printf '\e[%dA\e[?25h' "$drawn"
}

run() { # run "message" command [args...]: live view on a terminal, indented stream otherwise
  local msg=$1; shift
  LAST_RUN="$msg"
  log "\$ $*"
  local rc=0
  if (( IS_TTY )); then
    local off
    off=$(( $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) + 1 ))
    ( trap - ERR; "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$!
    live_view "$pid" "$msg" "$off"
    wait "$pid" || rc=$?
  else
    printf '  %s›%s %s\n' "$C_CYAN" "$C_RESET" "$msg"
    ( trap - ERR; set -o pipefail; "$@" </dev/null 2>&1 | tee -a "$LOG_FILE" | clean_output | sed 's/^/    │ /' ) || rc=$?
  fi
  if (( rc == 0 )); then ok "$msg"; else err "$msg (exit $rc)"; return "$rc"; fi
}

on_error() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  printf '\n%s┏━ Installation failed ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_RED" "$C_RESET" >&2
  printf '%s┃%s Step:    %s\n' "$C_RED" "$C_RESET" "$CURRENT_STEP" >&2
  [[ $cmd == return* && -n ${LAST_RUN:-} ]] && cmd="$LAST_RUN"
  printf '%s┃%s Failed:  %s (line %s, exit %s)\n' "$C_RED" "$C_RESET" "$cmd" "$line" "$rc" >&2
  printf '%s┃%s Log:     %s\n' "$C_RED" "$C_RESET" "$LOG_FILE" >&2
  printf '%s┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_RED" "$C_RESET" >&2
  printf '%sLast lines of the log:%s\n' "$C_GRAY" "$C_RESET" >&2
  uniq "$LOG_FILE" 2>/dev/null | tail -n 25 | sed 's/^/    /' >&2
  printf '\nThe script is safe to re-run.\n' >&2
  printf 'Report issues: https://github.com/Eportela99/sudohomelab/issues (attach the log)\n\n' >&2
  log "FAILED at line $line: $cmd (exit $rc)"
  exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Prompts (read from /dev/tty so `curl | bash` still works) ─────────────────
tty_foreground() {
  local pgid tpgid
  read -r pgid tpgid < <(ps -o pgid=,tpgid= -p $$ 2>/dev/null) || return 1
  [[ -n $tpgid && $tpgid != -1 && $pgid == "$tpgid" ]]
}
has_tty() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null && tty_foreground; }
run_hint() { echo "sudo bash -c \"\$(curl -fsSL $SCRIPT_URL)\"${1:+ _$1}"; }

check_interactive() {
  (( ASSUME_YES )) && return 0
  [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null || return 0
  tty_foreground && return 0
  local args="" a
  for a in "${ORIG_ARGS[@]}"; do args+=" $(printf '%q' "$a")"; done
  printf '\n  %s✗%s This script may ask you questions, but %scurl | sudo bash%s runs it in the background,\n' "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
  printf '    so it can'"'"'t read your answers. Run it like this instead:\n\n' >&2
  printf '      %s%s%s\n\n' "$C_CYAN" "$(run_hint "$args")" "$C_RESET" >&2
  exit 1
}

ask() { # ask "question" default → echoes answer
  local q=$1 def=${2:-} ans
  if (( ASSUME_YES )) || ! has_tty; then echo "$def"; return; fi
  printf '  %s?%s %s %s[%s]%s ' "$C_PURPLE" "$C_RESET" "$q" "$C_GRAY" "$def" "$C_RESET" >/dev/tty
  IFS= read -r ans </dev/tty || true
  echo "${ans:-$def}"
}
ask_secret() {
  local q=$1 ans
  printf '  %s?%s %s ' "$C_PURPLE" "$C_RESET" "$q" >/dev/tty
  IFS= read -rs ans </dev/tty || true
  printf '\n' >/dev/tty
  echo "$ans"
}
confirm() { local a; a=$(ask "$1 (Y/n)" "y"); [[ ${a,,} =~ ^y(es)?$ ]]; }

menu() { # menu "title" default "label|desc" ... → echoes chosen index (1-based)
  local title=$1 def=$2; shift 2
  local n=$# i=1 choice
  if (( ASSUME_YES )) || ! has_tty; then echo "$def"; return; fi
  {
    printf '\n  %s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
    for opt in "$@"; do
      printf '    %s%d)%s %-14s %s%s%s\n' "$C_GREEN" "$i" "$C_RESET" "${opt%%|*}" "$C_GRAY" "${opt#*|}" "$C_RESET"
      i=$((i + 1))
    done
  } >/dev/tty
  while :; do
    printf '  %s›%s Choose [1-%d] %s(default %d)%s: ' "$C_CYAN" "$C_RESET" "$n" "$C_GRAY" "$def" "$C_RESET" >/dev/tty
    IFS= read -r choice </dev/tty || true
    choice=${choice:-$def}
    [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) && break
    printf '    %sPlease enter a number between 1 and %d.%s\n' "$C_YELLOW" "$n" "$C_RESET" >/dev/tty
  done
  echo "$choice"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
sudo homelab · Beszel agent v$VERSION

Usage: sudo bash beszel-agent.sh [options]
With no options it asks for the hub address and your Beszel login.

Options:
  --hub=URL                  The hub, e.g. http://192.168.1.50:8090
  --key=KEY                  The hub's public key (ssh-ed25519 …)
  --token=TOKEN              The hub's universal token (Beszel → Settings → Tokens)
  --token-file=FILE          The same, read from a file
  --email=ADDRESS            Instead of key + token: your Beszel login …
  --password-file=FILE       … and its password (the key and token are fetched for you)
  --name=NAME                Name in the hub (default: $(hostname 2>/dev/null || echo "the hostname"))
  --mode=docker|service      Container or system service (default: container when
                             Docker is running, otherwise a service)
  --uninstall                Remove the agent from this machine (keeps its data)
  --purge                    With --uninstall, also delete its data
  -y, --yes                  Non-interactive
  --dry-run                  Show what would happen, change nothing
  -h, --help                 Show this help
EOF
}

read_secret_file() { [[ -r $1 ]] || { echo "Can't read $1" >&2; exit 2; }; head -n1 "$1" | tr -d '\r\n'; }
parse_args() {
  for arg in "$@"; do
    case $arg in
      --hub=*) HUB=${arg#*=} ;;
      --key=*) KEY=${arg#*=} ;;
      --token=*) TOKEN=${arg#*=} ;;
      --token-file=*) TOKEN=$(read_secret_file "${arg#*=}") || exit 2 ;;
      --email=*) EMAIL=${arg#*=} ;;
      --password-file=*) PASSWORD=$(read_secret_file "${arg#*=}") || exit 2 ;;
      --name=*) NAME=${arg#*=} ;;
      --mode=*) MODE=${arg#*=} ;;
      --uninstall) ACTION=uninstall ;;
      --purge) PURGE=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ -z $MODE || $MODE =~ ^(docker|service)$ ]] || { echo "--mode must be docker or service" >&2; exit 2; }
  (( ! PURGE )) || [[ $ACTION == uninstall ]] || { echo "--purge only goes with --uninstall" >&2; exit 2; }
  ACTION=${ACTION:-install}
  return 0
}

# Secrets never go on a command line: curl reads its config from stdin (-K -).
cq() { local v=$1; v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//$'\r'/}; v=${v//$'\n'/\\n}; printf '"%s"' "$v"; }
ckv() { printf '%s = %s\n' "$1" "$(cq "$2")"; }
SHL_TMP=""
sfile() { local f="$SHL_TMP/$1"; ( umask 077; printf '%s' "$2" >"$f" ); printf '%s' "$f"; }
cleanup() {
  [[ -n $SHL_TMP && -d $SHL_TMP ]] && rm -rf "$SHL_TMP"
  (( IS_TTY )) && printf '\e[?25h'
  return 0
}

docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
dc() { docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
service_installed() { [[ -f /etc/systemd/system/beszel-agent.service || -f /etc/init.d/beszel-agent ]]; }
container_installed() { [[ -f $INSTALL_DIR/docker-compose.yml ]]; }

normalize_hub() { # "192.168.1.50", "192.168.1.50:8090", "http://nas:8090/" → http://host:port
  local h=${1%/}
  [[ $h == http://* || $h == https://* ]] || h="http://$h"
  [[ ${h#*://} == *:* ]] || h="$h:8090"
  echo "$h"
}

is_local_hub() { # is $HUB this machine (any of its addresses)?
  local h=${HUB#*://}; h=${h%%[:/]*}
  [[ $h == localhost || $h == 127.* || $h == "$(hostname)" ]] && return 0
  ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | grep -qxF -- "$h"
}

hub_up() { [[ $(curl -s -m 8 "$HUB/api/health" 2>/dev/null) == *'"code":200'* ]]; }

# ── Option B: log in to the hub, fetch the key and token ──────────────────────
BZ_AUTH=""; BZ_USER_ID=""
bz_api() { # bz_api METHOD PATH [json] → response body; fails on an HTTP error
  local m=$1 p=$2 body=${3:-}
  { ckv url "$HUB$p"; ckv request "$m"
    [[ -n $BZ_AUTH ]] && ckv header "Authorization: $BZ_AUTH"
    if [[ -n $body ]]; then ckv header "Content-Type: application/json"; ckv data "$body"; fi
  } | curl -fsS -m 20 -K -
}

bz_login() {
  local r
  r=$(bz_api POST /api/collections/users/auth-with-password \
    "$(jq -nc --rawfile i "$(sfile id "$EMAIL")" --rawfile p "$(sfile pw "$PASSWORD")" '{identity: $i, password: $p}')" 2>/dev/null) || return 1
  BZ_AUTH=$(jq -r '.token // empty' <<<"$r"); BZ_USER_ID=$(jq -r '.record.id // empty' <<<"$r")
  [[ -n $BZ_AUTH ]]
}

fetch_key_token() {
  local r
  KEY=$(bz_api GET /api/beszel/info | jq -r '.key // empty')
  [[ $KEY == ssh-* ]] || { err "The hub didn't give its key."; return 1; }
  r=$(bz_api GET /api/beszel/universal-token)
  if [[ $(jq -r '.active' <<<"$r") != true ]]; then
    # Turned off in the hub: turn it on for this agent. Permanent only if it was made permanent before.
    r=$(bz_api GET "/api/beszel/universal-token?enable=1&token=$(jq -r .token <<<"$r")")
    info "The hub's universal token was off: turned it on (it switches itself off after an hour)"
  fi
  TOKEN=$(jq -r '.token // empty' <<<"$r")
  [[ -n $TOKEN && $(jq -r .active <<<"$r") == true ]] || { err "The hub didn't give a token: $r"; return 1; }
}

# ── Steps ─────────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint)"
  [[ $(uname -s) == Linux ]] || die "This script is for Linux. On Windows or macOS, use Beszel's own agent installer."
  local pretty="Linux"
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && pretty=$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")
  ok "OS: $pretty · $(uname -m)"
  if [[ -f /etc/version && -d /usr/share/truenas ]] || command -v midclt >/dev/null 2>&1; then
    die "This is TrueNAS: use the TrueNAS version of the Monitoring Stack's agent instead (apps here are managed by TrueNAS)."
  fi
  for c in curl jq; do
    command -v "$c" >/dev/null 2>&1 && continue
    if command -v apt-get >/dev/null 2>&1; then
      run "Installing $c" bash -c "DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install --no-install-recommends $c || { apt-get -y update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends $c; }"
    else
      die "Please install $c first (it's needed to talk to the hub)."
    fi
  done
  [[ -z $NAME ]] && NAME=$(hostname)
  [[ $NAME =~ ^[A-Za-z0-9._\ -]{1,64}$ ]] || die "Name may have letters, numbers, spaces and . _ - (got '$NAME')."
  if [[ -z $MODE ]]; then
    if container_installed; then MODE=docker
    elif service_installed; then MODE=service
    elif docker_ok; then MODE=docker
    else MODE=service; fi
  fi
  [[ $MODE == docker ]] && ! docker_ok && die "--mode=docker needs Docker with the compose plugin running on this machine."
  ok "Name in the hub: $NAME · runs as $( [[ $MODE == docker ]] && echo "a Docker container (Docker stats included)" || echo "a system service")"
  # Another agent (installed by hand, CasaOS, the hub's UI command…) would report this machine twice.
  local other=""
  if command -v docker >/dev/null 2>&1; then
    other=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null |
      awk -F'|' -v p="$PROJECT" '$2 ~ /beszel-agent/ && $3 != p {print "container \"" $1 "\""; exit}')
  fi
  if [[ -n $other ]]; then
    warn "A Beszel agent already runs here ($other)."
    (( ASSUME_YES )) || ! has_tty || confirm "Install another one anyway? (the hub would list this machine twice)" || { info "Cancelled."; exit 0; }
  fi
  if [[ $MODE == service ]] && container_installed; then die "An agent container from this script is already here. Remove it first:  $(run_hint " --uninstall")"; fi
  if [[ $MODE == docker ]] && service_installed; then die "An agent service is already installed here. Remove it first:  $(run_hint " --uninstall")"; fi
}

connect_hub() {
  step "Connecting to the hub"
  local interactive=0
  (( ! ASSUME_YES )) && has_tty && interactive=1
  # Re-run of a container install: reuse what it was set up with.
  if [[ -z $HUB && -f $INSTALL_DIR/.env ]]; then
    HUB=$(sed -n 's/^HUB_URL=//p' "$INSTALL_DIR/.env"); [[ -z $KEY ]] && KEY=$(sed -n 's/^KEY=//p' "$INSTALL_DIR/.env")
    [[ -z $TOKEN ]] && TOKEN=$(sed -n 's/^TOKEN=//p' "$INSTALL_DIR/.env")
    [[ -n $HUB ]] && info "Existing agent found: reusing hub $HUB"
  fi
  while :; do
    if [[ -z $HUB ]]; then
      (( interactive )) || die "Give the hub's address:  --hub=http://192.168.1.50:8090 (with --key and --token, or --email and --password-file)"
      HUB=$(ask "Hub address (IP or IP:port of the machine running Beszel)" "")
      [[ -n $HUB ]] || continue
    fi
    HUB=$(normalize_hub "$HUB")
    if hub_up; then ok "Hub answers: $HUB"; break; fi
    err "Nothing answers at $HUB/api/health"
    (( interactive )) || die "Check the address and that this machine can reach it (firewall, VPN)."
    HUB=""
  done

  # The Monitoring Stack's own hub already has an agent for its machine. (Another
  # hub is fine: the Proxmox host keeps the settings of a hub that runs in a container.)
  if [[ -f $HUB_STACK_DIR/docker-compose.yml ]] && is_local_hub; then
    die "$HUB is this machine's own hub (the Monitoring Stack), which already has an agent for it. Nothing to do here."
  fi

  if [[ -n $KEY && -n $TOKEN ]]; then
    [[ $KEY == ssh-ed25519\ * ]] || die "That key doesn't look right: it starts with ssh-ed25519."
    ok "Using the key and token you gave"
    return 0
  fi
  # Option B: log in and fetch them.
  (( interactive )) || [[ -n $EMAIL && -n $PASSWORD ]] ||
    die "Give --key and --token (the command the hub printed), or --email and --password-file."
  [[ -n $EMAIL ]] || printf '\n  %sYour Beszel login%s %s(used once to fetch the key and token; nothing is saved here)%s\n' "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
  local tries=0
  while :; do
    [[ -n $EMAIL ]] || EMAIL=$(ask "Email" "")
    [[ -n $PASSWORD ]] || PASSWORD=$(ask_secret "Password:")
    bz_login && break
    tries=$((tries + 1))
    err "The hub didn't accept that login."
    (( interactive && tries < 3 )) || die "Couldn't log in to the hub as $EMAIL."
    EMAIL=""; PASSWORD=""
  done
  ok "Logged in as $EMAIL"
  fetch_key_token || die "Couldn't get the key and token from the hub."
  ok "Got the hub's key and token"
}

# Disks besides / (a media drive, a second SSD…): the agent shows their usage too.
extra_filesystems() { # → "mountpoint<TAB>name" per line
  findmnt -rn -o TARGET,FSTYPE 2>/dev/null |
    awk '$2 ~ /^(ext4|xfs|btrfs|zfs|f2fs|ntfs3?|exfat|vfat)$/ && $1 != "/" && $1 !~ /^\/(boot|efi|snap|var\/lib\/docker|run|proc|sys)/ {print $1}' |
    while read -r m; do
      [[ $(df -Pm "$m" 2>/dev/null | awk 'NR==2 {print $2}') -ge 1024 ]] || continue
      printf '%s\t%s\n' "$m" "$(basename "$m" | tr -c 'A-Za-z0-9_.\n-' '_')"
    done | awk -F'\t' '!seen[$2]++'
}

install_container() {
  mkdir -p "$INSTALL_DIR/data"; chmod 700 "$INSTALL_DIR"
  ( umask 077; printf 'HUB_URL=%s\nKEY=%s\nTOKEN=%s\nSYSTEM_NAME=%s\n' "$HUB" "$KEY" "$TOKEN" "$NAME" >"$INSTALL_DIR/.env" )
  local f="$INSTALL_DIR/docker-compose.yml" m n
  cat >"$f" <<EOF
# sudo homelab · Beszel agent. Re-run the script to change settings.
name: $PROJECT
services:
  beszel-agent:
    image: $AGENT_IMAGE
    container_name: $(docker inspect beszel-agent >/dev/null 2>&1 && [[ $(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' beszel-agent) != "$PROJECT" ]] && echo shl-beszel-agent || echo beszel-agent)
    network_mode: host          # real network and disk stats; it dials out, nothing listens here
    env_file: .env
    environment:
      LISTEN: /var/lib/beszel-agent/beszel.sock
    volumes:
      - ./data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF
  while IFS=$'\t' read -r m n; do
    [[ -n $m ]] && printf '      - "%s/.beszel:/extra-filesystems/%s:ro"\n' "$m" "$n" >>"$f"
  done < <(extra_filesystems)
  printf '    restart: unless-stopped\n' >>"$f"
  docker pull "$AGENT_IMAGE"
  dc up -d --force-recreate
}

install_service() {
  local inst="$SHL_TMP/install-agent.sh"
  curl -fsSL "$OFFICIAL_INSTALLER" -o "$inst"
  # The official installer (systemd / OpenRC / procd, daily auto-update timer).
  # The port is only for the hub's older "connect to the agent" mode; ours dials out.
  sh "$inst" -k "$KEY" -t "$TOKEN" -url "$HUB" --auto-update=true </dev/null
  if [[ $NAME != "$(hostname)" ]] && [[ -d /run/systemd/system ]]; then
    mkdir -p /etc/systemd/system/beszel-agent.service.d
    printf '[Service]\nEnvironment="SYSTEM_NAME=%s"\n' "$NAME" >/etc/systemd/system/beszel-agent.service.d/sudohomelab-name.conf
    systemctl daemon-reload
    systemctl restart beszel-agent
  fi
}

agent_logs() {
  if [[ $MODE == docker ]]; then dc logs --since 10m beszel-agent 2>&1
  elif command -v journalctl >/dev/null 2>&1; then journalctl -u beszel-agent --since "-10min" --no-pager 2>&1
  else logread 2>/dev/null | grep -i beszel; fi
}

wait_connected() {
  local i l
  for i in $(seq 1 30); do
    l=$(agent_logs || true)
    grep -q 'WebSocket connected' <<<"$l" && { echo "The agent is connected to the hub"; return 0; }
    sleep 2
  done
  echo "No 'WebSocket connected' in the agent's log yet. Last lines:"
  tail -n 10 <<<"$l"
  return 1
}

install_agent() {
  step "Installing the agent"
  if (( DRY_RUN )); then info "Dry run: would install the agent as a $MODE for hub $HUB, name $NAME"; exit 0; fi
  if [[ $MODE == docker ]]; then run "Starting the agent container" install_container
  else run "Installing the agent service (Beszel's official installer)" install_service; fi
  run "Waiting for the agent to connect" wait_connected
}

# Default alerts for this machine: down, CPU, RAM, disk (only when logged in).
add_alerts() {
  local sys alerts id a n=0
  sys=$(bz_api GET "/api/collections/systems/records?filter=$(jq -rn --arg n "$NAME" '"name=\"" + $n + "\"" | @uri')")
  id=$(jq -r '.items[0].id // empty' <<<"$sys")
  [[ -n $id ]] || { echo "The hub doesn't list $NAME yet"; return 1; }
  alerts=$(bz_api GET "/api/collections/alerts/records?perPage=500&filter=$(jq -rn --arg s "$id" '"system=\"" + $s + "\"" | @uri')" | jq -r '.items[].name')
  for a in "Status 0 0" "CPU 90 10" "Memory 90 10" "Disk 90 10"; do
    set -- $a
    grep -qx "$1" <<<"$alerts" && continue
    bz_api POST /api/collections/alerts/records \
      "$(jq -nc --arg u "$BZ_USER_ID" --arg s "$id" --arg n "$1" --argjson v "$2" --argjson m "$3" '{user: $u, system: $s, name: $n, value: $v, min: $m}')" >/dev/null
    n=$((n + 1))
  done
  echo "$n new alert rule(s): down, CPU > 90%, RAM > 90%, disk > 90% (10 min)"
}

wait_up() {
  local i st
  for i in $(seq 1 30); do
    st=$(bz_api GET "/api/collections/systems/records?filter=$(jq -rn --arg n "$NAME" '"name=\"" + $n + "\"" | @uri')" | jq -r '.items[0].status // empty')
    [[ $st == up ]] && { echo "$NAME is up in the hub"; return 0; }
    echo "waiting for $NAME (${st:-not listed yet})"
    sleep 2
  done
  return 1
}

finish() {
  step "Checking with the hub"
  if [[ -n $BZ_AUTH ]]; then
    run "$NAME shows up in the hub" wait_up
    run "Default alerts for $NAME" add_alerts || warn "Couldn't add the alerts: add them in the hub (the bell icon on $NAME)."
  else
    info "Open $HUB: $NAME is listed there now. Alerts: the bell icon on $NAME"
    info "(or re-run the hub's script with --sync to give every new machine the default alerts)."
  fi
  printf '\n  %s%s★ %s reports to %s%s\n\n' "$C_BOLD" "$C_GREEN" "$NAME" "$HUB" "$C_RESET"
  if [[ $MODE == docker ]]; then
    printf '    %sManage:%s    cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"
  else
    printf '    %sManage:%s    sudo systemctl status beszel-agent · journalctl -u beszel-agent -f %s(updates itself daily)%s\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"
  fi
  printf '    %sUninstall:%s %s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --uninstall")"
  printf '    %sLog:%s       %s\n\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"
}

uninstall() {
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint " --uninstall")"
  if container_installed; then
    (( PURGE )) || info "The agent's data stays in $INSTALL_DIR (--purge deletes it)."
    confirm "Remove the agent container?" || { info "Cancelled."; exit 0; }
    run "Removing the agent container" dc down --remove-orphans
    (( PURGE )) && run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"
  elif service_installed; then
    confirm "Remove the agent service?" || { info "Cancelled."; exit 0; }
    rm -f /etc/systemd/system/beszel-agent.service.d/sudohomelab-name.conf
    run "Removing the agent service (Beszel's official uninstaller)" bash -c "curl -fsSL '$OFFICIAL_INSTALLER' -o '$SHL_TMP/i.sh' && sh '$SHL_TMP/i.sh' -u </dev/null"
  else
    die "No Beszel agent from this script found on this machine."
  fi
  ok "Uninstalled. The machine is still listed in the hub: delete it there (⋯ → Delete) if you want."
}

main() {
  ORIG_ARGS=("$@")
  SHL_TMP=$(mktemp -d /tmp/sudohomelab.XXXXXX); chmod 700 "$SHL_TMP"
  trap cleanup EXIT
  parse_args "$@"
  mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR=/tmp; LOG_FILE="/tmp/$(basename "$LOG_FILE")"; }
  : >"$LOG_FILE" 2>/dev/null || { LOG_FILE=/tmp/$(basename "$LOG_FILE"); : >"$LOG_FILE"; }
  chmod 600 "$LOG_FILE"
  log "sudo homelab beszel-agent v$VERSION · args: $(sed -E 's/(--token=)[^ ]*/\1***/g' <<<"$*")"
  check_interactive
  banner
  if [[ $ACTION == uninstall ]]; then uninstall; return; fi
  preflight
  connect_hub
  install_agent
  finish
  log "install finished"
}

[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
