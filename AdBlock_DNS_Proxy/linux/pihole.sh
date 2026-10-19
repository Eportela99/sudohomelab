#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Pi-hole installer (Ubuntu / Debian)
#  https://github.com/Eportela99/sudohomelab
#
#  Installs Pi-hole v6 as a Docker container (host network, so it sees real
#  client IPs) and sets it up so it's blocking from the first minute:
#    · Port 53 is checked first and freed if something holds it
#      (systemd-resolved's DNS stub, dnsmasq, bind9, another DNS container…)
#    · Your admin password (typed or generated)
#    · Upstream DNS: your own recursive resolver (Unbound) or a public one
#    · Curated blocklists (HaGeZi presets + optional extras) and allowlists
#    · Who may use it (local network only, or VPNs/other subnets too)
#    · Device names in the query log (asks your router), DNSSEC,
#      daily blocklist refresh
#
#  Usage:
#    sudo bash -c "$(curl -fsSL <url>/pihole.sh)"
#    sudo bash -c "$(curl -fsSL <url>/pihole.sh)" _ --uninstall --purge
#    sudo bash pihole.sh --blocklists=balanced --upstream=unbound --yes
#    sudo bash pihole.sh --help
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

VERSION="0.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/linux/pihole.sh"
INSTALL_DIR="/opt/sudohomelab/pihole"
LOG_DIR="/var/log/sudohomelab"
LOG_FILE="$LOG_DIR/pihole-$(date +%Y%m%d-%H%M%S).log"
PROJECT="sudohomelab-pihole"   # compose project name
IMAGE="pihole/pihole:latest"
UNBOUND_IMAGE="klutchell/unbound:latest"   # maintained, multi-arch (amd64/arm64/arm)
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/sudohomelab-pihole.conf"
GRAVITY_UNIT="sudohomelab-pihole-gravity"  # systemd timer for the daily refresh

APP_PASS=""
BLOCKLISTS=""      # light | balanced | aggressive | classic
EXTRAS=""          # comma list of: smarttv, devices, doh, gambling, nsfw
EXTRAS_SET=0
ALLOWLISTS=""      # comma list of: referral, shorteners
ALLOWLISTS_SET=0
CUSTOM_LISTS=""    # comma list of extra blocklist URLs
UPSTREAM=""        # unbound | cloudflare | quad9 | google | comma list of IPs
DNS_ACCESS=""      # local | all
REFRESH=""         # daily | weekly
DEVICE_NAMES=""    # yes | no
ROUTER_IP=""
LOCAL_DOMAIN=""
DNSSEC=1           # for public upstreams (Unbound validates by itself)
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0
PURGE=0

# Host ports (Pi-hole runs on the host network). DNS is always 53.
# Unbound listens on 127.0.0.1 only: nothing but Pi-hole can reach it.
P_WEB=80; P_WEBS=443; P_UNBOUND=5335
PORT_VARS=(P_WEB P_WEBS P_UNBOUND)

# ── Blocklists ────────────────────────────────────────────────────────────────
HG="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock"
preset_lists() {
  case $1 in
    light)      echo "$HG/light.txt $HG/tif.mini.txt" ;;
    balanced)   echo "$HG/pro.txt $HG/tif.medium.txt" ;;
    aggressive) echo "$HG/pro.plus.txt $HG/tif.txt $HG/fake.txt $HG/popupads.txt" ;;
    classic)    echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ;;
  esac
}
preset_label() {
  case $1 in
    light) echo "Light: HaGeZi Light + Threat Intel mini" ;;
    balanced) echo "Balanced: HaGeZi Pro + Threat Intel medium" ;;
    aggressive) echo "Aggressive: HaGeZi Pro++ + Threat Intel full + fake + pop-up ads" ;;
    classic) echo "Classic: StevenBlack hosts (Pi-hole's default)" ;;
  esac
}
EXTRA_IDS=(smarttv devices doh gambling nsfw)
extra_lists() {
  case $1 in
    smarttv)  echo "$HG/native.samsung.txt $HG/native.lgwebos.txt $HG/native.roku.txt $HG/native.amazon.txt" ;;
    devices)  echo "$HG/native.apple.txt $HG/native.winoffice.txt $HG/native.xiaomi.txt $HG/native.tiktok.txt" ;;
    doh)      echo "$HG/doh-vpn-proxy-bypass.txt" ;;
    gambling) echo "$HG/gambling.txt" ;;
    nsfw)     echo "$HG/nsfw.txt" ;;
  esac
}
extra_label() {
  case $1 in
    smarttv) echo "Smart TV telemetry (Samsung, LG, Roku, Amazon)" ;;
    devices) echo "Phone & PC telemetry (Apple, Windows/Office, Xiaomi, TikTok)" ;;
    doh) echo "DNS bypass (encrypted DNS, VPNs, proxies that skip Pi-hole)" ;;
    gambling) echo "Gambling sites" ;;
    nsfw) echo "Adult content" ;;
  esac
}
# Allowlists: domains that are never blocked, even when a blocklist has them.
ALLOW_IDS=(referral shorteners)
allow_lists() {
  case $1 in
    referral)   echo "$HG/whitelist-referral.txt" ;;
    shorteners) echo "$HG/whitelist-urlshortener.txt" ;;
  esac
}
allow_label() {
  case $1 in
    referral) echo "Shopping & affiliate links (deal sites, 'buy' links, email links keep working)" ;;
    shorteners) echo "Link shorteners (bit.ly, t.co, tinyurl… open instead of being blocked)" ;;
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

STEP=0
TOTAL_STEPS=9
CURRENT_STEP="starting"

