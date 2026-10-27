#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Monitoring Stack (Uptime Kuma + Beszel + ntfy)
#  for Proxmox VE 8 / 9
#  https://github.com/Eportela99/sudohomelab
#
#  Run on the Proxmox host shell (as root). It creates one small unprivileged
#  Debian LXC with a fixed IP and runs the Ubuntu/Debian installer inside it
#  (same questions, same wiring). On top of that:
#    · Uptime Kuma also watches your other guests: a ping for each container/VM,
#      plus the apps it finds inside each running container (media stack,
#      Pi-hole, anything in Docker), and this host's web UI
#    · Beszel's agent goes on this Proxmox host itself (a system service), so
#      you see the real host: CPU, RAM, disks, temperatures
#
#    Proxmox host  ── Beszel agent (service) ──┐
#     └── LXC "monitoring" (tag sudohomelab-monitoring, static IP)
#          ├── Uptime Kuma · Beszel hub ←──────┘ · ntfy
#          └── /opt/sudohomelab/monitoring  ← settings (host: --settings-dir)
#
#  Usage (Proxmox shell; no options = a menu):
#    bash -c "$(curl -fsSL <url>/Monitoring_Management/proxmox/monitoring.sh)"
#    bash -c "$(curl -fsSL <url>)" _ --sync
#    bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PX_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management"
LIB_URL="$PX_REPO_RAW/linux/monitoring.sh"
AGENT_LIB_URL="$PX_REPO_RAW/linux/beszel-agent.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
# The guard line (no auto-run as a library) and the .extra-found hook must both be there.
px_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$CORE_FILE" 2>/dev/null && grep -q 'extra-found' "$CORE_FILE"; }
px_load_core() {
  local here=""
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/monitoring.sh ]]; then
    CORE_FILE="$here/../linux/monitoring.sh"
    AGENT_FILE="$here/../linux/beszel-agent.sh"
  else
    CORE_FILE=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$CORE_FILE" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
    # Right after a release GitHub can still serve an older core for a few minutes.
    px_core_ok || curl -fsSL "$LIB_URL?t=$(date +%s)" -o "$CORE_FILE" || true
    AGENT_FILE=""
  fi
  px_core_ok || { echo "The installer core at $LIB_URL is an older version (GitHub's cache). Try again in 5 minutes." >&2; exit 1; }
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$CORE_FILE"
}
px_load_core

# ── Proxmox defaults ──────────────────────────────────────────────────────────
VERSION="0.1.0-proxmox (core $VERSION)"
SCRIPT_URL="$PX_REPO_RAW/proxmox/monitoring.sh"
LOG_FILE="$LOG_DIR/monitoring-proxmox-$(date +%Y%m%d-%H%M%S).log"
TOTAL_STEPS=8
INSTALL_DIR="/opt/sudohomelab/monitoring"   # settings on the HOST, mounted into the container
CT_TAG="sudohomelab-monitoring"
CT_SETTINGS=/opt/sudohomelab/monitoring
CT_HOSTNAME=monitoring
CTID=""; CT_EXISTS=0; CT_STORAGE=""; CT_BRIDGE=vmbr0; CT_IP_MODE=""; CT_GW=""; CT_IP=""
CT_CORES=2; CT_MEMORY=1536; CT_DISK=10
HOST_AGENT=""                           # yes | no: Beszel agent on this Proxmox host
UID_SHIFT=100000                        # unprivileged LXC: container uid N = host uid 100000+N
PASS_ARGS=()                            # install options handed to the installer inside

run_hint() { echo "bash -c \"\$(curl -fsSL $SCRIPT_URL)\"${1:+ _$1}"; }

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sMonitoring Stack: Uptime Kuma + Beszel + ntfy%s %sv%s · Proxmox VE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash monitoring.sh \[action\] \[options\]/Usage: bash monitoring.sh [action] [options]   (Proxmox VE host, as root)/;
                    /--install-dir=PATH/d'
  cat <<EOF

Proxmox options:
  --ctid=N                     Container ID (default: next free)
  --storage=NAME               Storage for the container disk (e.g. local-lvm, local-zfs)
  --bridge=NAME                Network bridge (default vmbr0)
  --ip=CIDR                    Container IP, e.g. 192.168.1.90/24 (default: asked, a free one
                               is suggested). "dhcp" works too, but then reserve the address.
  --gateway=IP                 Gateway (default: this host's)
  --cores=N --memory=MB --disk=GB
                               Container size (default 2 cores, 1536 MB, 10 GB)
  --host-agent | --no-host-agent
                               Beszel agent on this Proxmox host (default: yes)
  --settings-dir=PATH          Host folder for the settings (default $INSTALL_DIR)
EOF
}

