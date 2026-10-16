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

VERSION="0.3.1"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/linux/media-stack.sh"
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
GROW_DISK=0        # --grow-disk: allow growing an LVM root without asking
UNINSTALL=0
PURGE=0

SEERR_IMAGE="ghcr.io/seerr-team/seerr:latest"
LSIO="lscr.io/linuxserver"

# Host ports
P_JELLYFIN=8096; P_PLEX=32400; P_QBIT=8080; P_TORRENT=6881; P_SAB=8085
P_RADARR=7878; P_SONARR=8989; P_PROWLARR=9696; P_SEERR=5055
P_LIDARR=8686; P_BAZARR=6767; P_TDARR=8265; P_TDARR_SRV=8266

# How the apps reach EACH OTHER (host name / port inside the shared network).
# One compose project: service names + the images' internal ports. The TrueNAS
# script overrides these for its catalog-apps mode.
H_RADARR=radarr; I_RADARR=7878; H_SONARR=sonarr; I_SONARR=8989; H_PROWLARR=prowlarr; I_PROWLARR=9696
H_LIDARR=lidarr; I_LIDARR=8686; H_QBIT=qbittorrent; H_SAB=sabnzbd; I_SAB=8080; H_JELLYFIN=jellyfin; I_JELLYFIN=8096
# qBittorrent's web UI listens on the same port inside and out, so I_QBIT follows P_QBIT (see i_qbit).
SEERR_UID=1000   # Seerr's image runs as uid 1000
TDARR_IMAGE="ghcr.io/haveagitgat/tdarr:latest"
EXTRAS=""          # comma list of: lidarr, bazarr, tdarr
EXTRAS_SET=0
SUB_LANGS=""       # Bazarr subtitle languages, e.g. en,es

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
  for secret in "${APP_PASS:-}" "${RADARR_KEY:-}" "${SONARR_KEY:-}" "${PROWLARR_KEY:-}" "${SAB_KEY:-}" "${LIDARR_KEY:-}" "${BAZARR_KEY:-}"; do
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
  if tail -n 400 "$LOG_FILE" 2>/dev/null | grep -qi 'no space left on device'; then
    local dpath; dpath=$(docker_data_path 2>/dev/null || echo /)
    printf '%s┃%s\n%s┃%s %sCause:   the disk is full%s (%s GB free on %s).\n' "$C_RED" "$C_RESET" "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET" \
      "$(free_gb "$dpath" 2>/dev/null)" "$(df --output=target "$dpath" 2>/dev/null | tail -n1)" >&2
    printf '%s┃%s Fix:     free some space, or grow the disk, then re-run.\n' "$C_RED" "$C_RESET" >&2
    printf '%s┃%s          Unused LVM space? Re-run with %s--grow-disk%s, or: sudo lvextend -r -l +100%%FREE <your LV>\n' "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET" >&2
  fi
  printf '%s┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_RED" "$C_RESET" >&2
  printf '%sLast lines of the log:%s\n' "$C_GRAY" "$C_RESET" >&2
  # Image-layer progress ("3f2a… Extracting 16B") is noise here: hide it, collapse repeats.
  grep -vE '^[[:space:]]*[0-9a-f]{12} (Downloading|Extracting|Waiting|Verifying|Download complete|Pull complete|Already exists|Pulling fs layer)' \
    "$LOG_FILE" 2>/dev/null | uniq | tail -n 25 | sed 's/^/    /' >&2
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
  --extras=lidarr,bazarr,tdarr       Optional apps (or "none")
  --subtitle-langs=en,es             Bazarr subtitle languages (default en)
  --plex-claim=TOKEN                 Claim token from https://plex.tv/claim (optional)
  -y, --yes                          Non-interactive, accept defaults
  --dry-run                          Show what would be installed, change nothing
  --grow-disk                        If the disk is too small and LVM has free space, grow it (no prompt)
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
      --extras=*) EXTRAS=${arg#*=}; EXTRAS_SET=1 ;;
      --subtitle-langs=*) SUB_LANGS=${arg#*=} ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --grow-disk) GROW_DISK=1 ;;
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
    lidarr|bazarr|tdarr) [[ ,${PREV_EXTRAS:-}, == *,$1,* ]] ;;
  esac
}

want() { # want jellyfin|plex|qbittorrent|sabnzbd
  case $1 in
    jellyfin|plex) [[ $SERVER == "$1" || $SERVER == both ]] ;;
    qbittorrent|sabnzbd) [[ $DOWNLOADER == "$1" || $DOWNLOADER == both ]] ;;
    lidarr|bazarr|tdarr) [[ ,$EXTRAS, == *,$1,* ]] ;;
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

# Container control and deployment. The TrueNAS script redefines these.
svc_up() { dc up -d "$1"; }
svc_stop() { dc stop "$1"; }
svc_start() { dc start "$1"; }
svc_restart() { dc restart "$1"; }
pull_images() { run "Downloading images" dc --progress plain pull; }
deploy_stack() { run "Starting $1 containers" dc --progress plain up -d --remove-orphans; }
manage_hint() { printf '\n    %sManage:%s cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"; }
# Compose project names that count as "this stack" when checking port owners.
our_project() { [[ $1 == mediastack ]]; }

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
    printf '\n  %sLogin for your apps%s %s(one login for every app that has one: Radarr, Sonarr, Prowlarr, downloaders, extras)%s\n' \
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

EXTRA_APPS=(lidarr bazarr tdarr)

# Multi-select: type numbers ("1 3"), "a" for all, "n" for none, Enter = default.
ask_extras() {
  local def=$1 i ans pick picked=() n
  if (( ASSUME_YES )) || ! has_tty; then EXTRAS=$def; return; fi
  local defnums=""
  for i in "${!EXTRA_APPS[@]}"; do [[ ,$def, == *,${EXTRA_APPS[i]},* ]] && defnums+="$((i + 1)) "; done
  defnums=${defnums% }
  {
    printf '\n  %sExtras%s %s(optional, pick any)%s\n' "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"
    printf '    %s1)%s %-14s %s%s%s\n' "$C_GREEN" "$C_RESET" "Lidarr" "$C_GRAY" "music collection manager, wired like Radarr/Sonarr" "$C_RESET"
    printf '    %s2)%s %-14s %s%s%s\n' "$C_GREEN" "$C_RESET" "Bazarr" "$C_GRAY" "automatic subtitles for your movies and shows" "$C_RESET"
    printf '    %s3)%s %-14s %s%s%s\n' "$C_GREEN" "$C_RESET" "Tdarr" "$C_GRAY" "transcode / shrink your library (CPU heavy)" "$C_RESET"
  } >/dev/tty
  while :; do
    printf '  %s›%s Numbers separated by spaces, a = all, n = none %s(default: %s)%s: ' \
      "$C_CYAN" "$C_RESET" "$C_GRAY" "${defnums:-none}" "$C_RESET" >/dev/tty
    IFS= read -r ans </dev/tty || true
    ans=${ans:-${defnums:-n}}
    picked=()
    case ${ans,,} in
      a|all) picked=("${EXTRA_APPS[@]}") ;;
      n|none) ;;
      *)
        n=0
        for pick in ${ans//,/ }; do
          if [[ $pick =~ ^[1-3]$ ]]; then picked+=("${EXTRA_APPS[pick - 1]}"); else n=1; fi
        done
        if (( n )); then printf '    %sUse 1, 2 or 3 (e.g. "1 2"), a or n.%s\n' "$C_YELLOW" "$C_RESET" >/dev/tty; continue; fi
        ;;
    esac
    break
  done
  EXTRAS=$(printf '%s\n' "${picked[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -)
}

normalize_extras() { # drop unknown names (the website lists a few future extras)
  local e out=()
  [[ ${EXTRAS,,} == none ]] && { EXTRAS=""; return; }
  for e in ${EXTRAS//,/ }; do
    case $e in
      lidarr|bazarr|tdarr) out+=("$e") ;;
      *) warn "Extra '$e' isn't supported by this script yet; skipping it." ;;
    esac
  done
  EXTRAS=$(printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -)
}

