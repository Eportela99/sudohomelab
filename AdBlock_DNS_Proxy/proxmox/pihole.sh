#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Private DNS Stack (Pi-hole + Unbound + Nginx Proxy Manager)
#  for Proxmox VE 8 / 9
#  https://github.com/Eportela99/sudohomelab
#
#  Run on the Proxmox host shell (as root). It creates one small unprivileged
#  Debian LXC with a fixed IP (a DNS server must not move), optionally joins it
#  to your tailnet, and runs the Ubuntu/Debian installer inside it: same
#  questions, same blocklists, same app names.
#
#    Proxmox host
#     └── LXC "pihole" (tag sudohomelab-dns, static IP)
#          └── /opt/sudohomelab/pihole  ← settings (host: --settings-dir)
#
#  Usage (Proxmox shell; no options = a menu):
#    bash -c "$(curl -fsSL <url>/AdBlock_DNS_Proxy/proxmox/pihole.sh)"
#    bash -c "$(curl -fsSL <url>)" _ --add=jellyfin=192.168.1.50:8096
#    bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PX_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy"
LIB_URL="$PX_REPO_RAW/linux/pihole.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
px_load_core() {
  local here=""
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/pihole.sh ]]; then
    CORE_FILE="$here/../linux/pihole.sh"
  else
    CORE_FILE=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$CORE_FILE" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
  fi
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$CORE_FILE"
}
px_load_core

# ── Proxmox defaults ──────────────────────────────────────────────────────────
VERSION="0.1.0-proxmox (core $VERSION)"
SCRIPT_URL="$PX_REPO_RAW/proxmox/pihole.sh"
LOG_FILE="$LOG_DIR/pihole-proxmox-$(date +%Y%m%d-%H%M%S).log"
TOTAL_STEPS=7
INSTALL_DIR="/opt/sudohomelab/pihole"   # settings on the HOST, mounted into the container
CT_TAG="sudohomelab-dns"
CT_SETTINGS=/opt/sudohomelab/pihole
CT_HOSTNAME=pihole
CTID=""; CT_EXISTS=0; CT_STORAGE=""; CT_BRIDGE=vmbr0; CT_IP_MODE=""; CT_GW=""; CT_IP=""
CT_CORES=2; CT_MEMORY=1024; CT_DISK=8
TAILSCALE=""; TS_KEY_FILE=""; TS_IP=""
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
  printf '    %s❯%s %sPi-hole + Unbound + Nginx Proxy Manager%s %sv%s · Proxmox VE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash pihole.sh \[action\] \[options\]/Usage: bash pihole.sh [action] [options]   (Proxmox VE host, as root)/;
                    /--install-dir=PATH/d'
  cat <<EOF