# Logs may be attached to public GitHub issues: the password is masked, colours stripped.
log() {
  local m="$*"
  [[ ${#APP_PASS} -ge 4 ]] && m=${m//"$APP_PASS"/***}
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
  printf '    %s❯%s %sPi-hole%s installer %sv%s · Ubuntu / Debian%s\n\n' \
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

run_hint() { echo "sudo bash -c \"\$(curl -fsSL $SCRIPT_URL)\"${1:+ _$1}"; }

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

menu_index() { # menu_index value option1 option2 ... → 1-based index (1 if not found)
  local v=$1 i=1; shift
  for o in "$@"; do [[ $o == "$v" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo 1
}

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
sudo homelab · Pi-hole installer v$VERSION

Usage: sudo bash pihole.sh [options]

  --password=PASS                    Admin password (generated if omitted)
  --blocklists=light|balanced|aggressive|classic
                                     Blocklist preset (default balanced)
  --extras=smarttv,devices,doh,gambling,nsfw
                                     Extra blocklists (or "none")
  --allowlists=referral,shorteners   Allowlists (or "none"; default referral)
  --lists=URL,URL                    Your own extra blocklist URLs
  --upstream=unbound|cloudflare|quad9|google|IP,IP
                                     Where Pi-hole resolves names (default unbound:
                                     your own recursive resolver, no DNS provider)
  --dns-access=local|all             Answer only your local network (default), or any
                                     network that reaches this machine (VPNs like
                                     Tailscale/WireGuard, other subnets)
  --refresh=daily|weekly             How often blocklists update (default daily)
  --device-names=yes|no              Show device names in the query log by asking
                                     your router (default yes when a router is found)
  --router=IP                        Router to ask for device names (default: gateway)
  --local-domain=NAME                Your network's local domain (default: detected, or lan)
  --no-dnssec                        Don't validate DNSSEC (public upstreams only)
  --web-port=PORT                    Admin page HTTP port (default 80, or the next free one)
  --install-dir=PATH                 Compose file + Pi-hole data (default $INSTALL_DIR)
  -y, --yes                          Non-interactive: accept defaults, free port 53 automatically
  --dry-run                          Show what would happen, change nothing
  --uninstall                        Remove Pi-hole and give port 53 back to the system (keeps data)
  --purge                            With --uninstall, also delete Pi-hole's data
  -h, --help                         Show this help
EOF
}

WEB_PORT_SET=0
parse_args() {
  for arg in "$@"; do
    case $arg in
      --password=*) APP_PASS=${arg#*=} ;;
      --blocklists=*) BLOCKLISTS=${arg#*=} ;;
      --extras=*) EXTRAS=${arg#*=}; EXTRAS_SET=1 ;;
      --allowlists=*) ALLOWLISTS=${arg#*=}; ALLOWLISTS_SET=1 ;;
      --lists=*) CUSTOM_LISTS=${arg#*=} ;;
      --upstream=*) UPSTREAM=${arg#*=} ;;
      --dns-access=*) DNS_ACCESS=${arg#*=} ;;
      --refresh=*) REFRESH=${arg#*=} ;;
      --device-names=*) DEVICE_NAMES=${arg#*=} ;;
      --router=*) ROUTER_IP=${arg#*=} ;;
      --local-domain=*) LOCAL_DOMAIN=${arg#*=} ;;
      --no-dnssec) DNSSEC=0 ;;
      --web-port=*) P_WEB=${arg#*=}; WEB_PORT_SET=1 ;;
      --install-dir=*) INSTALL_DIR=${arg#*=} ;;
      -y|--yes) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  [[ $P_WEB =~ ^[0-9]+$ ]] && (( P_WEB >= 1 && P_WEB <= 65535 )) || { echo "--web-port must be a port number" >&2; exit 2; }
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

dc() { docker compose -p "$PROJECT" --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" "$@"; }
px() { dc exec -T pihole "$@"; }   # run a command inside the Pi-hole container
gravity_sql() { px pihole-FTL sqlite3 /etc/pihole/gravity.db "$@"; }

# Saved state (key=value) in the install folder: choices for re-runs, plus what we
# changed on the host so --uninstall can put it back.
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

# ── Who owns a port? ──────────────────────────────────────────────────────────
# Each owner is described as "kind|target|label":
#   ours       our own Pi-hole container (a re-run): not a conflict
#   resolved   systemd-resolved's DNS stub (127.0.0.53), Ubuntu's default
#   container  a Docker container
#   service    a systemd service (dnsmasq, named, unbound, a native Pi-hole…)
#   process    anything else
container_of_pid() { # → container id, if the process runs in a Docker container
  grep -oE '[0-9a-f]{64}' "/proc/$1/cgroup" 2>/dev/null | head -n1 || true
}

describe_container() { # describe_container id-or-name → owner line
  local name project
  name=$(docker inspect -f '{{.Name}}' "$1" 2>/dev/null) || { echo "process|$1|container $1"; return; }
  name=${name#/}
  project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null || true)
  if [[ $project == "$PROJECT" ]]; then echo "ours|$name|this Pi-hole"; else echo "container|$name|Docker container \"$name\""; fi
}

describe_pid() { # describe_pid pid name → owner line
  local pid=$1 proc=$2 cid unit
  [[ $proc == systemd-resolve* ]] && { echo "resolved|systemd-resolved|systemd-resolved (Ubuntu's built-in DNS cache)"; return; }
  cid=$(container_of_pid "$pid")
  if [[ -n $cid ]] && command -v docker >/dev/null 2>&1; then describe_container "$cid"; return; fi
  unit=$(ps -o unit= -p "$pid" 2>/dev/null | xargs || true)
  if [[ $unit == *.service ]]; then echo "service|$unit|service $unit (\"$proc\")"; return; fi
  echo "process|$pid|program \"$proc\" (pid $pid)"
}

# Docker-published ports (bridge networking: the owner is docker-proxy or iptables).
published_owners() { # published_owners port
  command -v docker >/dev/null 2>&1 || return 0
  local name
  docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null |
    awk -F'\t' -v a=":$1->" 'index($2, a) {print $1}' |
    while read -r name; do describe_container "$name"; done
}

port_owners() { # port_owners port [tcp|udp|both] → owner lines (deduplicated)
  local p=$1 proto=${2:-tcp} flags pid proc
  case $proto in tcp) flags=-Hltnp ;; udp) flags=-Hlunp ;; *) flags=-Hltunp ;; esac
  {
    published_owners "$p"
    ss "$flags" "sport = :$p" 2>/dev/null | grep -oE '"[^"]+",pid=[0-9]+' | sed -E 's/"([^"]+)",pid=([0-9]+)/\2 \1/' | sort -u |
      while read -r pid proc; do
        [[ $proc == docker-proxy ]] && continue   # covered by published_owners
        describe_pid "$pid" "$proc"
      done
  } | awk '!seen[$0]++'
}

conflicts() { port_owners "$@" | grep -v '^ours|' || true; }   # owners that are in our way

# ── Other ports ───────────────────────────────────────────────────────────────
port_label() {
  case $1 in P_WEB) echo "admin page (HTTP)" ;; P_WEBS) echo "admin page (HTTPS)" ;; P_UNBOUND) echo "Unbound resolver (local only)" ;; esac
}
port_needed() { [[ $1 != P_UNBOUND ]] || [[ $UPSTREAM == unbound ]]; }
port_proto() { [[ $1 == P_UNBOUND ]] && echo both || echo tcp; }   # DNS uses TCP and UDP

port_taken() { # port_taken port self-var
  local p=$1 self=$2 v
  for v in "${PORT_VARS[@]}"; do port_needed "$v" && [[ $v != "$self" && ${!v} == "$p" ]] && return 0; done
  [[ $p == 53 ]] && return 0
  [[ -n $(conflicts "$p" "$(port_proto "$self")") ]]
}

next_free_port() { # next_free_port var → a free port, preferring the usual alternates
  local var=$1 p tries=0
  case $var in P_WEB) p=8080 ;; P_WEBS) p=8443 ;; *) p=5336 ;; esac
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
  alt=$(next_free_port "$var") || die "Couldn't find a free port for the $label."
  if (( DRY_RUN )); then info "Would use port $alt for the $label instead"; printf -v "$var" '%s' "$alt"; return; fi
  case $(menu "What should I do?" 1 \
    "Use $alt|next free port ($owner stays where it is)" \
    "Choose a port|type the port you want" \
    "Cancel|nothing has been installed yet") in
    1) p=$alt ;;
    2)
      while :; do
        p=$(ask "Port for the $label (1-65535)" "$alt")
        if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then warn "Enter a number between 1 and 65535."; continue; fi
        if port_taken "$p" "$var"; then warn "Port $p is taken too: try another."; continue; fi
        break
      done
      ;;
    *) info "Cancelled. Nothing was installed."; exit 0 ;;
  esac
  printf -v "$var" '%s' "$p"
  ok "The $label will use port $p"
}

check_other_ports() {
  local var line moved=0
  for var in "${PORT_VARS[@]}"; do
    port_needed "$var" || continue
    line=$(conflicts "${!var}" "$(port_proto "$var")" | head -n1)
    if [[ -n $line ]]; then resolve_port "$var" "${line##*|}"; moved=1; fi
  done
  (( moved )) || ok "Ports $P_WEB / $P_WEBS (admin page)$( [[ $UPSTREAM == unbound ]] && echo " and $P_UNBOUND (Unbound)") are free"
}