copy_fn parse_args core_parse_args
parse_args() {
  local rest=() arg
  for arg in "$@"; do
    case $arg in
      --ctid=*) CTID=${arg#*=} ;;
      --storage=*) CT_STORAGE=${arg#*=} ;;
      --bridge=*) CT_BRIDGE=${arg#*=} ;;
      --ip=*) CT_IP_MODE=${arg#*=} ;;
      --gateway=*) CT_GW=${arg#*=} ;;
      --cores=*) CT_CORES=${arg#*=} ;;
      --memory=*) CT_MEMORY=${arg#*=} ;;
      --disk=*) CT_DISK=${arg#*=} ;;
      --host-agent) HOST_AGENT=yes ;;
      --no-host-agent) HOST_AGENT=no ;;
      --settings-dir=*|--install-dir=*) INSTALL_DIR=${arg#*=} ;;
      *) rest+=("$arg")
         # Install options go to the installer inside. Secrets travel as files, not arguments.
         case $arg in
           --install|--agent-cmd|--sync|--uninstall|--purge|--dry-run|-y|--yes|-h|--help) ;;
           --password=*|--password-file=*) ;;
           *) PASS_ARGS+=("$arg") ;;
         esac ;;
    esac
  done
  core_parse_args "${rest[@]}"
  [[ $CT_CORES =~ ^[0-9]+$ && $CT_MEMORY =~ ^[0-9]+$ && $CT_DISK =~ ^[0-9]+$ ]] ||
    { echo "--cores, --memory and --disk take numbers" >&2; exit 2; }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
px_ct_by_tag() { # → CTID of our container, if any
  local id
  for id in $(pct list 2>/dev/null | awk 'NR > 1 {print $1}'); do
    pct config "$id" 2>/dev/null | grep -qE "^tags:.*\b$CT_TAG\b" && { echo "$id"; return 0; }
  done
  return 1
}

px_mount_source() { # px_mount_source CTID container-path → host path of that bind mount
  pct config "$1" | awk -v mp="mp=$2" -F'[ ,]' '/^mp[0-9]+:/ {for (i = 1; i <= NF; i++) if ($i == mp) print $2}' | head -n1
}

