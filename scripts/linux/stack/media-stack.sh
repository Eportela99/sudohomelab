#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Media Stack installer (Ubuntu / Debian)
#  https://github.com/Eportela99/sudohomelab
#
#  Installs Jellyfin and/or Plex, qBittorrent and/or SABnzbd, plus Seerr,
#  Radarr, Sonarr and Prowlarr as Docker containers, and wires them together:
#    · Radarr / Sonarr  → root folders + download clients
#    · Prowlarr         → syncs indexers to Radarr & Sonarr
#    · Seerr            → Radarr & Sonarr pre-configured
#    · qBittorrent / SABnzbd → download folders + categories
#
#  Usage:
#    sudo bash -c "$(curl -fsSL <url>/media-stack.sh)"
#    sudo bash -c "$(curl -fsSL <url>/media-stack.sh)" _ --uninstall --purge
#    (`curl | sudo bash` only works with --yes: see check_interactive)
#    sudo bash media-stack.sh --server=jellyfin --downloader=qbittorrent --yes
#    sudo bash media-stack.sh --help
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.1"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts/linux/stack/media-stack.sh"
INSTALL_DIR="/opt/sudohomelab/media-stack"
DATA_DIR="/srv/media"
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/media-stack-$(date +%Y%m%d-%H%M%S).log"

SERVER=""            # jellyfin | plex | both
DOWNLOADER=""        # qbittorrent | sabnzbd | both
APP_USER=""
APP_PASS=""
PLEX_CLAIM=""
ASSUME_YES=0
DATA_DIR_SET=0
DRY_RUN=0
UNINSTALL=0
PURGE=0

SEERR_IMAGE="ghcr.io/seerr-team/seerr:latest"
LSIO="lscr.io/linuxserver"

# Host ports
P_JELLYFIN=8096; P_PLEX=32400; P_QBIT=8080; P_SAB=8085
P_RADARR=7878; P_SONARR=8989; P_PROWLARR=9696; P_SEERR=5055

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
CURL_FAIL=--fail
TOTAL_STEPS=10
CURRENT_STEP="starting"

# Logs may be attached to public GitHub issues: secrets are masked, colours stripped.
log() {
  local m="$*" secret
  for secret in "${APP_PASS:-}" "${RADARR_KEY:-}" "${SONARR_KEY:-}" "${PROWLARR_KEY:-}" "${SAB_KEY:-}"; do
    [[ ${#secret} -ge 6 ]] && m=${m//"$secret"/***}
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
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sMedia Stack%s installer %sv%s · Ubuntu / Debian%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

step() {
  STEP=$((STEP + 1))
  CURRENT_STEP="$1"
  printf '\n%s━━ %s[%d/%d]%s %s%s%s\n' "$C_PURPLE" "$C_GRAY" "$STEP" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  log "════ STEP $STEP/$TOTAL_STEPS: $1"
}

LIVE_LINES=6   # how many lines of live output to show under a running step

# Clean a chunk of command output for display: carriage-return progress bars
# become separate lines, colour codes go, blank lines go.
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
  # Erase the window and leave the cursor where it started.
  printf '\e[%dA' "$drawn"
  for (( k = 0; k < drawn; k++ )); do printf '\e[2K\n'; done
  printf '\e[%dA\e[?25h' "$drawn"
}

# run "message" command [args...]
#  · terminal: live view of the command's output while it runs
#  · no terminal (CI, ssh without -t): output is streamed, indented
#  Everything is also written to the log file.
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
    ( trap - ERR; set -o pipefail; "$@" 2>&1 | tee -a "$LOG_FILE" | clean_output | sed 's/^/    │ /' ) || rc=$?
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
  tail -n 25 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' >&2
  printf '\nThe script is safe to re-run: finished steps are skipped.\n' >&2
  printf 'Report issues: https://github.com/Eportela99/sudohomelab/issues (attach the log)\n\n' >&2
  log "FAILED at line $line: $cmd (exit $rc)"
  exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Prompts (read from /dev/tty so `curl | bash` still works) ─────────────────
# True when we own the terminal's foreground. Under `curl ... | sudo bash`, sudo
# (with use_pty, the default on current Ubuntu) runs the command in the
# background of its own pty: any read from /dev/tty then gets SIGTTIN and the
# script silently freezes. So "a terminal exists" is not enough to prompt.
tty_foreground() {
  local pgid tpgid
  read -r pgid tpgid < <(ps -o pgid=,tpgid= -p $$ 2>/dev/null) || return 1
  [[ -n $tpgid && $tpgid != -1 && $pgid == "$tpgid" ]]
}

has_tty() { [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null && tty_foreground; }

# Stop early, with the right command, instead of freezing at the first question.
check_interactive() {
  (( ASSUME_YES )) && return 0
  [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null || return 0   # no terminal at all: defaults apply
  tty_foreground && return 0
  local args="" a
  for a in "${ORIG_ARGS[@]}"; do args+=" $(printf '%q' "$a")"; done
  printf '\n  %s✗%s This script asks you questions, but %scurl | sudo bash%s runs it in the background,\n' "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
  printf '    so it can'"'"'t read your answers. Run it like this instead:\n\n' >&2
  printf '      %ssudo bash -c "$(curl -fsSL %s)"%s%s\n\n' "$C_CYAN" "$SCRIPT_URL" "${args:+ _$args}" "$C_RESET" >&2
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

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
sudo homelab · Media Stack installer v$VERSION

Usage: sudo bash media-stack.sh [options]

  --server=jellyfin|plex|both        Media server(s) to install
  --downloader=qbittorrent|sabnzbd|both
                                     Download client(s) to install
  --data-dir=PATH                    Media + downloads folder   (default $DATA_DIR)
  --install-dir=PATH                 Compose file + app configs (default $INSTALL_DIR)
  --username=NAME                    Login for Radarr/Sonarr/Prowlarr/downloaders
  --password=PASS                    Password for those apps (generated if omitted)
  --plex-claim=TOKEN                 Claim token from https://plex.tv/claim (optional)
  -y, --yes                          Non-interactive, accept defaults
  --dry-run                          Show what would be installed, change nothing
  --uninstall                        Stop and remove the stack (keeps media + configs)
  --purge                            With --uninstall, also delete app configs
  -h, --help                         Show this help
EOF
}

parse_args() {
  for arg in "$@"; do
    case $arg in
      --server=*) SERVER=${arg#*=} ;;
      --downloader=*) DOWNLOADER=${arg#*=} ;;
      --data-dir=*) DATA_DIR=${arg#*=}; DATA_DIR_SET=1 ;;
      --install-dir=*) INSTALL_DIR=${arg#*=} ;;
      --username=*) APP_USER=${arg#*=} ;;
      --password=*) APP_PASS=${arg#*=} ;;
      --plex-claim=*) PLEX_CLAIM=${arg#*=} ;;
      --extras=*) EXTRAS_IGNORED=${arg#*=} ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  # Accept the website's comma-separated form, e.g. --downloader=qbittorrent,sabnzbd
  [[ $SERVER == *,* ]] && SERVER=both
  [[ $DOWNLOADER == *,* ]] && DOWNLOADER=both
  return 0
}

was_installed() { # same as want(), against the previous run's choices
  case $1 in
    jellyfin|plex) [[ $PREV_SERVER == "$1" || $PREV_SERVER == both ]] ;;
    qbittorrent|sabnzbd) [[ $PREV_DOWNLOADER == "$1" || $PREV_DOWNLOADER == both ]] ;;
  esac
}

want() { # want jellyfin|plex|qbittorrent|sabnzbd
  case $1 in
    jellyfin|plex) [[ $SERVER == "$1" || $SERVER == both ]] ;;
    qbittorrent|sabnzbd) [[ $DOWNLOADER == "$1" || $DOWNLOADER == both ]] ;;
  esac
}

gen_secret() { python3 -c "import secrets; print(secrets.token_${1:-hex}(${2:-16}))"; }

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

dc() { docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }

# HTTP helpers. Bodies of failed requests land in the log via --fail-with-body.
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || true; }

