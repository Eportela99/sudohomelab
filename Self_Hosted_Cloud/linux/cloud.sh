#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Cloud Stack: Nextcloud + Office, Photos, Passwords, PDF, Notes
#  (Ubuntu / Debian) · https://github.com/Eportela99/sudohomelab
#
#  Installs as Docker containers, already connected to each other:
#    · Nextcloud    → Postgres + Redis + cron, with Calendar, Tasks, Contacts, Mail,
#                     Deck, Collectives, News, Notes and Office installed
#    · Collabora    → the Office app's editor (Word, Excel, PowerPoint files)
#    · Immich       → photo backup from your phone; also shows the Photos folder
#    · Vaultwarden  → password manager for the Bitwarden apps
#    · Stirling PDF → PDF tools, plus drop folders that OCR / compress on their own
#    · Obsidian     → the real Obsidian in your browser, on the shared Notes folder
#  One folder tree for your files, shared by the apps:
#    <data>/Documents (+ PDF Inbox / PDF Done), <data>/Notes, <data>/Photos
#  HTTPS either through a built-in proxy with its own certificate, or with names
#  like https://cloud.home from the sudo homelab Private DNS Stack.
#
#  Usage (no options = a menu: Install, Lock sign-ups, Back up now, Uninstall, Quit):
#    sudo bash -c "$(curl -fsSL <url>/cloud.sh)"
#    sudo bash -c "$(curl -fsSL <url>/cloud.sh)" _ --install --https=caddy --yes
#    sudo bash -c "$(curl -fsSL <url>/cloud.sh)" _ --uninstall
#    sudo bash cloud.sh --help
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.0"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Self_Hosted_Cloud/linux/cloud.sh"
DNS_SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/linux/pihole.sh"
INSTALL_DIR="/opt/sudohomelab/cloud"
DNS_DIR="/opt/sudohomelab/pihole"   # the Private DNS Stack, if it's on this machine
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/cloud-$(date +%Y%m%d-%H%M%S).log"
PROJECT="sudohomelab-cloud"         # compose project name
BACKUP_UNIT="sudohomelab-cloud-backup"
DATA_DEFAULT="/srv/cloud"           # suggested folder for your files (TrueNAS: a dataset)
NC_IMAGE="nextcloud:stable-apache"
PG_IMAGE="postgres:17-alpine"
REDIS_IMAGE="redis:7-alpine"
COLLABORA_IMAGE="collabora/code:latest"
IMMICH_VERSION="v3"
IMMICH_IMAGE="ghcr.io/immich-app/immich-server:$IMMICH_VERSION"
IMMICH_ML_IMAGE="ghcr.io/immich-app/immich-machine-learning:$IMMICH_VERSION"
IMMICH_DB_IMAGE="ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0"
VALKEY_IMAGE="docker.io/valkey/valkey:9"
VW_IMAGE="vaultwarden/server:latest"
STIRLING_IMAGE="stirlingtools/stirling-pdf:latest"
OBSIDIAN_IMAGE="lscr.io/linuxserver/obsidian:latest"
CADDY_IMAGE="caddy:2-alpine"
WWW_UID=33                          # www-data: Nextcloud, and the others write as it too

APP_USER=""
APP_PASS=""
ADMIN_EMAIL=""     # Immich logs in with an email address
DATA_DIR=""        # your files (default /srv/cloud)
HTTPS_MODE=""      # caddy (built-in proxy + own certificate) | dns (Private DNS Stack names)
DOMAIN=""          # dns mode: the ending, cloud.<DOMAIN>
DNS_HOST=""        # dns mode: "local", or the IP of the machine with the DNS stack
APPS=""            # comma list of: office, photos, ml, vault, pdf, obsidian
APPS_SET=0
TRUSTED_EXTRA=""   # more names/addresses people open Nextcloud with
TRUSTED_SET=0
ACTION=""          # install | lock | backup | uninstall (empty = ask)
ASSUME_YES=0
DRY_RUN=0
PURGE=0
DELETE_FILES=0

# Built-in proxy: one HTTPS port per app. DNS mode: the apps' own (http) ports.
P_HTTPS=443; P_HTTP=80; P_NC=8080; P_OFFICE=9980
P_PHOTOS=2283; P_VAULT=8222; P_PDF=8484; P_NOTES=""
PORT_VARS=(P_HTTPS P_HTTP P_NC P_OFFICE P_PHOTOS P_VAULT P_PDF P_NOTES)   # earlier ones win a clash
APP_IDS=(office photos ml vault pdf obsidian)
NC_APPS=(calendar tasks contacts mail deck collectives news notes)
SHARED=(Documents Notes Photos)    # folders Nextcloud mounts for every user

app_label() {
  case $1 in
    office) echo "Office (Collabora): edit Word, Excel and PowerPoint files inside Nextcloud · 2 GB disk" ;;
    photos) echo "Immich: phone photo backup; also shows the Photos folder · 3.7 GB disk" ;;
    ml) echo "Immich smart search + face recognition · 2 GB more RAM, 3 GB disk" ;;
    vault) echo "Vaultwarden: password manager for the Bitwarden apps · 0.4 GB disk" ;;
    pdf) echo "Stirling PDF: merge, split, OCR, compress (+ drop folders) · 3.7 GB disk" ;;
    obsidian) echo "Obsidian in the browser, opened on the Notes folder · 5.7 GB disk" ;;
  esac
}
nc_app_label() {
  case $1 in
    calendar) echo Calendar ;; tasks) echo Tasks ;; contacts) echo Contacts ;; mail) echo Mail ;;
    deck) echo Deck ;; collectives) echo Collectives ;; news) echo News ;; notes) echo Notes ;;
    richdocuments) echo Office ;; *) echo "$1" ;;
  esac
}

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

NC_DB_PASS=""      # Nextcloud's database
IMMICH_DB_PASS=""  # Immich's database
IM_TOKEN=""        # Immich session while setting it up
STEP=0
TOTAL_STEPS=14     # set in choose_options from the apps you pick
CURRENT_STEP="starting"

# Logs may be attached to public GitHub issues: secrets are masked, colours stripped.
log() {
  local m="$*" s
  for s in "$APP_PASS" "$NC_DB_PASS" "$IMMICH_DB_PASS" "$IM_TOKEN"; do
    [[ ${#s} -ge 4 ]] && m=${m//"$s"/***}
  done
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$(sed -E 's/\x1b\[[0-9;]*m//g' <<<"$m")" >>"$LOG_FILE"
}
say()  { printf '%s\n' "$*"; log "$*"; }
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
  [[ -n ${SHL_NO_BANNER:-} ]] && return 0   # a wrapper (Proxmox) already showed its own
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sCloud Stack: Nextcloud + Office, Photos, Passwords, PDF, Notes%s %sv%s · Ubuntu / Debian%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

step() {
  STEP=$((STEP + 1))
  CURRENT_STEP="$1"
  printf '\n%s━━ %s[%d/%d]%s %s%s%s\n' "$C_PURPLE" "$C_GRAY" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  log "════ STEP $STEP/$TOTAL_STEPS: $1"
}

LIVE_LINES=6   # how many lines of live output to show under a running step

clean_output() { tr '\r' '\n' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; /^[[:space:]]*$/d'; }

# Live view: spinner + elapsed time, with the last few output lines scrolling
# underneath. The window is erased when the step finishes.
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

# run "message" command [args...]: live view on a terminal, indented stream otherwise.
run() {
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
  grep -vE '^[[:space:]]*[0-9a-f]{12} (Downloading|Extracting|Waiting|Verifying|Download complete|Pull complete|Already exists|Pulling fs layer)' \
    "$LOG_FILE" 2>/dev/null | uniq | tail -n 25 | sed 's/^/    /' >&2
  printf '\nThe script is safe to re-run: finished steps are skipped.\n' >&2
  printf 'Report issues: https://github.com/Eportela99/sudohomelab/issues (attach the log)\n\n' >&2
  log "FAILED at line $line: $cmd (exit $rc)"
  exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Prompts (read from /dev/tty so `curl | bash` still works) ─────────────────
# Under `curl ... | sudo bash`, sudo (use_pty) runs the script in the background
# of its own pty: reading /dev/tty then freezes it. So "a terminal exists" isn't enough.
tty_foreground() {
  local pgid tpgid
  read -r pgid tpgid < <(ps -o pgid=,tpgid= -p $$ 2>/dev/null) || return 1
  [[ -n $tpgid && $tpgid != -1 && $pgid == "$tpgid" ]]
}

has_tty() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null && tty_foreground; }

# SHL_HINT_CMD: set by a wrapper (Proxmox) that runs this script for you.
run_hint() { echo "${SHL_HINT_CMD:-sudo bash -c \"\$(curl -fsSL $SCRIPT_URL)\"}${1:+ _$1}"; }

check_interactive() {
  (( ASSUME_YES )) && return 0
  [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null || return 0   # no terminal at all: defaults apply
  tty_foreground && return 0
  local args="" a
  for a in "${ORIG_ARGS[@]}"; do args+=" $(printf '%q' "$a")"; done
  printf '\n  %s✗%s This script asks you questions, but %scurl | sudo bash%s runs it in the background,\n' "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
  printf '    so it can'"'"'t read your answers. Run it like this instead:\n\n' >&2
  printf '      %s%s%s\n\n' "$C_CYAN" "$(run_hint "$args")" "$C_RESET" >&2
  printf '    Or skip the questions:  curl -fsSL <url> | sudo bash -s --%s --yes\n\n' "$args" >&2
  log "aborted: interactive run with stdin piped under sudo (background process group)"
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

confirm() { # confirm "question" (default yes)
  local a
  a=$(ask "$1 (Y/n)" "y")
  [[ ${a,,} =~ ^y(es)?$ ]]
}

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

# Multi-select: type numbers ("1 3"), "a" for all, "n" for none, Enter = default.
multi_select() { # multi_select "title" "default,ids" label_func id... → comma list of chosen ids
  local title=$1 def=$2 label_fn=$3; shift 3
  local ids=("$@") i ans pick picked=() bad defnums=""
  if (( ASSUME_YES )) || ! has_tty; then echo "$def"; return; fi
  for i in "${!ids[@]}"; do [[ ,$def, == *,${ids[i]},* ]] && defnums+="$((i + 1)) "; done
  defnums=${defnums% }
  {
    printf '\n  %s%s%s %s(pick any)%s\n' "$C_BOLD" "$title" "$C_RESET" "$C_GRAY" "$C_RESET"
    for i in "${!ids[@]}"; do
      printf '    %s%2d)%s %s\n' "$C_GREEN" $((i + 1)) "$C_RESET" "$("$label_fn" "${ids[i]}")"
    done
  } >/dev/tty
  while :; do
    printf '  %s›%s Numbers separated by spaces, a = all, n = none %s(default: %s)%s: ' \
      "$C_CYAN" "$C_RESET" "$C_GRAY" "${defnums:-none}" "$C_RESET" >/dev/tty
    IFS= read -r ans </dev/tty || true
    ans=${ans:-${defnums:-n}}
    picked=()
    case ${ans,,} in
      a|all) picked=("${ids[@]}") ;;
      n|none) ;;
      *)
        bad=0
        for pick in ${ans//,/ }; do
          if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then picked+=("${ids[pick - 1]}"); else bad=1; fi
        done
        if (( bad )); then printf '    %sUse numbers 1-%d (e.g. "1 2"), a or n.%s\n' "$C_YELLOW" "${#ids[@]}" "$C_RESET" >/dev/tty; continue; fi
        ;;
    esac
    break
  done
  printf '%s\n' "${picked[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -
}

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
sudo homelab · Cloud Stack (Nextcloud + Office, Photos, Passwords, PDF, Notes) v$VERSION

Usage: sudo bash cloud.sh [action] [options]
With no action it shows a menu.

Actions:
  --install                    Install, or change the settings of an existing install
  --lock-signups               Close Vaultwarden sign-ups (once your account exists)
  --backup                     Back up the databases and Vaultwarden now
  --uninstall                  Remove the containers (keeps settings and your files)
  --purge                      With --uninstall, also delete the apps' settings and databases
  --delete-files               With --purge, also delete your files (the data folder)

Install options:
  --username=NAME              Login for the apps (default admin)
  --password=PASS              Its password (generated if omitted)
  --password-file=FILE         The same, read from a file (keeps it out of the process list)
  --email=ADDRESS              Immich login (default <username>@homelab.local)
  --data-dir=PATH              Your files: Documents, Notes, Photos… (default /srv/cloud)
  --https=caddy|dns            caddy: built-in HTTPS with its own certificate (default)
                               dns: names like https://cloud.home from the Private DNS Stack
  --domain=ENDING              dns: the DNS stack's ending (read from it when it's on this machine)
  --dns-host=IP                dns: the machine with the DNS stack, when it isn't this one
  --apps=LIST                  office,photos,ml,vault,pdf,obsidian (or "none": Nextcloud only)
  --trusted=NAME,...           More names or addresses you open Nextcloud with
  --install-dir=PATH           Compose file, settings and databases (default $INSTALL_DIR)
  -y, --yes                    Non-interactive: accept defaults
  --dry-run                    Show what would happen, change nothing
  -h, --help                   Show this help
USAGE
}

read_secret_file() { [[ -r $1 ]] || { echo "Can't read $1" >&2; exit 2; }; head -n1 "$1" | tr -d '\r\n'; }
set_action() {
  [[ -z $ACTION || $ACTION == "$1" ]] || { echo "Choose one action: --$ACTION or --$1" >&2; exit 2; }
  ACTION=$1
}
parse_args() {
  for arg in "$@"; do
    case $arg in
      --username=*) APP_USER=${arg#*=} ;;
      --password=*) APP_PASS=${arg#*=} ;;
      --password-file=*) APP_PASS=$(read_secret_file "${arg#*=}") || exit 2 ;;
      --email=*) ADMIN_EMAIL=${arg#*=} ;;
      --data-dir=*) DATA_DIR=${arg#*=}; DATA_DIR=${DATA_DIR%/} ;;
      --https=*) HTTPS_MODE=${arg#*=} ;;
      --domain=*) DOMAIN=${arg#*=}; DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN#.} ;;
      --dns-host=*) DNS_HOST=${arg#*=} ;;
      --apps=*) APPS=${arg#*=}; APPS_SET=1 ;;
      --trusted=*) TRUSTED_EXTRA=${arg#*=}; TRUSTED_SET=1 ;;
      --install-dir=*) INSTALL_DIR=${arg#*=}; INSTALL_DIR=${INSTALL_DIR%/} ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --install) set_action install ;;
      --lock-signups) set_action lock ;;
      --backup) set_action backup ;;
      --uninstall) set_action uninstall ;;
      --purge) PURGE=1 ;;
      --delete-files) DELETE_FILES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ -z $HTTPS_MODE || $HTTPS_MODE =~ ^(caddy|dns)$ ]] || { echo "--https must be caddy or dns" >&2; exit 2; }
  (( ! PURGE )) || [[ $ACTION == uninstall ]] || { echo "--purge only goes with --uninstall" >&2; exit 2; }
  (( ! DELETE_FILES )) || (( PURGE )) || { echo "--delete-files only goes with --uninstall --purge" >&2; exit 2; }
  return 0
}