choose_options() {
  step "Choose your stack"

  # Re-run: default to what's installed now, so nothing gets removed by accident.
  PREV_SERVER=""; PREV_DOWNLOADER=""; PREV_EXTRAS=""; local prev_langs=""
  if [[ -f $INSTALL_DIR/.env ]]; then
    PREV_SERVER=$(sed -n 's/^STACK_SERVER=//p' "$INSTALL_DIR/.env")
    PREV_DOWNLOADER=$(sed -n 's/^STACK_DOWNLOADER=//p' "$INSTALL_DIR/.env")
    PREV_EXTRAS=$(sed -n 's/^STACK_EXTRAS=//p' "$INSTALL_DIR/.env")
    prev_langs=$(sed -n 's/^STACK_SUB_LANGS=//p' "$INSTALL_DIR/.env")
    local prev_data
    prev_data=$(sed -n 's/^DATA_DIR=//p' "$INSTALL_DIR/.env")
    (( DATA_DIR_SET )) || DATA_DIR=${prev_data:-$DATA_DIR}
    local v val
    for v in "${PORT_VARS[@]}"; do
      val=$(sed -n "s/^$v=//p" "$INSTALL_DIR/.env")
      [[ $val =~ ^[0-9]+$ ]] && printf -v "$v" '%s' "$val"
    done
    [[ -z $SERVER && $PREV_SERVER == none ]] && (( ASSUME_YES )) && SERVER=none
    [[ -n $PREV_SERVER ]] && info "Currently installed: ${PREV_SERVER} + ${PREV_DOWNLOADER}${PREV_EXTRAS:+ + ${PREV_EXTRAS//,/, }} (shown as the defaults)"
  fi

  if [[ -z $SERVER ]]; then
    case $(menu "Which media server do you want?" "$(menu_index "${PREV_SERVER:-jellyfin}" jellyfin plex both)" \
      "Jellyfin|free & open source, no account needed" \
      "Plex|polished apps everywhere, needs a plex.tv account" \
      "Both|run Jellyfin and Plex side by side") in
      1) SERVER=jellyfin ;; 2) SERVER=plex ;; 3) SERVER=both ;;
    esac
  fi
  [[ $SERVER =~ ^(jellyfin|plex|both|none)$ ]] || die "Invalid --server '$SERVER' (use jellyfin, plex or both)."

  if [[ -z $DOWNLOADER ]]; then
    case $(menu "Which download client do you want?" "$(menu_index "${PREV_DOWNLOADER:-qbittorrent}" qbittorrent sabnzbd both)" \
      "qBittorrent|torrents" \
      "SABnzbd|usenet (needs a usenet provider)" \
      "Both|torrents + usenet") in
      1) DOWNLOADER=qbittorrent ;; 2) DOWNLOADER=sabnzbd ;; 3) DOWNLOADER=both ;;
    esac
  fi
  [[ $DOWNLOADER =~ ^(qbittorrent|sabnzbd|both)$ ]] || die "Invalid --downloader '$DOWNLOADER'."

  (( EXTRAS_SET )) || ask_extras "$PREV_EXTRAS"
  normalize_extras
  if want tdarr && (( $(nproc) < 4 )); then
    warn "Tdarr transcodes with your CPU/GPU. With $(nproc) CPU core(s) it will be slow and can starve the other apps."
  fi

  if want bazarr; then
    [[ -z $SUB_LANGS ]] && SUB_LANGS=$(ask "Subtitle languages for Bazarr (2-letter codes, comma-separated)" "${prev_langs:-en}")
    SUB_LANGS=${SUB_LANGS,,}; SUB_LANGS=${SUB_LANGS// /}
    [[ $SUB_LANGS =~ ^[a-z]{2}(,[a-z]{2})*$ ]] || die "Subtitle languages must look like en or en,es (got '$SUB_LANGS')."
  fi

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
  local extras_txt
  extras_txt=$(want lidarr && echo -n "Lidarr "; want bazarr && echo -n "Bazarr (subtitles: $SUB_LANGS) "; want tdarr && echo -n "Tdarr"; true)
  printf '    %-16s %s\n' "Media server" "$servers" "Downloads" "$dls" "Automation" "Seerr · Radarr · Sonarr · Prowlarr" \
    "Extras" "${extras_txt:-none}" "Media folder" "$DATA_DIR" "App configs" "$INSTALL_DIR" "Login" "$APP_USER"
  log "Plan: server=$SERVER downloader=$DOWNLOADER extras=${EXTRAS:-none} data=$DATA_DIR install=$INSTALL_DIR user=$APP_USER"
  printf '\n'

  # Warn before a re-run drops an app that's installed today (its config folder is kept).
  local removed=() app
  if [[ -n $PREV_SERVER ]]; then
    for app in jellyfin plex qbittorrent sabnzbd lidarr bazarr tdarr; do
      if was_installed "$app" && ! want "$app"; then removed+=("$app"); fi
    done
  fi
  if (( ${#removed[@]} )); then
    warn "This will REMOVE: ${removed[*]} (their settings stay in $INSTALL_DIR/config)"
  fi

  if (( DRY_RUN )); then
    report_ports
    report_disk
    info "Dry run: nothing was changed."
    exit 0
  fi
  confirm "Install now?" || { info "Cancelled. Nothing was changed."; exit 0; }
}

stack_images() { # images this selection needs
  local imgs=("$LSIO/radarr:latest" "$LSIO/sonarr:latest" "$LSIO/prowlarr:latest" "$SEERR_IMAGE")
  want jellyfin && imgs+=("$LSIO/jellyfin:latest")
  want plex && imgs+=("$LSIO/plex:latest")
  want lidarr && imgs+=("$LSIO/lidarr:latest")
  want bazarr && imgs+=("$LSIO/bazarr:latest")
  want tdarr && imgs+=("$TDARR_IMAGE")
  want qbittorrent && imgs+=("$LSIO/qbittorrent:latest")
  want sabnzbd && imgs+=("$LSIO/sabnzbd:latest")
  printf '%s\n' "${imgs[@]}"
}

# Disk needed per image (GB): unpacked layers plus the compressed copy Docker 29's
# containerd store keeps. Measured on amd64, Oct 2026.
image_gb() {
  case $1 in
    *tdarr*) echo 6.0 ;; *seerr*) echo 1.6 ;; *jellyfin*) echo 1.7 ;; *plex*) echo 0.9 ;;
    *bazarr*) echo 0.8 ;; *lidarr*) echo 0.6 ;; *qbittorrent*) echo 0.45 ;; *) echo 0.4 ;;
  esac
}

# Where images actually land: containerd's store (Docker 29 default) or the classic root.
docker_data_path() {
  local p
  if docker info -f '{{range .DriverStatus}}{{index . 1}} {{end}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    p=/var/lib/containerd
  else
    p=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
  fi
  while [[ ! -d $p && $p != / ]]; do p=$(dirname "$p"); done
  echo "$p"
}

free_gb() { df -Pk "$1" | awk 'NR==2 {printf "%.1f", $4/1048576}'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a < b)}'; }

# Ubuntu's installer often gives the root LV only half the disk. Offer to fix it.
grow_disk() { # grow_disk path → 0 if the filesystem was grown
  local path=$1 dev vfree mnt
  command -v lvs >/dev/null 2>&1 || return 1
  dev=$(df --output=source "$path" | tail -n1)
  mnt=$(df --output=target "$path" | tail -n1)
  vfree=$(lvs --noheadings -o vg_free --units g --nosuffix "$dev" 2>/dev/null | tr -d ' ')
  [[ -n $vfree ]] && ! lt "$vfree" 1 || return 1
  info "Your disk has ${vfree%.*} GB of unallocated LVM space (Ubuntu's installer often leaves half the disk unused)."
  if (( GROW_DISK )) || { (( ! ASSUME_YES )) && has_tty && confirm "Add it to $mnt now? Safe while running, no reboot."; }; then
    run "Growing $mnt by ${vfree%.*} GB" lvextend -r -l +100%FREE "$dev"
    return 0
  fi
  info "To do it yourself later:  ${C_CYAN}sudo lvextend -r -l +100%FREE $dev${C_RESET}"
  return 1
}