wait_for() { # wait_for "name" url [timeout] [extra curl args...]
  local name=$1 url=$2 timeout=${3:-180}; shift 3 || shift $#
  local start=$SECONDS code
  while (( SECONDS - start < timeout )); do
    code=$(http_code "$@" "$url")
    [[ $code =~ ^(200|30[1-8]|401|403)$ ]] && { log "$name ready ($code) after $((SECONDS - start))s"; return 0; }
    echo "$name is starting up… (HTTP ${code:-000}, $((SECONDS - start))s / ${timeout}s)"
    sleep 2
  done
  log "$name not ready after ${timeout}s (last HTTP $code) at $url"
  return 1
}

api() { # api METHOD URL KEY [JSON]
  local method=$1 url=$2 key=$3 data=${4:-}
  local args=(-sS "$CURL_FAIL" -m 30 -X "$method" -H "X-Api-Key: $key" -H 'Content-Type: application/json')
  [[ -n $data ]] && args+=(--data "$data")
  curl "${args[@]}" "$url"
}

xml_key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$1" 2>/dev/null | head -n1; }

# ── Steps ─────────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Please run as root:  sudo bash -c \"\$(curl -fsSL $SCRIPT_URL)\""

  [[ -r /etc/os-release ]] || die "Cannot detect the OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=$ID; OS_NAME=$PRETTY_NAME
  case $OS_ID in
    ubuntu|debian) ok "OS: $OS_NAME" ;;
    *) [[ ${ID_LIKE:-} == *debian* ]] && warn "OS: $OS_NAME (Debian-based, not officially tested)" \
         || die "Unsupported OS: $OS_NAME. This installer supports Ubuntu Server and Debian." ;;
  esac

  ARCH=$(dpkg --print-architecture)
  [[ $ARCH == amd64 || $ARCH == arm64 ]] || die "Unsupported architecture: $ARCH (need amd64 or arm64)."
  ok "Architecture: $ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"

  local mem_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  (( mem_mb >= 1800 )) || warn "Less than 2 GB RAM detected. The stack may struggle."

  TZ_NAME=$(detect_tz); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "Server IP: $HOST_IP"

  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    PUID=$(id -u "$SUDO_USER"); PGID=$(id -g "$SUDO_USER"); OWNER=$SUDO_USER
  elif id -u 1000 >/dev/null 2>&1; then
    PUID=1000; PGID=$(id -g 1000); OWNER=$(id -nu 1000)
  else
    PUID=1000; PGID=1000; OWNER="uid 1000"
  fi
  ok "Apps will run as $OWNER (PUID=$PUID PGID=$PGID)"

  # A render node (renderD*) means a usable GPU; VMs often expose only a
  # virtual display card (card0), which can't transcode.
  if compgen -G '/dev/dri/renderD*' >/dev/null; then
    HAS_DRI=1; ok "GPU found ($(compgen -G '/dev/dri/renderD*' | head -n1)): hardware transcoding enabled"
  else
    HAS_DRI=0; info "No GPU render device found: media servers will use CPU transcoding"
  fi

  if (( (mem_mb < 4096) )) && (( $(nproc) < 2 )); then
    warn "1 CPU / <4 GB RAM: fine for streaming, but avoid running both media servers plus transcoding."
  fi
}