# ── Port 53 ───────────────────────────────────────────────────────────────────
# Found before the plan (so you see what will change), fixed after the image is
# downloaded (so this machine keeps working DNS for as long as possible).
P53_OWNERS=()
check_port53() {
  mapfile -t P53_OWNERS < <(conflicts 53 both)
  if (( ${#P53_OWNERS[@]} == 0 )); then
    if [[ -n $(port_owners 53 both) ]]; then ok "Port 53 (DNS) is used by this Pi-hole already"
    else ok "Port 53 (DNS) is free"; fi
    return 0
  fi

  local o kind target label blocked=0
  warn "Port 53 (DNS) is in use. Pi-hole needs it."
  for o in "${P53_OWNERS[@]}"; do
    IFS='|' read -r kind target label <<<"$o"
    case $kind in
      resolved)  info "${C_BOLD}$label${C_RESET} → I'll turn off its DNS stub listener. This machine keeps resolving names normally." ;;
      container) info "${C_BOLD}$label${C_RESET} → I'll stop it and turn off its auto-restart (it isn't deleted)." ;;
      service)
        if [[ $target == libvirtd.service || $target == lxd* || $target == snap.lxd* ]]; then
          info "${C_BOLD}$label${C_RESET} → a virtual-network DNS. I won't stop it automatically."; blocked=1
        else
          info "${C_BOLD}$label${C_RESET} → I'll stop and disable it."
        fi ;;
      *) info "${C_BOLD}$label${C_RESET} → I don't know how to stop this safely."; blocked=1 ;;
    esac
  done

  if (( blocked )); then
    printf '\n' >&2
    err "Something on port 53 has to be stopped by hand first."
    info "See what it is:   sudo ss -ltunp 'sport = :53'"
    info "Then stop it (systemctl stop/disable, or close the program) and re-run this script."
    exit 1
  fi
  (( DRY_RUN )) && return 0
  case $(menu "Free port 53 for Pi-hole?" 1 \
    "Free it|do what's listed above (undone by --uninstall)" \
    "Cancel|nothing has been changed") in
    1) ok "Port 53 will be freed after the download step" ;;
    *) info "Cancelled. Nothing was changed."; exit 0 ;;
  esac
}

upstream_ips() { # what Pi-hole forwards to (space separated, Pi-hole's ip#port form)
  case $UPSTREAM in
    unbound) echo "127.0.0.1#$P_UNBOUND" ;;
    cloudflare) echo "1.1.1.1 1.0.0.1" ;;
    quad9) echo "9.9.9.9 149.112.112.112" ;;
    google) echo "8.8.8.8 8.8.4.4" ;;
    *) echo "${UPSTREAM//,/ }" ;;
  esac
}

upstream_label() {
  case $UPSTREAM in
    unbound) echo "Unbound (your own recursive resolver, with DNSSEC)" ;;
    *) echo "$(upstream_ips)$( (( DNSSEC )) && echo " · DNSSEC on")" ;;
  esac
}

# DNS servers for THIS machine if it has none of its own after the stub goes away.
# (Unbound isn't running yet at that point, so use public resolvers then.)
host_fallback_dns() { [[ $UPSTREAM == unbound ]] && echo "1.1.1.1 9.9.9.9" || upstream_ips; }

dns_works() { # can this machine still look up names?
  local i
  for i in 1 2 3 4 5; do
    getent ahosts registry-1.docker.io >/dev/null 2>&1 && getent ahosts github.com >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

free_resolved() {
  # Remember how /etc/resolv.conf looked, once, so --uninstall can restore it.
  mkdir -p "$INSTALL_DIR"
  if [[ -z $(state_get RESOLVED_CHANGED) ]]; then
    if [[ -L /etc/resolv.conf ]]; then state_set RESOLV_LINK "$(readlink /etc/resolv.conf)"
    else cp -a /etc/resolv.conf "$INSTALL_DIR/resolv.conf.orig"; state_set RESOLV_LINK file; fi
  fi
  mkdir -p "$(dirname "$RESOLVED_DROPIN")"
  printf '# sudo homelab: Pi-hole needs port 53. Remove this file (or run the uninstaller) to undo.\n[Resolve]\nDNSStubListener=no\n' >"$RESOLVED_DROPIN"
  # The stub address (127.0.0.53) stops answering, so point this machine at the real servers.
  ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved
  state_set RESOLVED_CHANGED 1
  echo "systemd-resolved: DNS stub listener turned off"
  if ! grep -q '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null || ! dns_works; then
    # No DNS servers learned from the network (e.g. static config without DNS): give it the upstreams.
    echo "No working DNS servers known to systemd-resolved; adding $(host_fallback_dns)"
    printf 'DNS=%s\n' "$(host_fallback_dns)" >>"$RESOLVED_DROPIN"
    systemctl restart systemd-resolved
    dns_works || { echo "This machine can't resolve names after the change"; return 1; }
  fi
  echo "This machine still resolves names: OK"
}

free_container() {
  docker update --restart=no "$1" >/dev/null
  docker stop "$1"
  state_set STOPPED_CONTAINERS "$(state_get STOPPED_CONTAINERS)${1},"
}

free_service() {
  systemctl disable --now "$1"
  state_set STOPPED_SERVICES "$(state_get STOPPED_SERVICES)${1},"
}

free_port53() {
  step "Freeing port 53"
  if (( ${#P53_OWNERS[@]} == 0 )); then
    ok "Nothing to do: port 53 is free"
    return 0
  fi
  local o kind target label i
  for o in "${P53_OWNERS[@]}"; do
    IFS='|' read -r kind target label <<<"$o"
    case $kind in
      resolved) run "Turning off the systemd-resolved DNS stub" free_resolved ;;
      container) run "Stopping container $target" free_container "$target" ;;
      service) run "Stopping $target" free_service "$target" ;;
    esac
  done
  for i in $(seq 1 15); do
    [[ -z $(conflicts 53 both) ]] && { ok "Port 53 is free"; return 0; }
    sleep 1
  done
  conflicts 53 both | while IFS='|' read -r _ _ label; do err "Still on port 53: $label"; done
  die "Port 53 is still in use. Stop the program above and re-run."
}

# ── Steps ─────────────────────────────────────────────────────────────────────
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
  [[ $ARCH =~ ^(amd64|arm64|armhf)$ ]] || die "Unsupported architecture: $ARCH."
  ok "Architecture: $ARCH · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  command -v ss >/dev/null 2>&1 || die "The 'ss' command is missing (package iproute2)."
  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  (( free_mb >= 1024 )) || die "Only ${free_mb} MB free on /. Pi-hole needs about 1 GB (image + blocklists)."
  TZ_NAME=$(detect_tz); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "Server IP: $HOST_IP"
  local dev
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n $dev ]] && ip -4 addr show dev "$dev" 2>/dev/null | grep -q "inet $HOST_IP/.* dynamic"; then
    DYNAMIC_IP=1
    warn "$HOST_IP comes from DHCP. A DNS server needs a fixed address: reserve it on your router (or set a static IP)."
  fi
}