host_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "${ip:-localhost}"
}

detect_tz() {
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null) || true
  [[ -z $tz && -f /etc/timezone ]] && tz=$(</etc/timezone)
  echo "${tz:-Etc/UTC}"
}

# Address on a VPN interface (Tailscale, WireGuard, ZeroTier), if this machine has one.
vpn_address() {
  ip -4 -br addr show 2>/dev/null |
    awk '($1 == "tailscale0" || $1 ~ /^wg/ || $1 ~ /^zt/) && $3 && !f {split($3, a, "/"); print $1, a[1]; f = 1}'   # no `exit`: ip would get SIGPIPE
}

dc() { docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
want() { [[ ,$APPS, == *,$1,* ]]; }

# Saved state (key=value) in the install folder: choices for re-runs.
state_get() { [[ -f $INSTALL_DIR/.state ]] && sed -n "s/^$1=//p" "$INSTALL_DIR/.state" | tail -n1 || true; }
state_set() {
  mkdir -p "$INSTALL_DIR"
  touch "$INSTALL_DIR/.state"
  sed -i "/^$1=/d" "$INSTALL_DIR/.state"
  printf '%s=%s\n' "$1" "$2" >>"$INSTALL_DIR/.state"
}

# Secrets never go on a command line (they'd show in `ps`): curl reads its
# config from stdin (-K -), jq reads files from SHL_TMP (root only, removed on exit).
cq() { local v=$1; v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//$'\r'/}; v=${v//$'\n'/\\n}; printf '"%s"' "$v"; }
ckv() { printf '%s = %s\n' "$1" "$(cq "$2")"; }
SHL_TMP=""
sfile() { # sfile name value → path of a 600 file in SHL_TMP holding value
  local f="$SHL_TMP/$1"
  ( umask 077; printf '%s' "$2" >"$f" )
  printf '%s' "$f"
}
cleanup() {
  [[ -n $SHL_TMP && -d $SHL_TMP ]] && rm -rf "$SHL_TMP"
  (( IS_TTY )) && printf '\e[?25h'
  return 0
}

http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true; }
gen_pass() { head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"${1:-16}"; }

load_secrets() {
  [[ -f $INSTALL_DIR/.secrets ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case $k in
      APP_USER) [[ -z $APP_USER ]] && APP_USER=$v ;;
      APP_PASS) [[ -z $APP_PASS ]] && APP_PASS=$v ;;
      NC_DB_PASS) NC_DB_PASS=$v ;;
      IMMICH_DB_PASS) IMMICH_DB_PASS=$v ;;
    esac
  done <"$INSTALL_DIR/.secrets"
  return 0
}

save_secrets() {
  mkdir -p "$INSTALL_DIR"
  ( umask 077
    printf 'APP_USER=%s\nAPP_PASS=%s\nNC_DB_PASS=%s\nIMMICH_DB_PASS=%s\n' \
      "$APP_USER" "$APP_PASS" "$NC_DB_PASS" "$IMMICH_DB_PASS" >"$INSTALL_DIR/.secrets" )
}

# ── Who owns a port? ──────────────────────────────────────────────────────────
# ── Who owns a port? ──────────────────────────────────────────────────────────
our_project() { [[ $1 == "$PROJECT" ]]; }

describe_container() { # describe_container id-or-name → owner line "kind|target|label"
  local name project
  name=$(docker inspect -f '{{.Name}}' "$1" 2>/dev/null) || { echo "process|$1|container $1"; return; }
  name=${name#/}
  project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null || true)
  if our_project "$project"; then echo "ours|$name|this stack"; else echo "container|$name|Docker container \"$name\""; fi
}

# Docker-published ports. `docker ps` folds ranges (0.0.0.0:8265-8266->8265-8266/tcp).
published_owners() { # published_owners port
  command -v docker >/dev/null 2>&1 || return 0
  local name
  docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null |
    awk -F'\t' -v p="$1" '{
      n = split($2, m, ", ")
      for (i = 1; i <= n; i++) {
        if (m[i] !~ /->/) continue
        split(m[i], h, "->"); hp = h[1]; sub(/.*:/, "", hp)
        split(hp, r, "-"); lo = r[1]; hi = (r[2] != "" ? r[2] : r[1])
        if (p + 0 >= lo + 0 && p + 0 <= hi + 0) { print $1; break }
      }
    }' |
    while read -r name; do describe_container "$name"; done
}

port_owners() { # port_owners port → owner lines (deduplicated)
  local p=$1 pid proc cid unit
  {
    published_owners "$p"
    ss -Hltnp "sport = :$p" 2>/dev/null | grep -oE '"[^"]+",pid=[0-9]+' | sed -E 's/"([^"]+)",pid=([0-9]+)/\2 \1/' | sort -u |
      while read -r pid proc; do
        [[ $proc == docker-proxy ]] && continue   # covered by published_owners
        cid=$(grep -oE '[0-9a-f]{64}' "/proc/$pid/cgroup" 2>/dev/null | head -n1 || true)
        if [[ -n $cid ]] && command -v docker >/dev/null 2>&1; then describe_container "$cid"; continue; fi
        unit=$(ps -o unit= -p "$pid" 2>/dev/null | xargs || true)
        if [[ $unit == *.service ]]; then echo "service|$unit|service $unit (\"$proc\")"; else echo "process|$pid|program \"$proc\" (pid $pid)"; fi
      done
  } | awk '!seen[$0]++'
}

conflicts() { port_owners "$@" | grep -v '^ours|' || true; }   # owners that are in our way

port_label() {
  case $1 in
    P_HTTPS) echo "Nextcloud (HTTPS)" ;; P_HTTP) echo "certificate page" ;; P_NC) echo "Nextcloud" ;;
    P_OFFICE) echo "Collabora" ;; P_PHOTOS) echo "Immich" ;; P_VAULT) echo "Vaultwarden" ;;
    P_PDF) echo "Stirling PDF" ;; P_NOTES) echo "Obsidian" ;;
  esac
}
port_needed() {
  case $1 in
    P_HTTPS|P_HTTP) [[ $HTTPS_MODE == caddy ]] ;;
    P_NC) [[ $HTTPS_MODE == dns ]] ;;
    P_OFFICE) [[ $HTTPS_MODE == dns ]] && want office ;;
    P_PHOTOS) want photos ;; P_VAULT) want vault ;; P_PDF) want pdf ;; P_NOTES) want obsidian ;;
  esac
}

next_free_port() { # next_free_port var → a free port near the usual one
  local var=$1 p tries=0
  case $var in P_HTTPS) p=8443 ;; P_HTTP) p=8880 ;; *) p=$(( ${!var} + 1 )) ;; esac
  while (( tries < 200 )); do
    port_taken "$p" "$var" || { echo "$p"; return 0; }
    p=$((p + 1)); tries=$((tries + 1))
  done
  return 1
}

port_taken() { # port_taken port self-var
  local p=$1 self=$2 v
  for v in "${PORT_VARS[@]}"; do port_needed "$v" && [[ $v != "$self" && ${!v} == "$p" ]] && return 0; done
  [[ -n $(conflicts "$p") ]]
}
resolve_port() { # resolve_port VAR "owner label"
  local var=$1 owner=$2 label cur alt p
  label=$(port_label "$var"); cur=${!var}
  warn "Port $cur ($label) is already used by $owner"
  alt=$(next_free_port "$var") || die "Couldn't find a free port for $label."
  if (( DRY_RUN )); then info "Would use port $alt for $label instead"; printf -v "$var" '%s' "$alt"; return; fi
  case $(menu "What should I do?" 1 \
    "Use $alt|next free port ($owner stays where it is)" \
    "Choose a port|type the port you want" \
    "Cancel|nothing has been installed yet") in
    1) p=$alt ;;
    2)
      while :; do
        p=$(ask "Port for $label (1-65535)" "$alt")
        if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then warn "Enter a number between 1 and 65535."; continue; fi
        if port_taken "$p" "$var"; then warn "Port $p is taken too: try another."; continue; fi
        break
      done
      ;;
    *) info "Cancelled. Nothing was installed."; exit 0 ;;
  esac
  printf -v "$var" '%s' "$p"
  ok "$label will use port $p"
}

check_ports() {
  local var line moved=0 list=""
  for var in "${PORT_VARS[@]}"; do
    port_needed "$var" || continue
    line=$(conflicts "${!var}" | awk "NR == 1")
    if [[ -n $line ]]; then resolve_port "$var" "${line##*|}"; moved=1; fi
    list+="${list:+, }${!var} ($(port_label "$var"))"
  done
  (( moved )) || ok "Ports $list are free"
}

# ── Addresses ─────────────────────────────────────────────────────────────────
portsfx() { [[ $1 == 443 ]] || printf ':%s' "$1"; }

# The Tailscale name of this machine (host.tailnet.ts.net), if it has one.
ts_name() {
  command -v tailscale >/dev/null 2>&1 || return 0
  local j
  j=$(tailscale status --json 2>/dev/null) || return 0
  if command -v jq >/dev/null 2>&1; then jq -r '.Self.DNSName // empty' <<<"$j" 2>/dev/null | sed 's/\.$//'
  else grep -m1 '"DNSName"' <<<"$j" | sed -E 's/.*"DNSName": *"([^"]*)".*/\1/; s/\.$//'; fi   # Self comes before Peer
  return 0
}

# Every name and address people may open Nextcloud with (also the certificate's).
auto_addresses() {
  local vpn
  {
    echo "$HOST_IP"
    vpn=$(vpn_address); [[ -n $vpn ]] && echo "${vpn#* }"
    hostname -s 2>/dev/null
    ts_name
    if [[ $HTTPS_MODE == dns ]]; then echo "cloud.$DOMAIN"; fi
  } | awk 'NF && $0 != "localhost" && !seen[$0]++'
}
all_addresses() { { auto_addresses; tr ',' '\n' <<<"$TRUSTED_EXTRA"; } | awk 'NF && !seen[$0]++'; }

is_ip() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
private_ip() { [[ $1 =~ ^(10\.|192\.168\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

nc_url() { if [[ $HTTPS_MODE == dns ]]; then echo "https://cloud.$DOMAIN"; else echo "https://$HOST_IP$(portsfx "$P_HTTPS")"; fi; }
app_url() { # app_url photos|vault|pdf|obsidian|office
  local name port
  case $1 in
    photos) name=photos port=$P_PHOTOS ;; vault) name=vault port=$P_VAULT ;;
    pdf) name=pdf port=$P_PDF ;; obsidian) name=notes port=$P_NOTES ;; office) name=office port=$P_HTTPS ;;
  esac
  if [[ $HTTPS_MODE == dns ]]; then echo "https://$name.$DOMAIN"; else echo "https://$HOST_IP$(portsfx "$port")"; fi
}
# How this script reaches an app from the machine itself.
local_base() { # local_base nextcloud|photos|vault|pdf|obsidian|office
  local port
  if [[ $HTTPS_MODE == caddy ]]; then
    case $1 in nextcloud|office) port=$P_HTTPS ;; photos) port=$P_PHOTOS ;; vault) port=$P_VAULT ;; pdf) port=$P_PDF ;; obsidian) port=$P_NOTES ;; esac
    echo "https://127.0.0.1:$port"
  else
    case $1 in nextcloud) port=$P_NC ;; office) port=$P_OFFICE ;; photos) port=$P_PHOTOS ;; vault) port=$P_VAULT ;; pdf) port=$P_PDF ;; obsidian) port=$P_NOTES ;; esac
    echo "http://127.0.0.1:$port"
  fi
}
lcode() { curl -sk -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null || true; }   # http_code, any certificate