report_disk() { # dry run: the same estimate as check_disk, without prompts or changes
  command -v docker >/dev/null 2>&1 || return 0
  local path free need=1 img missing=0
  path=$(docker_data_path)
  for img in $(stack_images); do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    missing=$((missing + 1)); need=$(awk -v a="$need" -v b="$(image_gb "$img")" 'BEGIN {print a + b}')
  done
  free=$(free_gb "$path")
  if (( missing == 0 )); then ok "Disk: images already downloaded (${free} GB free)"
  elif lt "$free" "$need"; then warn "Disk: ${free} GB free, ~${need} GB needed for $missing image(s): the install would stop here"
  else ok "Disk: ${free} GB free (~${need} GB needed for $missing image(s))"; fi
}

check_disk() {
  local path free need=1 img missing=0 big=""
  path=$(docker_data_path)
  for img in $(stack_images); do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    missing=$((missing + 1))
    need=$(awk -v a="$need" -v b="$(image_gb "$img")" 'BEGIN {print a + b}')
    [[ $img == *tdarr* ]] && big=" (Tdarr alone needs ~6 GB)"
  done
  free=$(free_gb "$path")
  log "disk: ${free} GB free at $path, $missing images to pull, need ~${need} GB"
  if (( missing == 0 )); then ok "Disk: images already downloaded (${free} GB free)"; return 0; fi
  if lt "$free" "$need"; then
    warn "Not enough disk: ${free} GB free on $(df --output=target "$path" | tail -n1), ~${need} GB needed for $missing image(s)$big."
    if grow_disk "$path"; then
      free=$(free_gb "$path")
      lt "$free" "$need" || { ok "Disk: ${free} GB free now"; return 0; }
    fi
    die "Free up space (or skip the biggest apps${big:+, e.g. Tdarr}) and re-run. Nothing has been installed yet."
  elif lt "$free" "$(awk -v n="$need" 'BEGIN {print n + 3}')"; then
    warn "Low disk: ${free} GB free, ~${need} GB needed for $missing image(s)$big."
    grow_disk "$path" || true
  else
    ok "Disk: ${free} GB free (~${need} GB needed)"
  fi
}

# ── Port conflicts ────────────────────────────────────────────────────────────
# Apps talk to each other on their internal container ports, so a host port
# can move freely without touching the wiring. Exceptions: Plex (host network,
# fixed 32400), qBittorrent's web UI (same port inside and out, a linuxserver
# CSRF requirement) and the torrent port (peers must reach the announced port).

PORT_VARS=(P_JELLYFIN P_PLEX P_QBIT P_TORRENT P_SAB P_RADARR P_SONARR P_PROWLARR P_SEERR P_LIDARR P_BAZARR P_TDARR P_TDARR_SRV)

port_label() {
  case $1 in
    P_JELLYFIN) echo "Jellyfin" ;; P_PLEX) echo "Plex" ;; P_QBIT) echo "qBittorrent web UI" ;;
    P_TORRENT) echo "qBittorrent torrent traffic" ;; P_SAB) echo "SABnzbd" ;; P_RADARR) echo "Radarr" ;;
    P_SONARR) echo "Sonarr" ;; P_PROWLARR) echo "Prowlarr" ;; P_SEERR) echo "Seerr" ;;
    P_LIDARR) echo "Lidarr" ;; P_BAZARR) echo "Bazarr" ;; P_TDARR) echo "Tdarr web UI" ;; P_TDARR_SRV) echo "Tdarr server (nodes)" ;;
  esac
}

port_needed() { # is this port variable used by the current selection?
  case $1 in
    P_JELLYFIN) want jellyfin ;; P_PLEX) want plex ;; P_QBIT|P_TORRENT) want qbittorrent ;;
    P_SAB) want sabnzbd ;; P_LIDARR) want lidarr ;; P_BAZARR) want bazarr ;;
    P_TDARR|P_TDARR_SRV) want tdarr ;; *) return 0 ;;
  esac
}

# Who holds a port? Prints e.g. 'container "nginx"' or 'program "casaos-gateway"'
# (empty if free). Containers of this stack count as free: a re-run reuses them.
port_owner() { # port_owner port [udp]
  local p=$1 proto=${2:-tcp} line proc name
  name=$(docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null |
    awk -F'\t' -v a=":$p->" -v b="]:$p->" 'index($2, a) || index($2, b) {print $1; exit}')
  if [[ -n $name ]]; then
    our_project "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null)" && return 0
    echo "container \"$name\""; return 0
  fi
  if [[ $proto == udp ]]; then line=$(ss -Hlunp "sport = :$p" 2>/dev/null | head -n1)
  else line=$(ss -Hltnp "sport = :$p" 2>/dev/null | head -n1); fi
  [[ -z $line ]] && return 0
  proc=$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line")
  # Our own Plex runs on the host network, so it shows up as a program.
  if [[ $proc == Plex* ]] && docker ps --filter label=com.docker.compose.service=plex --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null |
       while read -r pr; do our_project "$pr" && echo ours; done | grep -q ours; then
    return 0
  fi
  echo "program \"${proc:-unknown}\""
}

port_taken() { # free for us? checks other processes/containers and ports already assigned in this stack
  local p=$1 self=$2 v
  for v in "${PORT_VARS[@]}"; do
    [[ $v != "$self" ]] && port_needed "$v" && [[ ${!v} == "$p" ]] && return 0
  done
  [[ -n $(port_owner "$p") ]] && return 0
  [[ $self == P_TORRENT && -n $(port_owner "$p" udp) ]] && return 0
  return 1
}

next_free_port() { # next_free_port start var
  local p=$(( $1 + 1 )) tries=0
  while (( tries < 200 )); do
    (( p > 65535 )) && p=20000
    port_taken "$p" "$2" || { echo "$p"; return 0; }
    p=$((p + 1)); tries=$((tries + 1))
  done
  return 1
}

resolve_port() { # resolve_port VAR owner
  local var=$1 owner=$2 label cur alt choice p
  label=$(port_label "$var"); cur=${!var}
  warn "Port $cur ($label) is already used by $owner"

  if [[ $var == P_PLEX ]]; then
    # Plex runs on the host network and always listens on 32400.
    info "Plex can't change ports. If another Plex runs here, you can keep using that one."
    case $(menu "What should I do?" 1 \
      "Skip Plex|don't install Plex (Seerr can still use the Plex you already have)" \
      "Cancel|nothing has been installed yet") in
      1) case $SERVER in both) SERVER=jellyfin ;; plex) SERVER=none ;; esac
         ok "Skipping Plex"; return 0 ;;
      *) info "Cancelled. Nothing was installed."; exit 0 ;;
    esac
  fi

  alt=$(next_free_port "$cur" "$var") || die "Couldn't find a free port for $label."
  choice=$(menu "What should I do?" 1 \
    "Use $alt|next free port" \
    "Choose a port|type the port you want" \
    "Cancel|nothing has been installed yet")
  case $choice in
    1) p=$alt ;;
    2)
      while :; do
        p=$(ask "Port for $label (1024-65535)" "$alt")
        if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1024 || p > 65535 )); then warn "Enter a number between 1024 and 65535."; continue; fi
        if port_taken "$p" "$var"; then warn "Port $p is taken too: try another."; continue; fi
        break
      done
      ;;
    *) info "Cancelled. Nothing was installed."; exit 0 ;;
  esac
  printf -v "$var" '%s' "$p"
  ok "$label will use port $p"
}

