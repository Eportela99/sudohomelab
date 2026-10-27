#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Monitoring Stack: Uptime Kuma + Beszel + ntfy (Ubuntu / Debian)
#  https://github.com/Eportela99/sudohomelab
#
#  Installs the three as Docker containers and wires them together:
#    · ntfy         → locked down (no anonymous access), an alerts topic and a
#                     publish token for Kuma, Beszel and your own scripts
#    · Uptime Kuma  → admin account, ntfy as the default notification, and a
#                     monitor for every app it finds on this machine (sudo homelab
#                     stacks, other containers, SSH/SMB…): you pick from a list
#    · Beszel       → hub admin account, an agent for this machine, ntfy alerts
#                     (down, CPU, RAM, disk), and a ready command to add others
#  Optional extras: Dozzle (live container logs), Portainer (manage containers).
#
#  Usage (no options = a menu: Install, Add a machine, Re-scan apps, Uninstall, Quit):
#    sudo bash -c "$(curl -fsSL <url>/monitoring.sh)"
#    sudo bash -c "$(curl -fsSL <url>/monitoring.sh)" _ --install --extras=dozzle --yes
#    sudo bash -c "$(curl -fsSL <url>/monitoring.sh)" _ --agent-cmd
#    sudo bash -c "$(curl -fsSL <url>/monitoring.sh)" _ --uninstall --purge
#    sudo bash monitoring.sh --help
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.1.0"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/linux/monitoring.sh"
AGENT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/linux/beszel-agent.sh"
INSTALL_DIR="/opt/sudohomelab/monitoring"
STACKS_DIR="/opt/sudohomelab"
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/monitoring-$(date +%Y%m%d-%H%M%S).log"
PROJECT="sudohomelab-monitoring"   # compose project name
KUMA_IMAGE="louislam/uptime-kuma:2"
BESZEL_IMAGE="henrygd/beszel:latest"
AGENT_IMAGE="henrygd/beszel-agent:latest"
NTFY_IMAGE="binwiederhier/ntfy:latest"
DOZZLE_IMAGE="amir20/dozzle:latest"
PORTAINER_IMAGE="portainer/portainer-ce:lts"
NTFY_PUBLISHER="shl-alerts"        # ntfy account that may only publish to the alerts topic
KUMA_TAG="sudohomelab"             # monitors with this tag belong to the script

APP_USER=""
APP_PASS=""
ADMIN_EMAIL=""     # Beszel logs in with an email address
TOPIC=""           # ntfy topic for alerts
EXTRAS=""          # comma list of: dozzle, portainer
EXTRAS_SET=0
MONITOR=""         # which found apps get a Kuma monitor without asking: known | all | none
MONITOR_SET=0
ACTION=""          # install | agent | sync | uninstall (empty = ask)
ASSUME_YES=0
DRY_RUN=0
PURGE=0

P_KUMA=3001; P_BESZEL=8090; P_NTFY=2586; P_DOZZLE=8888; P_PORTAINER=9443
PORT_VARS=(P_KUMA P_BESZEL P_NTFY P_DOZZLE P_PORTAINER)   # earlier ones win a clash
EXTRA_IDS=(dozzle portainer)

extra_label() {
  case $1 in
    dozzle) echo "Dozzle: live logs of every container in your browser" ;;
    portainer) echo "Portainer: start, stop and update containers from a web page" ;;
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

NTFY_TOKEN=""      # publish token (alerts topic only)
NTFY_PUB_PASS=""   # password of the publisher account (nobody logs in with it)
BESZEL_TOKEN=""    # Beszel universal token: lets agents register themselves
BESZEL_KEY=""      # the hub's public key (agents check they talk to the right hub)
KUMA_PASS=""
STEP=0
TOTAL_STEPS=12     # 11 without extras (set in choose_options)
CURRENT_STEP="starting"

# Logs may be attached to public GitHub issues: secrets are masked, colours stripped.
log() {
  local m="$*" s
  for s in "$APP_PASS" "$NTFY_TOKEN" "$NTFY_PUB_PASS" "$BESZEL_TOKEN"; do
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
  printf '    %s❯%s %sMonitoring Stack: Uptime Kuma + Beszel + ntfy%s %sv%s · Ubuntu / Debian%s\n\n' \
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
  cat <<EOF
sudo homelab · Monitoring Stack (Uptime Kuma + Beszel + ntfy) v$VERSION

Usage: sudo bash monitoring.sh [action] [options]
With no action it shows a menu.

Actions:
  --install                    Install, or change the settings of an existing install
  --agent-cmd                  Show the command that adds another machine to Beszel
  --sync                       Look for apps again and update Uptime Kuma's monitors
                               (and give new Beszel machines the default alerts)
  --uninstall                  Remove the containers (keeps data)
  --purge                      With --uninstall, also delete all data

Install options:
  --username=NAME              Login for every app (default admin)
  --password=PASS              Its password (generated if omitted)
  --password-file=FILE         The same, read from a file (keeps it out of the process list)
  --email=ADDRESS              Beszel login (default <username>@homelab.local)
  --topic=NAME                 ntfy topic for alerts (default homelab-alerts)
  --extras=dozzle,portainer    Optional apps (or "none")
  --monitor=known|all|none     Which apps found on this machine get an Uptime Kuma
                               monitor without asking: known apps (default with --yes),
                               every container, or none
  --install-dir=PATH           Compose file + data (default $INSTALL_DIR)
  -y, --yes                    Non-interactive: accept defaults
  --dry-run                    Show what would happen, change nothing
  -h, --help                   Show this help
EOF
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
      --topic=*) TOPIC=${arg#*=} ;;
      --extras=*) EXTRAS=${arg#*=}; EXTRAS_SET=1 ;;
      --monitor=*) MONITOR=${arg#*=}; MONITOR_SET=1 ;;
      --install-dir=*) INSTALL_DIR=${arg#*=} ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --install) set_action install ;;
      --agent-cmd) set_action agent ;;
      --sync) set_action sync ;;
      --uninstall) set_action uninstall ;;
      --purge) PURGE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ -z $MONITOR || $MONITOR =~ ^(known|all|none)$ ]] || { echo "--monitor must be known, all or none" >&2; exit 2; }
  (( ! PURGE )) || [[ $ACTION == uninstall ]] || { echo "--purge only goes with --uninstall" >&2; exit 2; }
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
want() { [[ ,$EXTRAS, == *,$1,* ]]; }

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
      NTFY_TOKEN) NTFY_TOKEN=$v ;;
      NTFY_PUB_PASS) NTFY_PUB_PASS=$v ;;
      BESZEL_TOKEN) BESZEL_TOKEN=$v ;;
    esac
  done <"$INSTALL_DIR/.secrets"
  return 0
}

save_secrets() {
  mkdir -p "$INSTALL_DIR"
  ( umask 077
    printf 'APP_USER=%s\nAPP_PASS=%s\nNTFY_TOKEN=%s\nNTFY_PUB_PASS=%s\nBESZEL_TOKEN=%s\n' \
      "$APP_USER" "$APP_PASS" "$NTFY_TOKEN" "$NTFY_PUB_PASS" "$BESZEL_TOKEN" >"$INSTALL_DIR/.secrets" )
}

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
    P_KUMA) echo "Uptime Kuma" ;; P_BESZEL) echo "Beszel" ;; P_NTFY) echo "ntfy" ;;
    P_DOZZLE) echo "Dozzle" ;; P_PORTAINER) echo "Portainer" ;;
  esac
}
port_needed() {
  case $1 in P_DOZZLE) want dozzle ;; P_PORTAINER) want portainer ;; *) return 0 ;; esac
}

port_taken() { # port_taken port self-var
  local p=$1 self=$2 v
  for v in "${PORT_VARS[@]}"; do port_needed "$v" && [[ $v != "$self" && ${!v} == "$p" ]] && return 0; done
  [[ -n $(conflicts "$p") ]]
}

next_free_port() { # next_free_port var → a free port near the usual one
  local var=$1 p tries=0
  case $var in P_KUMA) p=3002 ;; P_BESZEL) p=8091 ;; P_NTFY) p=2587 ;; P_DOZZLE) p=8889 ;; *) p=9444 ;; esac
  while (( tries < 200 )); do
    port_taken "$p" "$var" || { echo "$p"; return 0; }
    p=$((p + 1)); tries=$((tries + 1))
  done
  return 1
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

# ── Finding apps to monitor ───────────────────────────────────────────────────
# Each app becomes one Uptime Kuma monitor. A found app is a line:
#   key|name|type|target|port|source|known
#     key     c:<container>, s:<service>, or dns:<container> (stable across re-runs)
#     type    http (target = path), port (TCP check), docker (container running), dns
#     source  which sudo homelab stack it belongs to, "docker" or "this machine"
# Kuma runs in a container: it reaches apps on this machine through
# host.docker.internal (the Docker host), so the monitors survive an IP change.