Proxmox options:
  --ctid=N                           Container ID (default: next free)
  --storage=NAME                     Storage for the container disk (e.g. local-lvm, local-zfs)
  --bridge=NAME                      Network bridge (default vmbr0)
  --ip=CIDR                          Container IP, e.g. 192.168.1.53/24 (default: asked, a free one
                                     is suggested). "dhcp" works too, but then reserve the address.
  --gateway=IP                       Gateway (default: this host's)
  --cores=N --memory=MB --disk=GB    Container size (default 2 cores, 1024 MB, 8 GB)
  --tailscale | --no-tailscale       Put the container on your tailnet (default: asked, no)
  --tailscale-key-file=FILE          Tailscale auth key (tskey-auth-…) in a file; without one
                                     you log in with a link
  --settings-dir=PATH                Host folder for the settings (default $INSTALL_DIR)
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
      --tailscale) TAILSCALE=yes ;;
      --no-tailscale) TAILSCALE=no ;;
      --tailscale-key-file=*) TS_KEY_FILE=${arg#*=} ;;
      --settings-dir=*|--install-dir=*) INSTALL_DIR=${arg#*=} ;;
      *) rest+=("$arg")
         # Install options go to the installer inside. Secrets travel as files, not arguments.
         case $arg in
           --install|--list|--add|--add=*|--delete|--delete=*|--uninstall|--purge|--dry-run|-y|--yes|-h|--help) ;;
           --password=*|--password-file=*|--cloudflare-token=*|--cloudflare-token-file=*) ;;
           *) PASS_ARGS+=("$arg") ;;
         esac ;;
    esac
  done
  core_parse_args "${rest[@]}"
  [[ -z $TS_KEY_FILE || -r $TS_KEY_FILE ]] || { echo "Can't read $TS_KEY_FILE" >&2; exit 2; }
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
px_ts_ip() { pct exec "$CTID" -- tailscale ip -4 2>/dev/null | head -n1 || true; }
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
  for n in 53 253 252 251 250 249 248 54 55 56 57 58; do
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
  pct push "$CTID" "$CORE_FILE" /root/pihole.sh --perms 0755
  log "inner: pct exec $CTID -- bash /root/pihole.sh $(sed -E 's/(--(password|cloudflare-token)=)[^ ]*/\1***/g' <<<"$*")"
  local rc=0
  pct exec "$CTID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 SHL_NO_BANNER=1 "SHL_HINT_CMD=$(run_hint)" bash /root/pihole.sh "$@" || rc=$?
  px_drop_secrets
  local inner
  inner=$(pct exec "$CTID" -- sh -c 'ls -t /var/log/sudohomelab/pihole-*.log 2>/dev/null | head -n1' 2>/dev/null || true)
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
  local ver major minor
  ver=$(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p')
  major=${ver%%.*}; minor=$(cut -d. -f2 <<<"$ver")
  (( major >= 8 )) || die "Proxmox VE $ver is too old. This installer needs Proxmox VE 8 or newer."
  PVE_DEV_OK=$(( major > 8 || (major == 8 && minor >= 2) ))   # devN passthrough
  ok "Proxmox VE $ver on $(hostname)"
  local t
  for t in curl pveam pvesm pvesh ping; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing on this Proxmox host."; done
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
    [[ -z $TAILSCALE && $(px_saved TAILSCALE) == yes ]] && TAILSCALE=yes
  else
    [[ -f $INSTALL_DIR/.proxmox ]] && info "Previous install found in $INSTALL_DIR: its settings, lists and app names come back"
    px_ask_new
  fi
  px_ask_tailscale

  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  if (( CT_EXISTS )); then
    printf '    %-12s %s\n' "Container" "$CTID (existing, updated in place) · ${CT_IP_MODE:-?}"
  else
    printf '    %-12s %s\n' "Container" "$CTID · Debian · $CT_CORES cores · $CT_MEMORY MB RAM · $CT_DISK GB disk on $CT_STORAGE"
    printf '    %-12s %s\n' "Address" "$CT_IP_MODE$( [[ $CT_IP_MODE != dhcp ]] && echo " via $CT_GW") on $CT_BRIDGE"
  fi
  printf '    %-12s %s\n' "Tailscale" "$( [[ $TAILSCALE == yes ]] && echo "yes (hostname $CT_HOSTNAME)" || echo no)"
  printf '    %-12s %s %s(host) → %s%s\n' "Settings" "$INSTALL_DIR" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  printf '    %-12s %s\n\n' "Then" "the Pi-hole questions (blocklists, upstream, app names) inside the container"
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

  # A DNS server needs an address that never changes.
  local prefix=${BRIDGE_CIDR#*/} ipa interactive=0
  [[ $prefix =~ ^[0-9]+$ ]] || prefix=24
  (( ! ASSUME_YES )) && has_tty && interactive=1
  if [[ -z $CT_IP_MODE ]]; then
    local def
    def=$(px_suggest_ip || true)
    (( interactive )) && printf '\n  %sContainer address%s %s(your devices will use it as their DNS server, so it must not change.\n   Pick one outside your router'"'"'s DHCP range, or reserve it in the router.)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while :; do
      ipa=$(ask "Static IP (or \"dhcp\")" "$def")
      [[ -n $ipa ]] || { (( interactive )) || die "No free address found: set one with --ip=CIDR."; warn "Type an address like ${HOST_IP%.*}.53"; continue; }
      [[ ${ipa,,} == dhcp ]] && { CT_IP_MODE=dhcp; break; }
      [[ $ipa == */* ]] || ipa="$ipa/$prefix"
      if [[ ! $ipa =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        (( interactive )) || die "Static IP must look like 192.168.1.53/24 (got '$ipa')."
        warn "That doesn't look like an address (e.g. ${HOST_IP%.*}.53)."; continue
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
    [[ $CT_IP_MODE =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Static IP must look like 192.168.1.53/24 (got '$CT_IP_MODE')."
    px_ip_in_use "${CT_IP_MODE%/*}" && die "${CT_IP_MODE%/*} is already in use on your network. Pick another --ip."
  fi
  if [[ $CT_IP_MODE == dhcp ]]; then
    warn "With DHCP, reserve the container's address in your router, or your devices lose DNS when it changes."
  else
    [[ $CT_GW =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "A static IP needs a gateway (--gateway=IP)."
  fi
  ok "Container $CTID on $CT_STORAGE, $CT_IP_MODE"
}

px_ask_tailscale() {
  if [[ -z $TAILSCALE ]]; then
    if (( ASSUME_YES )) || ! has_tty; then TAILSCALE=no
    else
      case $(menu "Tailscale in the container?" 2 \
        "Yes|use Pi-hole and the app names from anywhere on your tailnet (you log in once)" \
        "No|local network only (add it later by running Install again)") in
        1) TAILSCALE=yes ;; *) TAILSCALE=no ;;
      esac
    fi
  fi
  [[ $TAILSCALE == yes && -n $TS_KEY_FILE ]] && ok "Tailscale auth key from $TS_KEY_FILE"
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
px_has_tun() { pct config "$CTID" | grep -qE '^(dev[0-9]+: (path=)?/dev/net/tun|lxc\.mount\.entry: /dev/net/tun)'; }

px_add_tun() { # Tailscale needs /dev/net/tun in the container
  if (( PVE_DEV_OK )); then
    local i=0
    while pct config "$CTID" | grep -q "^dev$i:"; do i=$((i + 1)); done
    pct set "$CTID" --"dev$i" /dev/net/tun
  else
    printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >>"/etc/pve/lxc/$CTID.conf"
  fi
}

make_container() {
  step "Creating the container"
  mkdir -p "$INSTALL_DIR"
  chown "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR" 2>/dev/null || true; chmod 700 "$INSTALL_DIR"
  if (( CT_EXISTS )); then
    if [[ $TAILSCALE == yes ]] && ! px_has_tun; then
      run "Giving container $CTID a network tunnel device (for Tailscale)" px_add_tun
      px_running && run "Restarting container $CTID" pct reboot "$CTID"
    fi
    px_start
  else
    local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_MODE"
    [[ $CT_IP_MODE != dhcp ]] && net+=",gw=$CT_GW"
    # shellcheck disable=SC2054  # commas belong inside pct option values
    local args=(
      "$CTID" "$TEMPLATE_STORE:vztmpl/$TEMPLATE"
      --hostname "$CT_HOSTNAME" --tags "$CT_TAG" --description "sudo homelab private DNS (Pi-hole) · $SCRIPT_URL"
      --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --startup order=1 --timezone host
      --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 512
      --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net"
      --mp0 "$INSTALL_DIR,mp=$CT_SETTINGS"
    )
    run "Creating container $CTID (Debian, unprivileged, Docker-ready)" pct create "${args[@]}"
    [[ $TAILSCALE == yes ]] && run "Giving it a network tunnel device (for Tailscale)" px_add_tun
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
  printf 'CTID=%s\nCT_IP=%s\nTAILSCALE=%s\n' "$CTID" "$CT_IP" "$TAILSCALE" >"$INSTALL_DIR/.proxmox"
  ok "Container $CTID is up at $CT_IP"
}

# ── Install: Tailscale (step 5, optional) ────────────────────────────────────
px_tailscale() {
  step "Tailscale"
  [[ $TAILSCALE == yes ]] || { info "Not used (to add it later, run Install again and choose Tailscale)"; return 0; }
  if ! pct exec "$CTID" -- sh -c 'command -v tailscale' >/dev/null 2>&1; then
    run "Installing Tailscale" pct exec "$CTID" -- bash -c '
      export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
      command -v curl >/dev/null || { apt-get update && apt-get -y install --no-install-recommends curl ca-certificates; }
      curl -fsSL https://tailscale.com/install.sh | sh'
  fi
  pct exec "$CTID" -- systemctl enable --now tailscaled >/dev/null 2>&1 || true
  TS_IP=$(px_ts_ip)
  if [[ -n $TS_IP ]]; then
    pct exec "$CTID" -- tailscale set --accept-dns=false >/dev/null 2>&1 || true
    ok "Already on your tailnet: $TS_IP"; return 0
  fi
  local key="" up=(tailscale up --accept-dns=false "--hostname=$CT_HOSTNAME")
  [[ -n $TS_KEY_FILE ]] && key=$(head -n1 "$TS_KEY_FILE" | tr -d '\r\n')
  if [[ -z $key ]] && (( ! ASSUME_YES )) && has_tty; then
    printf '\n  %sJoin your tailnet%s %s(an auth key from login.tailscale.com → Settings → Keys, or log in with a link)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    key=$(ask_secret "Auth key (tskey-auth-…), or Enter for a login link:")
  fi
  if [[ -n $key ]]; then
    up+=("--auth-key=file:$(px_push_secret tskey "$key")")
    run "Joining your tailnet" pct exec "$CTID" -- "${up[@]}" || { px_drop_secrets; die "Tailscale didn't accept the auth key (expired or used up?). Make a new one and run Install again."; }
    px_drop_secrets
  elif (( ! ASSUME_YES )) && has_tty; then
    info "Open the link Tailscale prints to add this container to your tailnet (waits up to 10 minutes):"
    pct exec "$CTID" -- "${up[@]}" --timeout=10m || warn "Not logged in. Later: pct exec $CTID -- tailscale up --accept-dns=false"
  else
    warn "No auth key (--tailscale-key-file): join later with  pct exec $CTID -- tailscale up --accept-dns=false"
    return 0
  fi
  TS_IP=$(px_ts_ip)
  [[ -n $TS_IP ]] && ok "On your tailnet: $TS_IP ($CT_HOSTNAME)"
  return 0
}

# ── Install: Pi-hole inside (last steps) ─────────────────────────────────────
inner_install() {
  step "Installing Pi-hole inside container $CTID"
  local a=(--install "${PASS_ARGS[@]}")
  (( ASSUME_YES )) || ! has_tty && a+=(--yes)
  [[ -n $APP_PASS ]] && a+=("--password-file=$(px_push_secret pass "$APP_PASS")")
  [[ -n $CF_TOKEN ]] && a+=("--cloudflare-token-file=$(px_push_secret cftoken "$CF_TOKEN")")
  info "Live output from inside the container (its questions too):"
  px_core "${a[@]}" || die "The installer inside container $CTID failed. Its log: ${INNER_LOG:-/var/log/sudohomelab/ in the container}"
}

px_install() {
  START_TIME=$SECONDS
  (( BANNER_SHOWN )) || banner
  preflight
  choose_container
  get_template
  make_container
  px_tailscale
  inner_install
  px_summary
  log "install finished"
}

px_summary() {
  step "Done"
  [[ $TAILSCALE == yes ]] && TS_IP=$(px_ts_ip)
  printf '\n  %s%s★ Container %s (%s) is your DNS server%s\n' "$C_BOLD" "$C_GREEN" "$CTID" "$CT_HOSTNAME" "$C_RESET"
  printf '    %s%-11s%s %s%s%s  %s← set this as the DNS server in your router%s\n' "$C_BOLD" "DNS server" "$C_RESET" "$C_CYAN" "$CT_IP" "$C_RESET" "$C_GRAY" "$C_RESET"
  if [[ $TAILSCALE == yes ]]; then
    if [[ -n $TS_IP ]]; then
      printf '    %s%-11s%s %s  %s(Tailscale admin → DNS → Add nameserver → Custom; the steps are above)%s\n' "$C_BOLD" "Tailscale" "$C_RESET" "$TS_IP" "$C_GRAY" "$C_RESET"
      [[ $(state_get DNS_ACCESS) == all ]] ||
        printf '    %s%-11s%s Pi-hole answers your local network only. To use it over Tailscale, run Install again and choose "Any network".\n' "$C_YELLOW" "!" "$C_RESET"
    else
      printf '    %s%-11s%s not logged in yet:  pct exec %s -- tailscale up --accept-dns=false\n' "$C_BOLD" "Tailscale" "$C_RESET" "$CTID"
    fi
  fi
  printf '    %sMenu:%s       %s   %s(install · list/add/delete names · uninstall)%s\n' "$C_GRAY" "$C_RESET" "$(run_hint)" "$C_GRAY" "$C_RESET"
  printf '    %sShell:%s      pct enter %s   %s(then: cd %s && docker compose ps)%s\n' "$C_GRAY" "$C_RESET" "$CTID" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  printf '    %sSettings:%s   %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR" "$CT_SETTINGS"
  printf '    %sLogin:%s      %s/credentials.txt (host, root only)\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR"
  printf '    %sLogs:%s       %s%s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE" "${INNER_LOG:+ and $INNER_LOG}"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s       %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
  printf '  %sBack it up:%s Datacenter → Backup, or  vzdump %s --mode snapshot\n\n' "$C_GRAY" "$C_RESET" "$CTID"
}

# ── List / add / delete names (run inside) ───────────────────────────────────
px_manage() {
  (( BANNER_SHOWN )) || banner
  px_need_root " --$ACTION"
  CTID=$(px_ct_by_tag || true)
  [[ -n $CTID ]] || die "No DNS container yet. Install first:  $(run_hint " --install")"
  px_start
  local a
  case $ACTION in
    list) a=(--list) ;;
    add) a=("--add${ADD_SPEC:+=$ADD_SPEC}") ;;
    delete) a=("--delete${DELETE_NAME:+=$DELETE_NAME}") ;;
  esac
  (( ASSUME_YES )) && a+=(--yes)
  px_core "${a[@]}" || exit $?
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  (( BANNER_SHOWN )) || banner
  px_need_root " --uninstall"
  local s
  CTID=$(px_ct_by_tag || true)
  if [[ -z $CTID ]]; then
    # Uninstalled earlier with the settings kept: only those are left.
    [[ -f $INSTALL_DIR/.proxmox ]] || die "No sudo homelab DNS container (tag $CT_TAG) on this host."
    info "The container is already gone; its settings are still in $INSTALL_DIR."
    if (( PURGE )) || confirm_no "Delete them too?"; then
      (( PURGE )) || confirm "Delete $INSTALL_DIR (settings, app names, certificates, query history)?" || { info "Cancelled. Nothing was changed."; exit 0; }
      run "Deleting $INSTALL_DIR" rm -rf "$INSTALL_DIR"
      ok "Uninstalled."
    else
      info "Kept. Run Install to bring everything back, or --uninstall --purge to delete them."
    fi
    return 0
  fi
  s=$(px_mount_source "$CTID" "$CT_SETTINGS")
  warn "This stops and deletes container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')). Devices using it for DNS lose"
  warn "name lookups until you point your router back to another DNS server, and the app names stop working."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the settings?" 1 \
      "Keep them|settings, lists, app names and certificates stay in ${s:-?} for a reinstall" \
      "Delete them|also delete all settings, app names, certificates and query history") in
      2) PURGE=1 ;;
    esac
  fi
  if (( PURGE )); then warn "All settings in ${s:-?} on the host (lists, app names, certificates, query history) will be deleted."
  else info "The settings stay in ${s:-?} on the host (run Install again to bring everything back)."; fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  local ts=0
  if px_running; then
    if pct exec "$CTID" -- sh -c 'command -v tailscale' >/dev/null 2>&1 && [[ -n $(px_ts_ip) ]]; then
      ts=1; run "Leaving your tailnet" pct exec "$CTID" -- tailscale logout || true
    fi
    run "Stopping container $CTID" pct stop "$CTID"
  fi
  run "Deleting container $CTID" pct destroy "$CTID" --purge 1
  if [[ -n $s && $s != / && -d $s ]]; then
    if (( PURGE )); then run "Deleting $s" rm -rf "$s"
    else sed -i 's/^TAILSCALE=.*/TAILSCALE=no/' "$s/.proxmox" 2>/dev/null || true; fi
  fi
  (( ts )) && info "Tailscale: remove the old '$CT_HOSTNAME' machine in the admin console (login.tailscale.com → Machines)."
  ok "Uninstalled."
}

# ── Menu + actions (the core's menu loop calls these) ────────────────────────
run_action() {
  log "action: $ACTION"
  case $ACTION in
    uninstall) uninstall ;;
    list|add|delete) px_manage ;;
    *) px_install ;;
  esac
}

choose_action() {
  (( BANNER_SHOWN )) || { banner; BANNER_SHOWN=1; }
  local installed=0 dom
  [[ -n $(px_ct_by_tag || true) ]] && installed=1
  dom=$(state_get DOMAIN); dom=${dom:-home}
  case $(menu "What would you like to do?" 1 \
    "Install|$( (( installed )) && echo "already installed: re-run the setup to change settings" || echo "a small container with Pi-hole + Unbound + Nginx Proxy Manager")" \
    "List domains|the app names and the address each one points to" \
    "Add domain|an app's address + a name, e.g. 192.168.1.50:8096 → jellyfin.$dom" \
    "Delete domain|remove an app name (the app itself isn't touched)" \
    "Uninstall|delete the container (asks whether to keep the settings)" \
    "Quit|close the menu") in
    1) ACTION=install ;; 2) ACTION=list ;; 3) ACTION=add ;; 4) ACTION=delete ;; 5) ACTION=uninstall ;; 6) ACTION=quit ;;
  esac
}

main "$@"