# Multi-select: type numbers ("1 3"), "a" for all, "n" for none, Enter = default.
multi_select() { # multi_select "title" "default,ids" label_func id... → comma list of chosen ids
  local title=$1 def=$2 label_fn=$3; shift 3
  local ids=("$@") i ans pick picked=() bad defnums=""
  if (( ASSUME_YES )) || ! has_tty; then echo "$def"; return; fi
  for i in "${!ids[@]}"; do [[ ,$def, == *,${ids[i]},* ]] && defnums+="$((i + 1)) "; done
  defnums=${defnums% }
  {
    printf '\n  %s%s%s %s(optional, pick any)%s\n' "$C_BOLD" "$title" "$C_RESET" "$C_GRAY" "$C_RESET"
    for i in "${!ids[@]}"; do
      printf '    %s%d)%s %s\n' "$C_GREEN" $((i + 1)) "$C_RESET" "$("$label_fn" "${ids[i]}")"
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

clean_ids() { # clean_ids "a,b" list_func what → known ids only
  local e out=()
  [[ ${1,,} == none ]] && return 0
  for e in ${1//,/ }; do
    if [[ -n $("$2" "$e") ]]; then out+=("$e"); else warn "Unknown $3 '$e'; skipping it."; fi
  done
  printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -
}

is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

normalize_choices() {
  local u
  EXTRAS=$(clean_ids "$EXTRAS" extra_lists "extra list")
  ALLOWLISTS=$(clean_ids "$ALLOWLISTS" allow_lists "allowlist")
  [[ -n $(preset_lists "$BLOCKLISTS") ]] || die "Unknown --blocklists '$BLOCKLISTS' (use light, balanced, aggressive or classic)."
  for u in ${CUSTOM_LISTS//,/ }; do
    [[ $u =~ ^https?://[^\'\"[:space:]]+$ ]] || die "Not a valid blocklist URL: $u"
  done
  if [[ $UPSTREAM != unbound ]]; then
    for u in $(upstream_ips); do
      [[ $u =~ ^[0-9.]+(#[0-9]+)?$ || $u =~ ^[0-9a-fA-F:]+$ ]] || die "Upstream DNS must be unbound, cloudflare, quad9, google or IP addresses (got '$u')."
    done
    [[ -n $(upstream_ips) ]] || die "No upstream DNS servers given."
  fi
  [[ $DNS_ACCESS =~ ^(local|all)$ ]] || die "--dns-access must be local or all (got '$DNS_ACCESS')."
  [[ $REFRESH =~ ^(daily|weekly)$ ]] || die "--refresh must be daily or weekly (got '$REFRESH')."
  [[ $DEVICE_NAMES =~ ^(yes|no)$ ]] || die "--device-names must be yes or no (got '$DEVICE_NAMES')."
  if [[ $DEVICE_NAMES == yes ]]; then
    is_ipv4 "$ROUTER_IP" || die "Router address must be an IPv4 address (got '${ROUTER_IP:-nothing}'), or use --device-names=no."
    [[ $LOCAL_DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Local domain must look like lan or home.arpa (got '$LOCAL_DOMAIN')."
    [[ -n $LAN_CIDR ]] || die "Couldn't work out your local subnet for device names; use --device-names=no."
  fi
}

# Every list for the current choices, one per line: "<type> <url>", where type is
# 0 = blocklist and 1 = allowlist (Pi-hole's adlist.type).
wanted_lists() {
  local e
  { preset_lists "$BLOCKLISTS"; for e in ${EXTRAS//,/ }; do extra_lists "$e"; done; echo "${CUSTOM_LISTS//,/ }"; } |
    tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "0 " $0}'
  for e in ${ALLOWLISTS//,/ }; do allow_lists "$e"; done | tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "1 " $0}'
}

# The router and subnet this machine's LAN interface uses, for device names.
detect_lan() {
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  DETECTED_ROUTER=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}') || true
  LAN_CIDR=""
  [[ -n $dev ]] && LAN_CIDR=$(ip -4 route show dev "$dev" proto kernel scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}') || true
  # The search domain your router hands out over DHCP, if any.
  DETECTED_DOMAIN=$(awk '/^search / {print $2; exit}' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null | head -n1) || true
  [[ -z $DETECTED_DOMAIN && -n $dev ]] && DETECTED_DOMAIN=$(resolvectl domain "$dev" 2>/dev/null | awk -F': ' '{print $2}' | awk '{print $1}' | tr -d '~' | head -n1) || true
  [[ $DETECTED_DOMAIN == . || -z $DETECTED_DOMAIN ]] && DETECTED_DOMAIN=lan
  return 0
}

# Address on a VPN interface (Tailscale, WireGuard, ZeroTier), if this machine has one.
vpn_address() {
  local ifc
  for ifc in tailscale0 wg0 zt+; do
    ip -4 -br addr show 2>/dev/null | awk -v p="${ifc%+}" 'index($1, p) == 1 && $3 {split($3, a, "/"); print $1, a[1]; exit}'
  done | head -n1
}

is_private_ip() { [[ $1 =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.) ]]; }

ask_password() {
  if [[ -f $INSTALL_DIR/.secrets && -z $APP_PASS ]]; then
    APP_PASS=$(sed -n 's/^APP_PASS=//p' "$INSTALL_DIR/.secrets")
    [[ -n $APP_PASS ]] && { info "Existing install found: keeping the current admin password"; return; }
  fi
  if [[ -z $APP_PASS ]] && (( ! ASSUME_YES )) && has_tty; then
    printf '\n  %sAdmin password%s %s(Pi-hole has no usernames: one password protects the admin page)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    case $(menu "Password for the Pi-hole admin page" 1 \
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
  if [[ -z $APP_PASS ]] && (( DRY_RUN )); then info "A random admin password would be generated"; return; fi
  if [[ -z $APP_PASS ]]; then
    APP_PASS=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    GENERATED_PASS=1
    # Straight to the screen (not via ok/log) so the password never lands in the log.
    printf '  %s✓%s Generated password: %s%s%s  %s(also saved to %s/credentials.txt)%s\n' \
      "$C_GREEN" "$C_RESET" "$C_BOLD" "$APP_PASS" "$C_RESET" "$C_GRAY" "$INSTALL_DIR" "$C_RESET"
    log "OK   Generated a random password"
  fi
}

choose_options() {
  step "Choose your setup"
  local prev vpn
  # Re-run: default to what's installed now.
  if [[ -f $INSTALL_DIR/.state ]]; then
    info "Existing install found in $INSTALL_DIR (its settings are the defaults)"
    (( WEB_PORT_SET )) || { prev=$(state_get P_WEB); [[ $prev =~ ^[0-9]+$ ]] && P_WEB=$prev; }
    prev=$(state_get P_WEBS); [[ $prev =~ ^[0-9]+$ ]] && P_WEBS=$prev
    prev=$(state_get P_UNBOUND); [[ $prev =~ ^[0-9]+$ ]] && P_UNBOUND=$prev
  fi

  # ── What to block ──
  if [[ -z $BLOCKLISTS ]]; then
    case $(menu "Which blocklists?" "$(menu_index "$(state_get BLOCKLISTS)" balanced light aggressive classic)" \
      "Balanced|HaGeZi Pro + threat intel. Blocks a lot, rarely breaks sites (recommended)" \
      "Light|HaGeZi Light. Almost never breaks anything" \
      "Aggressive|HaGeZi Pro++ + full threat intel. Expect to allow-list a few sites" \
      "Classic|StevenBlack hosts, Pi-hole's default list") in
      1) BLOCKLISTS=balanced ;; 2) BLOCKLISTS=light ;; 3) BLOCKLISTS=aggressive ;; 4) BLOCKLISTS=classic ;;
    esac
  fi
  (( EXTRAS_SET )) || EXTRAS=$(multi_select "Extra blocklists" "$(state_get EXTRAS)" extra_label "${EXTRA_IDS[@]}")
  if (( ! ALLOWLISTS_SET )); then
    prev=referral; [[ -f $INSTALL_DIR/.state ]] && prev=$(state_get ALLOWLISTS)
    ALLOWLISTS=$(multi_select "Allowlists: never block these, to avoid broken links" "$prev" allow_label "${ALLOW_IDS[@]}")
  fi
  [[ -z $CUSTOM_LISTS ]] && CUSTOM_LISTS=$(state_get CUSTOM_LISTS)

  if [[ -z $REFRESH ]]; then
    case $(menu "How often should the blocklists update?" "$(menu_index "$(state_get REFRESH)" daily weekly)" \
      "Daily|new scam & malware domains are blocked sooner (recommended)" \
      "Weekly|Pi-hole's default") in
      1) REFRESH=daily ;; 2) REFRESH=weekly ;;
    esac
  fi

  # ── Where answers come from ──
  if [[ -z $UPSTREAM ]]; then
    prev=$(state_get UPSTREAM)
    case $(menu "Upstream DNS (where Pi-hole looks up the sites it doesn't block)" \
      "$(case ${prev:-unbound} in unbound) echo 1 ;; cloudflare) echo 2 ;; quad9) echo 3 ;; google) echo 4 ;; *) echo 5 ;; esac)" \
      "Unbound|your own resolver: asks the internet's root servers directly, no DNS company sees your lookups (recommended)" \
      "Cloudflare|1.1.1.1, fast, privacy-focused" \
      "Quad9|9.9.9.9, also blocks known malware domains" \
      "Google|8.8.8.8" \
      "Custom|type your own server IPs") in
      1) UPSTREAM=unbound ;; 2) UPSTREAM=cloudflare ;; 3) UPSTREAM=quad9 ;; 4) UPSTREAM=google ;;
      5) UPSTREAM=$(ask "DNS server IPs, comma-separated" "$( [[ $prev =~ ^[0-9] ]] && echo "$prev" || echo 1.1.1.1,1.0.0.1)") ;;
    esac
  fi
  [[ ${UPSTREAM,,} == unbound ]] && UPSTREAM=unbound
  [[ $(state_get DNSSEC) == 0 ]] && DNSSEC=0

  # ── Who can use it ──
  if [[ -z $DNS_ACCESS ]]; then
    vpn=$(vpn_address)
    case $(menu "Who should be able to use this Pi-hole?" "$(menu_index "$(state_get DNS_ACCESS)" local all)" \
      "Local network|devices on your home network only (recommended)" \
      "Any network|also VPNs (Tailscale, WireGuard…) and other subnets. Never forward port 53 to the internet") in
      1) DNS_ACCESS=local ;; 2) DNS_ACCESS=all ;;
    esac
    [[ $DNS_ACCESS == local && -n $vpn ]] && info "This machine is on a VPN (${vpn%% *}). Pick 'Any network' if devices should use Pi-hole through it."
  fi
  if [[ $DNS_ACCESS == all ]] && ! is_private_ip "$HOST_IP"; then
    warn "$HOST_IP is a public address: with 'Any network', anyone on the internet could use this DNS server."
    warn "Block port 53 in your firewall for everything except your own networks."
  fi

  # ── Device names in the query log ──
  detect_lan
  [[ -z $ROUTER_IP ]] && ROUTER_IP=$(state_get ROUTER_IP)
  [[ -z $ROUTER_IP ]] && ROUTER_IP=$DETECTED_ROUTER
  [[ -z $LOCAL_DOMAIN ]] && LOCAL_DOMAIN=$(state_get LOCAL_DOMAIN)
  [[ -z $LOCAL_DOMAIN ]] && LOCAL_DOMAIN=$DETECTED_DOMAIN
  if [[ -z $DEVICE_NAMES ]]; then
    prev=$(state_get DEVICE_NAMES)
    if [[ -z $ROUTER_IP || -z $LAN_CIDR ]]; then
      DEVICE_NAMES=no; info "No router found on this network: the query log will show IP addresses."
    else
      case $(menu "Show device names in the query log (e.g. 'Living-Room-TV' instead of an IP)?" "$(menu_index "${prev:-yes}" yes no)" \
        "Yes|ask your router ($ROUTER_IP) for the names of devices on $LAN_CIDR" \
        "No|show IP addresses only") in
        1) DEVICE_NAMES=yes
           ROUTER_IP=$(ask "Router address" "$ROUTER_IP")
           LOCAL_DOMAIN=$(ask "Local domain your router uses (often lan, home or localdomain)" "$LOCAL_DOMAIN") ;;
        2) DEVICE_NAMES=no ;;
      esac
    fi
  fi
  normalize_choices

  ask_password

  step "Checking ports"
  check_port53
  check_other_ports

  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  local extras_txt="" allow_txt="" e
  for e in ${EXTRAS//,/ }; do extras_txt+="${extras_txt:+, }$(extra_label "$e" | sed 's/ (.*//')"; done
  for e in ${ALLOWLISTS//,/ }; do allow_txt+="${allow_txt:+, }$(allow_label "$e" | sed 's/ (.*//')"; done
  printf '    %-16s %s\n' "Pi-hole" "$IMAGE (Docker, host network)" \
    "Admin page" "http://$HOST_IP:$P_WEB/admin" \
    "Blocklists" "$(preset_label "$BLOCKLISTS")" \
    "Extra lists" "${extras_txt:-none}${CUSTOM_LISTS:+ + $(wc -w <<<"${CUSTOM_LISTS//,/ }") of your own}" \
    "Allowlists" "${allow_txt:-none}" \
    "List updates" "$REFRESH" \
    "Upstream DNS" "$(upstream_label)" \
    "Answers" "$( [[ $DNS_ACCESS == local ]] && echo "local network only" || echo "any network (VPNs, other subnets)")" \
    "Device names" "$( [[ $DEVICE_NAMES == yes ]] && echo "from $ROUTER_IP ($LAN_CIDR, .$LOCAL_DOMAIN)" || echo "off")" \
    "Data" "$INSTALL_DIR"
  local o
  for o in "${P53_OWNERS[@]}"; do printf '    %-16s %s\n' "Port 53" "free it from ${o##*|}"; done
  log "Plan: blocklists=$BLOCKLISTS extras=${EXTRAS:-none} allow=${ALLOWLISTS:-none} custom=${CUSTOM_LISTS:-none} refresh=$REFRESH upstream=$UPSTREAM dnssec=$DNSSEC access=$DNS_ACCESS names=$DEVICE_NAMES router=$ROUTER_IP cidr=$LAN_CIDR domain=$LOCAL_DOMAIN web=$P_WEB/$P_WEBS unbound=$P_UNBOUND port53=${P53_OWNERS[*]:-free}"
  printf '\n'

  if (( DRY_RUN )); then info "Dry run: nothing was changed."; exit 0; fi
  confirm "Install now?" || { info "Cancelled. Nothing was changed."; exit 0; }
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
  for pkg in curl jq ca-certificates gnupg iproute2; do
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
  # Download while this machine's DNS is still untouched.
  run "Downloading Pi-hole" docker pull "$IMAGE"
  [[ $UPSTREAM == unbound ]] && run "Downloading Unbound" docker pull "$UNBOUND_IMAGE"
  return 0
}

write_files() {
  mkdir -p "$INSTALL_DIR/etc-pihole"
  chmod 700 "$INSTALL_DIR"
  # A fresh Pi-hole builds its blocklist database from this file on first start,
  # so the first gravity run already uses our lists. Later changes go through the database.
  [[ -f $INSTALL_DIR/etc-pihole/gravity.db ]] || wanted_lists | awk '$1 == 0 {print $2}' >"$INSTALL_DIR/etc-pihole/adlists.list"
  cat >"$INSTALL_DIR/docker-compose.yml" <<EOF
# sudo homelab · Pi-hole. Re-run the installer to change settings.
name: $PROJECT
services:
  pihole:
    image: $IMAGE
    network_mode: host          # real client IPs in the query log; DNS on port 53
    environment:
      TZ: "$TZ_NAME"
      # o = optional (don't fail if taken), s = HTTPS with a self-signed certificate
      FTLCONF_webserver_port: "${P_WEB}o,${P_WEBS}os,[::]:${P_WEB}o,[::]:${P_WEBS}os"
    volumes:
      - ./etc-pihole:/etc/pihole
    cap_add:
      - SYS_NICE
    restart: unless-stopped
EOF
  if [[ $UPSTREAM == unbound ]]; then
    cat >>"$INSTALL_DIR/docker-compose.yml" <<EOF
    depends_on:
      - unbound

  # Recursive resolver: asks the root/TLD servers directly and validates DNSSEC.
  # Reachable only from this machine (127.0.0.1), i.e. by Pi-hole.
  unbound:
    image: $UNBOUND_IMAGE
    ports:
      - "127.0.0.1:${P_UNBOUND}:53/tcp"
      - "127.0.0.1:${P_UNBOUND}:53/udp"
    restart: unless-stopped
EOF
  fi
  ( umask 077; printf 'APP_PASS=%s\n' "$APP_PASS" >"$INSTALL_DIR/.secrets" )
  local v
  for v in P_WEB P_WEBS P_UNBOUND BLOCKLISTS EXTRAS ALLOWLISTS CUSTOM_LISTS REFRESH UPSTREAM DNSSEC DNS_ACCESS DEVICE_NAMES ROUTER_IP LOCAL_DOMAIN; do
    state_set "$v" "${!v}"
  done
}

wait_pihole() { # stream the container log until the admin page answers
  local start=$SECONDS code lp state cid
  cid=$(dc ps -aq pihole)
  # Plain `docker logs` (not the dc wrapper) so $! is the process itself: if a
  # leftover child kept the output pipe open, this step would never finish.
  docker logs -f --since "$LOGS_SINCE" "$cid" 2>&1 & lp=$!
  while (( SECONDS - start < 900 )); do
    state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)
    if [[ $state == exited || $state == dead ]]; then kill "$lp" 2>/dev/null; echo "The Pi-hole container stopped ($state)"; return 1; fi
    code=$(http_code "http://127.0.0.1:$P_WEB/admin/")
    if [[ $code =~ ^(200|30[1-8])$ ]]; then kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null || true; return 0; fi
    sleep 2
  done
  kill "$lp" 2>/dev/null
  echo "Pi-hole didn't come up within 15 minutes"
  return 1
}

start_pihole() {
  step "Starting Pi-hole"
  write_files
  ok "Wrote $INSTALL_DIR/docker-compose.yml"
  LOGS_SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # the wait step shows only this start's log
  run "Starting the container$( [[ $UPSTREAM == unbound ]] && echo s)" dc up -d --remove-orphans
  local first=""
  [[ -f $INSTALL_DIR/etc-pihole/gravity.db ]] || first=" (first start downloads the blocklists: a few minutes)"
  run "Waiting for Pi-hole$first" wait_pihole
}

set_password() { printf '%s\n%s\n' "$APP_PASS" "$APP_PASS" | px pihole setpassword; }

wait_unbound() { # the first lookups of a fresh resolver take a moment (root, TLD, DNSSEC keys)
  local i ans
  for i in $(seq 1 30); do
    ans=$(px dig +short +time=3 +tries=1 @127.0.0.1 -p "$P_UNBOUND" github.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    [[ -n $ans ]] && { echo "Unbound answers: github.com → $ans"; return 0; }
    echo "Unbound is starting up… (${i}/30)"
    sleep 2
  done
  echo "Unbound didn't answer on 127.0.0.1:$P_UNBOUND"
  return 1
}

set_upstreams() {
  local json
  json=$(upstream_ips | tr ' ' '\n' | jq -R . | jq -sc .)
  px pihole-FTL --config dns.upstreams "$json"
  # Unbound validates DNSSEC itself; with a public upstream, Pi-hole does it.
  if [[ $UPSTREAM != unbound ]] && (( DNSSEC )); then px pihole-FTL --config dns.dnssec true
  else px pihole-FTL --config dns.dnssec false; fi
}

set_access() {
  case $DNS_ACCESS in
    local) px pihole-FTL --config dns.listeningMode LOCAL ;;
    all) px pihole-FTL --config dns.listeningMode ALL ;;
  esac
}