# Known images: name|health path|port inside the container|accepted HTTP codes
known_image() {
  local img=${1##*/}; img=${img%%:*}; img=${img%%@*}
  case $img in
    jellyfin) echo "Jellyfin|/health|8096" ;;
    plex|pms-docker) echo "Plex|/identity|32400" ;;
    emby|embyserver) echo "Emby|/emby/System/Info/Public|8096" ;;
    radarr) echo "Radarr|/ping|7878" ;;
    sonarr) echo "Sonarr|/ping|8989" ;;
    prowlarr) echo "Prowlarr|/ping|9696" ;;
    lidarr) echo "Lidarr|/ping|8686" ;;
    readarr) echo "Readarr|/ping|8787" ;;
    bazarr) echo "Bazarr|/|6767" ;;
    qbittorrent|qbittorrent-nox) echo "qBittorrent|/|8080" ;;
    sabnzbd) echo "SABnzbd|/|8080" ;;
    transmission) echo "Transmission|/transmission/web/|9091" ;;
    deluge) echo "Deluge|/|8112" ;;
    seerr|overseerr|jellyseerr) echo "Seerr|/api/v1/status|5055" ;;
    tdarr) echo "Tdarr|/api/v2/status|8265" ;;
    audiobookshelf) echo "Audiobookshelf|/healthcheck|80" ;;
    komga) echo "Komga|/|25600" ;;
    kavita) echo "Kavita|/api/health|5000" ;;
    calibre-web) echo "Calibre-Web|/|8083" ;;
    immich-server|server) [[ $1 == *immich* ]] && echo "Immich|/api/server/ping|2283" ;;
    nextcloud) echo "Nextcloud|/status.php|80" ;;
    vaultwarden|server-vaultwarden) echo "Vaultwarden|/alive|80" ;;
    home-assistant|homeassistant) echo "Home Assistant|/manifest.json|8123" ;;
    grafana) echo "Grafana|/api/health|3000" ;;
    n8n) echo "n8n|/healthz|5678" ;;
    pihole) echo "Pi-hole|/admin/|80" ;;
    adguardhome) echo "AdGuard Home|/|3000" ;;
    nginx-proxy-manager) echo "Nginx Proxy Manager|/|81" ;;
    homarr) echo "Homarr|/|7575" ;;
    homepage) echo "Homepage|/|3000" ;;
    gitea) echo "Gitea|/api/healthz|3000" ;;
    paperless-ngx) echo "Paperless-ngx|/|8000" ;;
    syncthing) echo "Syncthing|/rest/noauth/health|8384" ;;
    filebrowser) echo "File Browser|/health|80" ;;
    portainer-ce|portainer-ee) echo "Portainer|/api/system/status|9000" ;;
    uptime-kuma) echo "Uptime Kuma (another)|/|3001" ;;
    beszel) echo "Beszel (another)|/api/health|8090" ;;
    dozzle) echo "Dozzle|/healthcheck|8080" ;;
    ntfy) echo "ntfy (another)|/v1/health|80" ;;
    casaos*) ;;
  esac
}

stack_of() { # compose project → which sudo homelab stack it is
  case $1 in
    mediastack) echo "media stack" ;;
    sudohomelab-pihole|ix-pihole) echo "DNS stack" ;;
    "$PROJECT") echo "this stack" ;;
    "") echo "docker" ;;
    *) echo "docker ($1)" ;;
  esac
}

# Ports of host-network containers aren't in `docker ps`: our stacks saved them.
saved_port() { # saved_port container default
  local v=""
  case $1 in
    plex) v=$(sed -n 's/^P_PLEX=//p' "$STACKS_DIR/media-stack/.env" 2>/dev/null) ;;
    pihole) v=$(sed -n 's/^P_WEB=//p' "$STACKS_DIR/pihole/.state" 2>/dev/null | tail -n1) ;;
  esac
  echo "${v:-$2}"
}

published_host_port() { # published_host_port "<docker ps Ports>" container-port → host port
  awk -v cp="$2" 'BEGIN { RS = ", " } /->/ && /\/tcp/ {
      split($0, h, "->"); hp = h[1]; sub(/.*:/, "", hp); c = h[2]; sub(/\/tcp.*/, "", c)
      split(hp, r, "-"); split(c, cr, "-")
      if (cp == "" ) { print r[1]; exit }
      if (cp + 0 >= cr[1] + 0 && cp + 0 <= (cr[2] != "" ? cr[2] : cr[1]) + 0) { print r[1] + (cp - cr[1]); exit }
    }' <<<"$1"
}

speaks_http() { [[ $(http_code "http://127.0.0.1:$1/") =~ ^[1-5][0-9][0-9]$ ]]; }

# What the last scan found, so a stopped container or service keeps its monitor
# (and shows as down) instead of disappearing. A removed container loses it.
FOUND_FILE=".found"
saved_found() { [[ -f $INSTALL_DIR/$FOUND_FILE ]] && awk -F'|' -v k="$1" '$1 == k {print; exit}' "$INSTALL_DIR/$FOUND_FILE" || true; }
mark_found() { awk -F'|' -v OFS='|' -v m="$2" '{$6 = $6 " (" m ")"; print}' <<<"$1"; }   # mark_found line note
save_found() { printf '%s\n' "${FOUND[@]}" | sed -E 's/ \((stopped now|not listening now)\)\|/|/' | sort >"$INSTALL_DIR/$FOUND_FILE"; }

discover() {
  local name image ports project state mode k info aname path cport port src seen_plex=0 line
  command -v docker >/dev/null 2>&1 || return 0
  # "|" separators: tabs are whitespace to `read`, so an empty Ports field (host network) would shift the rest.
  while IFS='|' read -r name image ports project state; do
    our_project "$project" && continue   # our own apps are always monitored (see kuma_monitors)
    src=$(stack_of "$project")
    if [[ $state != running ]]; then
      # Stopped: no published ports to read, so reuse what the last scan saw.
      line=$(saved_found "c:$name")
      if [[ -n $line ]]; then mark_found "$line" "stopped now"
      else
        info=$(known_image "$image"); aname=${info%%|*}
        echo "c:$name|${aname:-$name}|docker|$name||$src (stopped now)|$( [[ -n $info ]] && echo 1 || echo 0)"
      fi
      continue
    fi
    mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name" 2>/dev/null || true)
    info=$(known_image "$image")
    if [[ -n $info ]]; then
      IFS='|' read -r aname path cport <<<"$info"
      [[ $aname == Plex ]] && seen_plex=1
      if [[ $mode == host ]]; then port=$(saved_port "$name" "$cport")
      else port=$(published_host_port "$ports" "$cport"); [[ -z $port ]] && port=$(published_host_port "$ports" ""); fi
      if [[ -n $port ]]; then echo "c:$name|$aname|http|$path|$port|$src|1"
      else echo "c:$name|$aname|docker|$name||$src|1"; fi
      [[ $aname == Pi-hole ]] && echo "dns:$name|Pi-hole DNS|dns|53|53|$src|1"
    else
      [[ $image == *casaos* || $name == tailscale* ]] && continue
      port=$(published_host_port "$ports" "")
      if [[ -n $port ]] && speaks_http "$port"; then echo "c:$name|$name|http|/|$port|$src|0"
      elif [[ -n $port ]]; then echo "c:$name|$name|port||$port|$src|0"
      else echo "c:$name|$name|docker|$name||$src|0"; fi
    fi
  done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}|{{.State}}' 2>/dev/null | sort)

  # Services installed on the machine itself (not in Docker).
  # "port<TAB>program" for everything listening on more than localhost
  local procs
  procs=$(ss -Hltnp 2>/dev/null | awk '$4 !~ /^(127\.|\[::1\])/' |
    sed -nE 's/^[^ ]+ +[0-9]+ +[0-9]+ +[^ ]*:([0-9]+) .*users:\(\("([^"]+)".*/\1\t\2/p' | sort -u || true)
  listening() { awk -F'\t' -v p="$1" '$1 == p {f = 1} END {exit !f}' <<<"$procs"; }
  svc() { awk -F'\t' -v n="$1" '$2 == n {print $1; exit}' <<<"$procs"; }
  {
    # sshd is often socket-activated (the listener is systemd), so go by the port.
    listening 22 && echo "s:ssh|SSH|port||22|this machine|1"
    listening 445 && echo "s:smb|SMB file sharing|port||445|this machine|1"
    port=$(svc casaos-gateway); [[ -n $port ]] && echo "s:casaos|CasaOS|http|/|$port|this machine|1"
    port=$(svc cockpit-ws); [[ -n $port ]] && echo "s:cockpit|Cockpit|http|/|$port|this machine|1"
    if (( ! seen_plex )); then port=$(svc 'Plex Media Serv'); [[ -n $port ]] && echo "s:plex|Plex|http|/identity|32400|this machine|1"; fi
    true
  }
  # Services seen before but not listening now (stopped, or crashed) keep their monitor.
  if [[ -f $INSTALL_DIR/$FOUND_FILE ]]; then
    local now
    now=$(listening 22 && echo s:ssh; listening 445 && echo s:smb; [[ -n $(svc casaos-gateway) ]] && echo s:casaos
          [[ -n $(svc cockpit-ws) ]] && echo s:cockpit; [[ -n $(svc 'Plex Media Serv') ]] && echo s:plex; true)
    while IFS= read -r line; do
      k=${line%%|*}
      grep -qx -- "$k" <<<"$now" || mark_found "$line" "not listening now"
    done < <(grep '^s:' "$INSTALL_DIR/$FOUND_FILE" || true)
  fi
  return 0
}