px_ct_ip() { pct exec "$1" -- sh -c "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | head -n1; }
px_running() { [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') == running ]]; }
px_saved() { [[ -f $INSTALL_DIR/.proxmox ]] && sed -n "s/^$1=//p" "$INSTALL_DIR/.proxmox" | tail -n1 || true; }
px_storages() { pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}'; }

px_ip_in_use() { # px_ip_in_use IP → true if this host, a container or anything on the LAN has it
  local ip=$1 id
  [[ $ip == "$HOST_IP" || $ip == "$CT_GW" ]] && return 0
  for id in $(pct list 2>/dev/null | awk 'NR > 1 {print $1}'); do
    pct config "$id" 2>/dev/null | grep -qE "^net[0-9]+:.*[,=]ip=$ip/" && return 0
  done
  # A stale ARP entry (e.g. a container deleted a minute ago) isn't a user: ask afresh.
  ip neigh flush to "$ip" >/dev/null 2>&1 || true
  ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 0
  ip neigh show "$ip" 2>/dev/null | grep -qE 'lladdr .*(REACHABLE|STALE|DELAY|PROBE)'   # answered ARP but not ping (firewalled)
}

px_suggest_ip() { # a free address in this host's /24, easy to remember first
  local base=${HOST_IP%.*} n prev
  prev=$(px_saved CT_IP)
  [[ -n $prev ]] && ! px_ip_in_use "$prev" && { echo "$prev"; return 0; }
  for n in 90 91 92 93 94 95 240 241 242 243 244 245; do
    px_ip_in_use "$base.$n" || { echo "$base.$n"; return 0; }
  done
  return 1
}

# Pushes a secret into the container as a root-only file; prints its path there.
px_push_secret() { # px_push_secret name value
  local f="$SHL_TMP/$1" dst="/root/.shl-$1"
  ( umask 077; printf '%s\n' "$2" >"$f" )
  pct push "$CTID" "$f" "$dst" --perms 0600 >/dev/null
  rm -f "$f"
  echo "$dst"
}
px_drop_secrets() { pct exec "$CTID" -- sh -c 'rm -f /root/.shl-*' 2>/dev/null || true; }

# Runs the installer inside the container on this terminal (it draws its own
# live view and asks its own questions).
px_core() { # px_core args...
  pct push "$CTID" "$CORE_FILE" /root/monitoring.sh --perms 0755
  log "inner: pct exec $CTID -- bash /root/monitoring.sh $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
  local rc=0
  pct exec "$CTID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 SHL_NO_BANNER=1 "SHL_HINT_CMD=$(run_hint)" bash /root/monitoring.sh "$@" || rc=$?
  px_drop_secrets
  local inner
  inner=$(pct exec "$CTID" -- sh -c 'ls -t /var/log/sudohomelab/monitoring-*.log 2>/dev/null | head -n1' 2>/dev/null || true)
  if [[ -n $inner ]]; then
    INNER_LOG="$LOG_DIR/$(basename "$inner" .log)-ct$CTID.log"
    pct pull "$CTID" "$inner" "$INNER_LOG" 2>/dev/null && chmod 600 "$INNER_LOG" && log "inner log copied to $INNER_LOG"
  fi
  return "$rc"
}

px_need_root() {
  [[ $EUID -eq 0 ]] || die "Run this in the Proxmox host shell as root:  $(run_hint "${1:-}")"
  command -v pveversion >/dev/null 2>&1 && command -v pct >/dev/null 2>&1 ||
    die "This is the Proxmox version, but pveversion/pct aren't here. On Ubuntu/Debian use the Linux script."
}

px_start() {
  px_running && return 0
  run "Starting container $CTID" pct start "$CTID"
  local i
  for i in $(seq 1 30); do pct exec "$CTID" -- true >/dev/null 2>&1 && return 0; sleep 1; done
}

# ── Install: pre-flight (step 1) ─────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  px_need_root " --install"
  local ver major
  ver=$(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p')
  major=${ver%%.*}
  (( major >= 8 )) || die "Proxmox VE $ver is too old. This installer needs Proxmox VE 8 or newer."
  ok "Proxmox VE $ver on $(hostname)"
  local t
  for t in curl jq pveam pvesm pvesh ping; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing on this Proxmox host."; done
  ip -br link show "$CT_BRIDGE" >/dev/null 2>&1 || die "Network bridge '$CT_BRIDGE' doesn't exist (see --bridge)."
  BRIDGE_CIDR=$(ip -4 -o addr show dev "$CT_BRIDGE" 2>/dev/null | awk '{print $4; exit}')
  HOST_IP=${BRIDGE_CIDR%/*}; [[ -n $HOST_IP ]] || HOST_IP=$(host_ip)
  ok "Host IP: $HOST_IP ($CT_BRIDGE)"
  : "${CT_GW:=$(ip -4 route show default | awk '{print $3; exit}')}"
}

# ── Install: container choices (step 2) ──────────────────────────────────────
choose_container() {
  step "The container"
  local existing
  existing=$(px_ct_by_tag || true)
  if [[ -n $existing ]]; then
    CTID=$existing; CT_EXISTS=1
    local s
    s=$(px_mount_source "$CTID" "$CT_SETTINGS"); [[ -n $s ]] && INSTALL_DIR=$s
    CT_IP_MODE=$(pct config "$CTID" | sed -n 's/^net0:.*[ ,]ip=\([^,]*\).*/\1/p')
    info "Existing container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')) found: it'll be updated in place"
  else
    [[ -f $INSTALL_DIR/.proxmox ]] && info "Previous install found in $INSTALL_DIR: its monitors, history and logins come back"
    px_ask_new
  fi
  px_ask_host_agent

  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  if (( CT_EXISTS )); then
    printf '    %-12s %s\n' "Container" "$CTID (existing, updated in place) · ${CT_IP_MODE:-?}"
  else
    printf '    %-12s %s\n' "Container" "$CTID · Debian · $CT_CORES cores · $CT_MEMORY MB RAM · $CT_DISK GB disk on $CT_STORAGE"
    printf '    %-12s %s\n' "Address" "$CT_IP_MODE$( [[ $CT_IP_MODE != dhcp ]] && echo " via $CT_GW") on $CT_BRIDGE"
  fi
  printf '    %-12s %s\n' "Host agent" "$( [[ $HOST_AGENT == yes ]] && echo "Beszel agent on $(hostname) (system service, updates itself daily)" || echo no)"
  printf '    %-12s %s\n' "Guests" "Uptime Kuma also watches your other containers/VMs and the apps inside them"
  printf '    %-12s %s %s(host) → %s%s\n' "Settings" "$INSTALL_DIR" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  printf '    %-12s %s\n\n' "Then" "the Monitoring Stack questions (login, extras, which apps to watch) inside the container"
  if (( DRY_RUN )); then info "Dry run: nothing was changed."; exit 0; fi
  confirm "$( (( CT_EXISTS )) && echo "Continue?" || echo "Create the container?")" || { info "Cancelled. Nothing was changed."; exit 0; }
}

px_ask_new() {
  [[ -n $CTID ]] || CTID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')
  [[ $CTID =~ ^[0-9]+$ ]] || die "Couldn't get a free container ID (pvesh get /cluster/nextid)."
  pct status "$CTID" >/dev/null 2>&1 && die "Container ID $CTID is already in use. Pick another with --ctid=N."
  qm status "$CTID" >/dev/null 2>&1 && die "ID $CTID belongs to a VM. Pick another with --ctid=N."

  local storages n
  storages=$(px_storages)
  [[ -n $storages ]] || die "No active storage that can hold containers (content 'rootdir')."
  if [[ -z $CT_STORAGE ]]; then
    n=$(wc -l <<<"$storages")
    if (( n == 1 )); then CT_STORAGE=$storages; else
      local opts=() s def=1 i=1
      while read -r s; do
        opts+=("$s|$(pvesm status -storage "$s" 2>/dev/null | awk 'NR == 2 {printf "%s, %.0f GB free", $2, $6 / 1048576}')")
        [[ $s == local-lvm || $s == local-zfs ]] && def=$i; i=$((i + 1))
      done <<<"$storages"
      CT_STORAGE=$(sed -n "$(menu "Where should the container's disk live?" "$def" "${opts[@]}")p" <<<"$storages")
    fi
  fi
  grep -qx "$CT_STORAGE" <<<"$storages" || die "Storage '$CT_STORAGE' can't hold containers. Options: $(paste -sd, - <<<"$storages")"
  local free
  free=$(pvesm status -storage "$CT_STORAGE" 2>/dev/null | awk 'NR == 2 {printf "%.0f", $6 / 1048576}')
  [[ -z $free ]] || (( free >= CT_DISK )) ||
    die "Storage $CT_STORAGE has ${free} GB free; the container needs ${CT_DISK} GB. Free space, pick another --storage, or set --disk."

  # Agents on other machines and your phone connect to it: the address should stay put.
  local prefix=${BRIDGE_CIDR#*/} ipa interactive=0
  [[ $prefix =~ ^[0-9]+$ ]] || prefix=24
  (( ! ASSUME_YES )) && has_tty && interactive=1
  if [[ -z $CT_IP_MODE ]]; then
    local def
    def=$(px_suggest_ip || true)
    (( interactive )) && printf '\n  %sContainer address%s %s(Beszel agents and the ntfy app on your phone connect to it, so it should not change.\n   Pick one outside your router'"'"'s DHCP range, or reserve it in the router.)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while :; do
      ipa=$(ask "Static IP (or \"dhcp\")" "$def")
      [[ -n $ipa ]] || { (( interactive )) || die "No free address found: set one with --ip=CIDR."; warn "Type an address like ${HOST_IP%.*}.90"; continue; }
      [[ ${ipa,,} == dhcp ]] && { CT_IP_MODE=dhcp; break; }
      [[ $ipa == */* ]] || ipa="$ipa/$prefix"
      if [[ ! $ipa =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        (( interactive )) || die "Static IP must look like 192.168.1.90/24 (got '$ipa')."
        warn "That doesn't look like an address (e.g. ${HOST_IP%.*}.90)."; continue
      fi
      if [[ ${ipa%/*} != "$def" ]] && px_ip_in_use "${ipa%/*}"; then
        (( interactive )) || die "${ipa%/*} is already in use on your network."
        warn "${ipa%/*} is already in use on your network. Pick another."; continue
      fi
      CT_IP_MODE=$ipa; break
    done
    [[ $CT_IP_MODE == dhcp ]] || CT_GW=$(ask "Gateway (your router)" "$CT_GW")
  elif [[ $CT_IP_MODE != dhcp ]]; then
    [[ $CT_IP_MODE == */* ]] || CT_IP_MODE="$CT_IP_MODE/$prefix"
    [[ $CT_IP_MODE =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Static IP must look like 192.168.1.90/24 (got '$CT_IP_MODE')."
    px_ip_in_use "${CT_IP_MODE%/*}" && die "${CT_IP_MODE%/*} is already in use on your network. Pick another --ip."
  fi
  if [[ $CT_IP_MODE == dhcp ]]; then
    warn "With DHCP, reserve the container's address in your router, or agents and your phone lose the hub when it changes."
  else
    [[ $CT_GW =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "A static IP needs a gateway (--gateway=IP)."
  fi
  ok "Container $CTID on $CT_STORAGE, $CT_IP_MODE"
}

# The agent's settings, as Beszel's official installer wrote them (systemd).
host_agent_hub() {
  local f=/etc/systemd/system/beszel-agent.service
  [[ -f $f ]] || return 0
  sed -n 's/^Environment="\{0,1\}HUB_URL=\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -n1
}

px_ask_host_agent() {
  if [[ -z $HOST_AGENT ]]; then
    HOST_AGENT=$(px_saved HOST_AGENT)
    if [[ -z $HOST_AGENT ]]; then
      if (( ASSUME_YES )) || ! has_tty; then HOST_AGENT=yes
      else
        case $(menu "Beszel agent on this Proxmox host?" 1 \
          "Yes|see the host itself: CPU, RAM, disks, temperatures (recommended)" \
          "No|only the container is measured") in
          1) HOST_AGENT=yes ;; *) HOST_AGENT=no ;;
        esac
      fi
    fi
  fi
  local cur
  cur=$(host_agent_hub)
  if [[ $HOST_AGENT == yes && -n $cur ]] && [[ $cur != "http://$(px_saved CT_IP):"* || -z $(px_saved CT_IP) ]]; then
    warn "This host already has a Beszel agent, reporting to $cur."
    if (( ! ASSUME_YES )) && has_tty; then
      confirm "Move it to this stack's hub? (No keeps it where it is)" || HOST_AGENT=keep
    fi
  fi
  return 0
}

# ── Install: template (step 3) ───────────────────────────────────────────────
get_template() {
  step "Container template"
  if (( CT_EXISTS )); then ok "Using container $CTID"; return 0; fi
  TEMPLATE_STORE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')
  [[ -n $TEMPLATE_STORE ]] || die "No storage allows container templates (content 'vztmpl'). Enable it on 'local' in Datacenter → Storage."
  run "Refreshing the template list" px_template_update
  TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E '^debian-1[2-9]-standard_.*amd64' | sort -V | tail -n1)
  [[ -n $TEMPLATE ]] || die "No Debian template found in 'pveam available'. Check this host's internet access and DNS, then re-run."
  if px_have_template; then
    ok "Template $TEMPLATE already downloaded"
  else
    run "Downloading $TEMPLATE" px_template_download ||
      die "Couldn't download $TEMPLATE. Check this host's internet access and DNS (a router that answers with IPv6 only breaks it), or run: pveam download $TEMPLATE_STORE $TEMPLATE"
  fi
}

# pveam prints "update failed" / "download failed" but can still exit 0, so check
# the result ourselves.
px_have_template() { pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; }

# pveam downloads with wget. Some routers (e.g. AT&T gateways) drop the IPv4 answer
# when A and AAAA are asked together, so wget only gets an IPv6 address it can't
# reach. Without an IPv6 route, tell wget to use IPv4 only.
px_pveam() {
  if [[ -z $(ip -6 route show default 2>/dev/null) ]]; then
    local rc="$SHL_TMP/wgetrc"
    [[ -f $rc ]] || { cat /etc/wgetrc 2>/dev/null; echo "inet4_only = on"; } >"$rc"
    WGETRC=$rc pveam "$@"
  else
    pveam "$@"
  fi
}

px_template_update() {
  local i out
  for i in 1 2 3; do
    out=$(px_pveam update 2>&1) || true
    echo "$out"
    [[ $out != *failed* ]] && return 0
    echo "Template list refresh failed (attempt $i/3), retrying in 5s"
    sleep 5
  done
  echo "Using the cached template list"
}

px_template_download() {
  local i
  for i in 1 2 3; do
    px_pveam download "$TEMPLATE_STORE" "$TEMPLATE" || true
    px_have_template && return 0
    echo "Download failed (attempt $i/3), retrying in 5s"
    sleep 5
  done
  return 1
}

# ── Install: container (step 4) ──────────────────────────────────────────────
make_container() {
  step "Creating the container"
  mkdir -p "$INSTALL_DIR"
  chown "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR" 2>/dev/null || true; chmod 700 "$INSTALL_DIR"
  if (( CT_EXISTS )); then
    px_start
  else
    local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_MODE"
    [[ $CT_IP_MODE != dhcp ]] && net+=",gw=$CT_GW"
    # shellcheck disable=SC2054  # commas belong inside pct option values
    local args=(
      "$CTID" "$TEMPLATE_STORE:vztmpl/$TEMPLATE"
      --hostname "$CT_HOSTNAME" --tags "$CT_TAG" --description "sudo homelab Monitoring Stack (Uptime Kuma + Beszel + ntfy) · $SCRIPT_URL"
      --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --startup order=2 --timezone host
      --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 512
      --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net"
      --mp0 "$INSTALL_DIR,mp=$CT_SETTINGS"
    )
    run "Creating container $CTID (Debian, unprivileged, Docker-ready)" pct create "${args[@]}"
    run "Starting container $CTID" pct start "$CTID"
  fi

  local i ip=""
  for i in $(seq 1 60); do
    ip=$(px_ct_ip "$CTID" || true)
    [[ -n $ip ]] && pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
  done
  [[ -n $ip ]] || die "Container $CTID has no network after 2 minutes. Check bridge $CT_BRIDGE and the address."
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 ||
    die "Container $CTID ($ip) can't look up names. Check the gateway ($CT_GW) and this host's DNS (/etc/resolv.conf)."
  CT_IP=$ip
  printf 'CTID=%s\nCT_IP=%s\nHOST_AGENT=%s\n' "$CTID" "$CT_IP" "$HOST_AGENT" >"$INSTALL_DIR/.proxmox"
  chown "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR/.proxmox" 2>/dev/null || true
  ok "Container $CTID is up at $CT_IP"
}

# ── Your other guests (step 5) ───────────────────────────────────────────────
# Written to the settings folder as .extra-found: the installer inside reads it
# and offers these next to its own apps (same "found" line format, see the core).
#   · this host's web UI (port 8006)
#   · a ping for every container and VM that has an address
#   · inside each running container: the core's own app scan, pointed at the
#     container's address (http → url, TCP → tcp, DNS server = the container)
guest_ip_vm() { # guest_ip_vm VMID → first IPv4 from the guest agent (needs qemu-guest-agent)
  timeout 5 qm guest cmd "$1" network-get-interfaces 2>/dev/null |
    jq -r '[.[] | select(.name != "lo") | ."ip-addresses"[]? | select(."ip-address-type" == "ipv4") | ."ip-address"] | .[0] // empty' 2>/dev/null || true
}

guest_ip_ct() { # guest_ip_ct CTID → its address (running: live, stopped: the static one in its config)
  local ip=""
  [[ $(pct status "$1" 2>/dev/null | awk '{print $2}') == running ]] && ip=$(lxc-info -n "$1" -iH 2>/dev/null | grep -E '^[0-9]+\.' | grep -v '^172\.1[7-9]\.' | head -n1 || true)
  [[ -n $ip ]] || ip=$(pct config "$1" 2>/dev/null | sed -n 's/^net0:.*[ ,]ip=\([0-9.]*\)\/.*/\1/p')
  echo "$ip"
}

# The core's app scan, run inside a guest (read-only: docker ps, ss), as found
# lines for that guest's address.
scan_inside() { # scan_inside CTID ip name
  local id=$1 ip=$2 name=$3
  pct exec "$id" -- sh -c 'command -v bash >/dev/null' 2>/dev/null || return 0
  pct push "$id" "$CORE_FILE" /root/.shl-scan.sh --perms 0700 2>/dev/null || return 0
  pct exec "$id" -- bash -c 'SHL_LIBRARY=1; source /root/.shl-scan.sh; INSTALL_DIR=/nonexistent-shl; LOG_FILE=/dev/null; discover' 2>/dev/null </dev/null |
    awk -F'|' -v OFS='|' -v id="$id" -v ip="$ip" -v g="$name" '
      $1 == "s:ssh" || $3 == "docker" {next}           # SSH in every guest is noise; docker checks need its socket
      { $1 = "ct" id ":" $1; $2 = $2 " · " g; $6 = "CT " id " " g " · " $6 }
      $3 == "http" { $3 = "url"; $4 = "http://" ip ":" $5 $4; $5 = "" }
      $3 == "port" { $3 = "tcp"; $4 = ip }
      $3 == "dns"  { $4 = ip }
      {print}' || true
  pct exec "$id" -- rm -f /root/.shl-scan.sh 2>/dev/null || true
}

scan_guests() {
  local out="$INSTALL_DIR/.extra-found" tmp id status name ip line n=0
  tmp=$(mktemp "$SHL_TMP/extra.XXXXXX")
  echo "x:pve|Proxmox VE ($(hostname))|url|https://$HOST_IP:8006||Proxmox host|1" >>"$tmp"
  while read -r id status name; do
    [[ -n $id && $id != "$CTID" ]] || continue
    ip=$(guest_ip_ct "$id")
    if [[ $status == running && -n $ip ]]; then
      echo "g:ct$id|CT $id $name|ping|$ip||Proxmox guest|1" >>"$tmp"
      scan_inside "$id" "$ip" "$name" >>"$tmp"
      echo "CT $id ($name, $ip): scanned"
    else
      # Stopped: keep its ping and the apps the last scan found there (they show
      # as down). A DHCP guest has no address while stopped, so that comes from there too.
      line=$(grep -E "^(g:ct$id\||ct$id:)" "$INSTALL_DIR/$FOUND_FILE" 2>/dev/null || true)
      if [[ -n $line ]]; then
        while IFS= read -r line; do mark_found "$line" "stopped now"; done <<<"$line" >>"$tmp"
      elif [[ -n $ip ]]; then
        echo "g:ct$id|CT $id $name|ping|$ip||Proxmox guest (stopped now)|0" >>"$tmp"
      fi
      echo "CT $id ($name): $status"
    fi
  done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1, $2, $NF}')
  while read -r id name status; do
    [[ -n $id ]] || continue
    ip=""; [[ $status == running ]] && ip=$(guest_ip_vm "$id")
    if [[ -n $ip ]]; then echo "g:vm$id|VM $id $name|ping|$ip||Proxmox guest|1" >>"$tmp"; echo "VM $id ($name, $ip)"
    else echo "VM $id ($name): $status, no address known (install qemu-guest-agent in it to watch it)"; fi
  done < <(qm list 2>/dev/null | awk 'NR > 1 {print $1, $2, $3}')
  n=$(grep -c . "$tmp" || true)
  # The container's root is host uid $UID_SHIFT (unprivileged): it must be able to read it.
  install -m 600 -o "$UID_SHIFT" -g "$UID_SHIFT" "$tmp" "$out"
  echo "$n guest checks offered"
}

# ── Install: inside the container (step 6) ───────────────────────────────────
inner_install() {
  step "Installing the Monitoring Stack inside container $CTID"
  local a=(--install "${PASS_ARGS[@]}")
  (( ASSUME_YES )) || ! has_tty && a+=(--yes)
  [[ -n $APP_PASS ]] && a+=("--password-file=$(px_push_secret pass "$APP_PASS")")
  info "Live output from inside the container (its questions too):"
  px_core "${a[@]}" || die "The installer inside container $CTID failed. Its log: ${INNER_LOG:-/var/log/sudohomelab/ in the container}"
}

# ── Install: the agent on this host (step 7) ─────────────────────────────────
px_agent_file() {
  if [[ -n ${AGENT_FILE:-} && -f $AGENT_FILE ]]; then echo "$AGENT_FILE"; return; fi
  local f="$SHL_TMP/beszel-agent.sh"
  curl -fsSL "$AGENT_LIB_URL" -o "$f" && echo "$f"
}

host_agent() {
  step "Beszel agent on this host"
  case $HOST_AGENT in
    no) info "Skipped (--host-agent adds it later)"; return 0 ;;
    keep) info "Kept the existing agent (it reports to $(host_agent_hub))"; return 0 ;;
  esac
  local key token port f hub
  key=$(sed -n 's/^BESZEL_KEY=//p' "$INSTALL_DIR/.state" | tail -n1)
  token=$(sed -n 's/^BESZEL_TOKEN=//p' "$INSTALL_DIR/.secrets")
  port=$(sed -n 's/^P_BESZEL=//p' "$INSTALL_DIR/.state" | tail -n1)
  [[ -n $key && -n $token ]] || { warn "No agent key/token saved by the installer: skipped."; return 0; }
  hub="http://$CT_IP:${port:-8090}"
  if [[ $(host_agent_hub) == "$hub" ]] && systemctl is-active --quiet beszel-agent; then
    ok "This host's agent already reports to $hub"; return 0
  fi
  f=$(px_agent_file) || die "Couldn't download the agent script from $AGENT_LIB_URL"
  ( umask 077; printf '%s\n' "$token" >"$SHL_TMP/agent-token" )
  # A host agent for another hub is replaced (asked earlier); the official installer only keeps one.
  if [[ -n $(host_agent_hub) ]]; then
    run "Removing the old agent (it reported to $(host_agent_hub))" bash "$f" --uninstall --yes
  fi
  info "Agent setup (the agent script's own output):"
  bash "$f" --hub="$hub" --key="$key" --token-file="$SHL_TMP/agent-token" --mode=service --yes </dev/null ||
    { warn "The host agent didn't install; the stack works without it. Retry:  $(run_hint " --install")"; return 0; }
  # Give the new machine the default alerts (down, CPU, RAM, disk).
  sleep 3
  px_core --sync --yes --monitor=known >/dev/null 2>&1 || true
  ok "$(hostname) gets the default Beszel alerts"
}

px_install() {
  START_TIME=$SECONDS
  (( BANNER_SHOWN )) || banner
  preflight
  choose_container
  get_template
  make_container
  step "Looking at your other guests"
  run "Scanning containers and VMs on this host" scan_guests
  inner_install
  host_agent
  px_summary
  log "install finished"
}

px_summary() {
  step "Done"
  local port
  port=$(sed -n 's/^P_BESZEL=//p' "$INSTALL_DIR/.state" | tail -n1)
  printf '\n  %s%s★ Container %s (%s) runs your Monitoring Stack at %s%s\n' "$C_BOLD" "$C_GREEN" "$CTID" "$CT_HOSTNAME" "$CT_IP" "$C_RESET"
  printf '    %sThe logins and links are in the summary above, and in %s/credentials.txt (host, root only).%s\n' "$C_GRAY" "$INSTALL_DIR" "$C_RESET"
  if systemctl is-active --quiet beszel-agent 2>/dev/null; then
    printf '    %s%-11s%s %s reports to %s\n' "$C_BOLD" "Host agent" "$C_RESET" "$(hostname)" "$(host_agent_hub)"
  fi
  printf '    %sNew guests:%s %s   %s(adds their checks to Uptime Kuma)%s\n' "$C_GRAY" "$C_RESET" "$(run_hint " --sync")" "$C_GRAY" "$C_RESET"
  printf '    %sMenu:%s       %s   %s(install · add a machine · re-scan · uninstall)%s\n' "$C_GRAY" "$C_RESET" "$(run_hint)" "$C_GRAY" "$C_RESET"
  printf '    %sShell:%s      pct enter %s   %s(then: cd %s && docker compose ps)%s\n' "$C_GRAY" "$C_RESET" "$CTID" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  printf '    %sSettings:%s   %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR" "$CT_SETTINGS"
  printf '    %sLogs:%s       %s%s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE" "${INNER_LOG:+ and $INNER_LOG}"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s       %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
  printf '  %sBack it up:%s Datacenter → Backup, or  vzdump %s --mode snapshot\n\n' "$C_GRAY" "$C_RESET" "$CTID"
}

# ── Add a machine / re-scan (run inside) ─────────────────────────────────────
px_inside() { # px_inside action → finds the container, then runs the core with that action
  (( BANNER_SHOWN )) || banner
  px_need_root " --$1"
  CTID=$(px_ct_by_tag || true)
  [[ -n $CTID ]] || die "No Monitoring Stack container yet. Install first:  $(run_hint " --install")"
  local s; s=$(px_mount_source "$CTID" "$CT_SETTINGS"); [[ -n $s ]] && INSTALL_DIR=$s
  px_start
  CT_IP=$(px_ct_ip "$CTID")
  local a=("--$1" "${PASS_ARGS[@]}")
  (( ASSUME_YES )) && a+=(--yes)
  if [[ $1 == sync ]]; then
    BRIDGE_CIDR=$(ip -4 -o addr show dev "$CT_BRIDGE" 2>/dev/null | awk '{print $4; exit}')
    HOST_IP=${BRIDGE_CIDR%/*}; [[ -n $HOST_IP ]] || HOST_IP=$(host_ip)
    run "Scanning containers and VMs on this host" scan_guests
  fi
  px_core "${a[@]}" || exit $?
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  (( BANNER_SHOWN )) || banner
  px_need_root " --uninstall"
  local s agent=0
  [[ -n $(host_agent_hub) ]] && [[ $(host_agent_hub) == "http://$(px_saved CT_IP):"* ]] && agent=1
  CTID=$(px_ct_by_tag || true)
  if [[ -z $CTID ]]; then
    # Uninstalled earlier with the settings kept: only those are left.
    [[ -f $INSTALL_DIR/.proxmox ]] || die "No sudo homelab Monitoring Stack container (tag $CT_TAG) on this host."
    info "The container is already gone; its settings are still in $INSTALL_DIR."
    if (( PURGE )) || confirm_no "Delete them too?"; then
      (( PURGE )) || confirm "Delete $INSTALL_DIR (monitors, history, accounts, tokens)?" || { info "Cancelled. Nothing was changed."; exit 0; }
      run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"
      ok "Uninstalled."
    else
      info "Kept. Run Install to bring everything back, or --uninstall --purge to delete them."
    fi
    return 0
  fi
  s=$(px_mount_source "$CTID" "$CT_SETTINGS")
  warn "This stops and deletes container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')): Uptime Kuma, Beszel, ntfy."
  (( agent )) && warn "This host's Beszel agent reports to it, so it's removed too."
  warn "Agents on other machines keep running but have no hub to report to."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|monitors, history, logins and tokens stay in ${s:-?} for a reinstall" \
      "Delete it|also delete all monitors, history, accounts and tokens") in
      2) PURGE=1 ;;
    esac
  fi
  if (( PURGE )); then warn "All data in ${s:-?} on the host (monitors, history, accounts, tokens) will be deleted."
  else info "The data stays in ${s:-?} on the host (run Install again to bring everything back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  if (( agent )); then
    local f; f=$(px_agent_file) && run "Removing this host's Beszel agent" bash "$f" --uninstall --yes || warn "Couldn't remove the host agent: run beszel-agent.sh --uninstall"
  fi
  px_running && run "Stopping container $CTID" pct stop "$CTID"
  run "Deleting container $CTID" pct destroy "$CTID" --purge 1
  if [[ -n $s && $s != / && -d $s ]] && (( PURGE )); then run "Deleting $s" rm -rf "$s"; fi
  ok "Uninstalled."
}

# ── Menu + actions (the core's menu loop calls these) ────────────────────────
run_action() {
  log "action: $ACTION"
  case $ACTION in
    uninstall) uninstall ;;
    agent) px_inside agent-cmd ;;
    sync) px_inside sync ;;
    *) px_install ;;
  esac
}

choose_action() {
  (( BANNER_SHOWN )) || { banner; BANNER_SHOWN=1; }
  local installed=0
  [[ -n $(px_ct_by_tag || true) ]] && installed=1
  case $(menu "What would you like to do?" 1 \
    "Install|$( (( installed )) && echo "already installed: re-run the setup to change settings" || echo "a small container with Uptime Kuma + Beszel + ntfy, watching this host and its guests")" \
    "Add a machine|show the command that adds another computer to Beszel" \
    "Re-scan apps|look for new guests and apps, and update Uptime Kuma's monitors" \
    "Uninstall|delete the container (asks whether to keep the data)" \
    "Quit|close the menu") in
    1) ACTION=install ;; 2) ACTION=agent ;; 3) ACTION=sync ;; 4) ACTION=uninstall ;; 5) ACTION=quit ;;
  esac
}

main "$@"