# Conditional forwarding: reverse lookups for the LAN (IP → name) and names in
# the local domain go to the router, which knows its DHCP clients' names.
set_device_names() {
  if [[ $DEVICE_NAMES == yes ]]; then
    px pihole-FTL --config dns.revServers "$(jq -nc --arg v "true,$LAN_CIDR,$ROUTER_IP,$LOCAL_DOMAIN" '[$v]')"
  else
    px pihole-FTL --config dns.revServers '[]'
  fi
}

# Daily refresh: a host systemd timer, so it survives container updates. Weekly
# is Pi-hole's own schedule inside the container, so then there's nothing to add.
set_refresh() {
  local svc=/etc/systemd/system/$GRAVITY_UNIT.service tmr=/etc/systemd/system/$GRAVITY_UNIT.timer
  if [[ $REFRESH == daily ]]; then
    cat >"$svc" <<EOF
[Unit]
Description=sudo homelab: update Pi-hole blocklists
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$(command -v docker) compose -p $PROJECT -f $INSTALL_DIR/docker-compose.yml exec -T pihole pihole -g
EOF
    cat >"$tmr" <<EOF
[Unit]
Description=sudo homelab: update Pi-hole blocklists daily

[Timer]
OnCalendar=*-*-* 04:00
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$GRAVITY_UNIT.timer"
    systemctl list-timers "$GRAVITY_UNIT.timer" --no-pager | head -n2
  else
    remove_refresh
    echo "Weekly: Pi-hole's built-in schedule"
  fi
}