# ── Pre-flight ────────────────────────────────────────────────────────────────
MEM_GB=0
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint)"
  [[ -r /etc/os-release ]] || die "Cannot detect the OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case $ID in
    ubuntu|debian) ok "OS: $PRETTY_NAME" ;;
    *) [[ ${ID_LIKE:-} == *debian* ]] && warn "OS: $PRETTY_NAME (Debian-based, not officially tested)" \
         || die "Unsupported OS: $PRETTY_NAME. This installer supports Ubuntu Server and Debian." ;;
  esac
  ARCH=$(dpkg --print-architecture)
  [[ $ARCH =~ ^(amd64|arm64)$ ]] || die "Unsupported architecture: $ARCH (the apps need amd64 or arm64)."
  MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
  ok "Architecture: $ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  command -v ss >/dev/null 2>&1 || die "The 'ss' command is missing (package iproute2)."
  # The apps you pick decide how much disk they need: checked in choose_apps.
  TZ_NAME=$(detect_tz); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "Server IP: $HOST_IP"
}

# ── Choices ───────────────────────────────────────────────────────────────────
ask_credentials() {
  local interactive=0 prev
  (( ! ASSUME_YES )) && has_tty && interactive=1
  load_secrets
  if [[ -f $INSTALL_DIR/.secrets && -n $APP_PASS ]]; then
    info "Existing install found: keeping login '$APP_USER'"
  else
    (( interactive )) && printf '\n  %sLogin for your apps%s %s(one login for Nextcloud, Immich, Stirling PDF and Obsidian)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while [[ -z $APP_USER ]] || [[ ! $APP_USER =~ ^[A-Za-z0-9._-]{3,32}$ ]]; do
      [[ -n $APP_USER ]] && warn "Username must be 3-32 characters: letters, numbers, . _ -"
      (( interactive )) || { APP_USER=${APP_USER:-admin}; break; }
      APP_USER=$(ask "Username" "admin")
    done
    if [[ -z $APP_PASS ]] && (( interactive )); then
      case $(menu "Password for '$APP_USER'" 1 \
        "Auto-generate|a strong random password, shown now and saved for you" \
        "Type my own|at least 12 characters, no ' (single quote)") in
        2)
          while :; do
            APP_PASS=$(ask_secret "Password:")
            if (( ${#APP_PASS} < 12 )); then warn "Use at least 12 characters."; continue; fi
            if [[ $APP_PASS == *"'"* ]]; then warn "Leave out the ' (single quote): some of the apps' settings files can't hold it."; continue; fi
            [[ $(ask_secret "Confirm password:") == "$APP_PASS" ]] && break
            warn "Passwords didn't match, try again."
          done
          ;;
      esac
    fi
    if [[ -z $APP_PASS ]]; then
      APP_PASS=$(gen_pass 16)
      GENERATED_PASS=1
      # Straight to the screen (not via ok/log) so the password never lands in the log.
      local where="also saved to $INSTALL_DIR/credentials.txt"
      (( DRY_RUN )) && where="dry run: not saved, a real run makes a new one"
      printf '  %s✓%s Generated password: %s%s%s  %s(%s)%s\n' \
        "$C_GREEN" "$C_RESET" "$C_BOLD" "$APP_PASS" "$C_RESET" "$C_GRAY" "$where" "$C_RESET"
      log "OK   Generated a random password"
    fi
  fi
  [[ $APP_USER =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "Username must be 3-32 characters: letters, numbers, . _ -"
  (( ${#APP_PASS} >= 12 )) || die "The password must be at least 12 characters."
  [[ $APP_PASS != *"'"* ]] || die "The password can't contain a ' (single quote)."
  [[ -z $NC_DB_PASS ]] && NC_DB_PASS=$(gen_pass 24)
  [[ -z $IMMICH_DB_PASS ]] && IMMICH_DB_PASS=$(gen_pass 24)

  prev=$(state_get ADMIN_EMAIL)
  [[ -z $ADMIN_EMAIL ]] && ADMIN_EMAIL=$prev
  if [[ -z $ADMIN_EMAIL ]]; then
    ADMIN_EMAIL=$(ask "Email for the Immich login and Nextcloud (it doesn't have to be real)" "${APP_USER,,}@homelab.local")
  fi
  [[ $ADMIN_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Not a valid email address: '$ADMIN_EMAIL'."
}

choose_data_dir() {
  [[ -z $DATA_DIR ]] && DATA_DIR=$(state_get DATA_DIR)
  if [[ -z $DATA_DIR ]]; then
    has_tty && (( ! ASSUME_YES )) && printf '\n  %sWhere your files go%s %s(Documents, Notes, Photos, backups…: put it on your biggest disk)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while :; do
      DATA_DIR=$(ask "Folder for your files" "$DATA_DEFAULT"); DATA_DIR=${DATA_DIR%/}
      [[ $DATA_DIR =~ ^/[A-Za-z0-9._/-]+$ && $DATA_DIR != "$INSTALL_DIR"* ]] && break
      (( ASSUME_YES )) || ! has_tty && break
      warn "Use a full path with letters, numbers, . _ - and / (like /srv/cloud or /mnt/data/cloud)."
    done
  fi
  [[ $DATA_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || die "The data folder must be a full path with letters, numbers, . _ - / (got '$DATA_DIR')."
  [[ $DATA_DIR != / && $DATA_DIR != "$INSTALL_DIR"* ]] || die "Pick a data folder of its own (not / or inside $INSTALL_DIR)."
  local d=$DATA_DIR
  while [[ ! -d $d ]]; do d=$(dirname "$d"); done
  local free_gb
  free_gb=$(df -Pk "$d" | awk 'NR==2 {printf "%.0f", $4/1048576}')
  if [[ -d $DATA_DIR ]] && [[ -n $(ls -A "$DATA_DIR" 2>/dev/null) ]]; then
    ok "Files: $DATA_DIR (already exists: what's in it stays, missing folders are added) · ${free_gb} GB free"
  else
    ok "Files: $DATA_DIR · ${free_gb} GB free"
  fi
  (( free_gb >= 20 )) || warn "Only ${free_gb} GB free there: fine to try out, small for photos."
}

dns_local_domain() { [[ -f $DNS_DIR/.state ]] && sed -n 's/^DOMAIN=//p' "$DNS_DIR/.state" | tail -n1 || true; }

choose_https() {
  local local_domain def=1
  local_domain=$(dns_local_domain)
  [[ -z $HTTPS_MODE ]] && HTTPS_MODE=$(state_get HTTPS_MODE)
  if [[ -z $HTTPS_MODE ]]; then
    [[ -n $local_domain || -n ${SHL_DNS_FOUND:-} ]] && def=2
    # SHL_DNS_FOUND: a wrapper (Proxmox) found the DNS stack next door and passed --dns-host/--domain.
    case $(menu "How should the apps be opened?" "$def" \
      "Built-in HTTPS|https://$HOST_IP for Nextcloud, other ports for the rest; trust one certificate per device" \
      "DNS Stack names|https://cloud.$( if [[ -n $local_domain ]]; then echo "$local_domain (DNS stack found here)"; elif [[ -n ${SHL_DNS_FOUND:-} ]]; then echo "$DOMAIN ($SHL_DNS_FOUND)"; else echo "home… from the sudo homelab Private DNS Stack"; fi)") in
      2) HTTPS_MODE=dns ;; *) HTTPS_MODE=caddy ;;
    esac
  fi
  if [[ $HTTPS_MODE == caddy ]]; then ok "HTTPS: built-in, with a certificate made for this machine"; return 0; fi

  [[ -z $DNS_HOST ]] && DNS_HOST=$(state_get DNS_HOST)
  if [[ -n $local_domain && ( -z $DNS_HOST || $DNS_HOST == local ) ]]; then
    DNS_HOST=local
    [[ -n $DOMAIN && $DOMAIN != "$local_domain" ]] && warn "The DNS stack here uses .$local_domain: using that instead of .$DOMAIN."
    DOMAIN=$local_domain
    ok "HTTPS: names through the Private DNS Stack on this machine (cloud.$DOMAIN…)"
    return 0
  fi
  [[ $DNS_HOST == local ]] && DNS_HOST=""
  [[ -z $DOMAIN ]] && DOMAIN=$(state_get DOMAIN)
  [[ -n ${SHL_NAMES_BY_WRAPPER:-} ]] || info "The Private DNS Stack isn't on this machine: I'll show the commands to run on the one that has it."
  while [[ -z $DNS_HOST ]] || ! is_ip "$DNS_HOST"; do
    (( ASSUME_YES )) || ! has_tty && die "Give the DNS stack's machine with --dns-host=IP (or use --https=caddy)."
    [[ -n $DNS_HOST ]] && warn "Type an IP address, like 192.168.1.20."
    DNS_HOST=$(ask "IP of the machine with the DNS stack" "")
  done
  while [[ -z $DOMAIN || ! $DOMAIN =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; do
    (( ASSUME_YES )) || ! has_tty && die "Give the DNS stack's ending with --domain= (e.g. --domain=home)."
    DOMAIN=$(ask "Its ending for names (the part after cloud.)" "home"); DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN#.}
  done
  ok "HTTPS: names through the Private DNS Stack on $DNS_HOST (cloud.$DOMAIN…)"
}

# Disk each app's downloads take, roughly (GB × 10): images, plus Nextcloud's code
# and the smart-search models. Measured on amd64.
app_disk() { case $1 in base) echo 30 ;; office) echo 20 ;; photos) echo 37 ;; ml) echo 30 ;; vault) echo 4 ;; pdf) echo 37 ;; obsidian) echo 57 ;; esac; }
app_image() {
  case $1 in base) echo "$NC_IMAGE" ;; office) echo "$COLLABORA_IMAGE" ;; photos) echo "$IMMICH_IMAGE" ;; ml) echo "$IMMICH_ML_IMAGE" ;;
    vault) echo "$VW_IMAGE" ;; pdf) echo "$STIRLING_IMAGE" ;; obsidian) echo "$OBSIDIAN_IMAGE" ;; esac
}
docker_root() {
  local r
  r=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null) || r=/var/lib/docker
  while [[ ! -d $r ]]; do r=$(dirname "$r"); done
  echo "$r"
}
check_disk() { # stops before downloading what wouldn't fit (images already here don't count)
  local a need=0 root free_mb big=""
  for a in base ${APPS//,/ }; do
    docker image inspect "$(app_image "$a")" >/dev/null 2>&1 || need=$(( need + $(app_disk "$a") ))
  done
  root=$(docker_root)
  free_mb=$(df -Pm "$root" | awk 'NR==2 {print $4}')
  need=$(( need * 1024 / 10 + 2048 ))   # MB, plus 2 GB to breathe
  if (( free_mb < need )); then
    want obsidian && big+=", Obsidian (5.7 GB)"
    want pdf && big+=", Stirling PDF (3.7 GB)"
    want ml && big+=", smart search (3 GB)"
    err "The apps need about $((need / 1024)) GB on $root; only $((free_mb / 1024)) GB is free."
    die "Free some space or grow the disk${big:+, or leave out ${big#, }}."
  fi
  ok "Disk: about $((need / 1024)) GB needed for the apps, $((free_mb / 1024)) GB free on $root"
}

# RAM each app needs, roughly (GB × 10).
app_ram() { case $1 in office) echo 10 ;; photos) echo 12 ;; ml) echo 20 ;; vault) echo 1 ;; pdf) echo 7 ;; obsidian) echo 8 ;; esac; }