menu_index() { # menu_index value option1 option2 ... → 1-based index (1 if not found)
  local v=$1 i=1; shift
  for o in "$@"; do [[ $o == "$v" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo 1
}

# One login shared by Radarr, Sonarr, Prowlarr, qBittorrent and SABnzbd.
ask_credentials() {
  local interactive=0
  (( ! ASSUME_YES )) && has_tty && interactive=1

  if (( interactive )); then
    printf '\n  %sLogin for your apps%s %s(Radarr, Sonarr, Prowlarr, qBittorrent, SABnzbd)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
  fi
  while [[ -z $APP_USER ]] || [[ ! $APP_USER =~ ^[A-Za-z0-9._-]{3,32}$ ]]; do
    [[ -n $APP_USER ]] && warn "Username must be 3-32 characters: letters, numbers, . _ -"
    (( interactive )) || { APP_USER=${APP_USER:-admin}; break; }
    APP_USER=$(ask "Username" "admin")
  done

  if [[ -z $APP_PASS ]] && (( interactive )); then
    case $(menu "Password for '$APP_USER'" 1 \
      "Auto-generate|a strong random password, shown now and saved for you" \
      "Type my own|at least 8 characters") in
      2)
        while :; do
          APP_PASS=$(ask_secret "Password:")
          if (( ${#APP_PASS} < 8 )); then warn "Use at least 8 characters."; continue; fi
          [[ $(ask_secret "Confirm password:") == "$APP_PASS" ]] && break
          warn "Passwords didn't match, try again."
        done
        ;;
    esac
  fi
  if [[ -z $APP_PASS ]]; then
    # Runs before dependencies are installed, so plain coreutils only (fixed-size reads: no SIGPIPE under pipefail).
    APP_PASS=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    GENERATED_PASS=1
    # Straight to the screen (not via ok/log) so the password never lands in the log.
    printf '  %s✓%s Generated password: %s%s%s  %s(also saved to %s/credentials.txt)%s\n' \
      "$C_GREEN" "$C_RESET" "$C_BOLD" "$APP_PASS" "$C_RESET" "$C_GRAY" "$INSTALL_DIR" "$C_RESET"
    log "OK   Generated a random password"
  fi
}

choose_options() {
  step "Choose your stack"

  # Re-run: default to what's installed now, so nothing gets removed by accident.
  PREV_SERVER=""; PREV_DOWNLOADER=""
  if [[ -f $INSTALL_DIR/.env ]]; then
    PREV_SERVER=$(sed -n 's/^STACK_SERVER=//p' "$INSTALL_DIR/.env")
    PREV_DOWNLOADER=$(sed -n 's/^STACK_DOWNLOADER=//p' "$INSTALL_DIR/.env")
    local prev_data
    prev_data=$(sed -n 's/^DATA_DIR=//p' "$INSTALL_DIR/.env")
    (( DATA_DIR_SET )) || DATA_DIR=${prev_data:-$DATA_DIR}
    [[ -n $PREV_SERVER ]] && info "Currently installed: ${PREV_SERVER} + ${PREV_DOWNLOADER} (shown as the defaults)"
  fi

  if [[ -z $SERVER ]]; then
    case $(menu "Which media server do you want?" "$(menu_index "${PREV_SERVER:-jellyfin}" jellyfin plex both)" \
      "Jellyfin|free & open source, no account needed" \
      "Plex|polished apps everywhere, needs a plex.tv account" \
      "Both|run Jellyfin and Plex side by side") in
      1) SERVER=jellyfin ;; 2) SERVER=plex ;; 3) SERVER=both ;;
    esac
  fi
  [[ $SERVER =~ ^(jellyfin|plex|both)$ ]] || die "Invalid --server '$SERVER' (use jellyfin, plex or both)."

  if [[ -z $DOWNLOADER ]]; then
    case $(menu "Which download client do you want?" "$(menu_index "${PREV_DOWNLOADER:-qbittorrent}" qbittorrent sabnzbd both)" \
      "qBittorrent|torrents" \
      "SABnzbd|usenet (needs a usenet provider)" \
      "Both|torrents + usenet") in
      1) DOWNLOADER=qbittorrent ;; 2) DOWNLOADER=sabnzbd ;; 3) DOWNLOADER=both ;;
    esac
  fi
  [[ $DOWNLOADER =~ ^(qbittorrent|sabnzbd|both)$ ]] || die "Invalid --downloader '$DOWNLOADER'."

  { printf '\n' >/dev/tty; } 2>/dev/null || true
  DATA_DIR=$(ask "Where should media + downloads live?" "$DATA_DIR")
  DATA_DIR=${DATA_DIR%/}
  [[ $DATA_DIR == /* ]] || die "Data folder must be an absolute path (got '$DATA_DIR')."

  # Credentials: reuse from a previous run so re-running never breaks logins.
  if [[ -f $INSTALL_DIR/.secrets ]]; then
    APP_USER=$(sed -n 's/^APP_USER=//p' "$INSTALL_DIR/.secrets")
    APP_PASS=$(sed -n 's/^APP_PASS=//p' "$INSTALL_DIR/.secrets")
    info "Existing install found: reusing login '$APP_USER'"
  else
    ask_credentials
  fi
  [[ $APP_USER =~ ^[A-Za-z0-9._-]{3,32}$ ]] || die "Username must be 3-32 characters: letters, numbers, . _ -"

  if want plex && [[ -z $PLEX_CLAIM ]] && (( ! ASSUME_YES )) && has_tty; then
    info "Optional: a claim token links Plex to your account automatically."
    info "Get one at ${C_CYAN}https://plex.tv/claim${C_RESET} (valid 4 minutes), or press Enter to skip."
    PLEX_CLAIM=$(ask "Plex claim token" "")
  fi

  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  local servers dls
  servers=$(want jellyfin && echo -n "Jellyfin "; want plex && echo -n "Plex"; true)
  dls=$(want qbittorrent && echo -n "qBittorrent "; want sabnzbd && echo -n "SABnzbd"; true)
  printf '    %-16s %s\n' "Media server" "$servers" "Downloads" "$dls" "Automation" "Seerr · Radarr · Sonarr · Prowlarr" \
    "Media folder" "$DATA_DIR" "App configs" "$INSTALL_DIR" "Login" "$APP_USER"
  log "Plan: server=$SERVER downloader=$DOWNLOADER data=$DATA_DIR install=$INSTALL_DIR user=$APP_USER"
  printf '\n'

  # Warn before a re-run drops an app that's installed today (its config folder is kept).
  local removed=() app
  if [[ -n $PREV_SERVER ]]; then
    for app in jellyfin plex qbittorrent sabnzbd; do
      if was_installed "$app" && ! want "$app"; then removed+=("$app"); fi
    done
  fi
  if (( ${#removed[@]} )); then
    warn "This will REMOVE: ${removed[*]} (their settings stay in $INSTALL_DIR/config)"
  fi

  if (( DRY_RUN )); then
    info "Dry run: nothing was changed."
    exit 0
  fi
  confirm "Install now?" || { info "Cancelled. Nothing was changed."; exit 0; }
}

stack_images() { # images this selection needs
  local imgs=("$LSIO/radarr:latest" "$LSIO/sonarr:latest" "$LSIO/prowlarr:latest" "$SEERR_IMAGE")
  want jellyfin && imgs+=("$LSIO/jellyfin:latest")
  want plex && imgs+=("$LSIO/plex:latest")
  want qbittorrent && imgs+=("$LSIO/qbittorrent:latest")
  want sabnzbd && imgs+=("$LSIO/sabnzbd:latest")
  printf '%s\n' "${imgs[@]}"
}

check_disk() {
  local root free_gb missing=0 need img
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
  [[ -d $root ]] || root=/var/lib
  free_gb=$(df -Pk "$root" | awk 'NR==2 {printf "%.1f", $4/1048576}')
  for img in $(stack_images); do docker image inspect "$img" >/dev/null 2>&1 || missing=$((missing + 1)); done
  # ~0.6 GB per image still to download, plus 1 GB headroom for app databases.
  need=$(awk -v m="$missing" 'BEGIN {printf "%.1f", m * 0.6 + 1}')
  log "disk: ${free_gb} GB free at $root, $missing images to pull, need ~${need} GB"
  if awk -v f="$free_gb" -v n="$need" 'BEGIN {exit !(f < n)}'; then
    lvm_hint
    die "Only ${free_gb} GB free for Docker, ~${need} GB needed ($missing images to download)."
  elif awk -v f="$free_gb" -v n="$need" 'BEGIN {exit !(f < n + 3)}'; then
    warn "Low disk: ${free_gb} GB free for Docker (~${need} GB needed now)."
    lvm_hint
  else
    ok "Disk: ${free_gb} GB free for Docker"
  fi
}

# Ubuntu's installer often gives the root LV only half the disk. Point that out.
lvm_hint() {
  local dev vfree
  dev=$(findmnt -no SOURCE / 2>/dev/null) || return 0
  [[ $dev == /dev/mapper/* ]] || return 0
  vfree=$(lvs --noheadings -o vg_free --units g --nosuffix "$dev" 2>/dev/null | tr -d ' ') || return 0
  [[ -n $vfree ]] && awk -v v="$vfree" 'BEGIN {exit !(v >= 1)}' || return 0
  info "Your volume group has ${vfree%.*} GB unallocated. Give it to / with:"
  info "  ${C_CYAN}sudo lvextend -r -l +100%FREE $dev${C_RESET}"
}

check_ports() {
  local ports=("$P_RADARR" "$P_SONARR" "$P_PROWLARR" "$P_SEERR") busy=()
  want jellyfin && ports+=("$P_JELLYFIN")
  want plex && ports+=("$P_PLEX")
  want qbittorrent && ports+=("$P_QBIT" 6881)
  want sabnzbd && ports+=("$P_SAB")
  # On a re-run our own containers hold these ports, which is fine.
  if [[ -f $INSTALL_DIR/docker-compose.yml ]] && [[ -n $(dc ps -q 2>/dev/null) ]]; then
    ok "Existing media stack detected: updating it in place"; return 0
  fi
  local p
  for p in "${ports[@]}"; do
    if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then busy+=("$p"); fi
  done
  (( ${#busy[@]} == 0 )) || die "These ports are already in use: ${busy[*]}. Stop whatever uses them and re-run."
  ok "Required ports are free"
}

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

install_deps() {
  step "Installing dependencies"
  export DEBIAN_FRONTEND=noninteractive
  local APT=(apt-get -y -o DPkg::Lock::Timeout=300)
  local need=()
  for pkg in curl jq python3 ca-certificates gnupg iproute2; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
  done
  if (( ${#need[@]} )); then
    run "Updating package lists" apt_update
    run "Installing ${need[*]}" "${APT[@]}" install --no-install-recommends "${need[@]}"
  else
    ok "curl, jq, python3 already installed"
  fi
}

docker_official() {
  # shellcheck disable=SC1091
  . /etc/os-release
  local codename=${UBUNTU_CODENAME:-$VERSION_CODENAME}
  # Runs inside `run ... || fallback`, where set -e is suspended: fail explicitly.
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
  if [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker
  else
    # WSL / containers without systemd: try the init script, then dockerd directly.
    service docker start || { nohup dockerd >/var/log/dockerd.log 2>&1 & }
  fi
  local i
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

install_docker() {
  step "Installing Docker"
  if command -v docker >/dev/null 2>&1; then
    if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
      warn "Docker is installed as a snap. Snap confinement can block access to $DATA_DIR."
      warn "If containers fail to start, remove it (sudo snap remove docker) and re-run."
    fi
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
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
    usermod -aG docker "$SUDO_USER" && ok "Added $SUDO_USER to the docker group (log out/in to use docker without sudo)"
  fi
  check_ports
  check_disk
}

arr_config_xml() { # arr_config_xml port name apikey
  cat <<EOF
<Config>
  <BindAddress>*</BindAddress>
  <Port>$1</Port>
  <EnableSsl>False</EnableSsl>
  <LaunchBrowser>False</LaunchBrowser>
  <ApiKey>$3</ApiKey>
  <LogLevel>info</LogLevel>
  <UrlBase></UrlBase>
  <InstanceName>$2</InstanceName>
</Config>
EOF
}

qbit_password_hash() { # PBKDF2-SHA512, the format qBittorrent stores in its config
  APP_PASS="$APP_PASS" python3 - <<'PY'
import base64, hashlib, os
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac('sha512', os.environ['APP_PASS'].encode(), salt, 100000)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(key).decode()))
PY
}

prepare_folders() {
  step "Creating folders"
  mkdir -p "$INSTALL_DIR"/config/{radarr,sonarr,prowlarr,seerr}
  want jellyfin && mkdir -p "$INSTALL_DIR/config/jellyfin"
  want plex && mkdir -p "$INSTALL_DIR/config/plex"
  want qbittorrent && mkdir -p "$INSTALL_DIR/config/qbittorrent/qBittorrent"
  want sabnzbd && mkdir -p "$INSTALL_DIR/config/sabnzbd"

  # One /data tree shared by every container, so Radarr/Sonarr can hardlink
  # finished downloads into the library instead of copying them.
  mkdir -p "$DATA_DIR"/{Movies,TV_Shows,Active_Downloads}
  want qbittorrent && mkdir -p "$DATA_DIR"/Active_Downloads/torrents/{movies,tv,incomplete}
  want sabnzbd && mkdir -p "$DATA_DIR"/Active_Downloads/usenet/{incomplete,complete/movies,complete/tv}
  ok "Media library:  $DATA_DIR/Movies  ·  $DATA_DIR/TV_Shows"
  ok "Downloads:      $DATA_DIR/Active_Downloads"

  # Pre-seed API keys so every app knows the others' keys before first boot.
  local app port name
  for app in radarr:$P_RADARR:Radarr sonarr:$P_SONARR:Sonarr prowlarr:$P_PROWLARR:Prowlarr; do
    IFS=: read -r name port _ <<<"$app"
    local f="$INSTALL_DIR/config/$name/config.xml"
    if [[ ! -f $f ]]; then
      arr_config_xml "$port" "${app##*:}" "$(gen_secret hex 16)" >"$f"
      log "seeded $f"
    fi
  done
  ok "API keys ready for Radarr, Sonarr, Prowlarr"

  if want qbittorrent; then
    local qconf="$INSTALL_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf"
    if [[ ! -f $qconf ]]; then
      cat >"$qconf" <<EOF
[BitTorrent]
Session\\DefaultSavePath=/data/Active_Downloads/torrents
Session\\TempPath=/data/Active_Downloads/torrents/incomplete
Session\\TempPathEnabled=true
Session\\Port=6881

[LegalNotice]
Accepted=true

[Preferences]
Downloads\\SavePath=/data/Active_Downloads/torrents
Downloads\\TempPath=/data/Active_Downloads/torrents/incomplete
Downloads\\TempPathEnabled=true
WebUI\\Port=8080
WebUI\\Username=$APP_USER
WebUI\\Password_PBKDF2="$(qbit_password_hash)"
WebUI\\HostHeaderValidation=false
WebUI\\LocalHostAuth=true
EOF
      log "seeded $qconf"
      ok "qBittorrent login + download paths pre-configured"
    else
      info "qBittorrent config exists, leaving it untouched"
    fi
  fi

  chown -R "$PUID:$PGID" "$INSTALL_DIR/config" "$DATA_DIR"
  chown -R 1000:1000 "$INSTALL_DIR/config/seerr"   # Seerr's image always runs as uid 1000
  chmod -R u+rwX,g+rwX "$DATA_DIR"
}

write_compose() {
  step "Writing docker-compose.yml"
  umask 077
  cat >"$INSTALL_DIR/.env" <<EOF
# sudo homelab · media stack. Keep this file private.
PUID=$PUID
PGID=$PGID
TZ=$TZ_NAME
DATA_DIR=$DATA_DIR
PLEX_CLAIM=$PLEX_CLAIM
STACK_SERVER=$SERVER
STACK_DOWNLOADER=$DOWNLOADER
EOF
  printf 'APP_USER=%s\nAPP_PASS=%s\n' "$APP_USER" "$APP_PASS" >"$INSTALL_DIR/.secrets"
  umask 022

  local f="$INSTALL_DIR/docker-compose.yml" gpu=""
  (( HAS_DRI )) && gpu=$'    devices:\n      - /dev/dri:/dev/dri\n'

  {
    cat <<'EOF'
# Generated by sudo homelab · media stack. Re-run the installer to change apps.
name: mediastack

x-common: &common
  restart: unless-stopped
  environment:
    PUID: ${PUID}
    PGID: ${PGID}
    TZ: ${TZ}

services:
EOF
    if want jellyfin; then cat <<EOF
  jellyfin:
    <<: *common
    image: $LSIO/jellyfin:latest
    container_name: jellyfin
    ports:
      - "$P_JELLYFIN:8096"
    volumes:
      - ./config/jellyfin:/config
      - \${DATA_DIR}:/data
${gpu}
EOF
    fi
    if want plex; then cat <<EOF
  plex:
    <<: *common
    image: $LSIO/plex:latest
    container_name: plex
    network_mode: host
    environment:
      PUID: \${PUID}
      PGID: \${PGID}
      TZ: \${TZ}
      VERSION: docker
      PLEX_CLAIM: \${PLEX_CLAIM}
    volumes:
      - ./config/plex:/config
      - \${DATA_DIR}:/data
${gpu}
EOF
    fi
    if want qbittorrent; then cat <<EOF
  qbittorrent:
    <<: *common
    image: $LSIO/qbittorrent:latest
    container_name: qbittorrent
    environment:
      PUID: \${PUID}
      PGID: \${PGID}
      TZ: \${TZ}
      WEBUI_PORT: 8080
      TORRENTING_PORT: 6881
    ports:
      - "$P_QBIT:8080"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - ./config/qbittorrent:/config
      - \${DATA_DIR}:/data

EOF
    fi
    if want sabnzbd; then cat <<EOF
  sabnzbd:
    <<: *common
    image: $LSIO/sabnzbd:latest
    container_name: sabnzbd
    ports:
      - "$P_SAB:8080"
    volumes:
      - ./config/sabnzbd:/config
      - \${DATA_DIR}:/data

EOF
    fi
    cat <<EOF
  radarr:
    <<: *common
    image: $LSIO/radarr:latest
    container_name: radarr
    ports:
      - "$P_RADARR:7878"
    volumes:
      - ./config/radarr:/config
      - \${DATA_DIR}:/data

  sonarr:
    <<: *common
    image: $LSIO/sonarr:latest
    container_name: sonarr
    ports:
      - "$P_SONARR:8989"
    volumes:
      - ./config/sonarr:/config
      - \${DATA_DIR}:/data

  prowlarr:
    <<: *common
    image: $LSIO/prowlarr:latest
    container_name: prowlarr
    ports:
      - "$P_PROWLARR:9696"
    volumes:
      - ./config/prowlarr:/config

  seerr:
    image: $SEERR_IMAGE
    container_name: seerr
    init: true
    restart: unless-stopped
    environment:
      TZ: \${TZ}
      LOG_LEVEL: info
    ports:
      - "$P_SEERR:5055"
    volumes:
      - ./config/seerr:/app/config
EOF
  } >"$f"

  run "Validating compose file" dc config -q
  ok "Saved $f"
}

start_stack() {
  step "Downloading & starting containers"
  local n
  n=$(dc config --services | wc -l)
  info "Downloading $n app images in parallel (~2-3 GB on a first install)"
  run "Downloading images" dc --progress plain pull
  # Seerr boots now too: it creates its default settings while the others start,
  # and gets Radarr/Sonarr injected in the wiring step.
  run "Starting $n containers" dc --progress plain up -d --remove-orphans

  RADARR_URL="http://localhost:$P_RADARR"; SONARR_URL="http://localhost:$P_SONARR"; PROWLARR_URL="http://localhost:$P_PROWLARR"
  RADARR_KEY=$(xml_key "$INSTALL_DIR/config/radarr/config.xml")
  SONARR_KEY=$(xml_key "$INSTALL_DIR/config/sonarr/config.xml")
  PROWLARR_KEY=$(xml_key "$INSTALL_DIR/config/prowlarr/config.xml")
  [[ -n $RADARR_KEY && -n $SONARR_KEY && -n $PROWLARR_KEY ]] || die "Could not read API keys from config.xml files."

  run "Waiting for Radarr" wait_for Radarr "$RADARR_URL/api/v3/system/status" 240 -H "X-Api-Key: $RADARR_KEY"
  run "Waiting for Sonarr" wait_for Sonarr "$SONARR_URL/api/v3/system/status" 240 -H "X-Api-Key: $SONARR_KEY"
  run "Waiting for Prowlarr" wait_for Prowlarr "$PROWLARR_URL/api/v1/system/status" 240 -H "X-Api-Key: $PROWLARR_KEY"
  want qbittorrent && run "Waiting for qBittorrent" wait_for qBittorrent "http://localhost:$P_QBIT/" 180
  want sabnzbd && run "Waiting for SABnzbd" wait_for SABnzbd "http://localhost:$P_SAB/" 180
  want jellyfin && run "Waiting for Jellyfin" wait_for Jellyfin "http://localhost:$P_JELLYFIN/health" 240
  want plex && run "Waiting for Plex" wait_for Plex "http://localhost:$P_PLEX/identity" 240
  return 0
}

# ── Wiring ────────────────────────────────────────────────────────────────────
set_auth() { # set_auth url apiver key: forms login (API keys keep working for app-to-app calls)
  local url=$1 v=$2 key=$3 cfg
  cfg=$(api GET "$url/api/$v/config/host" "$key")
  cfg=$(jq --arg u "$APP_USER" --arg p "$APP_PASS" \
    '.authenticationMethod="forms" | .authenticationRequired="enabled"
     | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cfg")
  api PUT "$url/api/$v/config/host/$(jq -r .id <<<"$cfg")" "$key" "$cfg" >/dev/null
}

add_root_folder() { # url key path
  if api GET "$1/api/v3/rootfolder" "$2" | jq -e --arg p "$3" 'any(.[]; .path == $p)' >/dev/null; then
    log "root folder $3 already present"; return 0
  fi
  api POST "$1/api/v3/rootfolder" "$2" "$(jq -n --arg p "$3" '{path: $p}')" >/dev/null
}

# add_from_schema url apiver key resource implementation name fields-json [extra-jq]
# Builds the resource from the app's own schema, so field names always match the version installed.
add_from_schema() {
  local url=$1 v=$2 key=$3 res=$4 impl=$5 name=$6 fields=$7 extra=${8:-.}
  if api GET "$url/api/$v/$res" "$key" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
    log "$res '$name' already present"; return 0
  fi
  local body
  body=$(api GET "$url/api/$v/$res/schema" "$key" | jq --arg impl "$impl" --arg n "$name" --argjson f "$fields" "
    first(.[] | select(.implementation == \$impl))
    | .name = \$n | .enable = true
    | .fields |= map(.name as \$k | if (\$f | has(\$k)) then .value = \$f[\$k] else . end)
    | $extra")
  [[ -n $body && $body != null ]] || { log "no schema for $impl"; return 1; }
  api POST "$url/api/$v/$res" "$key" "$body" >/dev/null
}

qbit_setup() {
  local jar q="http://localhost:$P_QBIT"
  jar=$(mktemp)
  # qBittorrent 4.x answers "Ok.", 5.x an empty 204; both set the session cookie.
  curl -sS -o /dev/null -c "$jar" -H "Referer: $q" --data-urlencode "username=$APP_USER" \
    --data-urlencode "password=$APP_PASS" "$q/api/v2/auth/login"
  grep -q QBT_SID "$jar" || { rm -f "$jar"; echo "qBittorrent login failed (wrong password?)"; return 1; }
  local cat
  for cat in movies tv; do
    curl -sS -b "$jar" -H "Referer: $q" --data "category=$cat" \
      --data-urlencode "savePath=/data/Active_Downloads/torrents/$cat" "$q/api/v2/torrents/createCategory" || true
    curl -sS -b "$jar" -H "Referer: $q" --data "category=$cat" \
      --data-urlencode "savePath=/data/Active_Downloads/torrents/$cat" "$q/api/v2/torrents/editCategory" || true
  done
  rm -f "$jar"
}

sab_setup() {
  local ini="$INSTALL_DIR/config/sabnzbd/sabnzbd.ini" i
  for i in $(seq 1 60); do grep -q '^api_key = .\+' "$ini" 2>/dev/null && break; sleep 2; done
  SAB_KEY=$(sed -n 's/^api_key = //p' "$ini" | head -n1)
  [[ -n $SAB_KEY ]] || { echo "SABnzbd API key not found in $ini"; return 1; }
  local s="http://localhost:$P_SAB/api" kv k v
  for kv in "host_whitelist=sabnzbd,$(hostname),$HOST_IP" \
            "download_dir=/data/Active_Downloads/usenet/incomplete" \
            "complete_dir=/data/Active_Downloads/usenet/complete" \
            "username=$APP_USER" "password=$APP_PASS"; do
    k=${kv%%=*}; v=${kv#*=}
    curl -sS "$CURL_FAIL" -G "$s" --data "mode=set_config" --data "section=misc" --data "keyword=$k" \
      --data-urlencode "value=$v" --data "apikey=$SAB_KEY" --data "output=json" >/dev/null
  done
  dc restart sabnzbd
  wait_for SABnzbd "http://localhost:$P_SAB/" 120

  # Category folders. On a brand-new SABnzbd, first-boot initialisation can
  # overwrite categories set too early, so apply after the restart, read them
  # back and retry until they stick.
  local try missing
  for try in 1 2 3 4 5 6; do
    for k in movies tv; do
      curl -sS "$CURL_FAIL" -G "$s" --data "mode=set_config" --data "section=categories" --data "keyword=$k" \
        --data "dir=$k" --data "apikey=$SAB_KEY" --data "output=json" >/dev/null
    done
    sleep 3
    missing=$(curl -sS -G "$s" --data "mode=get_config" --data "section=categories" --data "apikey=$SAB_KEY" --data "output=json" |
      jq -r '[.config.categories[] | select((.name == "movies" or .name == "tv") and .dir != .name)] | length')
    [[ $missing == 0 ]] && { echo "SABnzbd categories set (attempt $try)"; return 0; }
    echo "SABnzbd categories not applied yet (attempt $try), retrying"
  done
  echo "SABnzbd categories could not be set"; return 1
}

wire_radarr() {
  add_root_folder "$RADARR_URL" "$RADARR_KEY" /data/Movies
  if want qbittorrent; then
    add_from_schema "$RADARR_URL" v3 "$RADARR_KEY" downloadclient QBittorrent qBittorrent \
      "$(jq -n --arg u "$APP_USER" --arg p "$APP_PASS" '{host:"qbittorrent", port:8080, username:$u, password:$p, movieCategory:"movies"}')"
  fi
  if want sabnzbd; then
    add_from_schema "$RADARR_URL" v3 "$RADARR_KEY" downloadclient Sabnzbd SABnzbd \
      "$(jq -n --arg k "$SAB_KEY" '{host:"sabnzbd", port:8080, apiKey:$k, movieCategory:"movies"}')"
  fi
}

wire_sonarr() {
  add_root_folder "$SONARR_URL" "$SONARR_KEY" /data/TV_Shows
  if want qbittorrent; then
    add_from_schema "$SONARR_URL" v3 "$SONARR_KEY" downloadclient QBittorrent qBittorrent \
      "$(jq -n --arg u "$APP_USER" --arg p "$APP_PASS" '{host:"qbittorrent", port:8080, username:$u, password:$p, tvCategory:"tv"}')"
  fi
  if want sabnzbd; then
    add_from_schema "$SONARR_URL" v3 "$SONARR_KEY" downloadclient Sabnzbd SABnzbd \
      "$(jq -n --arg k "$SAB_KEY" '{host:"sabnzbd", port:8080, apiKey:$k, tvCategory:"tv"}')"
  fi
}

wire_prowlarr() {
  add_from_schema "$PROWLARR_URL" v1 "$PROWLARR_KEY" applications Radarr Radarr \
    "$(jq -n --arg k "$RADARR_KEY" '{prowlarrUrl:"http://prowlarr:9696", baseUrl:"http://radarr:7878", apiKey:$k}')" '.syncLevel = "fullSync"'
  add_from_schema "$PROWLARR_URL" v1 "$PROWLARR_KEY" applications Sonarr Sonarr \
    "$(jq -n --arg k "$SONARR_KEY" '{prowlarrUrl:"http://prowlarr:9696", baseUrl:"http://sonarr:8989", apiKey:$k}')" '.syncLevel = "fullSync"'
}

pick_profile() { # url key → "id<TAB>name", preferring HD-1080p
  api GET "$1/api/v3/qualityprofile" "$2" |
    jq -r '(map(select(.name == "HD-1080p")) + .)[0] | "\(.id)\t\(.name)"'
}

seerr_setup() {
  local settings="$INSTALL_DIR/config/seerr/settings.json"
  if [[ -f $settings ]] && jq -e '(.radarr | length) > 0' "$settings" >/dev/null 2>&1; then
    dc up -d seerr
    log "Seerr already has Radarr configured"; return 0
  fi
  # Let Seerr generate a complete default settings.json first: its migrations
  # expect every section to exist, so a hand-written partial file would crash it.
  dc up -d seerr
  local i
  for i in $(seq 1 90); do jq -e '.main.apiKey' "$settings" >/dev/null 2>&1 && break; sleep 2; done
  jq -e '.main.apiKey' "$settings" >/dev/null 2>&1 || { echo "Seerr did not create settings.json"; return 1; }
  sleep 3
  dc stop seerr

  local rp sp
  rp=$(pick_profile "$RADARR_URL" "$RADARR_KEY"); sp=$(pick_profile "$SONARR_URL" "$SONARR_KEY")
  cp "$settings" "$settings.bak"
  jq --arg rk "$RADARR_KEY" --arg sk "$SONARR_KEY" --arg ip "$HOST_IP" \
     --argjson rpid "${rp%%$'\t'*}" --arg rpn "${rp#*$'\t'}" \
     --argjson spid "${sp%%$'\t'*}" --arg spn "${sp#*$'\t'}" \
     --arg server "$SERVER" '
    .radarr = [{
      id: 0, name: "Radarr", hostname: "radarr", port: 7878, apiKey: $rk, useSsl: false, baseUrl: "",
      activeProfileId: $rpid, activeProfileName: $rpn, activeDirectory: "/data/Movies",
      tags: [], is4k: false, isDefault: true, externalUrl: "http://\($ip):7878",
      syncEnabled: true, preventSearch: false, tagRequests: false, overrideRule: [],
      minimumAvailability: "released"
    }]
    | .sonarr = [{
      id: 0, name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $sk, useSsl: false, baseUrl: "",
      activeProfileId: $spid, activeProfileName: $spn, activeDirectory: "/data/TV_Shows",
      activeAnimeProfileId: $spid, activeAnimeProfileName: $spn, activeAnimeDirectory: "/data/TV_Shows",
      tags: [], animeTags: [], is4k: false, isDefault: true, externalUrl: "http://\($ip):8989",
      syncEnabled: true, preventSearch: false, tagRequests: false, overrideRule: [],
      seriesType: "standard", animeSeriesType: "anime", enableSeasonFolders: true, monitorNewItems: "all"
    }]
    | if ($server == "jellyfin" or $server == "both") then .jellyfin.ip = "jellyfin" | .jellyfin.port = 8096 else . end
    | if ($server == "plex" or $server == "both") then .plex.ip = $ip | .plex.port = 32400 else . end
  ' "$settings.bak" >"$settings"
  chown 1000:1000 "$settings"

  dc start seerr
  if ! wait_for Seerr "http://localhost:$P_SEERR/api/v1/status" 120; then
    echo "Seerr failed to start with the pre-configured settings; restoring defaults"
    dc stop seerr; cp "$settings.bak" "$settings"; chown 1000:1000 "$settings"; dc start seerr
    touch "$INSTALL_DIR/.seerr_manual"
  fi
}

wire_stack() {
  step "Connecting the apps"
  run "Securing Radarr login" set_auth "$RADARR_URL" v3 "$RADARR_KEY"
  run "Securing Sonarr login" set_auth "$SONARR_URL" v3 "$SONARR_KEY"
  run "Securing Prowlarr login" set_auth "$PROWLARR_URL" v1 "$PROWLARR_KEY"
  want qbittorrent && run "qBittorrent: categories movies + tv" qbit_setup
  if want sabnzbd; then
    run "SABnzbd: folders, categories, login" sab_setup
    SAB_KEY=$(sed -n 's/^api_key = //p' "$INSTALL_DIR/config/sabnzbd/sabnzbd.ini" | head -n1)
  fi
  run "Radarr → /data/Movies + download clients" wire_radarr
  run "Sonarr → /data/TV_Shows + download clients" wire_sonarr
  run "Prowlarr → Radarr + Sonarr (indexer sync)" wire_prowlarr
  run "Seerr → Radarr + Sonarr" seerr_setup
  [[ -f $INSTALL_DIR/.seerr_manual ]] && warn "Seerr needs Radarr/Sonarr added by hand (Settings → Services). Keys are in credentials.txt."
  return 0
}

verify_arr() { # name url key
  local r
  r=$(api GET "$2/api/v3/downloadclient" "$3" | jq -r 'map(.name) | join(", ")')
  if [[ -n $r ]]; then ok "$1 download clients: $r"; else warn "$1 has no download client"; fi
  r=$(api GET "$2/api/v3/rootfolder" "$3" | jq -r 'map(.path) | join(", ")')
  if [[ -n $r ]]; then ok "$1 root folder: $r"; else warn "$1 has no root folder"; fi
}

verify() {
  step "Verifying connections"
  verify_arr Radarr "$RADARR_URL" "$RADARR_KEY"
  verify_arr Sonarr "$SONARR_URL" "$SONARR_KEY"
  local r
  r=$(api GET "$PROWLARR_URL/api/v1/applications" "$PROWLARR_KEY" | jq -r 'map(.name) | join(", ")')
  if [[ -n $r ]]; then ok "Prowlarr syncs to: $r"; else warn "Prowlarr has no apps connected"; fi
  if [[ $(http_code "http://localhost:$P_SEERR/api/v1/status") == 200 ]]; then ok "Seerr is up"; else warn "Seerr is not responding yet"; fi
  return 0
}

summary() {
  step "Done"
  local f="$INSTALL_DIR/credentials.txt" ip=$HOST_IP
  umask 077
  {
    echo "sudo homelab · media stack ($(date))"
    echo
    echo "Login for Radarr / Sonarr / Prowlarr / downloaders"
    echo "  username: $APP_USER"
    echo "  password: $APP_PASS"
    echo
    want jellyfin && echo "Jellyfin     http://$ip:$P_JELLYFIN"
    want plex && echo "Plex         http://$ip:$P_PLEX/web"
    echo "Seerr        http://$ip:$P_SEERR"
    echo "Radarr       http://$ip:$P_RADARR      API key: $RADARR_KEY"
    echo "Sonarr       http://$ip:$P_SONARR      API key: $SONARR_KEY"
    echo "Prowlarr     http://$ip:$P_PROWLARR      API key: $PROWLARR_KEY"
    want qbittorrent && echo "qBittorrent  http://$ip:$P_QBIT"
    want sabnzbd && echo "SABnzbd      http://$ip:$P_SAB      API key: ${SAB_KEY:-}"
    echo
    echo "Folders (inside every container the data folder is /data)"
    echo "  Movies     $DATA_DIR/Movies      → /data/Movies"
    echo "  TV Shows   $DATA_DIR/TV_Shows    → /data/TV_Shows"
    echo "  Downloads  $DATA_DIR/Active_Downloads → /data/Active_Downloads"
  } >"$f"
  umask 022

  printf '\n  %s%s★ Your media stack is running!%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  local row='    %s%-12s%s %s%s%s\n'
  want jellyfin && printf "$row" "$C_BOLD" "Jellyfin" "$C_RESET" "$C_CYAN" "http://$ip:$P_JELLYFIN" "$C_RESET"
  want plex && printf "$row" "$C_BOLD" "Plex" "$C_RESET" "$C_CYAN" "http://$ip:$P_PLEX/web" "$C_RESET"
  printf "$row" "$C_BOLD" "Seerr" "$C_RESET" "$C_CYAN" "http://$ip:$P_SEERR" "$C_RESET"
  printf "$row" "$C_BOLD" "Radarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_RADARR" "$C_RESET"
  printf "$row" "$C_BOLD" "Sonarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_SONARR" "$C_RESET"
  printf "$row" "$C_BOLD" "Prowlarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_PROWLARR" "$C_RESET"
  want qbittorrent && printf "$row" "$C_BOLD" "qBittorrent" "$C_RESET" "$C_CYAN" "http://$ip:$P_QBIT" "$C_RESET"
  want sabnzbd && printf "$row" "$C_BOLD" "SABnzbd" "$C_RESET" "$C_CYAN" "http://$ip:$P_SAB" "$C_RESET"

  printf '\n    %sLogin%s  %s / %s%s\n' "$C_GRAY" "$C_RESET" "$APP_USER" "$APP_PASS" \
    "$( [[ ${GENERATED_PASS:-0} == 1 ]] && printf '  %s(generated, saved below)%s' "$C_GRAY" "$C_RESET")"
  printf '    %sSaved%s  %s %s(root only)%s\n' "$C_GRAY" "$C_RESET" "$f" "$C_GRAY" "$C_RESET"

  printf '\n  %sNext steps for you%s\n' "$C_BOLD" "$C_RESET"
  local n=1
  printf '    %s%d.%s %sProwlarr%s → Indexers → Add Indexer. They sync to Radarr & Sonarr automatically.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET"
  if want jellyfin; then
    printf '    %s%d.%s %sJellyfin%s → create your account, add libraries %s/data/Movies%s and %s/data/TV_Shows%s\n' \
      "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  fi
  if want plex; then
    printf '    %s%d.%s %sPlex%s → sign in, add libraries %s/data/Movies%s and %s/data/TV_Shows%s\n' \
      "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  fi
  local seerr_srv
  if [[ $SERVER == plex ]]; then seerr_srv="your Plex account"; else seerr_srv="Jellyfin (server URL: http://jellyfin:8096)"; fi
  printf '    %s%d.%s %sSeerr%s → sign in with %s. Radarr & Sonarr are already connected.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$seerr_srv"
  want sabnzbd && printf '    %s%d.%s %sSABnzbd%s → add your usenet provider in the setup wizard.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET"

  printf '\n    %sManage:%s cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"
  printf '    %sLog:%s    %s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s   %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
}

uninstall() {
  banner
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "No media stack found in $INSTALL_DIR."
  warn "This stops and removes the media stack containers."
  (( PURGE )) && warn "--purge: app configs in $INSTALL_DIR will be deleted too."
  info "Your media in the data folder is never touched."
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  run "Removing containers" dc down --remove-orphans
  if (( PURGE )); then run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"; fi
  ok "Uninstalled."
}

main() {
  ORIG_ARGS=("$@")
  parse_args "$@"
  mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR=/tmp; LOG_FILE="/tmp/$(basename "$LOG_FILE")"; }
  : >"$LOG_FILE" 2>/dev/null || { LOG_FILE=/tmp/$(basename "$LOG_FILE"); : >"$LOG_FILE"; }
  chmod 600 "$LOG_FILE"
  log "sudo homelab media-stack v$VERSION · args: $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
  log "kernel: $(uname -a)"
  # --fail-with-body keeps error responses in the log; Debian 11's curl predates it.
  CURL_FAIL=--fail-with-body
  # (no grep -q: it would exit early and SIGPIPE curl, which pipefail reports as failure)
  curl --help all 2>/dev/null | grep -- --fail-with-body >/dev/null || CURL_FAIL=--fail

  check_interactive
  if (( UNINSTALL )); then uninstall; exit 0; fi

  (( IS_TTY )) && trap 'printf "\e[?25h"' EXIT   # never leave the cursor hidden
  START_TIME=$SECONDS
  banner
  [[ -n ${EXTRAS_IGNORED:-} ]] && warn "--extras=$EXTRAS_IGNORED isn't supported by this version yet; ignoring."
  preflight
  choose_options
  install_deps
  install_docker
  prepare_folders
  write_compose
  start_stack
  wire_stack
  verify
  summary
  log "install finished"
}

main "$@"