remove_refresh() {
  if [[ -f /etc/systemd/system/$GRAVITY_UNIT.timer ]]; then
    systemctl disable --now "$GRAVITY_UNIT.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/$GRAVITY_UNIT.timer" "/etc/systemd/system/$GRAVITY_UNIT.service"
    systemctl daemon-reload
  fi
  return 0
}

# Make the blocklists match the choices: add/enable what's wanted, remove lists
# this script added earlier that aren't wanted any more, and Pi-hole's default
# StevenBlack list unless chosen. Lists you added yourself are left alone.
sync_lists() {
  local before after sql t u q="SELECT type || '|' || address FROM adlist WHERE enabled = 1 ORDER BY type, address;"
  before=$(gravity_sql "$q")
  # .bail: stop at the first error (otherwise sqlite carries on and COMMITs half the changes)
  sql=$'.bail on\nBEGIN;'
  while read -r t u; do
    sql+="INSERT OR IGNORE INTO adlist (address, type, enabled, comment) VALUES ('$u', $t, 1, 'sudo homelab');"
    sql+="UPDATE adlist SET enabled = 1, comment = 'sudo homelab' WHERE address = '$u' AND type = $t;"
  done < <(wanted_lists)
  local keep drop
  keep=$(wanted_lists | awk -v q="'" '{printf "%s%s%s|%s%s", (NR > 1 ? "," : ""), q, $1, $2, q}')
  drop="SELECT id FROM adlist WHERE (type || '|' || address) NOT IN ($keep) AND (comment = 'sudo homelab' OR (comment LIKE 'Migrated from%' AND type = 0 AND address = 'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts'))"
  # gravity/antigravity rows reference their list (foreign key): remove them first.
  sql+="DELETE FROM gravity WHERE adlist_id IN ($drop);"
  sql+="DELETE FROM antigravity WHERE adlist_id IN ($drop);"
  sql+="DELETE FROM adlist WHERE id IN ($drop);"
  sql+="COMMIT;"
  printf '%s\n' "$sql" | px pihole-FTL sqlite3 /etc/pihole/gravity.db
  after=$(gravity_sql "$q")
  echo "Lists:"; sed 's/^0|/  block  /; s/^1|/  allow  /' <<<"$after"
  [[ $before != "$after" ]] && echo CHANGED >"$SHL_TMP/lists-changed"
  return 0
}