choose_apps() {
  local def a need=12   # Nextcloud + databases
  if (( ! APPS_SET )); then
    if [[ -f $INSTALL_DIR/.state ]]; then def=$(state_get APPS)
    else def="office,photos,vault,pdf,obsidian"; (( MEM_GB >= 6 )) && def+=",ml"; fi
    APPS=$(multi_select "Apps besides Nextcloud" "$def" app_label "${APP_IDS[@]}")
  fi
  [[ ${APPS,,} == none ]] && APPS=""
  for a in ${APPS//,/ }; do [[ -n $(app_label "$a") ]] || die "Unknown app '$a' (use office, photos, ml, vault, pdf, obsidian)."; done
  if want ml && ! want photos; then APPS=$(tr ',' '\n' <<<"$APPS" | grep -vx ml | paste -sd, -); info "Smart search is part of Immich: skipped without it."; fi
  for a in ${APPS//,/ }; do need=$(( need + $(app_ram "$a") )); done
  if (( need > MEM_GB * 10 + 5 )); then
    warn "These apps want about $((need / 10)).$((need % 10)) GB of RAM; this machine has ${MEM_GB} GB."
    warn "They'll start, but may be slow or get stopped: give it more RAM, or leave out Smart search / Obsidian / Office."
  fi
  check_disk
}

choose_trusted() {
  local a list
  [[ $TRUSTED_SET == 0 && -z $TRUSTED_EXTRA ]] && TRUSTED_EXTRA=$(state_get TRUSTED_EXTRA)
  list=$(auto_addresses | paste -sd, - | sed 's/,/, /g')
  info "Nextcloud will answer on: $list"
  if (( ! TRUSTED_SET )) && (( ! ASSUME_YES )) && has_tty; then
    printf '    %sOpen it with another name or address too (a domain, a router name)? Add it here, or Nextcloud refuses it.%s\n' "$C_GRAY" "$C_RESET" >/dev/tty
    TRUSTED_EXTRA=$(ask "Other names, comma separated (Enter = none)" "$TRUSTED_EXTRA")
  fi
  TRUSTED_EXTRA=$(tr ', ' '\n\n' <<<"${TRUSTED_EXTRA,,}" | sed -E 's#^https?://##; s#[:/].*$##' | awk 'NF && !seen[$0]++' | paste -sd, -)
  for a in ${TRUSTED_EXTRA//,/ }; do
    [[ $a =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "'$a' isn't a name or address Nextcloud can use."
  done
  [[ -n $TRUSTED_EXTRA ]] && ok "Also accepted: ${TRUSTED_EXTRA//,/, }"
  return 0
}

count_steps() {
  TOTAL_STEPS=10
  want office && TOTAL_STEPS=$((TOTAL_STEPS + 1))
  want photos && TOTAL_STEPS=$((TOTAL_STEPS + 1))
  want vault && TOTAL_STEPS=$((TOTAL_STEPS + 1))
  { want pdf || want obsidian; } && TOTAL_STEPS=$((TOTAL_STEPS + 1))
  [[ $HTTPS_MODE == dns ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
  return 0
}

choose_options() {
  step "Choose your setup"
  local prev v
  if [[ -f $INSTALL_DIR/.state ]]; then
    info "Existing install found in $INSTALL_DIR (its settings are the defaults)"
    for v in "${PORT_VARS[@]}"; do prev=$(state_get "$v"); [[ $prev =~ ^[0-9]+$ ]] && printf -v "$v" '%s' "$prev"; done
  fi
  ask_credentials
  choose_data_dir
  local was
  was=$(state_get HTTPS_MODE)
  choose_https
  # Obsidian's port differs by mode (HTTPS through Caddy, or its own http port).
  [[ -z $P_NOTES || ( -n $was && $was != "$HTTPS_MODE" ) ]] && { [[ $HTTPS_MODE == caddy ]] && P_NOTES=3443 || P_NOTES=3000; }
  choose_apps
  choose_trusted
  count_steps

  step "Checking ports"
  check_ports
  print_plan
  if (( DRY_RUN )); then info "Dry run: nothing was changed."; exit 0; fi
  confirm "Install now?" || { info "Cancelled. Nothing was changed."; exit 0; }
}

print_plan() {
  local a
  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  printf '    %-14s %s\n' "Nextcloud" "$(nc_url)  ·  $(for a in "${NC_APPS[@]}"; do nc_app_label "$a"; done | paste -sd, - | sed 's/,/, /g')"
  want office && printf '    %-14s %s\n' "Office" "inside Nextcloud (Collabora)"
  want photos && printf '    %-14s %s\n' "Immich" "$(app_url photos)$(want ml && echo "  ·  with smart search")"
  want vault && printf '    %-14s %s\n' "Vaultwarden" "$(app_url vault)"
  want pdf && printf '    %-14s %s\n' "Stirling PDF" "$(app_url pdf)"
  want obsidian && printf '    %-14s %s\n' "Obsidian" "$(app_url obsidian)"
  [[ $HTTPS_MODE == caddy ]] && printf '    %-14s %s\n' "Certificate" "http://$HOST_IP$( [[ $P_HTTP == 80 ]] || echo ":$P_HTTP")  ·  install it once on each device"
  printf '    %-14s %s\n' "Your files" "$DATA_DIR  (Documents, Notes, Photos, backups)" \
    "Login" "$APP_USER (Immich: $ADMIN_EMAIL)" "Settings" "$INSTALL_DIR"
  log "Plan: apps=${APPS:-none} https=$HTTPS_MODE domain=$DOMAIN dns_host=$DNS_HOST data=$DATA_DIR user=$APP_USER email=$ADMIN_EMAIL trusted=$TRUSTED_EXTRA ports=$P_HTTPS/$P_HTTP/$P_NC/$P_OFFICE/$P_PHOTOS/$P_VAULT/$P_PDF/$P_NOTES"
  printf '\n'
}

# ── Install ───────────────────────────────────────────────────────────────────
apt_update() {
  apt-get -y -o DPkg::Lock::Timeout=300 update && return 0
  echo "apt-get update failed; retrying with HTTPS mirrors (some firewalls block apt over HTTP)"
  local f changed=0
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $f ]] || continue
    if grep -qE 'http://(([a-z0-9-]+\.)*archive\.ubuntu\.com|ports\.ubuntu\.com|security\.ubuntu\.com|deb\.debian\.org|security\.debian\.org)' "$f"; then
      cp -n "$f" "$f.sudohomelab.bak"
      sed -i -E 's#http://(([a-z0-9-]+\.)*archive\.ubuntu\.com|ports\.ubuntu\.com|security\.ubuntu\.com|deb\.debian\.org|security\.debian\.org)#https://\1#g' "$f"
      changed=1
    fi
  done
  (( changed )) || return 1
  apt-get -y -o DPkg::Lock::Timeout=300 update
}

docker_official() {
  # shellcheck disable=SC1091
  . /etc/os-release
  local codename=${UBUNTU_CODENAME:-$VERSION_CODENAME}
  install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $codename stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get -y -o DPkg::Lock::Timeout=300 update || return 1
  apt-get -y -o DPkg::Lock::Timeout=300 install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

docker_distro() {
  rm -f /etc/apt/sources.list.d/docker.list
  apt-get -y -o DPkg::Lock::Timeout=300 update
  apt-get -y -o DPkg::Lock::Timeout=300 install docker.io docker-compose-v2 || \
    apt-get -y -o DPkg::Lock::Timeout=300 install docker.io docker-compose-plugin
}

start_docker() {
  systemctl enable --now docker
  local i
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

install_deps() {
  step "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  local need=() pkg
  for pkg in curl jq ca-certificates gnupg iproute2 openssl python3 argon2 qrencode; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
  done
  if (( ${#need[@]} )); then
    run "Updating package lists" apt_update
    run "Installing ${need[*]}" apt-get -y -o DPkg::Lock::Timeout=300 install --no-install-recommends "${need[@]}"
  fi
  if command -v docker >/dev/null 2>&1; then
    ok "Docker already installed ($(docker --version | sed 's/,.*//'))"
  else
    run "Installing Docker Engine (official repository)" docker_official || {
      warn "Official Docker repository failed for this release; using the distro packages instead."
      run "Installing Docker Engine (distro packages)" docker_distro
    }
  fi
  docker info >/dev/null 2>&1 || run "Starting Docker" start_docker
  if ! docker compose version >/dev/null 2>&1; then
    run "Installing Docker Compose plugin" bash -c \
      'apt-get -y -o DPkg::Lock::Timeout=300 install docker-compose-plugin || apt-get -y -o DPkg::Lock::Timeout=300 install docker-compose-v2'
  fi
  ok "$(docker compose version)"
}

# ── Folders ───────────────────────────────────────────────────────────────────
# Files in the shared folders belong to www-data, so Nextcloud, Obsidian and
# Stirling PDF (all running as it) can each change what the others made.
own_www() { find "$1" \( ! -user "$WWW_UID" -o ! -group "$WWW_UID" \) -exec chown "$WWW_UID:$WWW_UID" {} + 2>/dev/null || true; }

pdf_workflow() { # pdf_workflow folder "name" operation json-parameters
  local d="$DATA_DIR/Documents/PDF Inbox/$1"
  mkdir -p "$d"
  [[ -n $(find "$d" -maxdepth 1 -name '*.json' -print -quit) ]] && return 0   # yours, or made before
  jq -n --arg n "$2" --arg op "$3" --argjson p "$4" \
    '{name: $n, pipeline: [{operation: $op, parameters: $p}], outputDir: "{outputFolder}", outputFileName: "{filename}"}' \
    >"$d/$(tr 'A-Z ' 'a-z-' <<<"$1").folder-scan.json"
}

make_folders() {
  step "Creating your folders"
  local d
  mkdir -p "$DATA_DIR"/{nextcloud,immich,backups} "${SHARED[@]/#/$DATA_DIR/}"
  chown "$WWW_UID:$WWW_UID" "$DATA_DIR/nextcloud"; chmod 770 "$DATA_DIR/nextcloud"
  chmod 700 "$DATA_DIR/backups"
  if want pdf; then
    mkdir -p "$DATA_DIR/Documents/PDF Inbox" "$DATA_DIR/Documents/PDF Done"
    pdf_workflow OCR "Make scanned PDFs searchable" /api/v1/misc/ocr-pdf \
      '{"languages": ["eng"], "ocrType": "skip-text", "ocrRenderType": "sandwich", "sidecar": false, "deskew": true, "clean": false, "cleanFinal": false, "removeImagesAfter": false}'
    pdf_workflow Compress "Make PDFs smaller" /api/v1/misc/compress-pdf '{"optimizeLevel": 5}'
  fi
  if [[ -z $(ls -A "$DATA_DIR/Notes" 2>/dev/null) ]]; then
    cat >"$DATA_DIR/Notes/Welcome.md" <<'EOF'
# Welcome

This folder is shared by three apps:

- **Nextcloud** → Files → Notes, and the Notes app (each note is a file here)
- **Obsidian** (in your browser) → this folder is its vault
- Any device that syncs Nextcloud (desktop or phone app)

Write a note in one, and it shows up in the others.
EOF
  fi
  for d in "${SHARED[@]}"; do own_www "$DATA_DIR/$d"; chmod 775 "$DATA_DIR/$d"; done
  ok "Your files: $DATA_DIR"
  printf '    %s├─ Documents/%s   Nextcloud "Documents"%s\n' "$C_GRAY" "$( want pdf && echo '   PDF Inbox/{OCR,Compress} → PDF Done (Stirling PDF)')" "$C_RESET"
  printf '    %s├─ Notes/       Nextcloud "Notes" + Notes app%s%s\n' "$C_GRAY" "$( want obsidian && echo ' + Obsidian vault')" "$C_RESET"
  printf '    %s├─ Photos/      Nextcloud "Photos"%s%s\n' "$C_GRAY" "$( want photos && echo ' + an Immich library')" "$C_RESET"
  printf '    %s├─ nextcloud/   Nextcloud'"'"'s own data (each user'"'"'s private files)%s\n' "$C_GRAY" "$C_RESET"
  want photos && printf '    %s├─ immich/      photos uploaded with the Immich app%s\n' "$C_GRAY" "$C_RESET"
  printf '    %s└─ backups/     nightly database backups%s\n' "$C_GRAY" "$C_RESET"
}

# ── Certificate (built-in HTTPS) ──────────────────────────────────────────────
# Our own certificate authority, limited (name constraints) to private addresses
# and home names: even if its key leaked, it couldn't vouch for a real website.
CERT_DIR=""
CA_SUFFIXES=(local lan home home.arpa internal localdomain ts.net)   # a name constraint covers its subdomains

ca_names() { # → the DNS names the CA may sign for: home suffixes + any other name we use
  local n s ok
  printf '%s\n' "${CA_SUFFIXES[@]}"
  while read -r n; do
    is_ip "$n" && continue
    ok=0
    for s in "${CA_SUFFIXES[@]}"; do [[ $n == "$s" || $n == *".$s" ]] && ok=1; done
    (( ok )) || echo "$n"
  done < <(all_addresses)
}
ca_ips() { # → extra exact IPs outside the private ranges
  local n
  while read -r n; do is_ip "$n" && ! private_ip "$n" && echo "$n"; done < <(all_addresses)
  return 0
}

make_ca() {
  local cnf="$SHL_TMP/ca.cnf" nc="" n
  for n in 10.0.0.0/255.0.0.0 172.16.0.0/255.240.0.0 192.168.0.0/255.255.0.0 100.64.0.0/255.192.0.0 127.0.0.0/255.0.0.0; do nc+="permitted;IP:$n,"; done
  while read -r n; do nc+="permitted;IP:$n/255.255.255.255,"; done < <(ca_ips)
  while read -r n; do nc+="permitted;DNS:$n,"; done < <(ca_names)
  cat >"$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = sudo homelab Cloud CA ($(hostname -s))
O = sudo homelab
[ext]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,${nc%,}
EOF
  ( umask 077; openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" -days 3650 -sha256 -config "$cnf" -extensions ext ) || return 1
  chmod 644 "$CERT_DIR/ca.crt"
  ca_names | paste -sd, - >"$CERT_DIR/ca.names"
  ca_ips | paste -sd, - >"$CERT_DIR/ca.ips"
  echo "made the certificate authority"
}

leaf_sans() {
  local n
  { echo "IP:127.0.0.1"; while read -r n; do if is_ip "$n"; then echo "IP:$n"; else echo "DNS:$n"; fi; done < <(all_addresses); } | paste -sd, -
}

make_leaf() {
  local ext="$SHL_TMP/leaf.ext"
  printf 'basicConstraints = CA:FALSE\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = serverAuth\nsubjectAltName = %s\nauthorityKeyIdentifier = keyid\n' "$(leaf_sans)" >"$ext"
  ( umask 077
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$CERT_DIR/cloud.key" \
      -subj "/CN=sudo homelab Cloud/O=sudo homelab" -out "$SHL_TMP/leaf.csr" &&
    # 800 days: Apple devices refuse longer-lived certificates.
    openssl x509 -req -in "$SHL_TMP/leaf.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
      -set_serial "0x$(openssl rand -hex 16)" -days 800 -sha256 -extfile "$ext" -out "$CERT_DIR/cloud.crt" ) || return 1
  chmod 644 "$CERT_DIR/cloud.crt"
  # Caddy runs as root in its container; the key stays readable by root only.
  leaf_sans >"$CERT_DIR/cloud.sans"
  echo "certificate for: $(leaf_sans)"
}

ensure_certs() {
  CERT_DIR="$INSTALL_DIR/caddy/certs"
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  local new_ca=0
  if [[ ! -s $CERT_DIR/ca.crt || ! -s $CERT_DIR/ca.key ]]; then
    run "Making a certificate authority for this machine" make_ca; new_ca=1
  elif [[ $(ca_names | paste -sd, -) != "$(cat "$CERT_DIR/ca.names" 2>/dev/null)" || $(ca_ips | paste -sd, -) != "$(cat "$CERT_DIR/ca.ips" 2>/dev/null)" ]]; then
    warn "A new name or address isn't covered by your certificate authority: making a new one."
    warn "Devices that trust the old one need the new certificate (from the certificate page)."
    run "Making a new certificate authority" make_ca; new_ca=1
  fi
  if (( new_ca )) || [[ ! -s $CERT_DIR/cloud.crt ]] || [[ $(leaf_sans) != "$(cat "$CERT_DIR/cloud.sans" 2>/dev/null)" ]] ||
     ! openssl x509 -checkend $((60 * 86400)) -noout -in "$CERT_DIR/cloud.crt" >/dev/null 2>&1; then
    run "HTTPS certificate for $(all_addresses | paste -sd, - | sed 's/,/, /g')" make_leaf
  else
    ok "HTTPS certificate is current (valid until $(openssl x509 -enddate -noout -in "$CERT_DIR/cloud.crt" | cut -d= -f2))"
  fi
  mkdir -p "$INSTALL_DIR/caddy/site"
  cp "$CERT_DIR/ca.crt" "$INSTALL_DIR/caddy/site/sudohomelab-cloud-ca.crt"
}

# ── Compose ───────────────────────────────────────────────────────────────────
# env-file values in single quotes are taken literally (the password has no ').
envq() { printf "%s='%s'\n" "$1" "$2"; }

publish() { [[ $HTTPS_MODE == dns ]] && printf '    ports:\n      - "%s:%s"\n' "$1" "$2"; return 0; }

nc_volumes() {
  local d
  printf '    volumes:\n      - ./nextcloud:/var/www/html\n      - %s/nextcloud:/var/www/html/data\n' "$DATA_DIR"
  for d in "${SHARED[@]}"; do printf '      - %s/%s:/mnt/cloud/%s\n' "$DATA_DIR" "$d" "$d"; done
}

write_compose() {
  local f="$INSTALL_DIR/docker-compose.yml"
  {
    cat <<EOF
# sudo homelab · Cloud Stack (made by cloud.sh: re-run it to change settings)
name: $PROJECT
services:
  postgres:
    image: $PG_IMAGE
    restart: unless-stopped
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD_FILE: /run/secrets/nc_db_pass
    secrets: [nc_db_pass]
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nextcloud -d nextcloud"]
      interval: 10s
      retries: 12

  redis:
    image: $REDIS_IMAGE
    restart: unless-stopped

  nextcloud:
    image: $NC_IMAGE
    restart: unless-stopped
    depends_on:
      postgres: {condition: service_healthy}
      redis: {condition: service_started}
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD_FILE: /run/secrets/nc_db_pass
      NEXTCLOUD_ADMIN_USER: "$APP_USER"
      NEXTCLOUD_ADMIN_PASSWORD_FILE: /run/secrets/app_pass
      REDIS_HOST: redis
      PHP_MEMORY_LIMIT: 1024M
      PHP_UPLOAD_LIMIT: 16G
      TZ: "$TZ_NAME"
    secrets: [nc_db_pass, app_pass]
EOF
    nc_volumes
    publish "$P_NC" 80
    cat <<EOF

  nextcloud-cron:
    image: $NC_IMAGE
    restart: unless-stopped
    entrypoint: /cron.sh
    depends_on: [nextcloud]
    environment:
      TZ: "$TZ_NAME"
EOF
    nc_volumes

    if want office; then
      cat <<EOF

  collabora:
    image: $COLLABORA_IMAGE
    restart: unless-stopped
    env_file: .collabora.env
EOF
      publish "$P_OFFICE" 9980
      # It calls Nextcloud back at the address you opened it with: in DNS mode that
      # name must lead to the proxy even if this machine doesn't use Pi-hole.
      [[ $HTTPS_MODE == dns ]] && printf '    extra_hosts:\n      - "cloud.%s:%s"\n' "$DOMAIN" "$( [[ $DNS_HOST == local ]] && echo "$HOST_IP" || echo "$DNS_HOST")"
    fi

    if want photos; then
      cat <<EOF

  immich-server:
    image: $IMMICH_IMAGE
    restart: unless-stopped
    env_file: .immich.env
    volumes:
      - $DATA_DIR/immich:/data
      - $DATA_DIR/Photos:/mnt/photos:ro
      - /etc/localtime:/etc/localtime:ro
    depends_on: [immich-redis, immich-db]
EOF
      publish "$P_PHOTOS" 2283
      want ml && cat <<EOF

  immich-machine-learning:
    image: $IMMICH_ML_IMAGE
    restart: unless-stopped
    env_file: .immich.env
    volumes:
      - ./immich-ml:/cache
EOF
      cat <<EOF

  immich-redis:
    image: $VALKEY_IMAGE
    restart: unless-stopped
    healthcheck:
      test: redis-cli ping | grep -q PONG || exit 1

  immich-db:
    image: $IMMICH_DB_IMAGE
    restart: unless-stopped
    env_file: .immich.env
    volumes:
      - ./immich-db:/var/lib/postgresql/data
    shm_size: 128mb
EOF
    fi

    if want vault; then
      cat <<EOF

  vaultwarden:
    image: $VW_IMAGE
    restart: unless-stopped
    env_file: .vaultwarden.env
    volumes:
      - ./vaultwarden:/data
EOF
      publish "$P_VAULT" 80
    fi

    if want pdf; then
      cat <<EOF

  stirling-pdf:
    image: $STIRLING_IMAGE
    restart: unless-stopped
    env_file: .stirling.env
    volumes:
      - ./stirling/configs:/configs
      - ./stirling/logs:/logs
      - "$DATA_DIR/Documents/PDF Inbox:/pipeline/watchedFolders"
      - "$DATA_DIR/Documents/PDF Done:/pipeline/finishedFolders"
EOF
      publish "$P_PDF" 8080
    fi

    if want obsidian; then
      cat <<EOF

  obsidian:
    image: $OBSIDIAN_IMAGE
    restart: unless-stopped
    environment:
      PUID: "$WWW_UID"
      PGID: "$WWW_UID"
      TZ: "$TZ_NAME"
      TITLE: Obsidian
      CUSTOM_USER: "$APP_USER"
      FILE__PASSWORD: /run/secrets/app_pass
    secrets: [app_pass]
    volumes:
      - ./obsidian:/config
      - $DATA_DIR/Notes:/vault
    shm_size: 1gb
    security_opt: [seccomp:unconfined]
EOF
      publish "$P_NOTES" 3000
    fi

    if [[ $HTTPS_MODE == caddy ]]; then
      cat <<EOF

  caddy:
    image: $CADDY_IMAGE
    restart: unless-stopped
    depends_on: [nextcloud]
    ports:
      - "$P_HTTPS:443"
      - "$P_HTTP:80"
EOF
      want photos && printf '      - "%s:2283"\n' "$P_PHOTOS"
      want vault && printf '      - "%s:8222"\n' "$P_VAULT"
      want pdf && printf '      - "%s:8484"\n' "$P_PDF"
      want obsidian && printf '      - "%s:3443"\n' "$P_NOTES"
      cat <<EOF
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/certs:/certs:ro
      - ./caddy/site:/srv:ro
      - ./caddy/data:/data
EOF
    fi

    cat <<EOF

secrets:
  app_pass:
    file: ./secrets/app_pass
  nc_db_pass:
    file: ./secrets/nc_db_pass
EOF
  } >"$f"
}

write_caddyfile() {
  {
    cat <<EOF
# sudo homelab · Cloud Stack (made by cloud.sh)
{
	auto_https off
	default_sni $HOST_IP
}

(cert) {
	tls /certs/cloud.crt /certs/cloud.key
}

# Nextcloud$(want office && echo ", and Collabora's paths for the Office app")
https://:443 {
	import cert
	header Strict-Transport-Security "max-age=15552000"
	redir /.well-known/carddav /remote.php/dav/ 301
	redir /.well-known/caldav /remote.php/dav/ 301
EOF
    want office && printf '\t@office path /browser/* /hosting/* /cool/* /lool/*\n\thandle @office {\n\t\treverse_proxy collabora:9980\n\t}\n'
    printf '\thandle {\n\t\treverse_proxy nextcloud:80\n\t}\n}\n'
    want photos && printf '\nhttps://:2283 {\n\timport cert\n\treverse_proxy immich-server:2283\n}\n'
    want vault && printf '\nhttps://:8222 {\n\timport cert\n\treverse_proxy vaultwarden:80\n}\n'
    want pdf && printf '\nhttps://:8484 {\n\timport cert\n\treverse_proxy stirling-pdf:8080\n}\n'
    want obsidian && printf '\nhttps://:3443 {\n\timport cert\n\treverse_proxy obsidian:3000\n}\n'
    cat <<'EOF'

# The certificate page: http, so devices can fetch the certificate before they trust it.
http://:80 {
	root * /srv
	header /sudohomelab-cloud-ca.crt Content-Type application/x-x509-ca-cert
	file_server
}
EOF
  } >"$INSTALL_DIR/caddy/Caddyfile"
}

write_site() {
  local a links=""
  links+="<li><a href=\"$(nc_url)\">Nextcloud</a></li>"
  want photos && links+="<li><a href=\"$(app_url photos)\">Immich (photos)</a></li>"
  want vault && links+="<li><a href=\"$(app_url vault)\">Vaultwarden (passwords)</a></li>"
  want pdf && links+="<li><a href=\"$(app_url pdf)\">Stirling PDF</a></li>"
  want obsidian && links+="<li><a href=\"$(app_url obsidian)\">Obsidian</a></li>"
  a=$(hostname -s)
  cat >"$INSTALL_DIR/caddy/site/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cloud Stack · $a</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--fg:#1b1f24;--muted:#5b6470;--card:#fff;--accent:#0b7a5f}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--card:#161b22;--accent:#3fd0a4}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:32px 16px}
.card{background:var(--card);border-radius:12px;padding:20px 22px;margin:16px 0;box-shadow:0 1px 3px rgba(0,0,0,.12)}
a{color:var(--accent)}.btn{display:inline-block;background:var(--accent);color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:600}
h1{font-size:1.6rem;margin:0 0 4px}h2{font-size:1.1rem;margin:0 0 8px}p.m{color:var(--muted);margin:0}li{margin:4px 0}
code{font-size:.85em;background:rgba(127,127,127,.15);padding:1px 4px;border-radius:4px;overflow-wrap:anywhere}
</style></head><body><main>
<h1>Cloud Stack on $a</h1>
<p class="m">sudo homelab · trust this machine's certificate once per device, then the apps open without warnings.</p>
<div class="card"><h2>1. Download the certificate</h2>
<p><a class="btn" href="/sudohomelab-cloud-ca.crt">Download certificate</a></p>
<p class="m">It only works for addresses in your home network (and Tailscale), so it can't be used to impersonate real websites.</p></div>
<div class="card"><h2>2. Trust it</h2><ul>
<li><b>iPhone / iPad:</b> open this page in Safari, download, then Settings → General → VPN &amp; Device Management → install it; then Settings → General → About → Certificate Trust Settings → turn it on.</li>
<li><b>Android:</b> Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate → pick the file.</li>
<li><b>Windows:</b> double-click the file → Install Certificate → Local Machine → "Trusted Root Certification Authorities".</li>
<li><b>macOS:</b> in Terminal, run <code>sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/sudohomelab-cloud-ca.crt</code> (or: double-click the file → in Keychain Access, double-click the certificate → Trust → "Always Trust"). Then restart the browser.</li>
<li><b>Linux / Firefox:</b> Firefox → Settings → Privacy &amp; Security → View Certificates → Authorities → Import.</li>
</ul></div>
<div class="card"><h2>3. Open your apps</h2><ul>$links</ul></div>
</main></body></html>
EOF
}

write_env_files() {
  local d=$INSTALL_DIR o
  ( umask 077
    if want office; then
      if [[ $HTTPS_MODE == dns ]]; then o="https://cloud.$DOMAIN:443"
      else o=$(all_addresses | sed "s#.*#https://&:$P_HTTPS#" | paste -sd, -); fi
      {
        echo "# Nextcloud addresses that may use this office server"
        echo "aliasgroup1=$o"
        # TLS ends at the proxy. Our own certificate isn't in Collabora's trust store,
        # so it doesn't check the certificate when it calls Nextcloud back.
        # The address browsers use: its discovery tells Nextcloud where to load the editor from.
        echo "server_name=$( [[ $HTTPS_MODE == dns ]] && echo "office.$DOMAIN" || echo "$HOST_IP$(portsfx "$P_HTTPS")")"
        echo "extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:ssl.ssl_verification=false"
        echo "dictionaries=en_US en_GB es_ES de_DE fr_FR it pt_BR pt_PT"
      } >"$d/.collabora.env"
    fi
    if want photos; then
      {
        envq DB_HOSTNAME immich-db; envq DB_USERNAME postgres; envq DB_DATABASE_NAME immich
        envq DB_PASSWORD "$IMMICH_DB_PASS"; envq REDIS_HOSTNAME immich-redis; envq TZ "$TZ_NAME"
        envq POSTGRES_USER postgres; envq POSTGRES_DB immich; envq POSTGRES_PASSWORD "$IMMICH_DB_PASS"
        envq POSTGRES_INITDB_ARGS --data-checksums
      } >"$d/.immich.env"
    fi
    if want vault; then
      o=$(vw_hash)   # before the file is rewritten: it reads the old one
      vw_env "$(vw_signups)" "$o" >"$d/.vaultwarden.env"
    fi
    if want pdf; then
      {
        envq SECURITY_ENABLELOGIN true
        envq SECURITY_INITIALLOGIN_USERNAME "$APP_USER"
        envq SECURITY_INITIALLOGIN_PASSWORD "$APP_PASS"
        envq DISABLE_ADDITIONAL_FEATURES false
        envq PUID "$WWW_UID"; envq PGID "$WWW_UID"
        envq LANGS en_GB; envq TZ "$TZ_NAME"
      } >"$d/.stirling.env"
    fi
  )
}

# Vaultwarden: the admin page's token is a hash of your password (the page asks for
# the password itself). Sign-ups are open until the first account exists.
vw_users() { # (Python's sqlite: TrueNAS can't add the sqlite3 tool)
  python3 - "$INSTALL_DIR/vaultwarden/db.sqlite3" 2>/dev/null <<'PYEOF' || echo 0
import sqlite3, sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("SELECT count(*) FROM users").fetchone()[0])
PYEOF
}
vw_argon2() { argon2 "$1" -id -e -k 65540 -t 3 -p 4; }   # vw_argon2 salt < password → PHC hash
vw_signups() { [[ $(vw_users) -gt 0 ]] && echo false || echo true; }
vw_hash() { # the old hash while the password is the same (a new salt would recreate the container)
  local hash sum
  sum=$(printf '%s' "$APP_PASS" | sha256sum | cut -c1-64)
  hash=$(sed -n "s/^ADMIN_TOKEN='\(.*\)'$/\1/p" "$INSTALL_DIR/.vaultwarden.env" 2>/dev/null || true)
  if [[ -n $hash && $(state_get VW_PASS_SUM) == "$sum" ]]; then echo "$hash"; return 0; fi
  printf '%s' "$APP_PASS" | vw_argon2 "$(openssl rand -base64 32)"
  state_set VW_PASS_SUM "$sum"
}
vw_env() { # vw_env signups(true|false) admin-token-hash
  envq DOMAIN "$(app_url vault)"
  envq SIGNUPS_ALLOWED "$1"
  envq INVITATIONS_ALLOWED true
  envq ADMIN_TOKEN "$2"
  envq TZ "$TZ_NAME"
}

# Obsidian opens the Notes vault on its first start.
seed_obsidian() {
  local c="$INSTALL_DIR/obsidian/.config/obsidian"
  [[ -f $c/obsidian.json ]] && return 0
  mkdir -p "$c"
  printf '{"vaults":{"%s":{"path":"/vault","ts":%s,"open":true}}}\n' "$(openssl rand -hex 8)" "$(date +%s000)" >"$c/obsidian.json"
  chown -R "$WWW_UID:$WWW_UID" "$INSTALL_DIR/obsidian"
}

write_files() {
  mkdir -p "$INSTALL_DIR"/{secrets,nextcloud,postgres}
  chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/secrets"
  ( umask 077
    printf '%s' "$APP_PASS" >"$INSTALL_DIR/secrets/app_pass"
    printf '%s' "$NC_DB_PASS" >"$INSTALL_DIR/secrets/nc_db_pass" )
  want vault && mkdir -p "$INSTALL_DIR/vaultwarden"
  if want pdf; then mkdir -p "$INSTALL_DIR/stirling"/{configs,logs}; chown -R "$WWW_UID:$WWW_UID" "$INSTALL_DIR/stirling"; fi
  want obsidian && seed_obsidian
  if [[ $HTTPS_MODE == caddy ]]; then ensure_certs; write_caddyfile; write_site; fi
  write_env_files
  write_compose
  save_secrets
  local v
  for v in "${PORT_VARS[@]}" APPS HTTPS_MODE DOMAIN DNS_HOST DATA_DIR TRUSTED_EXTRA ADMIN_EMAIL; do state_set "$v" "${!v}"; done
}

pull_images() {
  local imgs=("$NC_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE")
  run "Downloading Nextcloud, Postgres, Redis" bash -c "$(printf 'docker pull %q && ' "${imgs[@]}") true"
  want office && run "Downloading Collabora Office" docker pull "$COLLABORA_IMAGE"
  if want photos; then
    run "Downloading Immich" bash -c "docker pull '$IMMICH_IMAGE' && docker pull '$IMMICH_DB_IMAGE' && docker pull '$VALKEY_IMAGE'"
    want ml && run "Downloading Immich smart search (about 1 GB)" docker pull "$IMMICH_ML_IMAGE"
  fi
  want vault && run "Downloading Vaultwarden" docker pull "$VW_IMAGE"
  want pdf && run "Downloading Stirling PDF (about 1.5 GB)" docker pull "$STIRLING_IMAGE"
  want obsidian && run "Downloading Obsidian" docker pull "$OBSIDIAN_IMAGE"
  [[ $HTTPS_MODE == caddy ]] && run "Downloading Caddy" docker pull "$CADDY_IMAGE"
  return 0
}

start_stack() {
  step "Starting the apps"
  pull_images
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  run "Starting the containers" dc up -d --remove-orphans
}

# ── Nextcloud ─────────────────────────────────────────────────────────────────
# occ as www-data. stdin is /dev/null: under `curl | bash` it would be the script.
occ() { dc exec -T -u www-data nextcloud php occ "$@" </dev/null; }

nc_wait() { # nc_wait seconds → until Nextcloud is installed and out of maintenance
  local i s
  for (( i = 0; i < $1; i += 5 )); do
    s=$(occ status --output=json 2>/dev/null | tail -n1 || true)
    # Apache starts last: before that the image's own setup may still change settings.
    if [[ $(jq -r '.installed' <<<"$s" 2>/dev/null) == true && $(jq -r '.maintenance' <<<"$s" 2>/dev/null) == false ]] &&
       dc top nextcloud 2>/dev/null | grep -q apache2; then
      echo "Nextcloud $(jq -r '.versionstring' <<<"$s") is ready"; return 0
    fi
    (( i % 30 == 0 )) && echo "still setting up… (${i}s) $(dc logs --tail 1 nextcloud 2>/dev/null | tail -n1)"
    sleep 5
  done
  echo "Nextcloud didn't finish within $1 seconds. Its log:"; dc logs --tail 30 nextcloud
  return 1
}

nc_trusted() {
  local i=0 a
  occ config:system:delete trusted_domains >/dev/null
  while read -r a; do
    occ config:system:set trusted_domains "$i" --value="$a" >/dev/null; i=$((i + 1))
  done < <({ all_addresses; echo localhost; } | awk '!seen[$0]++')
  echo "trusted domains: $({ all_addresses; echo localhost; } | awk '!seen[$0]++' | paste -sd' ' -)"
}

nc_settings() {
  local i=0 r
  nc_trusted
  # The proxy (Caddy, or the DNS stack's) is a private address: trust its forwarded headers.
  occ config:system:delete trusted_proxies >/dev/null
  for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1; do occ config:system:set trusted_proxies "$i" --value="$r" >/dev/null; i=$((i + 1)); done
  occ config:system:set forwarded_for_headers 0 --value=HTTP_X_FORWARDED_FOR
  occ config:system:set overwrite.cli.url --value="$(nc_url)"
  # Built-in HTTPS: every way in is https. DNS mode: http://<ip>:port works too, the proxy says when it's https.
  if [[ $HTTPS_MODE == caddy ]]; then occ config:system:set overwriteprotocol --value=https
  else occ config:system:delete overwriteprotocol; fi
  occ config:system:set allow_local_remote_servers --type=boolean --value=true   # reach Collabora by its container name
  occ config:system:set maintenance_window_start --type=integer --value=1
  occ config:system:set default_phone_region --value="$(locale_region)"
  occ config:system:set skeletondirectory --value=''   # new users start empty (the shared folders are there)
  occ background:cron
  occ user:setting "$APP_USER" settings email "$ADMIN_EMAIL" || true
  occ db:add-missing-indices -n || true
}

locale_region() {
  local r
  r=$(sed -n 's/^LANG=[a-z]*_\([A-Z][A-Z]\).*/\1/p' /etc/default/locale 2>/dev/null | head -n1)
  echo "${r:-US}"
}

nc_apps() { # installs or enables each app; a failing one doesn't stop the rest
  local list a name failed=()
  list=$(occ app:list --output=json 2>/dev/null)
  for a in "${NC_APPS[@]}" files_external $(want office && echo richdocuments); do
    name=$(nc_app_label "$a")
    if jq -e --arg a "$a" '.enabled | has($a)' <<<"$list" >/dev/null 2>&1; then echo "$name: already on"; continue; fi
    if jq -e --arg a "$a" '.disabled | has($a)' <<<"$list" >/dev/null 2>&1; then
      occ app:enable "$a" && { echo "$name: enabled"; continue; }
    fi
    occ app:install "$a" && { echo "$name: installed"; continue; }
    failed+=("$name")
  done
  if (( ${#failed[@]} )); then echo "FAILED: ${failed[*]}"; printf '%s\n' "${failed[@]}" >"$SHL_TMP/nc_failed"; fi
  return 0
}

nc_mounts() {
  local d list id
  list=$(occ files_external:list --output=json 2>/dev/null)
  for d in "${SHARED[@]}"; do
    if jq -e --arg m "/$d" '.[] | select(.mount_point == $m)' <<<"$list" >/dev/null 2>&1; then echo "/$d: already mounted"; continue; fi
    id=$(occ files_external:create "/$d" local null::null -c "datadir=/mnt/cloud/$d" | grep -oE '[0-9]+' | tail -n1)
    [[ -n $id ]] || { echo "couldn't create /$d"; return 1; }
    # Notice files the other apps (Obsidian, Stirling PDF, Immich) put there.
    occ files_external:option "$id" filesystem_check_changes 1
    occ files_external:option "$id" enable_sharing true
    echo "/$d → $DATA_DIR/$d (storage $id)"
  done
}

# Your account's own Documents/Photos/Notes (sample files) would hide the shared ones.
nc_move_samples() {
  local home="$DATA_DIR/nextcloud/$APP_USER/files" d moved=0
  [[ -d $home ]] || return 0
  for d in "${SHARED[@]}" Templates; do
    [[ -d $home/$d ]] || continue
    mkdir -p "$home/Nextcloud samples"; mv "$home/$d" "$home/Nextcloud samples/$d"; moved=1
  done
  (( moved )) && occ files:scan --path="/$APP_USER/files" >/dev/null && echo "moved the sample folders into \"Nextcloud samples\""
  return 0
}

setup_nextcloud() {
  step "Setting up Nextcloud"
  run "Waiting for Nextcloud (the first start installs it: a few minutes)" nc_wait 900
  run "Settings: addresses, proxy, background jobs" nc_settings
  run "Apps: $(for a in "${NC_APPS[@]}"; do nc_app_label "$a"; done | paste -sd, - | sed 's/,/, /g')$(want office && echo ', Office')" nc_apps
  [[ -s $SHL_TMP/nc_failed ]] && warn "Couldn't install: $(paste -sd, - "$SHL_TMP/nc_failed" | sed 's/,/, /g'). Try later in Nextcloud → Apps (the app store may be busy)."
  if [[ $(state_get NC_SAMPLES_MOVED) != 1 ]]; then run "Making room for the shared folders" nc_move_samples; state_set NC_SAMPLES_MOVED 1; fi
  run "Shared folders: ${SHARED[*]}" nc_mounts
  run "Reading the files already in them" occ files:scan --all --quiet
}

# ── Office (Collabora) ────────────────────────────────────────────────────────
office_link() {
  local i pub
  pub=$( [[ $HTTPS_MODE == dns ]] && app_url office || nc_url)
  occ config:app:set richdocuments wopi_url --value=http://collabora:9980
  occ config:app:delete richdocuments wopi_callback_url >/dev/null 2>&1 || true
  occ config:app:set richdocuments disable_certificate_verification --value=yes
  for (( i = 0; i < 180; i += 5 )); do
    if occ richdocuments:activate-config; then
      # activate-config takes the address from Collabora's discovery: make sure it's the public one.
      occ config:app:set richdocuments public_wopi_url --value="$pub"
      echo "browsers open the editor at $pub"
      return 0
    fi
    echo "waiting for Collabora to start… (${i}s)"; sleep 5
  done
  return 1
}

setup_office() {
  step "Connecting Office to Nextcloud"
  run "Linking Nextcloud Office to Collabora" office_link ||
    warn "Office isn't connected yet. When Collabora is up: Nextcloud → Administration → Office → Save."
}

# ── Immich ────────────────────────────────────────────────────────────────────
im_api() { # im_api METHOD PATH [json] → body; fails on an HTTP error. JSON goes in on stdin.
  local m=$1 p=$2 body=${3:-}
  if [[ -n $body ]]; then
    { [[ -n $IM_TOKEN ]] && ckv header "Authorization: Bearer $IM_TOKEN"; ckv header "Content-Type: application/json"; } >"$SHL_TMP/im.cfg"
    printf '%s' "$body" | curl -sk -f -m 60 -X "$m" -K "$SHL_TMP/im.cfg" --data-binary @- "$(local_base photos)$p"
  else
    { if [[ -n $IM_TOKEN ]]; then ckv header "Authorization: Bearer $IM_TOKEN"; fi; } | curl -sk -f -m 60 -X "$m" -K - "$(local_base photos)$p"
  fi
}

im_wait() {
  local i
  for (( i = 0; i < 300; i += 3 )); do
    [[ $(im_api GET /api/server/ping 2>/dev/null | jq -r '.res' 2>/dev/null) == pong ]] && { echo "Immich answers"; return 0; }
    sleep 3
  done
  echo "Immich didn't answer within 300 seconds"; dc logs --tail 20 immich-server; return 1
}

im_creds() { jq -nc --arg e "$ADMIN_EMAIL" --rawfile p "$(sfile ip "$APP_PASS")" --arg n "$APP_USER" '{email: $e, password: $p, name: $n}'; }

im_admin() {
  if [[ $(im_api GET /api/server/config | jq -r '.isInitialized') == true ]]; then echo "the admin account exists"; return 0; fi
  im_api POST /api/auth/admin-sign-up "$(im_creds)" >/dev/null && echo "made the admin account $ADMIN_EMAIL"
}

im_login() { # sets IM_TOKEN and IM_USER (not via run: it sets variables)
  local r
  IM_TOKEN=""
  r=$(im_api POST /api/auth/login "$(im_creds | jq -c 'del(.name)')" 2>/dev/null) || return 1
  IM_TOKEN=$(jq -r '.accessToken // empty' <<<"$r"); IM_USER=$(jq -r '.userId // empty' <<<"$r")
  [[ -n $IM_TOKEN ]]
}

im_library() {
  local id
  id=$(im_api GET /api/libraries | jq -r '.[] | select(.importPaths | index("/mnt/photos")) | .id' | head -n1)
  if [[ -z $id ]]; then
    id=$(im_api POST /api/libraries "$(jq -nc --arg o "$IM_USER" '{ownerId: $o, name: "Photos folder", importPaths: ["/mnt/photos"], exclusionPatterns: ["**/@eaDir/**", "**/.*/**"]}')" | jq -r '.id')
    [[ -n $id && $id != null ]] || { echo "couldn't create the library"; return 1; }
    echo "library \"Photos folder\" → $DATA_DIR/Photos"
  else
    echo "library for $DATA_DIR/Photos exists"
  fi
  im_api POST "/api/libraries/$id/scan" >/dev/null && echo "scanning it"
}

im_config() {
  local c
  c=$(im_api GET /api/system-config) || return 1
  c=$(jq -c --arg url "$(app_url photos)" --argjson ml "$(want ml && echo true || echo false)" \
    '.library.watch.enabled = true | .library.scan.enabled = true | .machineLearning.enabled = $ml | .server.externalDomain = $url' <<<"$c")
  im_api PUT /api/system-config "$c" >/dev/null && echo "watching the Photos folder · smart search $( want ml && echo on || echo off) · links use $(app_url photos)"
}

setup_photos() {
  step "Setting up Immich"
  run "Waiting for Immich" im_wait
  run "Immich admin account" im_admin
  if ! im_login; then
    warn "Couldn't log in to Immich as $ADMIN_EMAIL (password changed there?): the Photos library wasn't added."
    return 0
  fi
  ok "Logged in to Immich as $ADMIN_EMAIL"
  run "Library for the Photos folder" im_library
  run "Immich settings" im_config
}

# ── Vaultwarden ───────────────────────────────────────────────────────────────
vw_lock() {
  local h
  h=$(vw_hash)
  ( umask 077; vw_env false "$h" >"$INSTALL_DIR/.vaultwarden.env" )
  dc up -d vaultwarden
}

vw_wait() {
  local i
  for (( i = 0; i < 90; i += 3 )); do [[ $(lcode "$(local_base vault)/alive") == 200 ]] && { echo "Vaultwarden answers"; return 0; }; sleep 3; done
  echo "Vaultwarden didn't answer"; return 1
}

setup_vault() {
  step "Vaultwarden"
  run "Waiting for Vaultwarden" vw_wait
  local n ans
  n=$(vw_users)
  if (( n > 0 )); then
    [[ $(sed -n "s/^SIGNUPS_ALLOWED='\(.*\)'$/\1/p" "$INSTALL_DIR/.vaultwarden.env") == false ]] || run "Closing sign-ups ($n account(s) exist)" vw_lock
    ok "Vaultwarden: $n account(s), sign-ups closed (invite more from the admin page)"
    return 0
  fi
  info "Your vault is encrypted with a master password only you know: the script can't make the account for you."
  if (( ASSUME_YES )) || ! has_tty; then
    warn "Sign-ups stay open until you make your account at $(app_url vault), then run:  $(run_hint " --lock-signups")"
    return 0
  fi
  printf '    1. Open %s%s%s\n' "$C_CYAN" "$(app_url vault)" "$C_RESET" >/dev/tty
  [[ $HTTPS_MODE == caddy ]] && printf '       %s(trust the certificate first: http://%s%s, or accept the warning)%s\n' "$C_GRAY" "$HOST_IP" "$( [[ $P_HTTP == 80 ]] || echo ":$P_HTTP")" "$C_RESET" >/dev/tty
  printf '    2. "Create account" with a master password you won'"'"'t forget (it can'"'"'t be reset).\n' >/dev/tty
  while :; do
    ans=$(ask "Press Enter once the account exists (s = skip, lock later)" "")
    [[ ${ans,,} == s* ]] && { warn "Sign-ups stay open. Close them later:  $(run_hint " --lock-signups")"; return 0; }
    n=$(vw_users)
    (( n > 0 )) && break
    warn "No account yet. Make it in the browser, then press Enter."
  done
  run "Closing sign-ups" vw_lock
  ok "Vaultwarden: your account is made, nobody else can sign up"
}

lock_signups() {
  load_install
  want vault || die "Vaultwarden isn't part of this install."
  local n
  n=$(vw_users)
  (( n > 0 )) || die "There's no Vaultwarden account yet: make yours at $(app_url vault) first."
  run "Closing Vaultwarden sign-ups ($n account(s))" vw_lock
  ok "Done. Invite more people from $(app_url vault)/admin (log in with your stack password)."
}

# ── Stirling PDF + Obsidian ───────────────────────────────────────────────────
wait_app() { # wait_app app seconds "what" → waits for any answer that isn't an error
  local i c
  for (( i = 0; i < $2; i += 3 )); do
    c=$(lcode "$(local_base "$1")/")
    [[ $c =~ ^(200|30[0-9]|401)$ ]] && { echo "$3 answers ($c)"; return 0; }
    sleep 3
  done
  echo "$3 didn't answer within $2 seconds"; return 1
}

setup_tools() {
  step "Stirling PDF and Obsidian"
  if want pdf; then
    run "Waiting for Stirling PDF (Java: a minute on the first start)" wait_app pdf 240 "Stirling PDF" || warn "Stirling PDF is still starting: give it a minute."
    info "Drop PDFs into Documents/PDF Inbox/OCR (searchable text) or …/Compress (smaller): results land in PDF Done."
  fi
  if want obsidian; then
    run "Waiting for Obsidian" wait_app obsidian 180 "Obsidian" || warn "Obsidian is still starting: give it a minute."
  fi
  return 0
}

# ── Names through the Private DNS Stack ───────────────────────────────────────
dns_names() { # → "name port" for each app
  echo "cloud $P_NC"
  want office && echo "office $P_OFFICE"
  want photos && echo "photos $P_PHOTOS"
  want vault && echo "vault $P_VAULT"
  want pdf && echo "pdf $P_PDF"
  want obsidian && echo "notes $P_NOTES"
  return 0
}

dns_add() { # dns_add name port → through the DNS stack's own script
  local out rc=0
  out=$(SHL_NO_BANNER=1 bash "$SHL_TMP/pihole.sh" "--add=$1=$HOST_IP:$2" --yes 2>&1) || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) && return 0
  grep -q 'already exists' <<<"$out" && { echo "$1.$DOMAIN was already there"; return 0; }
  return "$rc"
}

setup_names() {
  step "App names (Private DNS Stack)"
  local name port
  dns_names >"$INSTALL_DIR/.dns-names"
  if [[ -n ${SHL_NAMES_BY_WRAPPER:-} ]]; then info "The names are added next, by the $SHL_NAMES_BY_WRAPPER installer."; return 0; fi
  if [[ $DNS_HOST == local ]]; then
    run "Getting the DNS stack's script" curl -fsSL "$DNS_SCRIPT_URL" -o "$SHL_TMP/pihole.sh"
    while read -r name port; do
      run "https://$name.$DOMAIN → port $port" dns_add "$name" "$port" || warn "Couldn't add $name.$DOMAIN: add it in the DNS stack's menu (Add a name → localhost:$port)."
    done < <(dns_names)
    return 0
  fi
  local list="" base=${DNS_SCRIPT_URL%/linux/*}
  while read -r name port; do list+="$name=$HOST_IP:$port "; done < <(dns_names)
  list=${list% }
  warn "Run this on the machine with the DNS stack ($DNS_HOST) to make the names (pick its system):"
  printf '    %sUbuntu / Debian:%s
      %sfor a in %s; do sudo bash -c "$(curl -fsSL %s)" _ --add=$a --yes; done%s
' \
    "$C_GRAY" "$C_RESET" "$C_CYAN" "$list" "$DNS_SCRIPT_URL" "$C_RESET"
  printf '    %sProxmox (on the host):%s
      %sfor a in %s; do bash -c "$(curl -fsSL %s/proxmox/pihole.sh)" _ --add=$a --yes; done%s
' \
    "$C_GRAY" "$C_RESET" "$C_CYAN" "$list" "$base" "$C_RESET"
  printf '    %sTrueNAS:%s
      %scurl -fsSL %s/truenas/pihole.sh -o /tmp/pihole.sh && for a in %s; do sudo bash /tmp/pihole.sh --add=$a --yes; done%s
' \
    "$C_GRAY" "$C_RESET" "$C_CYAN" "$base" "$list" "$C_RESET"
  if (( ! ASSUME_YES )) && has_tty; then ask "Press Enter when they're added (or later: the apps work once the names exist)" "" >/dev/null; fi
}

# ── Backups ───────────────────────────────────────────────────────────────────
write_backup() {
  local f="$INSTALL_DIR/backup.sh"
  cat >"$f" <<EOF
#!/usr/bin/env bash
# sudo homelab · Cloud Stack nightly backup (made by cloud.sh; re-run it to change)
# Databases and Vaultwarden into $DATA_DIR/backups, keeping the last 7 of each.
# Your files themselves (Documents, Notes, Photos…) aren't copied: back up $DATA_DIR elsewhere.
set -euo pipefail
DIR="$DATA_DIR/backups"; KEEP=7; D=\$(date +%Y%m%d-%H%M)
dc() { docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "\$@"; }
umask 077
mkdir -p "\$DIR"
dc exec -T postgres pg_dump -U nextcloud -Fc nextcloud </dev/null >"\$DIR/nextcloud-db-\$D.dump"
tar czf "\$DIR/nextcloud-config-\$D.tar.gz" -C "$INSTALL_DIR/nextcloud" config
echo "Nextcloud database and config saved"
EOF
    want photos && cat >>"$f" <<EOF
dc exec -T immich-db pg_dumpall --clean --if-exists -U postgres </dev/null | gzip >"\$DIR/immich-db-\$D.sql.gz"
echo "Immich database saved"
EOF
    want vault && cat >>"$f" <<EOF
T=\$(mktemp -d); trap 'rm -rf "\$T"' EXIT
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).backup(sqlite3.connect(sys.argv[2]))' "$INSTALL_DIR/vaultwarden/db.sqlite3" "\$T/db.sqlite3"
tar czf "\$DIR/vaultwarden-\$D.tar.gz" -C "$INSTALL_DIR/vaultwarden" --exclude='db.sqlite3*' --exclude=icon_cache . -C "\$T" db.sqlite3
echo "Vaultwarden saved"
EOF
    cat >>"$f" <<'EOF'
for p in nextcloud-db nextcloud-config immich-db vaultwarden; do
  { ls -1t "$DIR/$p-"* 2>/dev/null || true; } | tail -n +$((KEEP + 1)) | xargs -r rm -f   # no file yet = nothing to prune
done
echo "Backups in $DIR: $(du -sh "$DIR" | cut -f1)"
EOF
  chmod 700 "$f"
  backup_schedule "$f"
}

# Nightly at 3:30 (a systemd timer here; TrueNAS uses its own cron jobs).
backup_schedule() { # backup_schedule script
  cat >"/etc/systemd/system/$BACKUP_UNIT.service" <<EOF
[Unit]
Description=sudo homelab Cloud Stack backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$1
EOF
  cat >"/etc/systemd/system/$BACKUP_UNIT.timer" <<EOF
[Unit]
Description=sudo homelab Cloud Stack backup, nightly

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$BACKUP_UNIT.timer"
}
backup_scheduled() { # → when it runs next; fails if it isn't scheduled
  systemctl is-active --quiet "$BACKUP_UNIT.timer" || return 1
  systemctl show -p NextElapseUSecRealtime --value "$BACKUP_UNIT.timer" 2>/dev/null | awk '{print $1, $2, $3}'
}
backup_unschedule() {
  systemctl disable --now "$BACKUP_UNIT.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/$BACKUP_UNIT.service" "/etc/systemd/system/$BACKUP_UNIT.timer"
  systemctl daemon-reload
}

setup_backups() {
  step "Nightly backups"
  run "Backup job (every night at 3:30)" write_backup
  run "First backup" "$INSTALL_DIR/backup.sh"
}

backup_now() {
  load_install
  [[ -x $INSTALL_DIR/backup.sh ]] || die "No backup job yet: re-run Install."
  run "Backing up" "$INSTALL_DIR/backup.sh"
  ok "Saved in $DATA_DIR/backups"
}

# ── Check + summary ───────────────────────────────────────────────────────────
verify() {
  step "Checking that it works"
  local fails=0 code n pub
  if [[ $(curl -sk -m 10 "$(local_base nextcloud)/status.php" | jq -r .installed 2>/dev/null) == true ]]; then ok "Nextcloud answers through $( [[ $HTTPS_MODE == caddy ]] && echo "HTTPS" || echo "its port")"
  else err "Nextcloud doesn't answer at $(local_base nextcloud)"; fails=1; fi
  code=$( { ckv user "$APP_USER:$APP_PASS"; ckv header "OCS-APIRequest: true"; } | curl -sk -o /dev/null -m 10 -w '%{http_code}' -K - "$(local_base nextcloud)/ocs/v2.php/cloud/user")
  if [[ $code == 200 ]]; then ok "Nextcloud login works ($APP_USER)"; else err "Nextcloud login failed (HTTP $code)"; fails=1; fi
  # Every name and address you open it with (Nextcloud refuses the ones it doesn't trust).
  local bad=() addr
  while read -r addr; do
    [[ $(curl -sk -m 8 -H "Host: $addr" "$(local_base nextcloud)/status.php" | jq -r .installed 2>/dev/null) == true ]] || bad+=("$addr")
  done < <(all_addresses)
  if (( ${#bad[@]} == 0 )); then ok "Nextcloud accepts $(all_addresses | paste -sd, - | sed 's/,/, /g')"
  else err "Nextcloud refuses: ${bad[*]} (trusted domains)"; fails=1; fi
  n=$(occ files_external:list --output=json 2>/dev/null | jq '[.[] | select(.mount_point | test("^/(Documents|Notes|Photos)$"))] | length' 2>/dev/null || echo 0)
  if [[ $n == 3 ]]; then ok "Documents, Notes and Photos are in Nextcloud"; else err "Only $n of the 3 shared folders are in Nextcloud"; fails=1; fi
  if want office; then
    code=$(lcode "$(local_base office)/hosting/discovery")
    pub=$(occ config:app:get richdocuments public_wopi_url 2>/dev/null || true)
    if [[ $code == 200 && $pub == "$( [[ $HTTPS_MODE == dns ]] && app_url office || nc_url)" ]]; then ok "Office is connected (editor at $pub)"
    else err "Office isn't connected (Collabora: HTTP $code, editor address '$pub')"; fails=1; fi
  fi
  if want photos; then
    if im_login; then ok "Immich login works ($ADMIN_EMAIL)"; else err "Immich login failed"; fails=1; fi
  fi
  if want vault; then
    if [[ $(lcode "$(local_base vault)/alive") == 200 ]]; then ok "Vaultwarden answers"; else err "Vaultwarden doesn't answer"; fails=1; fi
  fi
  if want pdf; then
    code=$(lcode "$(local_base pdf)/login")
    if [[ $code =~ ^(200|30[0-9])$ ]]; then ok "Stirling PDF answers (login page)"; else warn "Stirling PDF: HTTP $code (still starting?)"; fi
  fi
  if want obsidian; then
    code=$(lcode "$(local_base obsidian)/")
    n=$( { ckv user "$APP_USER:$APP_PASS"; } | curl -sk -o /dev/null -m 8 -w '%{http_code}' -K - "$(local_base obsidian)/" || true)
    if [[ $code == 401 && $n == 200 ]]; then ok "Obsidian asks for the login, and it works"
    else err "Obsidian: HTTP $code without login, $n with it"; fails=1; fi
  fi
  if [[ $HTTPS_MODE == caddy ]]; then
    if [[ $(http_code "http://127.0.0.1:$P_HTTP/sudohomelab-cloud-ca.crt") == 200 ]]; then ok "Certificate page is up"; else err "The certificate page doesn't answer"; fails=1; fi
  fi
  if n=$(backup_scheduled); then ok "Nightly backup is scheduled (${n:-3:30})"
  else err "The backup timer isn't active"; fails=1; fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is active: allow the ports with  sudo ufw allow <port>/tcp  ($(for v in "${PORT_VARS[@]}"; do port_needed "$v" && printf '%s ' "${!v}"; done | sed 's/ $//'))"
  fi
  (( fails == 0 )) || warn "Some checks failed. The apps are installed; see the log for details: $LOG_FILE"
}

manage_hint() { printf '    %sManage:%s    cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"; }

sline() { printf '    %s%-13s%s %s%s%s  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET" "$C_CYAN" "$2" "$C_RESET" "$C_GRAY" "$3" "$C_RESET"; }

summary() {
  step "Done"
  local f="$INSTALL_DIR/credentials.txt" cert_page=""
  [[ $HTTPS_MODE == caddy ]] && cert_page="http://$HOST_IP$( [[ $P_HTTP == 80 ]] || echo ":$P_HTTP")"
  ( umask 077
    {
      echo "sudo homelab · Cloud Stack ($(date))"
      echo
      echo "Nextcloud     $(nc_url)        login $APP_USER"
      want photos && echo "Immich        $(app_url photos)        login $ADMIN_EMAIL"
      want vault && echo "Vaultwarden   $(app_url vault)        your own account · admin page /admin (stack password)"
      want pdf && echo "Stirling PDF  $(app_url pdf)        login $APP_USER"
      want obsidian && echo "Obsidian      $(app_url obsidian)        login $APP_USER"
      echo "Password      $APP_PASS"
      [[ -n $cert_page ]] && echo "Certificate   $cert_page"
      echo
      echo "Files         $DATA_DIR"
      echo "Backups       $DATA_DIR/backups (nightly, last 7)"
    } >"$f" )

  printf '\n  %s%s★ Your cloud is running and connected!%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  sline "Nextcloud" "$(nc_url)" "login $APP_USER · Files, Calendar, Contacts, Tasks, Mail, Deck, Notes, News, Collectives$(want office && echo ', Office')"
  want photos && sline "Immich" "$(app_url photos)" "login $ADMIN_EMAIL"
  want vault && sline "Vaultwarden" "$(app_url vault)" "your own account"
  want pdf && sline "Stirling PDF" "$(app_url pdf)" "login $APP_USER"
  want obsidian && sline "Obsidian" "$(app_url obsidian)" "login $APP_USER"
  printf '    %s%-13s%s %s%s\n' "$C_BOLD" "Password" "$C_RESET" "$APP_PASS" "$( [[ ${GENERATED_PASS:-0} == 1 ]] && printf '  %s(generated)%s' "$C_GRAY" "$C_RESET")"
  printf '    %sSaved%s         %s %s(root only)%s\n' "$C_GRAY" "$C_RESET" "$f" "$C_GRAY" "$C_RESET"

  if [[ -n $cert_page ]]; then
    printf '\n  %sTrust the certificate once on each device%s %s(no more warnings, and the phone apps can connect)%s\n' "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '    Open %s%s%s on it: download the certificate and follow the steps there.\n' "$C_CYAN" "$cert_page" "$C_RESET"
    if command -v qrencode >/dev/null 2>&1 && (( IS_TTY )); then
      printf '    %sOn a phone, scan this:%s\n' "$C_GRAY" "$C_RESET"
      qrencode -t ANSIUTF8 -m 1 "$cert_page" 2>/dev/null | sed 's/^/      /' || true
    fi
    want office && printf '    %sOffice opens documents through %s: use that address (not a name or VPN IP) when editing.%s\n' "$C_GRAY" "$(nc_url)" "$C_RESET"
  fi

  printf '\n  %sYour folders%s %s(%s)%s\n' "$C_BOLD" "$C_RESET" "$C_GRAY" "$DATA_DIR" "$C_RESET"
  printf '    Documents, Notes and Photos show up in Nextcloud for every user.\n'
  want obsidian && printf '    Notes is also the Obsidian vault and the Notes app'"'"'s folder.\n'
  want photos && printf '    Photos is an Immich library (read-only there); the Immich phone app backs up into %s/immich.\n' "$DATA_DIR"
  want pdf && printf '    PDFs dropped in Documents/PDF Inbox/OCR or /Compress come out in Documents/PDF Done.\n'

  printf '\n  %sPhone and desktop apps%s\n' "$C_BOLD" "$C_RESET"
  printf '    Nextcloud (files), DAVx⁵ or the iPhone accounts (calendar + contacts): server %s\n' "$(nc_url)"
  want photos && printf '    Immich: server %s\n' "$(app_url photos)"
  want vault && printf '    Bitwarden: Self-hosted → server %s\n' "$(app_url vault)"

  echo
  [[ -z ${SHL_HINT_CMD:-} ]] && manage_hint
  printf '    %sBackups:%s   %s/backups every night · now: %s\n' "$C_GRAY" "$C_RESET" "$DATA_DIR" "$(run_hint " --backup")"
  printf '    %sMenu:%s      %s\n' "$C_GRAY" "$C_RESET" "$(run_hint)"
  printf '    %sUninstall:%s %s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --uninstall")"
  printf '    %sLog:%s       %s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s      %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
}

# ── Actions: lock / backup / uninstall ────────────────────────────────────────
load_install() {
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint)"
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "Nothing is installed yet. Install first:  $(run_hint " --install")"
  local v val
  for v in "${PORT_VARS[@]}" APPS HTTPS_MODE DOMAIN DNS_HOST DATA_DIR TRUSTED_EXTRA ADMIN_EMAIL; do
    val=$(state_get "$v"); [[ -n $val ]] && printf -v "$v" '%s' "$val"
  done
  load_secrets
  HOST_IP=$(host_ip); TZ_NAME=$(detect_tz)
  [[ $(docker inspect -f '{{.State.Running}}' "$(dc ps -q nextcloud 2>/dev/null)" 2>/dev/null) == true ]] ||
    die "The stack isn't running. Start it:  cd $INSTALL_DIR && sudo docker compose up -d"
}

uninstall() {
  (( BANNER_SHOWN )) || banner
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "No Cloud Stack from this script found in $INSTALL_DIR."
  DATA_DIR=$(state_get DATA_DIR)
  local mode
  mode=$(state_get HTTPS_MODE)
  warn "This stops and removes Nextcloud and the other apps of the Cloud Stack."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|settings, databases and your files stay: re-run the installer to bring it all back" \
      "Delete settings|delete the apps' settings and databases; keep your files in ${DATA_DIR:-the data folder}" \
      "Delete all|also delete your files: Documents, Notes, Photos, backups") in
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
    warn "Settings and databases in $INSTALL_DIR will be deleted (calendars, contacts, Immich albums, your vault…)."
    info "Your files in $DATA_DIR stay."
  else
    info "Everything stays in $INSTALL_DIR and $DATA_DIR."
  fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  run "Removing the containers" dc down --remove-orphans
  # With nothing running it would fail every night; a reinstall puts it back.
  run "Removing the nightly backup job" backup_unschedule
  (( PURGE )) && run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"
  if (( DELETE_FILES )) && [[ -n $DATA_DIR && $DATA_DIR != / ]]; then run "Deleting $DATA_DIR" rm -rf "$DATA_DIR"; fi
  [[ $mode == dns ]] && info "The app names (cloud.…) stay in the DNS stack: delete them from its menu."
  ok "Uninstalled."
}

main() {
  ORIG_ARGS=("$@")
  SHL_TMP=$(mktemp -d /tmp/sudohomelab.XXXXXX); chmod 700 "$SHL_TMP"
  trap cleanup EXIT
  parse_args "$@"
  mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR=/tmp; LOG_FILE="/tmp/$(basename "$LOG_FILE")"; }
  : >"$LOG_FILE" 2>/dev/null || { LOG_FILE=/tmp/$(basename "$LOG_FILE"); : >"$LOG_FILE"; }
  chmod 600 "$LOG_FILE"
  log "sudo homelab cloud v$VERSION · args: $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
  log "kernel: $(uname -a)"

  check_interactive
  if [[ -n $ACTION ]] || (( ASSUME_YES )) || ! has_tty; then
    ACTION=${ACTION:-install}
    run_action
  else
    menu_loop
  fi
}

run_action() {
  log "action: $ACTION"
  case $ACTION in
    uninstall) uninstall; return ;;
    lock) (( BANNER_SHOWN )) || banner; lock_signups; return ;;
    backup) (( BANNER_SHOWN )) || banner; backup_now; return ;;
  esac

  START_TIME=$SECONDS
  (( BANNER_SHOWN )) || banner
  preflight
  choose_options
  install_deps
  make_folders
  start_stack
  setup_nextcloud
  want office && setup_office
  want photos && setup_photos
  want vault && setup_vault
  { want pdf || want obsidian; } && setup_tools
  [[ $HTTPS_MODE == dns ]] && setup_names
  setup_backups
  verify
  summary
  log "install finished"
}

# The menu comes back after each action until you pick Quit. Each action runs
# in a subshell, so its exits (done, cancelled or failed) return here.
menu_loop() {
  local ans
  while :; do
    choose_action
    [[ $ACTION == quit ]] && break
    trap - ERR; set +e
    ( set -e; trap 'on_error $LINENO "$BASH_COMMAND"' ERR; run_action )
    set -e; trap 'on_error $LINENO "$BASH_COMMAND"' ERR
    printf '\n  %s›%s Press Enter for the menu, or q to quit: ' "$C_CYAN" "$C_RESET" >/dev/tty
    IFS= read -r ans </dev/tty || ans=q
    [[ ${ans,,} =~ ^q(uit)?$ ]] && break
  done
  info "Bye."
}

# No action given: the main menu.
BANNER_SHOWN=0
choose_action() {
  (( BANNER_SHOWN )) || { banner; BANNER_SHOWN=1; }
  local installed=0
  [[ -f $INSTALL_DIR/docker-compose.yml ]] && installed=1
  case $(menu "What would you like to do?" 1 \
    "Install|$( (( installed )) && echo "already installed: re-run the setup to change settings" || echo "Nextcloud + Office, Immich, Vaultwarden, Stirling PDF, Obsidian")" \
    "Lock sign-ups|close Vaultwarden sign-ups once your account exists" \
    "Back up now|save the databases and Vaultwarden into the backups folder" \
    "Uninstall|remove the apps (asks whether to keep the data)" \
    "Quit|close the menu") in
    1) ACTION=install ;; 2) ACTION=lock ;; 3) ACTION=backup ;; 4) ACTION=uninstall ;; 5) ACTION=quit ;;
  esac
}

[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