# Dry run: say what check_ports would do, without asking or changing anything.
report_ports() {
  command -v ss >/dev/null 2>&1 || return 0
  local var owner any=0
  for var in "${PORT_VARS[@]}"; do
    port_needed "$var" || continue
    owner=$(port_owner "${!var}")
    [[ $var == P_TORRENT && -z $owner ]] && owner=$(port_owner "${!var}" udp)
    [[ -z $owner ]] && continue
    any=1
    if [[ $var == P_PLEX ]]; then
      warn "Port ${!var} ($(port_label "$var")) is used by $owner: you'd be offered to skip Plex"
    else
      warn "Port ${!var} ($(port_label "$var")) is used by $owner: would move to $(next_free_port "${!var}" "$var")"
    fi
  done
  (( any )) || ok "All ports for this plan are free (or already used by this stack)"
}

check_ports() {
  local var owner moved=0
  for var in "${PORT_VARS[@]}"; do
    port_needed "$var" || continue
    owner=$(port_owner "${!var}")
    [[ $var == P_TORRENT && -z $owner ]] && owner=$(port_owner "${!var}" udp)
    if [[ -n $owner ]]; then
      resolve_port "$var" "$owner"
      moved=1
    fi
  done
  (( moved )) || ok "Required ports are free"
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
  want lidarr && mkdir -p "$INSTALL_DIR/config/lidarr"
  want bazarr && mkdir -p "$INSTALL_DIR/config/bazarr"
  want tdarr && mkdir -p "$INSTALL_DIR"/config/tdarr/{server,configs,logs}

  # One /data tree shared by every container, so Radarr/Sonarr can hardlink
  # finished downloads into the library instead of copying them.
  mkdir -p "$DATA_DIR"/{Movies,TV_Shows,Active_Downloads}
  want qbittorrent && mkdir -p "$DATA_DIR"/Active_Downloads/torrents/{movies,tv,incomplete}
  want sabnzbd && mkdir -p "$DATA_DIR"/Active_Downloads/usenet/{incomplete,complete/movies,complete/tv}
  if want lidarr; then
    mkdir -p "$DATA_DIR/Music"
    want qbittorrent && mkdir -p "$DATA_DIR/Active_Downloads/torrents/music"
    want sabnzbd && mkdir -p "$DATA_DIR/Active_Downloads/usenet/complete/music"
  fi
  want tdarr && mkdir -p "$DATA_DIR/Transcode_Cache"
  ok "Media library:  $DATA_DIR/Movies  ·  $DATA_DIR/TV_Shows$(want lidarr && echo "  ·  $DATA_DIR/Music"; true)"
  ok "Downloads:      $DATA_DIR/Active_Downloads"

  # Pre-seed API keys so every app knows the others' keys before first boot.
  local app port name
  # Internal container ports (fixed); host ports are only in the compose mapping.
  local arrs="radarr:$I_RADARR:Radarr sonarr:$I_SONARR:Sonarr prowlarr:$I_PROWLARR:Prowlarr"
  want lidarr && arrs+=" lidarr:$I_LIDARR:Lidarr"
  for app in $arrs; do
    IFS=: read -r name port _ <<<"$app"
    local f="$INSTALL_DIR/config/$name/config.xml"
    if [[ ! -f $f ]]; then
      arr_config_xml "$port" "${app##*:}" "$(gen_secret hex 16)" >"$f"
      log "seeded $f"
    fi
  done
  ok "API keys ready for Radarr, Sonarr, Prowlarr$(want lidarr && echo ", Lidarr"; true)"

  if want qbittorrent; then
    local qconf="$INSTALL_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf"
    if [[ ! -f $qconf ]]; then
      cat >"$qconf" <<EOF
[BitTorrent]
Session\\DefaultSavePath=/data/Active_Downloads/torrents
Session\\TempPath=/data/Active_Downloads/torrents/incomplete
Session\\TempPathEnabled=true
Session\\Port=$P_TORRENT

[LegalNotice]
Accepted=true

[Preferences]
Downloads\\SavePath=/data/Active_Downloads/torrents
Downloads\\TempPath=/data/Active_Downloads/torrents/incomplete
Downloads\\TempPathEnabled=true
WebUI\\Port=$P_QBIT
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
  chown -R "$SEERR_UID:$SEERR_UID" "$INSTALL_DIR/config/seerr"
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
STACK_EXTRAS=$EXTRAS
STACK_SUB_LANGS=$SUB_LANGS
EOF
  local v
  for v in "${PORT_VARS[@]}"; do echo "$v=${!v}" >>"$INSTALL_DIR/.env"; done
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
      WEBUI_PORT: $P_QBIT
      TORRENTING_PORT: $P_TORRENT
    ports:
      - "$P_QBIT:$P_QBIT"
      - "$P_TORRENT:$P_TORRENT"
      - "$P_TORRENT:$P_TORRENT/udp"
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

EOF
    if want lidarr; then cat <<EOF
  lidarr:
    <<: *common
    image: $LSIO/lidarr:latest
    container_name: lidarr
    ports:
      - "$P_LIDARR:8686"
    volumes:
      - ./config/lidarr:/config
      - \${DATA_DIR}:/data

EOF
    fi
    if want bazarr; then cat <<EOF
  bazarr:
    <<: *common
    image: $LSIO/bazarr:latest
    container_name: bazarr
    ports:
      - "$P_BAZARR:6767"
    volumes:
      - ./config/bazarr:/config
      - \${DATA_DIR}:/data

EOF
    fi
    if want tdarr; then cat <<EOF
  tdarr:
    <<: *common
    image: $TDARR_IMAGE
    container_name: tdarr
    environment:
      PUID: \${PUID}
      PGID: \${PGID}
      TZ: \${TZ}
      UMASK_SET: "002"
      serverIP: 0.0.0.0
      serverPort: "8266"
      webUIPort: "8265"
      internalNode: "true"
      inContainer: "true"
      ffmpegVersion: "7"
      nodeName: InternalNode
    ports:
      - "$P_TDARR:8265"
      - "$P_TDARR_SRV:8266"
    volumes:
      - ./config/tdarr/server:/app/server
      - ./config/tdarr/configs:/app/configs
      - ./config/tdarr/logs:/app/logs
      - \${DATA_DIR}:/data
      - \${DATA_DIR}/Transcode_Cache:/temp
${gpu}
EOF
    fi
    cat <<EOF
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
  pull_images
  # Seerr boots now too: it creates its default settings while the others start,
  # and gets Radarr/Sonarr injected in the wiring step.
  deploy_stack "$n"

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
  if want lidarr; then
    LIDARR_URL="http://localhost:$P_LIDARR"
    LIDARR_KEY=$(xml_key "$INSTALL_DIR/config/lidarr/config.xml")
    run "Waiting for Lidarr" wait_for Lidarr "$LIDARR_URL/api/v1/system/status" 240 -H "X-Api-Key: $LIDARR_KEY"
  fi
  want bazarr && run "Waiting for Bazarr" wait_for Bazarr "http://localhost:$P_BAZARR/" 240
  want tdarr && run "Waiting for Tdarr" wait_for Tdarr "http://localhost:$P_TDARR/api/v2/status" 300
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
  # Already there (re-run): update its fields in place, so a changed port or
  # password follows along instead of leaving a stale connection.
  local existing
  existing=$(api GET "$url/api/$v/$res" "$key" | jq --arg n "$name" 'first(.[] | select(.name == $n)) // empty')
  if [[ -n $existing ]]; then
    local updated
    updated=$(jq --argjson f "$fields" '.fields |= map(.name as $k | if ($f | has($k)) then .value = $f[$k] else . end)' <<<"$existing")
    if [[ $(jq -S .fields <<<"$updated") != $(jq -S .fields <<<"$existing") ]] || jq -e '.fields[] | select(.name == "password" and .value == "********")' <<<"$existing" >/dev/null; then
      api PUT "$url/api/$v/$res/$(jq -r .id <<<"$existing")" "$key" "$updated" >/dev/null
      log "$res '$name' updated"
    else
      log "$res '$name' already up to date"
    fi
    return 0
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
  local cat cats="movies tv"
  want lidarr && cats+=" music"
  for cat in $cats; do
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
  svc_restart sabnzbd
  wait_for SABnzbd "http://localhost:$P_SAB/" 120

  # Category folders. On a brand-new SABnzbd, first-boot initialisation can
  # overwrite categories set too early, so apply after the restart, read them
  # back and retry until they stick.
  local try missing cats="movies tv"
  want lidarr && cats+=" music"
  for try in 1 2 3 4 5 6; do
    for k in $cats; do
      curl -sS "$CURL_FAIL" -G "$s" --data "mode=set_config" --data "section=categories" --data "keyword=$k" \
        --data "dir=$k" --data "apikey=$SAB_KEY" --data "output=json" >/dev/null
    done
    sleep 3
    missing=$(curl -sS -G "$s" --data "mode=get_config" --data "section=categories" --data "apikey=$SAB_KEY" --data "output=json" |
      jq -r --arg want "$cats" '($want | split(" ")) as $w | ($w - [.config.categories[] | select(.dir == .name) | .name]) | length')
    [[ $missing == 0 ]] && { echo "SABnzbd categories set (attempt $try)"; return 0; }
    echo "SABnzbd categories not applied yet (attempt $try), retrying"
  done
  echo "SABnzbd categories could not be set"; return 1
}