gravity_count() { gravity_sql "SELECT value FROM info WHERE property = 'gravity_count';" 2>/dev/null | tr -dc 0-9; }

configure() {
  step "Configuring Pi-hole"
  run "Setting the admin password" set_password
  [[ $UPSTREAM == unbound ]] && run "Waiting for Unbound" wait_unbound
  run "Setting upstream DNS: $(upstream_label)" set_upstreams
  run "Answering $( [[ $DNS_ACCESS == local ]] && echo "the local network only" || echo "any network")" set_access
  run "Device names in the query log: $( [[ $DEVICE_NAMES == yes ]] && echo "from $ROUTER_IP" || echo off)" set_device_names
  run "Blocklist updates: $REFRESH" set_refresh
  run "Setting up the block- and allowlists" sync_lists
  if [[ -f $SHL_TMP/lists-changed ]] || [[ $(gravity_count) == 0 || -z $(gravity_count) ]]; then
    run "Building the blocklist database (gravity)" px pihole -g
  else
    ok "Blocklist database is up to date"
  fi
}

api_login_ok() {
  local body sid resp
  body=$(jq -nc --rawfile p "$(sfile pw "$APP_PASS")" '{password: $p}')
  resp=$( { ckv url "http://127.0.0.1:$P_WEB/api/auth"; ckv header "Content-Type: application/json"; ckv data "$body"; } |
    curl -s -m 10 -K - ) || return 1
  [[ $(jq -r '.session.valid // false' <<<"$resp" 2>/dev/null) == true ]] || return 1
  sid=$(jq -r '.session.sid // empty' <<<"$resp")
  # Log out again: Pi-hole only allows a limited number of sessions.
  [[ -n $sid ]] && { ckv header "X-FTL-SID: $sid"; } | curl -s -m 5 -o /dev/null -X DELETE -K - "http://127.0.0.1:$P_WEB/api/auth" || true
  return 0
}