declare -A FOUND=()     # key → found line
FOUND_KEYS=()
found_label() {
  local k=$1 name type target port src known
  IFS='|' read -r _ name type target port src known <<<"${FOUND[$k]}"
  local what
  case $type in
    http) what=":$port" ;; port) what=":$port (TCP)" ;; dns) what=":53 (DNS)" ;; docker) what="(container running)" ;;
  esac
  printf '%-22s %-20s %s%s%s' "$name" "$what" "$C_GRAY" "$src$( [[ $known == 0 ]] && echo ", unknown app")" "$C_RESET"
}

# Which found apps get a monitor. A re-run keeps what you picked; new apps
# default to on when they're known apps.
choose_monitors() {
  local line k def="" prev_on prev_seen
  FOUND=(); FOUND_KEYS=()
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    k=${line%%|*}
    [[ -n ${FOUND[$k]:-} ]] && continue
    FOUND[$k]=$line; FOUND_KEYS+=("$k")
  done < <(discover)
  prev_on=$(state_get KUMA_ON); prev_seen=$(state_get KUMA_SEEN)
  [[ -z $MONITOR ]] && MONITOR=$(state_get MONITOR_MODE)
  for k in "${FOUND_KEYS[@]}"; do
    if [[ $MONITOR == all ]]; then def+="$k,"
    elif [[ $MONITOR == none ]]; then :
    elif [[ ,$prev_seen, == *,$k,* ]]; then [[ ,$prev_on, == *,$k,* ]] && def+="$k,"
    elif [[ ${FOUND[$k]##*|} == 1 ]]; then def+="$k,"
    fi
  done
  def=${def%,}
  if (( ${#FOUND_KEYS[@]} == 0 )); then KUMA_ON=""; info "No other apps found on this machine yet (re-scan later from the menu)"; return 0; fi
  ok "Found ${#FOUND_KEYS[@]} apps and services on this machine"
  if (( MONITOR_SET || ASSUME_YES )) || ! has_tty; then
    KUMA_ON=$def
  else
    KUMA_ON=$(multi_select "Which ones should Uptime Kuma watch? (unknown apps are off by default)" "$def" found_label "${FOUND_KEYS[@]}")
  fi
  local n=0; [[ -n $KUMA_ON ]] && n=$(tr ',' '\n' <<<"$KUMA_ON" | grep -c .)
  ok "Uptime Kuma will watch $n of them, plus this stack's own apps"
}

# ── Choices ───────────────────────────────────────────────────────────────────
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
  [[ $ARCH =~ ^(amd64|arm64)$ ]] || die "Unsupported architecture: $ARCH (Uptime Kuma 2 needs amd64 or arm64)."
  ok "Architecture: $ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  command -v ss >/dev/null 2>&1 || die "The 'ss' command is missing (package iproute2)."
  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  # Kuma ~0.5 GB, the rest ~0.1 GB, Portainer ~0.3 GB; plus history.
  (( free_mb >= 1536 )) || docker image inspect "$KUMA_IMAGE" >/dev/null 2>&1 ||
    die "Only ${free_mb} MB free on /. The monitoring apps need about 1.5 GB."
  TZ_NAME=$(detect_tz); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "Server IP: $HOST_IP"
}

ask_credentials() {
  local interactive=0 prev
  (( ! ASSUME_YES )) && has_tty && interactive=1
  load_secrets
  if [[ -f $INSTALL_DIR/.secrets && -n $APP_PASS ]]; then
    info "Existing install found: keeping login '$APP_USER'"
  else
    (( interactive )) && printf '\n  %sLogin for your apps%s %s(one login for Uptime Kuma, Beszel, ntfy and the extras)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while [[ -z $APP_USER ]] || [[ ! $APP_USER =~ ^[A-Za-z0-9._-]{3,32}$ ]]; do
      [[ -n $APP_USER ]] && warn "Username must be 3-32 characters: letters, numbers, . _ -"
      (( interactive )) || { APP_USER=${APP_USER:-admin}; break; }
      APP_USER=$(ask "Username" "admin")
    done
    if [[ -z $APP_PASS ]] && (( interactive )); then
      case $(menu "Password for '$APP_USER'" 1 \
        "Auto-generate|a strong random password, shown now and saved for you" \
        "Type my own|at least 12 characters (Portainer's minimum)") in
        2)
          while :; do
            APP_PASS=$(ask_secret "Password:")
            if (( ${#APP_PASS} < 12 )); then warn "Use at least 12 characters."; continue; fi
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
  (( ${#APP_PASS} >= 12 )) || die "The password must be at least 12 characters (Portainer's minimum)."

  prev=$(state_get ADMIN_EMAIL)
  [[ -z $ADMIN_EMAIL ]] && ADMIN_EMAIL=$prev
  if [[ -z $ADMIN_EMAIL ]]; then
    ADMIN_EMAIL=$(ask "Email for the Beszel login (it doesn't have to be real)" "${APP_USER,,}@homelab.local")
  fi
  [[ $ADMIN_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Not a valid email address: '$ADMIN_EMAIL'."
}

choose_options() {
  step "Choose your setup"
  local prev v
  if [[ -f $INSTALL_DIR/.state ]]; then
    info "Existing install found in $INSTALL_DIR (its settings are the defaults)"
    for v in "${PORT_VARS[@]}"; do prev=$(state_get "$v"); [[ $prev =~ ^[0-9]+$ ]] && printf -v "$v" '%s' "$prev"; done
  fi
  ask_credentials

  [[ -z $TOPIC ]] && TOPIC=$(state_get TOPIC)
  [[ -z $TOPIC ]] && TOPIC=homelab-alerts
  [[ $TOPIC =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "The ntfy topic may only have letters, numbers, - and _ (got '$TOPIC')."

  if (( ! EXTRAS_SET )); then
    EXTRAS=$(multi_select "Extras" "$(state_get EXTRAS)" extra_label "${EXTRA_IDS[@]}")
  fi
  [[ ${EXTRAS,,} == none ]] && EXTRAS=""
  for v in ${EXTRAS//,/ }; do [[ -n $(extra_label "$v") ]] || die "Unknown extra '$v' (use dozzle, portainer)."; done

  want dozzle || want portainer || TOTAL_STEPS=11

  step "Checking ports"
  check_ports
  local app name
  while IFS='|' read -r app name; do
    [[ -n $app ]] || continue
    warn "$app already runs here as container \"$name\": this stack adds its own (yours is left alone)."
    [[ $app == "Beszel agent" ]] && info "Two agents would report this machine twice: you can remove \"$name\" after the install."
  done < <(others_running)

  step "Finding apps to monitor"
  choose_monitors
  print_plan
  if (( DRY_RUN )); then info "Dry run: nothing was changed."; exit 0; fi
  confirm "Install now?" || { info "Cancelled. Nothing was changed."; exit 0; }
}

print_plan() {
  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  printf '    %-14s %s\n' "Uptime Kuma" "http://$HOST_IP:$P_KUMA  ·  watches your apps, alerts through ntfy" \
    "Beszel" "http://$HOST_IP:$P_BESZEL  ·  CPU/RAM/disk/containers of this machine (+ others you add)" \
    "ntfy" "http://$HOST_IP:$P_NTFY  ·  alerts topic \"$TOPIC\" (login required)"
  want dozzle && printf '    %-14s %s\n' "Dozzle" "http://$HOST_IP:$P_DOZZLE  ·  live container logs"
  want portainer && printf '    %-14s %s\n' "Portainer" "https://$HOST_IP:$P_PORTAINER"
  local n=0; [[ -n $KUMA_ON ]] && n=$(tr ',' '\n' <<<"$KUMA_ON" | grep -c .)
  printf '    %-14s %s\n' "Watching" "$n app(s) found here + this stack's own · Beszel: this machine" \
    "Login" "$APP_USER (Beszel: $ADMIN_EMAIL)" "Data" "$INSTALL_DIR"
  log "Plan: extras=${EXTRAS:-none} topic=$TOPIC user=$APP_USER email=$ADMIN_EMAIL ports=$P_KUMA/$P_BESZEL/$P_NTFY/$P_DOZZLE/$P_PORTAINER monitors=${KUMA_ON:-none}"
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
  for pkg in curl jq ca-certificates gnupg iproute2 qrencode; do
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

pull_images() {
  run "Downloading Uptime Kuma" docker pull "$KUMA_IMAGE"
  run "Downloading Beszel (hub + agent)" bash -c "docker pull '$BESZEL_IMAGE' && docker pull '$AGENT_IMAGE'"
  run "Downloading ntfy" docker pull "$NTFY_IMAGE"
  want dozzle && run "Downloading Dozzle" docker pull "$DOZZLE_IMAGE"
  want portainer && run "Downloading Portainer" docker pull "$PORTAINER_IMAGE"
  return 0
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

# Container names: the plain name, unless a container that isn't ours has it
# (lots of people already run one called "portainer"): then shl-<name>.
cname() {
  local p
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null) || { echo "$1"; return; }
  if our_project "$p"; then echo "$1"; else echo "shl-$1"; fi
}

# The same apps already running outside this stack (a CasaOS Beszel, your own Portainer…).
others_running() {
  local name image project
  docker ps -a --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null |
    while IFS='|' read -r name image project; do
      our_project "$project" && continue
      case ${image##*/} in
        uptime-kuma*) echo "Uptime Kuma|$name" ;; beszel:*|beszel) echo "Beszel hub|$name" ;; beszel-agent*) echo "Beszel agent|$name" ;;
        ntfy*) echo "ntfy|$name" ;; dozzle*) want dozzle && echo "Dozzle|$name" ;; portainer-ce*|portainer-ee*) want portainer && echo "Portainer|$name" ;;
      esac
    done
  return 0
}

write_compose() {
  local f="$INSTALL_DIR/docker-compose.yml" m n
  cat >"$f" <<EOF
# sudo homelab · Monitoring Stack. Re-run the installer to change settings.
name: $PROJECT
services:
  kuma:
    image: $KUMA_IMAGE
    container_name: $(cname uptime-kuma)
    ports:
      - "${P_KUMA}:3001"
    volumes:
      - ./kuma:/app/data
      - /var/run/docker.sock:/var/run/docker.sock:ro   # "container is running" monitors
    extra_hosts:
      - "host.docker.internal:host-gateway"            # apps on this machine
    environment:
      TZ: "$TZ_NAME"
    restart: unless-stopped

  beszel:
    image: $BESZEL_IMAGE
    container_name: $(cname beszel)
    ports:
      - "${P_BESZEL}:8090"
    volumes:
      - ./beszel:/beszel_data
    environment:
      APP_URL: "http://$HOST_IP:$P_BESZEL"
    restart: unless-stopped

  # This machine's agent. It dials out to the hub (no port opened here), the
  # same way agents on your other machines do.
  beszel-agent:
    image: $AGENT_IMAGE
    container_name: $(cname beszel-agent)
    network_mode: host
    env_file: .agent.env
    environment:
      HUB_URL: "http://127.0.0.1:$P_BESZEL"
      LISTEN: /var/lib/beszel-agent/beszel.sock
    volumes:
      - ./beszel-agent:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF
  while IFS=$'\t' read -r m n; do
    [[ -n $m ]] && printf '      - "%s/.beszel:/extra-filesystems/%s:ro"\n' "$m" "$n" >>"$f"
  done < <(extra_filesystems)
  cat >>"$f" <<EOF
    depends_on:
      - beszel
    restart: unless-stopped

  ntfy:
    image: $NTFY_IMAGE
    container_name: $(cname ntfy)
    command: serve
    ports:
      - "${P_NTFY}:80"
    environment:
      TZ: "$TZ_NAME"
      NTFY_BASE_URL: "http://$HOST_IP:$P_NTFY"
      NTFY_AUTH_FILE: /var/lib/ntfy/auth.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all      # nobody reads or posts without logging in
      NTFY_ENABLE_LOGIN: "true"
      NTFY_CACHE_FILE: /var/lib/ntfy/cache.db
      NTFY_CACHE_DURATION: 72h
      NTFY_UPSTREAM_BASE_URL: https://ntfy.sh # instant iPhone notifications (only a message ID goes there)
    volumes:
      - ./ntfy:/var/lib/ntfy
    healthcheck:
      test: ["CMD-SHELL", "wget -q -T 5 -O - http://localhost:80/v1/health | grep -q true"]
      interval: 60s
      timeout: 10s
      retries: 3
    restart: unless-stopped
EOF
  if want dozzle; then
    cat >>"$f" <<EOF

  dozzle:
    image: $DOZZLE_IMAGE
    container_name: $(cname dozzle)
    ports:
      - "${P_DOZZLE}:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./dozzle:/data
    environment:
      DOZZLE_AUTH_PROVIDER: simple
    restart: unless-stopped
EOF
  fi
  if want portainer; then
    cat >>"$f" <<EOF

  portainer:
    image: $PORTAINER_IMAGE
    container_name: $(cname portainer)
    command: --admin-password-file /run/portainer-pass
    ports:
      - "${P_PORTAINER}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer:/data
      - ./.portainer-pass:/run/portainer-pass:ro
    restart: unless-stopped
EOF
  fi
}

write_files() {
  mkdir -p "$INSTALL_DIR"/{kuma,beszel,beszel-agent,ntfy}
  chmod 700 "$INSTALL_DIR"
  # A fresh Kuma 2 asks which database to use before anything else: SQLite.
  [[ -f $INSTALL_DIR/kuma/db-config.json ]] || echo '{"type":"sqlite"}' >"$INSTALL_DIR/kuma/db-config.json"
  # The agent's key and token: filled in once the hub is up (an empty token just waits).
  [[ -f $INSTALL_DIR/.agent.env ]] || ( umask 077; : >"$INSTALL_DIR/.agent.env" )
  if want portainer; then
    ( umask 077; printf '%s' "$APP_PASS" >"$INSTALL_DIR/.portainer-pass" )
  fi
  write_compose
  save_secrets
  local v
  for v in "${PORT_VARS[@]}" EXTRAS TOPIC ADMIN_EMAIL; do state_set "$v" "${!v}"; done
  if (( MONITOR_SET )); then state_set MONITOR_MODE "$MONITOR"; fi
}

wait_http() { # wait_http url seconds "what"
  local i
  for (( i = 0; i < $2; i += 2 )); do
    [[ $(http_code "$1") =~ ^(200|30[1-8])$ ]] && { echo "$3 answers"; return 0; }
    sleep 2
  done
  echo "$3 didn't answer at $1 within $2 seconds"
  return 1
}

start_stack() {
  step "Starting the apps"
  pull_images
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  run "Starting the containers" dc up -d --remove-orphans
  run "Waiting for ntfy" wait_http "http://127.0.0.1:$P_NTFY/v1/health" 120 ntfy
  run "Waiting for Beszel" wait_http "http://127.0.0.1:$P_BESZEL/api/health" 120 Beszel
  run "Waiting for Uptime Kuma (first start sets up its database)" wait_http "http://127.0.0.1:$P_KUMA/api/entry-page" 300 "Uptime Kuma"
}

# ── ntfy ──────────────────────────────────────────────────────────────────────
# ntfy's own CLI (works on its user database directly). `exec -T` reads stdin: nx gets
# /dev/null, nx_in takes piped input. Under `curl | bash` stdin is the script itself.
nx() { dc exec -T ntfy ntfy "$@" </dev/null; }
nx_in() { dc exec -T ntfy ntfy "$@"; }
# Output is captured before grep: `grep -q` quits early, the writer gets SIGPIPE and pipefail fails the test.
ntfy_has_user() { local l; l=$(nx user list 2>&1); grep -q "^user $1 " <<<"$l"; }

ntfy_set_user() { # ntfy_set_user name password role
  if ntfy_has_user "$1"; then
    printf '%s\n%s\n' "$2" "$2" | nx_in user change-pass "$1" >/dev/null
    nx user change-role "$1" "$3"
  else
    printf '%s\n%s\n' "$2" "$2" | nx_in user add --role="$3" "$1"
  fi
}

ntfy_publish() { # ntfy_publish title message [priority] → fails unless ntfy accepts it
  { ckv url "http://127.0.0.1:$P_NTFY/$TOPIC"; ckv header "Authorization: Bearer $NTFY_TOKEN"
    ckv header "Title: $1"; ckv header "Priority: ${3:-3}"; ckv header "Tags: white_check_mark"; ckv data "$2"; } |
    curl -fsS -m 10 -o /dev/null -K -
}

# Test notifications go out once per token/topic: re-runs don't buzz your phone.
notify_key() { printf '%s|%s' "$NTFY_TOKEN" "$TOPIC" | sha256sum | cut -c1-16; }
fresh_notify() { [[ $(state_get NOTIFY_TESTED) != "$(notify_key)" ]]; }

ntfy_publisher() {
  ntfy_set_user "$NTFY_PUBLISHER" "$NTFY_PUB_PASS" user
  nx access --reset "$NTFY_PUBLISHER" >/dev/null
  nx access "$NTFY_PUBLISHER" "$TOPIC" write-only
}

setup_ntfy() {
  step "Setting up ntfy"
  run "Your account ($APP_USER, can read every topic)" ntfy_set_user "$APP_USER" "$APP_PASS" admin
  [[ -n $NTFY_PUB_PASS ]] || NTFY_PUB_PASS=$(gen_pass 24)
  run "Publisher account for alerts (may only post to \"$TOPIC\")" ntfy_publisher
  # Keep the saved token while ntfy still knows it; otherwise make a new one.
  local tokens
  tokens=$(nx token list "$NTFY_PUBLISHER" 2>&1 || true)
  if [[ -z $NTFY_TOKEN ]] || ! grep -qF -- "$NTFY_TOKEN" <<<"$tokens"; then
    tokens=$(nx token add --label="sudo homelab alerts" "$NTFY_PUBLISHER" 2>&1 || true)
    NTFY_TOKEN=$(grep -oE -m1 'tk_[a-z0-9]+' <<<"$tokens" || true)
    [[ -n $NTFY_TOKEN ]] || die "ntfy didn't create a publish token."
    save_secrets
    ok "Publish token created"
  else
    ok "Publish token is still valid"
  fi
}

# ── Beszel ────────────────────────────────────────────────────────────────────
BZ_AUTH=""      # Beszel login token (PocketBase)
BZ_USER_ID=""

bz_api() { # bz_api METHOD PATH [json] → response body; fails on an HTTP error
  local m=$1 p=$2 body=${3:-}
  { ckv url "http://127.0.0.1:$P_BESZEL$p"; ckv request "$m"
    [[ -n $BZ_AUTH ]] && ckv header "Authorization: $BZ_AUTH"
    if [[ -n $body ]]; then ckv header "Content-Type: application/json"; ckv data "$body"; fi
  } | curl -fsS -m 20 -K -
}

bz_login() { # bz_login [password] → sets BZ_AUTH / BZ_USER_ID
  local r
  r=$(BZ_AUTH="" bz_api POST /api/collections/users/auth-with-password \
    "$(jq -nc --rawfile i "$(sfile bzid "$ADMIN_EMAIL")" --rawfile p "$(sfile bzpw "${1:-$APP_PASS}")" '{identity: $i, password: $p}')" 2>/dev/null) || return 1
  BZ_AUTH=$(jq -r '.token // empty' <<<"$r"); BZ_USER_ID=$(jq -r '.record.id // empty' <<<"$r")
  [[ -n $BZ_AUTH ]]
}

bz_first_user() {
  if [[ $(bz_api GET /api/beszel/first-run | jq -r .firstRun) == true ]]; then
    bz_api POST /api/beszel/create-user \
      "$(jq -nc --rawfile e "$(sfile bze "$ADMIN_EMAIL")" --rawfile p "$(sfile bzp "$APP_PASS")" '{email: $e, password: $p}')"
    echo
  else
    echo "Beszel already has an admin account"
  fi
}

bz_connect() { # log in; if the password was changed in Beszel's page, ask for it
  bz_login && return 0
  local p
  if (( ! ASSUME_YES )) && has_tty; then
    warn "Beszel didn't accept the saved login for $ADMIN_EMAIL (changed in its page?)."
    p=$(ask_secret "Beszel password for $ADMIN_EMAIL:")
    [[ -n $p ]] && bz_login "$p" && return 0
  fi
  return 1
}

# The universal token lets agents add themselves to the hub. Permanent, so the
# command for other machines keeps working.
bz_token() {
  local r
  r=$(bz_api GET /api/beszel/universal-token)
  if [[ $(jq -r '.active and .permanent' <<<"$r") != true ]]; then
    r=$(bz_api GET "/api/beszel/universal-token?enable=1&permanent=1&token=$(jq -r .token <<<"$r")")
  fi
  BESZEL_TOKEN=$(jq -r '.token // empty' <<<"$r")
  [[ -n $BESZEL_TOKEN && $(jq -r '.active and .permanent' <<<"$r") == true ]] || { echo "No universal token: $r"; return 1; }
  BESZEL_KEY=$(bz_api GET /api/beszel/info | jq -r '.key // empty')
  [[ $BESZEL_KEY == ssh-* ]] || { echo "No hub key"; return 1; }
  echo "Token active and permanent"
}

bz_notify_url() { echo "ntfy://:$NTFY_TOKEN@ntfy:80/$TOPIC?scheme=http&title=Beszel"; }

# Our ntfy address goes into the hub's notification list (yours are kept).
bz_set_notify() {
  local rec id settings new
  rec=$(bz_api GET "/api/collections/user_settings/records?filter=$(jq -rn --arg u "$BZ_USER_ID" '"user=\"" + $u + "\"" | @uri')")
  id=$(jq -r '.items[0].id // empty' <<<"$rec")
  settings=$(jq -c '.items[0].settings // {}' <<<"$rec")
  new=$(jq -c --rawfile u "$(sfile bzn "$(bz_notify_url)")" \
    '.webhooks = ([(.webhooks // [])[] | select(startswith("ntfy://") and contains("@ntfy:80/") | not)] + [$u])
     | .emails = ((.emails // []) | map(select(endswith("@homelab.local") | not)))' <<<"$settings")
  if [[ -n $id ]]; then bz_api PATCH "/api/collections/user_settings/records/$id" "$(jq -nc --argjson s "$new" '{settings: $s}')" >/dev/null
  else bz_api POST /api/collections/user_settings/records "$(jq -nc --arg u "$BZ_USER_ID" --argjson s "$new" '{user: $u, settings: $s}')" >/dev/null; fi
  fresh_notify || { echo "ntfy address saved (test already sent with this token)"; return 0; }
  bz_api POST /api/beszel/test-notification "$(jq -nc --rawfile u "$(sfile bzn2 "$(bz_notify_url)")" '{url: $u}')" | grep -q '"err":false' ||
    { echo "Beszel couldn't send a test to ntfy"; return 1; }
  echo "Beszel sent a test notification to ntfy"
}

write_agent_env() {
  ( umask 077; printf 'KEY=%s\nTOKEN=%s\n' "$BESZEL_KEY" "$BESZEL_TOKEN" >"$INSTALL_DIR/.agent.env" )
}

bz_wait_system() { # bz_wait_system name → waits until that machine reports "up"
  local i st
  for i in $(seq 1 45); do
    st=$(bz_api GET "/api/collections/systems/records?filter=$(jq -rn --arg n "$1" '"name=\"" + $n + "\"" | @uri')" | jq -r '.items[0].status // empty')
    [[ $st == up ]] && { echo "$1 is up"; return 0; }
    echo "waiting for $1 (${st:-not registered yet})"
    sleep 2
  done
  return 1
}

# Default alerts for every machine that doesn't have them: down, CPU, RAM, disk.
bz_alerts() {
  local sys alerts id name a n=0
  sys=$(bz_api GET "/api/collections/systems/records?perPage=500" | jq -r '.items[] | "\(.id)\t\(.name)"')
  alerts=$(bz_api GET "/api/collections/alerts/records?perPage=500" | jq -r '.items[] | "\(.system)\t\(.name)"')
  while IFS=$'\t' read -r id name; do
    [[ -n $id ]] || continue
    for a in "Status 0 0" "CPU 90 10" "Memory 90 10" "Disk 90 10"; do
      set -- $a
      grep -qxF "$id"$'\t'"$1" <<<"$alerts" && continue
      bz_api POST /api/collections/alerts/records \
        "$(jq -nc --arg u "$BZ_USER_ID" --arg s "$id" --arg n "$1" --argjson v "$2" --argjson m "$3" '{user: $u, system: $s, name: $n, value: $v, min: $m}')" >/dev/null
      n=$((n + 1))
    done
    echo "$name: alerts for down, CPU > 90%, RAM > 90%, disk > 90% (10 min)"
  done <<<"$sys"
  echo "$n new alert rule(s)"
}

setup_beszel() {
  step "Setting up Beszel"
  run "Admin account ($ADMIN_EMAIL)" bz_first_user
  bz_connect || die "Couldn't log in to Beszel (http://$HOST_IP:$P_BESZEL) as $ADMIN_EMAIL."
  ok "Logged in to Beszel"
  state_set ADMIN_EMAIL "$ADMIN_EMAIL"
  # Not through `run`: that's a subshell, and bz_token sets BESZEL_TOKEN / BESZEL_KEY.
  bz_token >>"$LOG_FILE" 2>&1 || die "Beszel didn't give a token for agents (see the log)."
  ok "Token for agents (lets machines add themselves)"
  save_secrets; state_set BESZEL_KEY "$BESZEL_KEY"
  if ! cmp -s <(printf 'KEY=%s\nTOKEN=%s\n' "$BESZEL_KEY" "$BESZEL_TOKEN") "$INSTALL_DIR/.agent.env"; then
    write_agent_env
    run "Starting this machine's agent" dc up -d --force-recreate beszel-agent
  fi
  AGENT_NAME=$(hostname)
  run "Waiting for this machine ($AGENT_NAME) to show up" bz_wait_system "$AGENT_NAME"
  run "Alerts go to ntfy" bz_set_notify
  run "Default alerts" bz_alerts
}

# ── Uptime Kuma ───────────────────────────────────────────────────────────────
# Kuma 2 has no REST API for setup: everything goes over its websocket. This
# Node script runs inside the Kuma container (which ships socket.io-client) and
# reads its job from a file in Kuma's data folder, which it deletes right away.
kuma_js() {
  cat <<'JS'
const fs = require("fs");
const JOB = "/app/data/.sudohomelab-job.json";
const job = JSON.parse(fs.readFileSync(JOB, "utf8")); fs.unlinkSync(JOB);
const { io } = require("/app/node_modules/socket.io-client");
const s = io("http://127.0.0.1:3001", { transports: ["websocket"], reconnection: false });
const call = (ev, ...a) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error(ev + " timed out")), 30000);
  s.emit(ev, ...a, (r) => { clearTimeout(t); res(r); });
});
const lists = {};
for (const ev of ["monitorList", "notificationList", "dockerHostList"]) s.on(ev, (l) => { lists[ev] = l; });
const wait = (k) => new Promise((res, rej) => {
  const t0 = Date.now();
  const i = setInterval(() => { if (lists[k]) { clearInterval(i); res(lists[k]); } else if (Date.now() - t0 > 30000) { clearInterval(i); rej(new Error("no " + k)); } }, 100);
});
const must = (r, what) => { if (!r || !r.ok) throw new Error(what + ": " + ((r && r.msg) || "failed")); return r; };
// What the web UI sends for a new monitor; `add` fails without these.
const BASE = { interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 2, timeout: 48, active: true, upsideDown: false,
  ignoreTls: false, maxredirects: 10, method: "GET", accepted_statuscodes: ["200-399"], conditions: [],
  kafkaProducerBrokers: [], kafkaProducerSaslOptions: { mechanism: "None" }, rabbitmqNodes: [],
  dns_resolve_type: "A", dns_resolve_server: "1.1.1.1", description: "Added by sudo homelab" };
const FIELDS = ["name", "type", "url", "hostname", "port", "docker_container", "docker_host", "dns_resolve_server", "accepted_statuscodes"];

s.once("info", async () => {   // handlers are registered after Kuma sends "info"
  try {
    if (await call("needSetup")) { must(await call("setup", job.user, job.pass), "create admin"); console.log("Admin account created: " + job.user); }
    const login = await call("login", { username: job.user, password: job.pass, token: "" });
    if (!login.ok) { console.log("LOGIN_FAILED " + (login.msg || "")); process.exitCode = 3; return; }
    if (job.mode === "login") { console.log("Login works"); return; }
    if (job.mode === "test") { must(await call("testNotification", job.notification), "test notification"); console.log("Kuma sent a test notification to ntfy"); return; }

    // ntfy notification: ours is found by name and kept up to date.
    const notifs = await wait("notificationList");
    const have = notifs.find((n) => n.name === job.notification.name);
    const n = must(await call("addNotification", { ...job.notification, isDefault: true, applyExisting: true }, have ? have.id : null), "ntfy notification");
    console.log((have ? "Updated" : "Added") + " notification: " + job.notification.name);
    const nid = have ? have.id : n.id;

    const hosts = await wait("dockerHostList");
    let host = hosts.find((h) => h.dockerDaemon === "/var/run/docker.sock");
    if (!host) { const r = must(await call("addDockerHost", { name: "This server", dockerType: "socket", dockerDaemon: "/var/run/docker.sock" }, null), "docker host"); host = { id: r.id }; console.log("Added Docker host: This server"); }

    let tag = (await call("getTags")).tags.find((t) => t.name === job.tag);
    if (!tag) tag = must(await call("addTag", { name: job.tag, color: "#a0e85b" }), "tag").tag;

    // Our monitors carry the tag, with the app's key as the tag value.
    const all = Object.values(await wait("monitorList"));
    const ours = new Map();
    for (const m of all) { const t = (m.tags || []).find((x) => x.tag_id === tag.id || x.name === job.tag); if (t && t.value) ours.set(t.value, m); }
    let added = 0, updated = 0, removed = 0, kept = 0;
    for (const want of job.monitors) {
      const m = { ...BASE, ...want.monitor };
      if (m.type === "docker") m.docker_host = host.id;
      const cur = ours.get(want.key); ours.delete(want.key);
      if (!cur) {
        const r = must(await call("add", { ...m, notificationIDList: { [nid]: true } }), "add " + m.name);
        must(await call("addMonitorTag", tag.id, r.monitorID, want.key), "tag " + m.name);
        console.log("+ " + m.name); added++;
      } else if (FIELDS.some((f) => f in m && JSON.stringify(f === "accepted_statuscodes" ? cur.accepted_statuscodes : cur[f]) !== JSON.stringify(m[f]))) {
        const edit = { ...cur, ...want.monitor, docker_host: m.type === "docker" ? host.id : cur.docker_host };
        edit.accepted_statuscodes = m.accepted_statuscodes;
        for (const k of ["kafkaProducerBrokers", "conditions", "rabbitmqNodes"]) if (typeof edit[k] === "string") { try { edit[k] = JSON.parse(edit[k]); } catch (e) { edit[k] = []; } }
        if (!edit.kafkaProducerSaslOptions || typeof edit.kafkaProducerSaslOptions === "string") edit.kafkaProducerSaslOptions = { mechanism: "None" };
        must(await call("editMonitor", edit), "update " + m.name);
        console.log("~ " + m.name); updated++;
      } else kept++;
    }
    for (const [key, m] of ours) { must(await call("deleteMonitor", m.id), "remove " + m.name); console.log("- " + m.name + " (not found or not picked any more)"); removed++; }
    console.log(`Monitors: ${added} added, ${updated} updated, ${removed} removed, ${kept} unchanged (yours without the ${job.tag} tag are never touched)`);
  } catch (e) { console.log("ERROR " + e.message); process.exitCode = 1; }
  finally { s.close(); }
});
s.on("connect_error", (e) => { console.log("ERROR can't reach Uptime Kuma: " + e.message); process.exit(1); });
JS
}

kuma_notification() { # the ntfy notification, as Kuma stores it
  jq -nc --rawfile t "$(sfile kt "$NTFY_TOKEN")" --arg topic "$TOPIC" \
    '{name: "ntfy (sudo homelab)", type: "ntfy", ntfyserverurl: "http://ntfy:80", ntfytopic: $topic, ntfyPriority: 4,
      ntfyAuthenticationMethod: "accessToken", ntfyaccesstoken: $t}'
}

# Monitors for this stack's own apps, then the apps you picked.
kuma_monitors() {
  local k name type target port src known url
  {
    jq -nc '{key: "self:beszel", monitor: {type: "http", name: "Beszel", url: "http://beszel:8090/api/health"}}'
    jq -nc '{key: "self:ntfy", monitor: {type: "http", name: "ntfy", url: "http://ntfy:80/v1/health"}}'
    want dozzle && jq -nc '{key: "self:dozzle", monitor: {type: "http", name: "Dozzle", url: "http://dozzle:8080/healthcheck"}}'
    want portainer && jq -nc '{key: "self:portainer", monitor: {type: "http", name: "Portainer", url: "http://portainer:9000/api/system/status"}}'
    for k in ${KUMA_ON//,/ }; do
      [[ -n ${FOUND[$k]:-} ]] || continue
      IFS='|' read -r _ name type target port src known <<<"${FOUND[$k]}"
      case $type in
        http)
          url="http://host.docker.internal:$port$target"
          jq -nc --arg k "$k" --arg n "$name" --arg u "$url" --argjson known "$known" \
            '{key: $k, monitor: {type: "http", name: $n, url: $u, accepted_statuscodes: (if $known == 1 then ["200-399"] else ["200-499"] end)}}' ;;
        port)
          jq -nc --arg k "$k" --arg n "$name" --argjson p "$port" '{key: $k, monitor: {type: "port", name: $n, hostname: "host.docker.internal", port: $p}}' ;;
        docker)
          jq -nc --arg k "$k" --arg n "$name" --arg c "$target" '{key: $k, monitor: {type: "docker", name: ($n + " (container)"), docker_container: $c}}' ;;
        dns)
          jq -nc --arg k "$k" --arg n "$name" --arg ip "$HOST_IP" '{key: $k, monitor: {type: "dns", name: $n, hostname: "github.com", dns_resolve_server: $ip, port: 53}}' ;;
      esac
    done
  } | jq -sc .
}

kuma_run() { # kuma_run mode [password] → runs the Node script with a job
  local pass=${2:-$APP_PASS} job="$INSTALL_DIR/kuma/.sudohomelab-job.json"
  ( umask 077
    jq -nc --arg mode "$1" --rawfile u "$(sfile ku "$APP_USER")" --rawfile p "$(sfile kp "$pass")" --arg tag "$KUMA_TAG" \
      --argjson n "$(kuma_notification)" --argjson m "$( [[ $1 == sync ]] && kuma_monitors || echo '[]')" \
      '{mode: $mode, user: $u, pass: $p, tag: $tag, notification: $n, monitors: $m}' >"$job" )
  kuma_js | dc exec -T kuma node -
}

kuma_connect() { # makes sure we can log in; asks for the password if it was changed
  KUMA_PASS=$APP_PASS
  kuma_run login >>"$LOG_FILE" 2>&1 && return 0
  if (( ! ASSUME_YES )) && has_tty; then
    warn "Uptime Kuma didn't accept the saved login for $APP_USER (changed in its page?)."
    KUMA_PASS=$(ask_secret "Uptime Kuma password for $APP_USER:")
    [[ -n $KUMA_PASS ]] && kuma_run login "$KUMA_PASS" >>"$LOG_FILE" 2>&1 && return 0
  fi
  return 1
}

setup_kuma() {
  step "Setting up Uptime Kuma"
  kuma_connect || die "Couldn't log in to Uptime Kuma (http://$HOST_IP:$P_KUMA) as $APP_USER."
  ok "Logged in to Uptime Kuma as $APP_USER"
  run "Monitors + ntfy notification" kuma_run sync "$KUMA_PASS"
  if fresh_notify; then run "Test notification from Uptime Kuma" kuma_run test "$KUMA_PASS"; fi
  state_set KUMA_ON "$KUMA_ON"
  save_found
  state_set KUMA_SEEN "$(printf '%s\n' "${FOUND_KEYS[@]}" "$(state_get KUMA_SEEN | tr ',' '\n')" | awk 'NF && !seen[$0]++' | paste -sd, -)"
}

# ── Extras ────────────────────────────────────────────────────────────────────
setup_dozzle() {
  # Dozzle's login file: generated by Dozzle itself (bcrypt), password read from stdin.
  local f="$INSTALL_DIR/dozzle/users.yml"
  mkdir -p "$INSTALL_DIR/dozzle"
  printf '%s\n' "$APP_PASS" | docker run --rm -i "$DOZZLE_IMAGE" generate "$APP_USER" --email "$ADMIN_EMAIL" --name "$APP_USER" >"$f.new"
  grep -q 'password: \$2' "$f.new" || { cat "$f.new"; rm -f "$f.new"; return 1; }
  mv "$f.new" "$f"; chmod 600 "$f"
  dc restart dozzle
  wait_http "http://127.0.0.1:$P_DOZZLE/healthcheck" 60 Dozzle
}

wait_portainer() {
  local i
  for i in $(seq 1 60); do
    curl -sk -m 5 "https://127.0.0.1:$P_PORTAINER/api/system/status" | grep -q '"Version"' && { echo "Portainer answers"; return 0; }
    sleep 2
  done
  echo "Portainer didn't answer on port $P_PORTAINER"
  return 1
}

setup_extras() {
  want dozzle || want portainer || return 0
  step "Setting up the extras"
  want dozzle && run "Dozzle login ($APP_USER)" setup_dozzle
  want portainer && run "Waiting for Portainer (admin account from your password)" wait_portainer
  return 0
}

# ── Checks ────────────────────────────────────────────────────────────────────
agent_cmd() { # the command that adds another machine to this hub
  local hub=${1:-http://$HOST_IP:$P_BESZEL}
  printf 'sudo bash -c "$(curl -fsSL %s)" _ --hub=%s --key='"'"'%s'"'"' --token=%s' "$AGENT_URL" "$hub" "$BESZEL_KEY" "$BESZEL_TOKEN"
}

verify() {
  step "Checking that it works"
  local fails=0 code n
  if [[ $(curl -s -m 5 "http://127.0.0.1:$P_NTFY/v1/health" | jq -r .healthy 2>/dev/null) == true ]]; then ok "ntfy is healthy"; else err "ntfy isn't healthy"; fails=1; fi
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -d x "http://127.0.0.1:$P_NTFY/$TOPIC")
  if [[ $code == 403 ]]; then ok "ntfy refuses messages without a login"; else err "ntfy accepted an anonymous message (HTTP $code)"; fails=1; fi
  if fresh_notify; then
    if ntfy_publish "sudo homelab" "The Monitoring Stack is set up. Alerts from Uptime Kuma and Beszel arrive here." 3; then ok "Publish token works (a welcome message is waiting in \"$TOPIC\")"
    else err "Couldn't post to ntfy with the publish token"; fails=1; fi
  elif [[ $( { ckv header "Authorization: Bearer $NTFY_TOKEN"; } | curl -s -m 5 -K - "http://127.0.0.1:$P_NTFY/v1/account" | jq -r '.username // empty' 2>/dev/null) == "$NTFY_PUBLISHER" ]]; then
    ok "Publish token is valid (no test message this time: it was sent on the first run)"
  else err "ntfy doesn't accept the publish token"; fails=1; fi
  code=$( { ckv user "$APP_USER:$APP_PASS"; } | curl -s -o /dev/null -m 5 -w '%{http_code}' -K - "http://127.0.0.1:$P_NTFY/$TOPIC/json?poll=1")
  if [[ $code == 200 ]]; then ok "Your ntfy login can read \"$TOPIC\""; else err "Your ntfy login can't read the topic (HTTP $code)"; fails=1; fi

  if bz_login; then ok "Beszel login works ($ADMIN_EMAIL)"; else err "Beszel login failed"; fails=1; fi
  n=$(bz_api GET "/api/collections/systems/records?perPage=500" 2>/dev/null | jq '[.items[] | select(.status == "up")] | length' 2>/dev/null || echo 0)
  if (( n > 0 )); then ok "Beszel: $n machine(s) up, this one included"; else err "Beszel has no machine reporting"; fails=1; fi

  if kuma_run login "$KUMA_PASS" >>"$LOG_FILE" 2>&1; then ok "Uptime Kuma login works ($APP_USER)"; else err "Uptime Kuma login failed"; fails=1; fi
  # Give the new monitors their first check, then count what's down.
  sleep 5
  local down
  down=$(dc exec -T kuma sqlite3 /app/data/kuma.db \
    "SELECT m.name FROM monitor m JOIN (SELECT monitor_id, max(id) id FROM heartbeat GROUP BY monitor_id) l ON l.monitor_id = m.id JOIN heartbeat h ON h.id = l.id WHERE h.status = 0 AND m.active = 1;" </dev/null 2>/dev/null || true)
  n=$(dc exec -T kuma sqlite3 /app/data/kuma.db "SELECT count(*) FROM monitor WHERE active = 1;" </dev/null 2>/dev/null | tr -dc 0-9)
  if [[ -z $down ]]; then ok "Uptime Kuma: ${n:-?} monitors, none down"
  else warn "Uptime Kuma: these are down right now: $(paste -sd, - <<<"$down" | sed 's/,/, /g')"; fi

  if want dozzle; then
    code=$( { ckv data-urlencode "username=$APP_USER"; ckv data-urlencode "password=$APP_PASS"; } | curl -s -o /dev/null -m 5 -w '%{http_code}' -K - "http://127.0.0.1:$P_DOZZLE/api/token")
    if [[ $code =~ ^2 ]]; then ok "Dozzle login works"; else err "Dozzle login failed (HTTP $code)"; fails=1; fi
  fi
  if want portainer; then
    code=$(jq -nc --rawfile p "$(sfile pp "$APP_PASS")" '{username: "admin", password: $p}' |
      curl -sk -o /dev/null -m 10 -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "https://127.0.0.1:$P_PORTAINER/api/auth")
    if [[ $code == 200 ]]; then ok "Portainer login works (user admin)"; else err "Portainer login failed (HTTP $code)"; fails=1; fi
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is active: allow the apps (and agents from other machines) with"
    warn "  sudo ufw allow $P_KUMA/tcp && sudo ufw allow $P_BESZEL/tcp && sudo ufw allow $P_NTFY/tcp"
  fi
  if (( fails == 0 )); then state_set NOTIFY_TESTED "$(notify_key)"
  else warn "Some checks failed. The apps are installed; see the log for details: $LOG_FILE"; fi
}

manage_hint() { printf '    %sManage:%s    cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"; }

print_agent_cmd() {
  local vpn
  printf '\n  %sAdd another machine to Beszel%s %s(Linux: run this on it)%s\n' "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET"
  printf '    %s%s%s\n' "$C_CYAN" "$(agent_cmd)" "$C_RESET"
  vpn=$(vpn_address)
  [[ -n $vpn ]] && printf '    %sOver %s, use --hub=http://%s:%s instead.%s\n' "$C_GRAY" "${vpn%% *}" "${vpn#* }" "$P_BESZEL" "$C_RESET"
  printf '    %sOr run it without options: it asks for the hub address and your Beszel login.%s\n' "$C_GRAY" "$C_RESET"
  printf '    %sThe token adds machines without a login: keep it private (Beszel → Settings → Tokens turns it off).%s\n' "$C_GRAY" "$C_RESET"
}

summary() {
  step "Done"
  local f="$INSTALL_DIR/credentials.txt" ip=$HOST_IP vpn
  ( umask 077
    {
      echo "sudo homelab · Monitoring Stack ($(date))"
      echo
      echo "Uptime Kuma  http://$ip:$P_KUMA        login $APP_USER"
      echo "Beszel       http://$ip:$P_BESZEL        login $ADMIN_EMAIL"
      echo "ntfy         http://$ip:$P_NTFY        login $APP_USER · topic $TOPIC"
      want dozzle && echo "Dozzle       http://$ip:$P_DOZZLE        login $APP_USER"
      want portainer && echo "Portainer    https://$ip:$P_PORTAINER       login admin"
      echo "Password     $APP_PASS"
      echo
      echo "ntfy publish token (alerts topic only): $NTFY_TOKEN"
      echo "Beszel agent key:   $BESZEL_KEY"
      echo "Beszel agent token: $BESZEL_TOKEN"
      echo
      echo "Add a machine: $(agent_cmd)"
    } >"$f" )

  printf '\n  %s%s★ Uptime Kuma, Beszel and ntfy are running and connected!%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '    %s%-12s%s %shttp://%s:%s%s  %s(login %s)%s\n' "$C_BOLD" "Uptime Kuma" "$C_RESET" "$C_CYAN" "$ip" "$P_KUMA" "$C_RESET" "$C_GRAY" "$APP_USER" "$C_RESET"
  printf '    %s%-12s%s %shttp://%s:%s%s  %s(login %s)%s\n' "$C_BOLD" "Beszel" "$C_RESET" "$C_CYAN" "$ip" "$P_BESZEL" "$C_RESET" "$C_GRAY" "$ADMIN_EMAIL" "$C_RESET"
  printf '    %s%-12s%s %shttp://%s:%s%s  %s(login %s · topic %s)%s\n' "$C_BOLD" "ntfy" "$C_RESET" "$C_CYAN" "$ip" "$P_NTFY" "$C_RESET" "$C_GRAY" "$APP_USER" "$TOPIC" "$C_RESET"
  want dozzle && printf '    %s%-12s%s %shttp://%s:%s%s  %s(login %s)%s\n' "$C_BOLD" "Dozzle" "$C_RESET" "$C_CYAN" "$ip" "$P_DOZZLE" "$C_RESET" "$C_GRAY" "$APP_USER" "$C_RESET"
  want portainer && printf '    %s%-12s%s %shttps://%s:%s%s  %s(login admin; accept the certificate warning)%s\n' "$C_BOLD" "Portainer" "$C_RESET" "$C_CYAN" "$ip" "$P_PORTAINER" "$C_RESET" "$C_GRAY" "$C_RESET"
  printf '    %s%-12s%s %s%s\n' "$C_BOLD" "Password" "$C_RESET" "$APP_PASS" "$( [[ ${GENERATED_PASS:-0} == 1 ]] && printf '  %s(generated)%s' "$C_GRAY" "$C_RESET")"
  printf '    %sSaved%s        %s %s(root only)%s\n' "$C_GRAY" "$C_RESET" "$f" "$C_GRAY" "$C_RESET"

  printf '\n  %sGet alerts on your phone%s\n' "$C_BOLD" "$C_RESET"
  printf '    1. Install the %sntfy%s app (Android / iPhone).\n' "$C_BOLD" "$C_RESET"
  printf '    2. Settings → Users → add %shttp://%s:%s%s with your login (%s).\n' "$C_BOLD" "$ip" "$P_NTFY" "$C_RESET" "$APP_USER"
  printf '    3. + → topic %s%s%s → "Use another server" → %shttp://%s:%s%s.\n' "$C_BOLD" "$TOPIC" "$C_RESET" "$C_BOLD" "$ip" "$P_NTFY" "$C_RESET"
  printf '       %sType exactly "%s": the app suggests a random topic name, and alerts only go to this one.%s\n' "$C_YELLOW" "$TOPIC" "$C_RESET"
  printf '       %sIn a browser: http://%s:%s/%s (log in, then "Subscribe").%s\n' "$C_GRAY" "$ip" "$P_NTFY" "$TOPIC" "$C_RESET"
  if command -v qrencode >/dev/null 2>&1 && (( IS_TTY )); then
    printf '    %sOr scan this to open the topic in the phone'"'"'s browser:%s\n' "$C_GRAY" "$C_RESET"
    qrencode -t ANSIUTF8 -m 1 "http://$ip:$P_NTFY/$TOPIC" 2>/dev/null | sed 's/^/      /' || true
  fi
  vpn=$(vpn_address)
  [[ -n $vpn ]] && printf '    %sAway from home over %s: use http://%s:%s in the app instead.%s\n' "$C_GRAY" "${vpn%% *}" "${vpn#* }" "$P_NTFY" "$C_RESET"
  printf '    %sYour own scripts can post too:%s curl -H "Authorization: Bearer <token>" -d "Backup done" http://%s:%s/%s\n' "$C_GRAY" "$C_RESET" "$ip" "$P_NTFY" "$TOPIC"
  printf '    %s(the publish token is in credentials.txt)%s\n' "$C_GRAY" "$C_RESET"

  print_agent_cmd

  echo
  [[ -z ${SHL_HINT_CMD:-} ]] && manage_hint
  printf '    %sMenu:%s      %s   %s(install · add a machine · re-scan apps · uninstall)%s\n' "$C_GRAY" "$C_RESET" "$(run_hint)" "$C_GRAY" "$C_RESET"
  printf '    %sNew apps:%s  %s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --sync")"
  printf '    %sUninstall:%s %s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --uninstall")"
  printf '    %sLog:%s       %s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s      %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
}

# ── Actions: add a machine / re-scan / uninstall ──────────────────────────────
load_install() {
  [[ $EUID -eq 0 ]] || die "Please run as root:  $(run_hint)"
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "Nothing is installed yet. Install first:  $(run_hint " --install")"
  local v val
  for v in "${PORT_VARS[@]}" EXTRAS TOPIC ADMIN_EMAIL BESZEL_KEY; do
    val=$(state_get "$v"); [[ -n $val ]] && printf -v "$v" '%s' "$val"
  done
  load_secrets
  HOST_IP=$(host_ip)
  [[ $(docker inspect -f '{{.State.Running}}' "$(dc ps -q beszel 2>/dev/null)" 2>/dev/null) == true ]] ||
    die "The stack isn't running. Start it:  cd $INSTALL_DIR && sudo docker compose up -d"
}

show_agent() {
  load_install
  [[ -n $BESZEL_KEY && -n $BESZEL_TOKEN ]] || die "No agent token saved. Re-run Install first."
  print_agent_cmd
  echo
}

sync_monitors() {
  load_install
  STEP=0; TOTAL_STEPS=2
  step "Finding apps to monitor"
  choose_monitors
  step "Updating Uptime Kuma and Beszel"
  kuma_connect || die "Couldn't log in to Uptime Kuma (http://$HOST_IP:$P_KUMA) as $APP_USER."
  run "Monitors" kuma_run sync "$KUMA_PASS"
  state_set KUMA_ON "$KUMA_ON"
  save_found
  state_set KUMA_SEEN "$(printf '%s\n' "${FOUND_KEYS[@]}" "$(state_get KUMA_SEEN | tr ',' '\n')" | awk 'NF && !seen[$0]++' | paste -sd, -)"
  if bz_connect; then run "Default alerts for every Beszel machine" bz_alerts
  else warn "Couldn't log in to Beszel: alerts for new machines weren't added."; fi
}

uninstall() {
  (( BANNER_SHOWN )) || banner
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "No Monitoring Stack from this script found in $INSTALL_DIR."
  warn "This stops and removes Uptime Kuma, Beszel (hub + this machine's agent), ntfy and the extras."
  warn "Agents on other machines keep running but have no hub to report to (remove them with: beszel-agent.sh --uninstall)."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|monitors, history, logins and tokens stay in $INSTALL_DIR for a reinstall" \
      "Delete it|also delete all monitors, history, accounts and tokens") in
      2) PURGE=1 ;;
    esac
  fi
  if (( PURGE )); then warn "All data in $INSTALL_DIR (monitors, history, accounts, tokens) will be deleted."
  else info "The data stays in $INSTALL_DIR (re-run the installer to bring everything back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  run "Removing the containers" dc down --remove-orphans
  if (( PURGE )); then run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"; fi
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
  log "sudo homelab monitoring v$VERSION · args: $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
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
    agent) (( BANNER_SHOWN )) || banner; show_agent; return ;;
    sync) (( BANNER_SHOWN )) || banner; sync_monitors; return ;;
  esac

  START_TIME=$SECONDS
  (( BANNER_SHOWN )) || banner
  preflight
  choose_options
  install_deps
  start_stack
  setup_ntfy
  setup_beszel
  setup_kuma
  setup_extras
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
    "Install|$( (( installed )) && echo "already installed: re-run the setup to change settings" || echo "Uptime Kuma + Beszel + ntfy, connected, plus optional extras")" \
    "Add a machine|show the command that adds another computer to Beszel" \
    "Re-scan apps|look for new apps on this machine and update Uptime Kuma's monitors" \
    "Uninstall|remove the apps (asks whether to keep the data)" \
    "Quit|close the menu") in
    1) ACTION=install ;; 2) ACTION=agent ;; 3) ACTION=sync ;; 4) ACTION=uninstall ;; 5) ACTION=quit ;;
  esac
}

[[ ${SHL_LIBRARY:-0} == 1 ]] || main "$@"