wire_radarr() {
  add_root_folder "$RADARR_URL" "$RADARR_KEY" /data/Movies
  if want qbittorrent; then
    add_from_schema "$RADARR_URL" v3 "$RADARR_KEY" downloadclient QBittorrent qBittorrent \
      "$(jq -n --arg u "$APP_USER" --arg p "$APP_PASS" --arg host "$H_QBIT" --arg port "$P_QBIT" '{host:$host, port:($port|tonumber), username:$u, password:$p, movieCategory:"movies"}')"
  fi
  if want sabnzbd; then
    add_from_schema "$RADARR_URL" v3 "$RADARR_KEY" downloadclient Sabnzbd SABnzbd \
      "$(jq -n --arg k "$SAB_KEY" --arg host "$H_SAB" --arg port "$I_SAB" '{host:$host, port:($port|tonumber), apiKey:$k, movieCategory:"movies"}')"
  fi
}

wire_sonarr() {
  add_root_folder "$SONARR_URL" "$SONARR_KEY" /data/TV_Shows
  if want qbittorrent; then
    add_from_schema "$SONARR_URL" v3 "$SONARR_KEY" downloadclient QBittorrent qBittorrent \
      "$(jq -n --arg u "$APP_USER" --arg p "$APP_PASS" --arg host "$H_QBIT" --arg port "$P_QBIT" '{host:$host, port:($port|tonumber), username:$u, password:$p, tvCategory:"tv"}')"
  fi
  if want sabnzbd; then
    add_from_schema "$SONARR_URL" v3 "$SONARR_KEY" downloadclient Sabnzbd SABnzbd \
      "$(jq -n --arg k "$SAB_KEY" --arg host "$H_SAB" --arg port "$I_SAB" '{host:$host, port:($port|tonumber), apiKey:$k, tvCategory:"tv"}')"
  fi
}

wire_prowlarr() {
  add_from_schema "$PROWLARR_URL" v1 "$PROWLARR_KEY" applications Radarr Radarr \
    "$(jq -n --arg k "$RADARR_KEY" --arg p "http://$H_PROWLARR:$I_PROWLARR" --arg b "http://$H_RADARR:$I_RADARR" '{prowlarrUrl:$p, baseUrl:$b, apiKey:$k}')" '.syncLevel = "fullSync"'
  add_from_schema "$PROWLARR_URL" v1 "$PROWLARR_KEY" applications Sonarr Sonarr \
    "$(jq -n --arg k "$SONARR_KEY" --arg p "http://$H_PROWLARR:$I_PROWLARR" --arg b "http://$H_SONARR:$I_SONARR" '{prowlarrUrl:$p, baseUrl:$b, apiKey:$k}')" '.syncLevel = "fullSync"'
}

wire_lidarr() {
  local qp mp
  qp=$(api GET "$LIDARR_URL/api/v1/qualityprofile" "$LIDARR_KEY" | jq -r '(map(select(.name == "Standard")) + .)[0].id')
  mp=$(api GET "$LIDARR_URL/api/v1/metadataprofile" "$LIDARR_KEY" | jq -r '(map(select(.name == "Standard")) + .)[0].id')
  if ! api GET "$LIDARR_URL/api/v1/rootfolder" "$LIDARR_KEY" | jq -e 'any(.[]; .path == "/data/Music")' >/dev/null; then
    api POST "$LIDARR_URL/api/v1/rootfolder" "$LIDARR_KEY" "$(jq -n --argjson qp "$qp" --argjson mp "$mp" \
      '{name: "Music", path: "/data/Music", defaultQualityProfileId: $qp, defaultMetadataProfileId: $mp,
        defaultMonitorOption: "all", defaultNewItemMonitorOption: "all", defaultTags: []}')" >/dev/null
  fi
  if want qbittorrent; then
    add_from_schema "$LIDARR_URL" v1 "$LIDARR_KEY" downloadclient QBittorrent qBittorrent \
      "$(jq -n --arg u "$APP_USER" --arg p "$APP_PASS" --arg host "$H_QBIT" --arg port "$P_QBIT" '{host:$host, port:($port|tonumber), username:$u, password:$p, musicCategory:"music"}')"
  fi
  if want sabnzbd; then
    add_from_schema "$LIDARR_URL" v1 "$LIDARR_KEY" downloadclient Sabnzbd SABnzbd \
      "$(jq -n --arg k "$SAB_KEY" --arg host "$H_SAB" --arg port "$I_SAB" '{host:$host, port:($port|tonumber), apiKey:$k, musicCategory:"music"}')"
  fi
  add_from_schema "$PROWLARR_URL" v1 "$PROWLARR_KEY" applications Lidarr Lidarr \
    "$(jq -n --arg k "$LIDARR_KEY" --arg p "http://$H_PROWLARR:$I_PROWLARR" --arg b "http://$H_LIDARR:$I_LIDARR" '{prowlarrUrl:$p, baseUrl:$b, apiKey:$k}')" '.syncLevel = "fullSync"'
}