verify() {
  step "Checking that it works"
  local fails=0 blocked_domain ans

  BLOCKED_COUNT=$(gravity_count)
  if [[ ${BLOCKED_COUNT:-0} -gt 0 ]]; then ok "Blocklists loaded: $(printf "%'d" "$BLOCKED_COUNT" 2>/dev/null || echo "$BLOCKED_COUNT") domains"
  else err "The blocklist database is empty"; fails=1; fi

  ans=$(px dig +short +time=3 +tries=2 @127.0.0.1 github.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
  if [[ -n $ans && $ans != 0.0.0.0 ]]; then ok "Normal sites resolve (github.com → $ans)"
  else err "github.com didn't resolve through Pi-hole"; fails=1; fi

  # A domain straight from the blocklist database must come back as 0.0.0.0.
  blocked_domain=$(gravity_sql "SELECT domain FROM gravity LIMIT 1 OFFSET 500;" 2>/dev/null | sed -E 's/^\|\|//; s/\^.*$//' || true)
  if [[ -n $blocked_domain ]]; then
    ans=$(px dig +short +time=3 +tries=2 @127.0.0.1 "$blocked_domain" A 2>/dev/null | head -n1 || true)
    if [[ $ans == 0.0.0.0 ]]; then ok "Ads are blocked ($blocked_domain → 0.0.0.0)"
    else err "$blocked_domain should be blocked but answered '${ans:-nothing}'"; fails=1; fi
  fi

  ans=$(px dig +short +time=3 +tries=2 @"$HOST_IP" github.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
  if [[ -n $ans ]]; then ok "Answers on the network address ($HOST_IP:53)"
  else err "No answer on $HOST_IP:53: check a firewall (sudo ufw allow 53)"; fails=1; fi

  if api_login_ok; then ok "Admin page login works (http://$HOST_IP:$P_WEB/admin)"
  else err "Couldn't log in to the admin page with the new password"; fails=1; fi

  if [[ $UPSTREAM == unbound ]]; then
    ans=$(px dig +short +time=3 +tries=2 @127.0.0.1 -p "$P_UNBOUND" example.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    if [[ -n $ans ]]; then ok "Unbound resolves on its own (example.com → $ans)"
    else err "Unbound didn't answer on 127.0.0.1:$P_UNBOUND"; fails=1; fi
  fi

  # dnssec-failed.org is deliberately mis-signed: a validating resolver must refuse it.
  if [[ $UPSTREAM == unbound ]] || (( DNSSEC )); then
    ans=$(px dig +time=5 +tries=2 @127.0.0.1 dnssec-failed.org A 2>/dev/null | grep -o 'status: [A-Z]*' | head -n1 || true)
    if [[ $ans == "status: SERVFAIL" ]]; then ok "DNSSEC works (forged answers are rejected)"
    else warn "DNSSEC test: dnssec-failed.org gave '${ans:-no answer}' instead of SERVFAIL"; fi
  fi

  if [[ -n $ALLOWLISTS ]]; then
    ans=$(gravity_sql "SELECT count(*) FROM antigravity;" 2>/dev/null | tr -dc 0-9)
    if [[ ${ans:-0} -gt 0 ]]; then ok "Allowlists loaded: $(printf "%'d" "$ans" 2>/dev/null || echo "$ans") domains never blocked"
    else err "The allowlists are empty"; fails=1; fi
  fi

  if [[ $DEVICE_NAMES == yes ]]; then
    ans=$(px dig +short +time=3 +tries=2 -x "$ROUTER_IP" @127.0.0.1 2>/dev/null | head -n1 || true)
    if [[ -n $ans ]]; then ok "Device names work ($ROUTER_IP → ${ans%.})"
    else warn "Your router didn't return a name for $ROUTER_IP. Some routers only know their DHCP clients: check the query log later."; fi
  fi

  if [[ $REFRESH == daily ]]; then
    if systemctl is-active --quiet "$GRAVITY_UNIT.timer"; then ok "Daily blocklist update scheduled ($(systemctl show -p NextElapseUSecRealtime --value "$GRAVITY_UNIT.timer" 2>/dev/null | awk '{print $2, $3}'))"
    else err "The daily update timer isn't active"; fails=1; fi
  fi

  local vpn
  vpn=$(vpn_address)
  if [[ $DNS_ACCESS == all && -n $vpn ]]; then
    ans=$(px dig +short +time=3 +tries=2 @"${vpn#* }" github.com A 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)
    if [[ -n $ans ]]; then ok "Answers on the VPN address (${vpn#* } on ${vpn%% *})"
    else err "No answer on the VPN address ${vpn#* }"; fails=1; fi
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is active: allow DNS and the admin page with  sudo ufw allow 53 && sudo ufw allow $P_WEB/tcp"
  fi
  (( fails == 0 )) || warn "Some checks failed. Pi-hole is installed; see the log for details: $LOG_FILE"
}

summary() {
  step "Done"
  local f="$INSTALL_DIR/credentials.txt" ip=$HOST_IP
  ( umask 077
    {
      echo "sudo homelab · Pi-hole ($(date))"
      echo
      echo "Admin page   http://$ip:$P_WEB/admin"
      echo "Password     $APP_PASS"
      echo "DNS server   $ip"
    } >"$f" )

  printf '\n  %s%s★ Pi-hole is running!%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '    %s%-12s%s %s%s%s\n' "$C_BOLD" "Admin page" "$C_RESET" "$C_CYAN" "http://$ip:$P_WEB/admin" "$C_RESET"
  printf '    %s%-12s%s %s%s\n' "$C_BOLD" "Password" "$C_RESET" "$APP_PASS" \
    "$( [[ ${GENERATED_PASS:-0} == 1 ]] && printf '  %s(generated)%s' "$C_GRAY" "$C_RESET")"
  printf '    %s%-12s%s %s\n' "$C_BOLD" "DNS server" "$C_RESET" "$ip"
  printf '    %s%-12s%s %s domains · %s\n' "$C_BOLD" "Blocking" "$C_RESET" "$(printf "%'d" "${BLOCKED_COUNT:-0}" 2>/dev/null || echo "$BLOCKED_COUNT")" "$(preset_label "$BLOCKLISTS" | sed 's/:.*//')${EXTRAS:+ + ${EXTRAS//,/, }}${ALLOWLISTS:+ · allow: ${ALLOWLISTS//,/, }} · updated $REFRESH"
  printf '    %s%-12s%s %s\n' "$C_BOLD" "Upstream" "$C_RESET" "$(upstream_label)"
  printf '    %s%-12s%s %s\n' "$C_BOLD" "Answers" "$C_RESET" "$( [[ $DNS_ACCESS == local ]] && echo "local network only" || echo "any network")"
  printf '    %s%-12s%s %s\n' "$C_BOLD" "Dev. names" "$C_RESET" "$( [[ $DEVICE_NAMES == yes ]] && echo "from your router ($ROUTER_IP)" || echo "off")"
  printf '    %sSaved%s        %s %s(root only)%s\n' "$C_GRAY" "$C_RESET" "$f" "$C_GRAY" "$C_RESET"

  printf '\n  %sNext steps for you%s\n' "$C_BOLD" "$C_RESET"
  local n=1
  [[ ${DYNAMIC_IP:-0} == 1 ]] && printf '    %s%d.%s Reserve %s%s%s for this machine in your router (DHCP reservation), so it never changes.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$ip" "$C_RESET"
  printf '    %s%d.%s In your router'"'"'s DHCP/LAN settings, set the DNS server to %s%s%s (and remove any second DNS,\n       or devices will skip Pi-hole). Devices pick it up when they reconnect.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "$ip" "$C_RESET"
  printf '    %s%d.%s Turn off any IPv6 DNS your router hands out (or set it to this machine), or devices may skip Pi-hole.\n' "$C_GREEN" $((n++)) "$C_RESET"
  local vpn
  vpn=$(vpn_address)
  if [[ $DNS_ACCESS == all && $vpn == tailscale0* ]]; then
    printf '    %s%d.%s Tailscale: admin console → DNS → Add nameserver → %s%s%s, and turn on "Override local DNS".\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "${vpn#* }" "$C_RESET"
  elif [[ $DNS_ACCESS == all && -n $vpn ]]; then
    printf '    %s%d.%s VPN clients: set %s%s%s as their DNS server.\n' "$C_GREEN" $((n++)) "$C_RESET" "$C_BOLD" "${vpn#* }" "$C_RESET"
  fi
  printf '    %s%d.%s Something broke? Admin page → Query Log → find the blocked domain → Allow.\n' "$C_GREEN" $((n++)) "$C_RESET"
  printf '    %s%d.%s YouTube ads can'"'"'t be blocked by DNS (use uBlock Origin in the browser).\n' "$C_GREEN" $((n++)) "$C_RESET"

  printf '\n    %sManage:%s    cd %s && sudo docker compose ps | logs -f | pull && up -d\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"
  printf '    %sUninstall:%s %s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --uninstall")"
  printf '    %sLog:%s       %s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s      %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
}

restore_resolved() {
  rm -f "$RESOLVED_DROPIN"
  local link
  link=$(state_get RESOLV_LINK)
  if [[ $link == file && -f $INSTALL_DIR/resolv.conf.orig ]]; then
    rm -f /etc/resolv.conf; cp -a "$INSTALL_DIR/resolv.conf.orig" /etc/resolv.conf
  elif [[ -n $link && $link != file ]]; then
    ln -sfn "$link" /etc/resolv.conf
  fi
  systemctl restart systemd-resolved
  state_set RESOLVED_CHANGED ""
  dns_works && echo "This machine resolves names: OK"
}

uninstall() {
  banner
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
  [[ -f $INSTALL_DIR/docker-compose.yml ]] || die "No Pi-hole from this script found in $INSTALL_DIR."
  warn "This stops and removes Pi-hole (and Unbound, if installed). Devices using it for DNS lose name lookups"
  warn "until you point your router back to another DNS server."
  if (( PURGE )); then warn "--purge: Pi-hole's data (settings, lists, query history) in $INSTALL_DIR will be deleted."
  else info "Pi-hole's data stays in $INSTALL_DIR (re-run the installer to bring it back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  run "Removing the containers" dc down --remove-orphans
  run "Removing the daily blocklist update" remove_refresh
  if [[ $(state_get RESOLVED_CHANGED) == 1 ]]; then
    run "Turning the systemd-resolved DNS stub back on" restore_resolved
  fi
  local s
  s=$(state_get STOPPED_SERVICES); s=${s%,}
  [[ -n $s ]] && info "Stopped earlier to free port 53: ${s//,/, }. Start again with: sudo systemctl enable --now ${s//,/ }"
  s=$(state_get STOPPED_CONTAINERS); s=${s%,}
  [[ -n $s ]] && info "Containers stopped earlier to free port 53: ${s//,/, }. Start again with: sudo docker start ${s//,/ }"
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
  log "sudo homelab pihole v$VERSION · args: $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
  log "kernel: $(uname -a)"

  check_interactive
  if (( UNINSTALL )); then uninstall; exit 0; fi

  START_TIME=$SECONDS
  banner
  preflight
  choose_options
  install_deps
  free_port53
  start_pihole
  configure
  verify
  summary
  log "install finished"
}

main "$@"