# Tdarr 3 (closed source) is driven through the same endpoints its web UI uses.
# Library defaults copied from Tdarr 3.01's own "new library" template, with
# transcoding OFF: a fresh install must never start re-encoding someone's media.
tdarr_library_template() {
  cat <<'JSON'
{"name":"","folder":"","foldersToIgnore":"","foldersToIgnoreCaseInsensitive":false,"folderWatchScanInterval":30,"scannerThreadCount":2,"cache":"","output":"","folderToFolderConversion":false,"folderToFolderConversionDeleteSource":false,"folderToFolderRecordHistory":true,"copyIfConditionsMet":false,"container":".mkv","containerFilter":"mkv,mp4,mov,m4v,mpg,mpeg,avi,flv,webm,wmv,vob,evo,iso,m2ts,ts","folderWatching":false,"useFsEvents":false,"scheduledScanFindNew":false,"processLibrary":true,"processTranscodes":true,"processHealthChecks":true,"scanOnStart":false,"exifToolScan":true,"mediaInfoScan":true,"ffprobeShowData":false,"isDirectoryLibrary":false,"closedCaptionScan":false,"scanButtons":true,"scanFound":"","navItemSelected":"navSourceFolder","pluginIDs":[],"pluginCommunity":true,"handbrake":true,"ffmpeg":false,"handbrakescan":true,"ffmpegscan":false,"preset":"-Z \"Very Fast 1080p30\"","decisionMaker":{"settingsPlugin":true,"settingsFlows":false,"settingsVideo":false,"videoExcludeSwitch":true,"video_codec_names_exclude":[{"codec":"hevc","checked":false},{"codec":"h264","checked":true}],"video_size_range_include":{"min":0,"max":100000},"video_height_range_include":{"min":0,"max":3000},"video_width_range_include":{"min":0,"max":4000},"settingsAudio":false,"audioExcludeSwitch":true,"audio_codec_names_exclude":[{"codec":"mp3","checked":true},{"codec":"aac","checked":false}],"audio_size_range_include":{"min":0,"max":10}},"schedule":[{"_id":"Sun:00-01","checked":true},{"_id":"Sun:01-02","checked":true},{"_id":"Sun:02-03","checked":true},{"_id":"Sun:03-04","checked":true},{"_id":"Sun:04-05","checked":true},{"_id":"Sun:05-06","checked":true},{"_id":"Sun:06-07","checked":true},{"_id":"Sun:07-08","checked":true},{"_id":"Sun:08-09","checked":true},{"_id":"Sun:09-10","checked":true},{"_id":"Sun:10-11","checked":true},{"_id":"Sun:11-12","checked":true},{"_id":"Sun:12-13","checked":true},{"_id":"Sun:13-14","checked":true},{"_id":"Sun:14-15","checked":true},{"_id":"Sun:15-16","checked":true},{"_id":"Sun:16-17","checked":true},{"_id":"Sun:17-18","checked":true},{"_id":"Sun:18-19","checked":true},{"_id":"Sun:19-20","checked":true},{"_id":"Sun:20-21","checked":true},{"_id":"Sun:21-22","checked":true},{"_id":"Sun:22-23","checked":true},{"_id":"Sun:23-00","checked":true},{"_id":"Mon:00-01","checked":true},{"_id":"Mon:01-02","checked":true},{"_id":"Mon:02-03","checked":true},{"_id":"Mon:03-04","checked":true},{"_id":"Mon:04-05","checked":true},{"_id":"Mon:05-06","checked":true},{"_id":"Mon:06-07","checked":true},{"_id":"Mon:07-08","checked":true},{"_id":"Mon:08-09","checked":true},{"_id":"Mon:09-10","checked":true},{"_id":"Mon:10-11","checked":true},{"_id":"Mon:11-12","checked":true},{"_id":"Mon:12-13","checked":true},{"_id":"Mon:13-14","checked":true},{"_id":"Mon:14-15","checked":true},{"_id":"Mon:15-16","checked":true},{"_id":"Mon:16-17","checked":true},{"_id":"Mon:17-18","checked":true},{"_id":"Mon:18-19","checked":true},{"_id":"Mon:19-20","checked":true},{"_id":"Mon:20-21","checked":true},{"_id":"Mon:21-22","checked":true},{"_id":"Mon:22-23","checked":true},{"_id":"Mon:23-00","checked":true},{"_id":"Tue:00-01","checked":true},{"_id":"Tue:01-02","checked":true},{"_id":"Tue:02-03","checked":true},{"_id":"Tue:03-04","checked":true},{"_id":"Tue:04-05","checked":true},{"_id":"Tue:05-06","checked":true},{"_id":"Tue:06-07","checked":true},{"_id":"Tue:07-08","checked":true},{"_id":"Tue:08-09","checked":true},{"_id":"Tue:09-10","checked":true},{"_id":"Tue:10-11","checked":true},{"_id":"Tue:11-12","checked":true},{"_id":"Tue:12-13","checked":true},{"_id":"Tue:13-14","checked":true},{"_id":"Tue:14-15","checked":true},{"_id":"Tue:15-16","checked":true},{"_id":"Tue:16-17","checked":true},{"_id":"Tue:17-18","checked":true},{"_id":"Tue:18-19","checked":true},{"_id":"Tue:19-20","checked":true},{"_id":"Tue:20-21","checked":true},{"_id":"Tue:21-22","checked":true},{"_id":"Tue:22-23","checked":true},{"_id":"Tue:23-00","checked":true},{"_id":"Wed:00-01","checked":true},{"_id":"Wed:01-02","checked":true},{"_id":"Wed:02-03","checked":true},{"_id":"Wed:03-04","checked":true},{"_id":"Wed:04-05","checked":true},{"_id":"Wed:05-06","checked":true},{"_id":"Wed:06-07","checked":true},{"_id":"Wed:07-08","checked":true},{"_id":"Wed:08-09","checked":true},{"_id":"Wed:09-10","checked":true},{"_id":"Wed:10-11","checked":true},{"_id":"Wed:11-12","checked":true},{"_id":"Wed:12-13","checked":true},{"_id":"Wed:13-14","checked":true},{"_id":"Wed:14-15","checked":true},{"_id":"Wed:15-16","checked":true},{"_id":"Wed:16-17","checked":true},{"_id":"Wed:17-18","checked":true},{"_id":"Wed:18-19","checked":true},{"_id":"Wed:19-20","checked":true},{"_id":"Wed:20-21","checked":true},{"_id":"Wed:21-22","checked":true},{"_id":"Wed:22-23","checked":true},{"_id":"Wed:23-00","checked":true},{"_id":"Thur:00-01","checked":true},{"_id":"Thur:01-02","checked":true},{"_id":"Thur:02-03","checked":true},{"_id":"Thur:03-04","checked":true},{"_id":"Thur:04-05","checked":true},{"_id":"Thur:05-06","checked":true},{"_id":"Thur:06-07","checked":true},{"_id":"Thur:07-08","checked":true},{"_id":"Thur:08-09","checked":true},{"_id":"Thur:09-10","checked":true},{"_id":"Thur:10-11","checked":true},{"_id":"Thur:11-12","checked":true},{"_id":"Thur:12-13","checked":true},{"_id":"Thur:13-14","checked":true},{"_id":"Thur:14-15","checked":true},{"_id":"Thur:15-16","checked":true},{"_id":"Thur:16-17","checked":true},{"_id":"Thur:17-18","checked":true},{"_id":"Thur:18-19","checked":true},{"_id":"Thur:19-20","checked":true},{"_id":"Thur:20-21","checked":true},{"_id":"Thur:21-22","checked":true},{"_id":"Thur:22-23","checked":true},{"_id":"Thur:23-00","checked":true},{"_id":"Fri:00-01","checked":true},{"_id":"Fri:01-02","checked":true},{"_id":"Fri:02-03","checked":true},{"_id":"Fri:03-04","checked":true},{"_id":"Fri:04-05","checked":true},{"_id":"Fri:05-06","checked":true},{"_id":"Fri:06-07","checked":true},{"_id":"Fri:07-08","checked":true},{"_id":"Fri:08-09","checked":true},{"_id":"Fri:09-10","checked":true},{"_id":"Fri:10-11","checked":true},{"_id":"Fri:11-12","checked":true},{"_id":"Fri:12-13","checked":true},{"_id":"Fri:13-14","checked":true},{"_id":"Fri:14-15","checked":true},{"_id":"Fri:15-16","checked":true},{"_id":"Fri:16-17","checked":true},{"_id":"Fri:17-18","checked":true},{"_id":"Fri:18-19","checked":true},{"_id":"Fri:19-20","checked":true},{"_id":"Fri:20-21","checked":true},{"_id":"Fri:21-22","checked":true},{"_id":"Fri:22-23","checked":true},{"_id":"Fri:23-00","checked":true},{"_id":"Sat:00-01","checked":true},{"_id":"Sat:01-02","checked":true},{"_id":"Sat:02-03","checked":true},{"_id":"Sat:03-04","checked":true},{"_id":"Sat:04-05","checked":true},{"_id":"Sat:05-06","checked":true},{"_id":"Sat:06-07","checked":true},{"_id":"Sat:07-08","checked":true},{"_id":"Sat:08-09","checked":true},{"_id":"Sat:09-10","checked":true},{"_id":"Sat:10-11","checked":true},{"_id":"Sat:11-12","checked":true},{"_id":"Sat:12-13","checked":true},{"_id":"Sat:13-14","checked":true},{"_id":"Sat:14-15","checked":true},{"_id":"Sat:15-16","checked":true},{"_id":"Sat:16-17","checked":true},{"_id":"Sat:17-18","checked":true},{"_id":"Sat:18-19","checked":true},{"_id":"Sat:19-20","checked":true},{"_id":"Sat:20-21","checked":true},{"_id":"Sat:21-22","checked":true},{"_id":"Sat:22-23","checked":true},{"_id":"Sat:23-00","checked":true}],"totalHealthCheckCount":0,"totalTranscodeCount":0,"sizeDiff":0,"holdNewFiles":false,"holdFor":3600,"holdForDisplayUnit":"hours","pluginStackOverview":true,"filterResolutionsSkip":"","filterCodecsSkip":"","filterContainersSkip":"","filterHardlinked":false,"processPluginsSequentially":true}
JSON
}

tdarr_api() { # tdarr_api path json → body ; needs TDARR_TOKEN
  curl -sS "$CURL_FAIL" -m 30 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TDARR_TOKEN" --data "$2" "http://localhost:$P_TDARR$1"
}

tdarr_setup() {
  local t="http://localhost:$P_TDARR" creds res code
  creds=$(jq -nc --arg u "$APP_USER" --arg p "$APP_PASS" '{username: $u, password: $p}')
  # First run: Tdarr has no users yet, so register the shared login as its admin.
  res=$(curl -s -m 30 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data "$creds" "$t/api/v2/public/auth/register")
  code=${res##*$'\n'}
  if [[ $code == 201 ]]; then
    echo "Tdarr admin account created for $APP_USER"
  else
    res=$(curl -s -m 30 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data "$creds" "$t/api/v2/public/auth/login")
    code=${res##*$'\n'}
    [[ $code == 200 ]] || { echo "Tdarr login failed (HTTP $code): was its admin created with another password?"; return 1; }
  fi
  TDARR_TOKEN=$(jq -r '.token // empty' <<<"${res%$'\n'*}")
  [[ -n $TDARR_TOKEN ]] || { echo "Tdarr returned no token"; return 1; }

  local libs id name folder prio=0
  libs=$(tdarr_api /api/v2/cruddb '{"data":{"collection":"LibrarySettingsJSONDB","mode":"getAll","docID":"","obj":{}}}')
  prio=$(jq 'length' <<<"$libs")
  for lib in "Movies:/data/Movies" "TV_Shows:/data/TV_Shows"; do
    name=${lib%%:*}; folder=${lib#*:}
    if jq -e --arg f "$folder" 'any(.[]; .folder == $f)' <<<"$libs" >/dev/null; then
      echo "Tdarr library for $folder already exists, leaving it alone"; continue
    fi
    id="shl$name$RANDOM"
    tdarr_api /api/v2/cruddb "$(tdarr_library_template | jq -c --arg id "$id" --arg n "$name" --arg f "$folder" --argjson prio "$prio" '
      {data: {collection: "LibrarySettingsJSONDB", mode: "insert", docID: $id,
        obj: (. + {_id: $id, name: $n, folder: $f, cache: "/temp", priority: $prio, createdAt: (now * 1000 | floor),
          folderWatching: true, processTranscodes: false, processHealthChecks: true, pluginIDs: []}
          | .decisionMaker.settingsPlugin = false | .decisionMaker.settingsFlows = true)}}')" >/dev/null
    echo "Tdarr library $name → $folder (transcoding off)"
    prio=$((prio + 1))
  done
}

bazarr_key() { # auth.apikey from Bazarr's config.yaml
  awk '/^auth:/ {a=1; next} a && /^[^ ]/ {a=0} a && /^  apikey:/ {gsub(/["\047]/, "", $2); print $2; exit}' \
    "$INSTALL_DIR/config/bazarr/config/config.yaml" 2>/dev/null
}

bazarr_setup() {
  local i b="http://localhost:$P_BAZARR"
  for i in $(seq 1 60); do [[ -n $(bazarr_key) ]] && break; sleep 2; done
  BAZARR_KEY=$(bazarr_key)
  [[ -n $BAZARR_KEY ]] || { echo "Bazarr API key not found in config.yaml"; return 1; }
  # Bazarr saves settings from form fields named settings-<section>-<key>,
  # exactly like its own web UI.
  local form=(
    --data-urlencode "settings-general-use_radarr=true" --data-urlencode "settings-general-use_sonarr=true"
    --data-urlencode "settings-radarr-ip=$H_RADARR" --data-urlencode "settings-radarr-port=$I_RADARR"
    --data-urlencode "settings-radarr-apikey=$RADARR_KEY" --data-urlencode "settings-radarr-base_url=/"
    --data-urlencode "settings-sonarr-ip=$H_SONARR" --data-urlencode "settings-sonarr-port=$I_SONARR"
    --data-urlencode "settings-sonarr-apikey=$SONARR_KEY" --data-urlencode "settings-sonarr-base_url=/"
    --data-urlencode "settings-auth-type=form" --data-urlencode "settings-auth-username=$APP_USER"
    --data-urlencode "settings-auth-password=$APP_PASS"
  )
  # Language profile: only on first setup, so a re-run never overwrites yours.
  if [[ $(curl -s -H "X-API-KEY: $BAZARR_KEY" "$b/api/system/languages/profiles" | jq 'length' 2>/dev/null) == 0 ]]; then
    local l profile
    for l in ${SUB_LANGS//,/ }; do form+=(--data-urlencode "languages-enabled=$l"); done
    profile=$(jq -nc --arg langs "$SUB_LANGS" '[{
      profileId: 1, name: ("Default (" + $langs + ")"), cutoff: null, mustContain: [], mustNotContain: [],
      originalFormat: false,
      items: ($langs | split(",") | to_entries | map({id: (.key + 1), language: .value,
        audio_exclude: "False", audio_only_include: "False", hi: "False", forced: "False"}))
    }]')
    form+=(--data-urlencode "languages-profiles=$profile"
      --data-urlencode "settings-general-serie_default_enabled=true" --data-urlencode "settings-general-serie_default_profile=1"
      --data-urlencode "settings-general-movie_default_enabled=true" --data-urlencode "settings-general-movie_default_profile=1")
    echo "Creating subtitle profile for: $SUB_LANGS"
  fi
  curl -sS "$CURL_FAIL" -m 60 -X POST -H "X-API-KEY: $BAZARR_KEY" "${form[@]}" "$b/api/system/settings" >/dev/null
  echo "Bazarr connected to Radarr + Sonarr"
}

pick_profile() { # url key → "id<TAB>name", preferring HD-1080p
  api GET "$1/api/v3/qualityprofile" "$2" |
    jq -r '(map(select(.name == "HD-1080p")) + .)[0] | "\(.id)\t\(.name)"'
}

seerr_setup() {
  local settings="$INSTALL_DIR/config/seerr/settings.json"
  if [[ -f $settings ]] && jq -e '(.radarr | length) > 0' "$settings" >/dev/null 2>&1; then
    svc_up seerr
    log "Seerr already has Radarr configured"; return 0
  fi
  # Let Seerr generate a complete default settings.json first: its migrations
  # expect every section to exist, so a hand-written partial file would crash it.
  svc_up seerr
  local i
  for i in $(seq 1 90); do jq -e '.main.apiKey' "$settings" >/dev/null 2>&1 && break; sleep 2; done
  jq -e '.main.apiKey' "$settings" >/dev/null 2>&1 || { echo "Seerr did not create settings.json"; return 1; }
  sleep 3
  svc_stop seerr

  local rp sp
  rp=$(pick_profile "$RADARR_URL" "$RADARR_KEY"); sp=$(pick_profile "$SONARR_URL" "$SONARR_KEY")
  cp "$settings" "$settings.bak"
  jq --arg rk "$RADARR_KEY" --arg sk "$SONARR_KEY" --arg ip "$HOST_IP" --arg rport "$P_RADARR" --arg sport "$P_SONARR" \
     --arg rh "$H_RADARR" --arg ri "$I_RADARR" --arg sh "$H_SONARR" --arg si "$I_SONARR" --arg jh "$H_JELLYFIN" --arg ji "$I_JELLYFIN" \
     --argjson rpid "${rp%%$'\t'*}" --arg rpn "${rp#*$'\t'}" \
     --argjson spid "${sp%%$'\t'*}" --arg spn "${sp#*$'\t'}" \
     --arg server "$SERVER" '
    .radarr = [{
      id: 0, name: "Radarr", hostname: $rh, port: ($ri | tonumber), apiKey: $rk, useSsl: false, baseUrl: "",
      activeProfileId: $rpid, activeProfileName: $rpn, activeDirectory: "/data/Movies",
      tags: [], is4k: false, isDefault: true, externalUrl: "http://\($ip):\($rport)",
      syncEnabled: true, preventSearch: false, tagRequests: false, overrideRule: [],
      minimumAvailability: "released"
    }]
    | .sonarr = [{
      id: 0, name: "Sonarr", hostname: $sh, port: ($si | tonumber), apiKey: $sk, useSsl: false, baseUrl: "",
      activeProfileId: $spid, activeProfileName: $spn, activeDirectory: "/data/TV_Shows",
      activeAnimeProfileId: $spid, activeAnimeProfileName: $spn, activeAnimeDirectory: "/data/TV_Shows",
      tags: [], animeTags: [], is4k: false, isDefault: true, externalUrl: "http://\($ip):\($sport)",
      syncEnabled: true, preventSearch: false, tagRequests: false, overrideRule: [],
      seriesType: "standard", animeSeriesType: "anime", enableSeasonFolders: true, monitorNewItems: "all"
    }]
    | if ($server == "jellyfin" or $server == "both") then .jellyfin.ip = $jh | .jellyfin.port = ($ji | tonumber) else . end
    | if ($server == "plex" or $server == "both" or $server == "none") then .plex.ip = $ip | .plex.port = 32400 else . end
  ' "$settings.bak" >"$settings"
  chown "$SEERR_UID:$SEERR_UID" "$settings"

  svc_start seerr
  if ! wait_for Seerr "http://localhost:$P_SEERR/api/v1/status" 120; then
    echo "Seerr failed to start with the pre-configured settings; restoring defaults"
    svc_stop seerr; cp "$settings.bak" "$settings"; chown "$SEERR_UID:$SEERR_UID" "$settings"; svc_start seerr
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
  if want lidarr; then
    run "Securing Lidarr login" set_auth "$LIDARR_URL" v1 "$LIDARR_KEY"
    run "Lidarr → /data/Music + download clients + Prowlarr" wire_lidarr
  fi
  if want bazarr; then
    run "Bazarr → Radarr + Sonarr, subtitles: $SUB_LANGS" bazarr_setup
    BAZARR_KEY=$(bazarr_key)
  fi
  want tdarr && run "Tdarr → admin login + Movies & TV libraries" tdarr_setup
  run "Seerr → Radarr + Sonarr" seerr_setup
  [[ -f $INSTALL_DIR/.seerr_manual ]] && warn "Seerr needs Radarr/Sonarr added by hand (Settings → Services). Keys are in credentials.txt."
  return 0
}

verify_arr() { # name url key [api version]
  local r v=${4:-v3}
  r=$(api GET "$2/api/$v/downloadclient" "$3" | jq -r 'map(.name) | join(", ")')
  if [[ -n $r ]]; then ok "$1 download clients: $r"; else warn "$1 has no download client"; fi
  r=$(api GET "$2/api/$v/rootfolder" "$3" | jq -r 'map(.path) | join(", ")')
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
  want lidarr && verify_arr Lidarr "$LIDARR_URL" "$LIDARR_KEY" v1
  if want bazarr; then
    r=$(curl -s -H "X-API-KEY: $BAZARR_KEY" "http://localhost:$P_BAZARR/api/system/settings" |
      jq -r '[if .general.use_radarr then "Radarr" else empty end, if .general.use_sonarr then "Sonarr" else empty end] | join(" + ")' 2>/dev/null)
    if [[ -n $r ]]; then ok "Bazarr watches: $r"; else warn "Bazarr isn't connected to Radarr/Sonarr"; fi
  fi
  if want tdarr; then
    if [[ $(http_code "http://localhost:$P_TDARR/api/v2/status") == 200 ]]; then ok "Tdarr is up (internal node, login required)"; else warn "Tdarr is not responding yet"; fi
  fi
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
    want qbittorrent && echo "qBittorrent  http://$ip:$P_QBIT      torrent port: $P_TORRENT (forward on your router)"
    want sabnzbd && echo "SABnzbd      http://$ip:$P_SAB      API key: ${SAB_KEY:-}"
    want lidarr && echo "Lidarr       http://$ip:$P_LIDARR      API key: ${LIDARR_KEY:-}"
    want bazarr && echo "Bazarr       http://$ip:$P_BAZARR      API key: ${BAZARR_KEY:-}"
    want tdarr && echo "Tdarr        http://$ip:$P_TDARR      (same login; libraries created with transcoding OFF)"
    echo
    echo "Folders (inside every container the data folder is /data)"
    echo "  Movies     $DATA_DIR/Movies      → /data/Movies"
    echo "  TV Shows   $DATA_DIR/TV_Shows    → /data/TV_Shows"
    echo "  Downloads  $DATA_DIR/Active_Downloads → /data/Active_Downloads"
    want lidarr && echo "  Music      $DATA_DIR/Music       → /data/Music"
    want tdarr && echo "  Tdarr cache $DATA_DIR/Transcode_Cache → /temp"
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
  want lidarr && printf "$row" "$C_BOLD" "Lidarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_LIDARR" "$C_RESET"
  want bazarr && printf "$row" "$C_BOLD" "Bazarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_BAZARR" "$C_RESET"
  want tdarr && printf "$row" "$C_BOLD" "Tdarr" "$C_RESET" "$C_CYAN" "http://$ip:$P_TDARR" "$C_RESET"

  printf '\n    %sLogin%s  %s / %s%s\n' "$C_GRAY" "$C_RESET" "$APP_USER" "$APP_PASS" \
    "$( [[ ${GENERATED_PASS:-0} == 1 ]] && printf '  %s(generated, saved below)%s' "$C_GRAY" "$C_RESET")"
  printf '    %sSaved%s  %s %s(root only)%s\n' "$C_GRAY" "$C_RESET" "$f" "$C_GRAY" "$C_RESET"

  printf '\n  %sNext steps for you%s\n' "$C_BOLD" "$C_RESET"
  local n=1
  printf '    %s%d.%s %sProwlarr%s → Indexers → Add Indexer. They sync to Radarr, Sonarr%s automatically.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$(want lidarr && echo " & Lidarr"; true)"
  if want jellyfin; then
    printf '    %s%d.%s %sJellyfin%s → create your account, add libraries %s/data/Movies%s and %s/data/TV_Shows%s\n' \
      "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  fi
  if want plex; then
    printf '    %s%d.%s %sPlex%s → sign in, add libraries %s/data/Movies%s and %s/data/TV_Shows%s\n' \
      "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
  fi
  local seerr_srv
  if [[ $SERVER == plex || $SERVER == none ]]; then seerr_srv="your Plex account"; else seerr_srv="Jellyfin (server URL: http://$H_JELLYFIN:$I_JELLYFIN)"; fi
  printf '    %s%d.%s %sSeerr%s → sign in with %s. Radarr & Sonarr are already connected.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$seerr_srv"
  want sabnzbd && printf '    %s%d.%s %sSABnzbd%s → add your usenet provider in the setup wizard.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET"
  want lidarr && printf '    %s%d.%s %sLidarr%s → ready; also add a Music library (%s/data/Music%s) in your media server.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
  want bazarr && printf '    %s%d.%s %sBazarr%s → Settings → Providers: pick subtitle sites (e.g. OpenSubtitles.com needs a free account).\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET"
  want tdarr && printf '    %s%d.%s %sTdarr%s → Movies & TV_Shows libraries are ready with transcoding %sOFF%s. Pick a Flow, then turn on Transcodes.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"

  manage_hint
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

# The TrueNAS script sources this file as a library (SHL_LIBRARY=1) and runs its own main.
[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
