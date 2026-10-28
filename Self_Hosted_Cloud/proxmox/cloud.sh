#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Cloud Stack (Nextcloud + Office, Photos, Passwords, PDF, Notes)
#  for Proxmox VE 8 / 9
#  https://github.com/Eportela99/sudohomelab
#
#  Run on the Proxmox host shell (as root). It creates one unprivileged Debian
#  LXC with a fixed IP and runs the Ubuntu/Debian installer inside it (same
#  questions, same wiring). Your files and the apps' settings live in folders on
#  the host, mounted into the container, so they survive a rebuild:
#
#    Proxmox host
#     ├── /srv/cloud              ← your files (Documents, Notes, Photos…; --data-dir)
#     ├── /opt/sudohomelab/cloud  ← settings + databases (--settings-dir)
#     └── LXC "cloud" (tag sudohomelab-cloud, static IP)
#          └── Nextcloud, Collabora, Immich, Vaultwarden, Stirling PDF, Obsidian
#
#  With the Private DNS Stack on this host too, it adds the app names
#  (cloud.home, photos.home…) to it for you.
#
#  Usage (Proxmox shell; no options = a menu):
#    bash -c "$(curl -fsSL <url>/Self_Hosted_Cloud/proxmox/cloud.sh)"
#    bash -c "$(curl -fsSL <url>)" _ --install --memory=8192 --disk=40
#    bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PX_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main"
LIB_URL="$PX_REPO_RAW/Self_Hosted_Cloud/linux/cloud.sh"
DNS_PX_URL="$PX_REPO_RAW/AdBlock_DNS_Proxy/proxmox/pihole.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
# The guard line (no auto-run as a library) and the names hook must both be there.
px_core_ok() { grep -q '^\[\[ \${SHL_LIBRARY:-0} == 1 \]\] || main' "$CORE_FILE" 2>/dev/null && grep -q 'SHL_NAMES_BY_WRAPPER' "$CORE_FILE"; }
px_load_core() {
  local here=""
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/cloud.sh ]]; then
    CORE_FILE="$here/../linux/cloud.sh"
    DNS_PX_FILE="$here/../../AdBlock_DNS_Proxy/proxmox/pihole.sh"
  else
    CORE_FILE=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$CORE_FILE" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
    # Right after a release GitHub can still serve an older core for a few minutes.
    px_core_ok || curl -fsSL "$LIB_URL?t=$(date +%s)" -o "$CORE_FILE" || true
    DNS_PX_FILE=""
  fi
  px_core_ok || { echo "The installer core at $LIB_URL is an older version (GitHub's cache). Try again in 5 minutes." >&2; exit 1; }
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$CORE_FILE"
}
px_load_core

# ── Proxmox defaults ──────────────────────────────────────────────────────────
VERSION="0.1.0-proxmox (core $VERSION)"
SCRIPT_URL="$PX_REPO_RAW/Self_Hosted_Cloud/proxmox/cloud.sh"
LOG_FILE="$LOG_DIR/cloud-proxmox-$(date +%Y%m%d-%H%M%S).log"
TOTAL_STEPS=7
INSTALL_DIR="/opt/sudohomelab/cloud"    # settings on the HOST, mounted into the container
HOST_DATA="/srv/cloud"                  # your files on the HOST, mounted into the container
HOST_DATA_SET=0
CT_TAG="sudohomelab-cloud"
CT_SETTINGS=/opt/sudohomelab/cloud
CT_DATA=/srv/cloud
CT_HOSTNAME=cloud
CTID=""; CT_EXISTS=0; CT_STORAGE=""; CT_BRIDGE=vmbr0; CT_IP_MODE=""; CT_GW=""; CT_IP=""
CT_CORES=4; CT_MEMORY=8192; CT_DISK=32  # every app: ~21 GB of images, 6-7 GB RAM
UID_SHIFT=100000                        # unprivileged LXC: container uid N = host uid 100000+N
PASS_ARGS=()                            # install options handed to the installer inside
DNS_SETTINGS=/opt/sudohomelab/pihole    # the Private DNS Stack's settings, if it's on this host
DNS_CT_IP=""; DNS_DOMAIN=""

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
  printf '    %s❯%s %sCloud Stack: Nextcloud + Office, Photos, Passwords, PDF, Notes%s %sv%s · Proxmox VE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }

copy_fn usage core_usage
usage() {
  core_usage | sed 's/^Usage: sudo bash cloud.sh \[action\] \[options\]/Usage: bash cloud.sh [action] [options]   (Proxmox VE host, as root)/;
                    /--install-dir=PATH/d; /--data-dir=PATH/d'
  cat <<EOF

Proxmox options:
  --data-dir=PATH              Host folder for your files (default $HOST_DATA): put it
                               on your big storage, e.g. a ZFS dataset or a mounted disk
  --settings-dir=PATH          Host folder for settings + databases (default $INSTALL_DIR)
  --ctid=N                     Container ID (default: next free)
  --storage=NAME               Storage for the container disk (e.g. local-lvm, local-zfs)
  --bridge=NAME                Network bridge (default vmbr0)
  --ip=CIDR                    Container IP, e.g. 192.168.1.95/24 (default: asked, a free one
                               is suggested). "dhcp" works too, but then reserve the address.
  --gateway=IP                 Gateway (default: this host's)
  --cores=N --memory=MB --disk=GB
                               Container size (default 4 cores, 8192 MB, 32 GB: the disk
                               holds the apps, about 21 GB with all of them)
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
      --data-dir=*) HOST_DATA=${arg#*=}; HOST_DATA=${HOST_DATA%/}; HOST_DATA_SET=1 ;;
      --settings-dir=*|--install-dir=*) INSTALL_DIR=${arg#*=}; INSTALL_DIR=${INSTALL_DIR%/} ;;
      *) rest+=("$arg")
         # Install options go to the installer inside. Secrets travel as files, not arguments.
         case $arg in
           --install|--lock-signups|--backup|--uninstall|--purge|--delete-files|--dry-run|-y|--yes|-h|--help) ;;
           --password=*|--password-file=*) ;;
           *) PASS_ARGS+=("$arg") ;;
         esac ;;
    esac
  done
  core_parse_args "${rest[@]}"
  [[ $CT_CORES =~ ^[0-9]+$ && $CT_MEMORY =~ ^[0-9]+$ && $CT_DISK =~ ^[0-9]+$ ]] ||
    { echo "--cores, --memory and --disk take numbers" >&2; exit 2; }
  [[ $HOST_DATA =~ ^/[A-Za-z0-9._/-]+$ && $HOST_DATA != / ]] || { echo "--data-dir must be a full path (letters, numbers, . _ - /)" >&2; exit 2; }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
px_ct_by_tag() { # px_ct_by_tag [tag] → CTID of our container, if any
  local id tag=${1:-$CT_TAG}
  for id in $(pct list 2>/dev/null | awk 'NR > 1 {print $1}'); do
    pct config "$id" 2>/dev/null | grep -qE "^tags:.*\b$tag\b" && { echo "$id"; return 0; }
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
  for n in 95 96 97 98 99 100 230 231 232 233 234 235; do
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
  pct push "$CTID" "$CORE_FILE" /root/cloud.sh --perms 0755
  log "inner: pct exec $CTID -- bash /root/cloud.sh $(sed -E 's/(--password=)[^ ]*/\1***/g' <<<"$*")"
  local rc=0 env=(LANG=C.UTF-8 LC_ALL=C.UTF-8 SHL_NO_BANNER=1 "SHL_HINT_CMD=$(run_hint)")
  if [[ -n $DNS_CT_IP ]]; then env+=("SHL_DNS_FOUND=DNS stack found in container $(px_saved_dns CTID)" "SHL_NAMES_BY_WRAPPER=Proxmox"); fi
  pct exec "$CTID" -- env "${env[@]}" bash /root/cloud.sh "$@" || rc=$?
  px_drop_secrets
  local inner
  inner=$(pct exec "$CTID" -- sh -c 'ls -t /var/log/sudohomelab/cloud-*.log 2>/dev/null | head -n1' 2>/dev/null || true)
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

# The Private DNS Stack (its Proxmox version) on this host: its container's address and ending.
px_saved_dns() { [[ -f $DNS_SETTINGS/.proxmox ]] && sed -n "s/^$1=//p" "$DNS_SETTINGS/.proxmox" | tail -n1 || true; }
px_find_dns() {
  [[ -f $DNS_SETTINGS/.state ]] || return 0
  local id
  id=$(px_ct_by_tag sudohomelab-dns || true)
  [[ -n $id && $id == "$(px_saved_dns CTID)" ]] || return 0
  DNS_CT_IP=$(px_saved_dns CT_IP)
  DNS_DOMAIN=$(sed -n 's/^DOMAIN=//p' "$DNS_SETTINGS/.state" | tail -n1)
  [[ -n $DNS_CT_IP && -n $DNS_DOMAIN ]] || { DNS_CT_IP=""; return 0; }
  ok "Private DNS Stack found: container $id ($DNS_CT_IP), names end in .$DNS_DOMAIN"
}

# ── Install: pre-flight (step 1) ─────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  px_need_root " --install"
  local ver major
  ver=$(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p')
  major=${ver%%.*}
  (( major >= 8 )) || die "Proxmox VE $ver is too old. This installer needs Proxmox VE 8 or newer."
  ok "Proxmox VE $ver on $(hostname) · $(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  local t
  for t in curl jq pveam pvesm pvesh ping; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing on this Proxmox host."; done
  ip -br link show "$CT_BRIDGE" >/dev/null 2>&1 || die "Network bridge '$CT_BRIDGE' doesn't exist (see --bridge)."
  BRIDGE_CIDR=$(ip -4 -o addr show dev "$CT_BRIDGE" 2>/dev/null | awk '{print $4; exit}')
  HOST_IP=${BRIDGE_CIDR%/*}; [[ -n $HOST_IP ]] || HOST_IP=$(host_ip)
  ok "Host IP: $HOST_IP ($CT_BRIDGE)"
  : "${CT_GW:=$(ip -4 route show default | awk '{print $3; exit}')}"
  px_find_dns
}

# ── Install: container choices (step 2) ──────────────────────────────────────
choose_container() {
  step "The container"
  local existing s
  existing=$(px_ct_by_tag || true)
  if [[ -n $existing ]]; then
    CTID=$existing; CT_EXISTS=1
    s=$(px_mount_source "$CTID" "$CT_SETTINGS"); [[ -n $s ]] && INSTALL_DIR=$s
    s=$(px_mount_source "$CTID" "$CT_DATA"); [[ -n $s ]] && HOST_DATA=$s
    CT_IP_MODE=$(pct config "$CTID" | sed -n 's/^net0:.*[ ,]ip=\([^,]*\).*/\1/p')
    info "Existing container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')) found: it'll be updated in place"
  else
    if [[ -f $INSTALL_DIR/.proxmox ]]; then
      info "Previous install found in $INSTALL_DIR: its settings, databases and logins come back"
      (( HOST_DATA_SET )) || { s=$(px_saved HOST_DATA); [[ -n $s ]] && HOST_DATA=$s; }
    fi
    px_ask_data
    px_ask_new
  fi

  printf '\n  %sPlan%s\n' "$C_BOLD" "$C_RESET"
  if (( CT_EXISTS )); then
    printf '    %-12s %s\n' "Container" "$CTID (existing, updated in place) · ${CT_IP_MODE:-?}"
  else
    printf '    %-12s %s\n' "Container" "$CTID · Debian · $CT_CORES cores · $CT_MEMORY MB RAM · $CT_DISK GB disk on $CT_STORAGE"
    printf '    %-12s %s\n' "Address" "$CT_IP_MODE$( [[ $CT_IP_MODE != dhcp ]] && echo " via $CT_GW") on $CT_BRIDGE"
  fi
  printf '    %-12s %s %s(host) → %s%s\n' "Your files" "$HOST_DATA" "$C_GRAY" "$CT_DATA" "$C_RESET"
  printf '    %-12s %s %s(host) → %s%s\n' "Settings" "$INSTALL_DIR" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  [[ -n $DNS_CT_IP ]] && printf '    %-12s %s\n' "App names" "added to the DNS stack at $DNS_CT_IP if you pick DNS names"
  printf '    %-12s %s\n\n' "Then" "the Cloud Stack questions (login, HTTPS, apps) inside the container"
  if (( DRY_RUN )); then info "Dry run: nothing was changed."; exit 0; fi
  confirm "$( (( CT_EXISTS )) && echo "Continue?" || echo "Create the container?")" || { info "Cancelled. Nothing was changed."; exit 0; }
}

# Your files: a host folder, so they're on the storage you choose and outlive the container.
px_ask_data() {
  if (( ! HOST_DATA_SET )) && (( ! ASSUME_YES )) && has_tty; then
    printf '\n  %sWhere your files go%s %s(a folder on this host: Documents, Notes, Photos, backups. Put it on your\n   big storage, e.g. /tank/cloud on a ZFS pool or /mnt/data/cloud on a mounted disk.)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while :; do
      HOST_DATA=$(ask "Host folder for your files" "$HOST_DATA"); HOST_DATA=${HOST_DATA%/}
      [[ $HOST_DATA =~ ^/[A-Za-z0-9._/-]+$ && $HOST_DATA != / && $HOST_DATA != "$INSTALL_DIR"* ]] && break
      warn "Use a full path with letters, numbers, . _ - and / (like /srv/cloud)."
    done
  fi
  local d=$HOST_DATA
  while [[ ! -d $d ]]; do d=$(dirname "$d"); done
  ok "Your files: $HOST_DATA ($(df -Pk "$d" | awk 'NR==2 {printf "%.0f GB free", $4/1048576}') on $(df -P "$d" | awk 'NR==2 {print $1}'))"
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
      CT_STORAGE=$(sed -n "$(menu "Where should the container's disk live? (it holds the apps: ${CT_DISK} GB)" "$def" "${opts[@]}")p" <<<"$storages")
    fi
  fi
  grep -qx "$CT_STORAGE" <<<"$storages" || die "Storage '$CT_STORAGE' can't hold containers. Options: $(paste -sd, - <<<"$storages")"
  local free
  free=$(pvesm status -storage "$CT_STORAGE" 2>/dev/null | awk 'NR == 2 {printf "%.0f", $6 / 1048576}')
  [[ -z $free ]] || (( free >= CT_DISK )) ||
    die "Storage $CT_STORAGE has ${free} GB free; the container needs ${CT_DISK} GB (--disk, fewer apps need less). Free space or pick another --storage."
  (( $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) > CT_MEMORY )) ||
    warn "This host has less RAM than the container's $CT_MEMORY MB: set --memory lower, and leave out some apps inside."

  # Phones, the certificate and the app names point at it: the address should stay put.
  local prefix=${BRIDGE_CIDR#*/} ipa interactive=0
  [[ $prefix =~ ^[0-9]+$ ]] || prefix=24
  (( ! ASSUME_YES )) && has_tty && interactive=1
  if [[ -z $CT_IP_MODE ]]; then
    local def
    def=$(px_suggest_ip || true)
    (( interactive )) && printf '\n  %sContainer address%s %s(your phones, the HTTPS certificate and the app names point at it, so it should not change.\n   Pick one outside your router'"'"'s DHCP range, or reserve it in the router.)%s\n' \
      "$C_BOLD" "$C_RESET" "$C_GRAY" "$C_RESET" >/dev/tty
    while :; do
      ipa=$(ask "Static IP (or \"dhcp\")" "$def")
      [[ -n $ipa ]] || { (( interactive )) || die "No free address found: set one with --ip=CIDR."; warn "Type an address like ${HOST_IP%.*}.95"; continue; }
      [[ ${ipa,,} == dhcp ]] && { CT_IP_MODE=dhcp; break; }
      [[ $ipa == */* ]] || ipa="$ipa/$prefix"
      if [[ ! $ipa =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        (( interactive )) || die "Static IP must look like 192.168.1.95/24 (got '$ipa')."
        warn "That doesn't look like an address (e.g. ${HOST_IP%.*}.95)."; continue
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
    [[ $CT_IP_MODE =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Static IP must look like 192.168.1.95/24 (got '$CT_IP_MODE')."
    px_ip_in_use "${CT_IP_MODE%/*}" && die "${CT_IP_MODE%/*} is already in use on your network. Pick another --ip."
  fi
  if [[ $CT_IP_MODE == dhcp ]]; then
    warn "With DHCP, reserve the container's address in your router: the certificate and app names use it."
  else
    [[ $CT_GW =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "A static IP needs a gateway (--gateway=IP)."
  fi
  ok "Container $CTID on $CT_STORAGE, $CT_IP_MODE"
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
  # The container's root is host uid $UID_SHIFT: it owns both folders (it hands
  # the shared ones to www-data itself, = host uid $((UID_SHIFT + WWW_UID))).
  mkdir -p "$INSTALL_DIR" "$HOST_DATA"
  chown "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR" "$HOST_DATA"; chmod 700 "$INSTALL_DIR"
  if (( CT_EXISTS )); then
    px_start
  else
    local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_MODE"
    [[ $CT_IP_MODE != dhcp ]] && net+=",gw=$CT_GW"
    # shellcheck disable=SC2054  # commas belong inside pct option values
    local args=(
      "$CTID" "$TEMPLATE_STORE:vztmpl/$TEMPLATE"
      --hostname "$CT_HOSTNAME" --tags "$CT_TAG" --description "sudo homelab Cloud Stack (Nextcloud, Collabora, Immich, Vaultwarden, Stirling PDF, Obsidian) · $SCRIPT_URL"
      --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --startup order=3 --timezone host
      --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 2048
      --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net"
      --mp0 "$INSTALL_DIR,mp=$CT_SETTINGS" --mp1 "$HOST_DATA,mp=$CT_DATA"
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
  printf 'CTID=%s\nCT_IP=%s\nHOST_DATA=%s\n' "$CTID" "$CT_IP" "$HOST_DATA" >"$INSTALL_DIR/.proxmox"
  chown "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR/.proxmox" 2>/dev/null || true
  ok "Container $CTID is up at $CT_IP"
}

# ── Install: inside the container (step 5) ───────────────────────────────────
inner_install() {
  step "Installing the Cloud Stack inside container $CTID"
  local a=(--install "--data-dir=$CT_DATA" "${PASS_ARGS[@]}")
  (( ASSUME_YES )) || ! has_tty && a+=(--yes)
  [[ -n $DNS_CT_IP ]] && a+=("--dns-host=$DNS_CT_IP" "--domain=$DNS_DOMAIN")
  [[ -n $APP_PASS ]] && a+=("--password-file=$(px_push_secret pass "$APP_PASS")")
  info "Live output from inside the container (its questions too):"
  px_core "${a[@]}" || die "The installer inside container $CTID failed. Its log: ${INNER_LOG:-/var/log/sudohomelab/ in the container}"
}

# ── Install: app names in the DNS stack (step 6) ─────────────────────────────
px_dns_file() {
  if [[ -n ${DNS_PX_FILE:-} && -f $DNS_PX_FILE ]]; then echo "$DNS_PX_FILE"; return; fi
  local f="$SHL_TMP/pihole-proxmox.sh"
  curl -fsSL "$DNS_PX_URL" -o "$f" && echo "$f"
}

px_dns_add() { # px_dns_add file name port
  local out rc=0
  out=$(bash "$1" "--add=$2=$CT_IP:$3" --yes </dev/null 2>&1) || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) && return 0
  grep -q 'already exists' <<<"$out" && { echo "$2.$DNS_DOMAIN was already there"; return 0; }
  return "$rc"
}

px_names() {
  step "App names"
  local mode host name port f
  mode=$(state_get HTTPS_MODE); host=$(state_get DNS_HOST)
  if [[ $mode != dns ]]; then info "Built-in HTTPS: no names needed"; return 0; fi
  if [[ -z $DNS_CT_IP || $host != "$DNS_CT_IP" ]]; then info "The DNS stack is elsewhere: the commands are in the output above"; return 0; fi
  [[ -s $INSTALL_DIR/.dns-names ]] || { warn "No list of names from the installer: re-run Install."; return 0; }
  f=$(px_dns_file) || die "Couldn't download the DNS stack's script from $DNS_PX_URL"
  while read -r name port; do
    [[ -n $name ]] || continue
    run "https://$name.$DNS_DOMAIN → $CT_IP:$port" px_dns_add "$f" "$name" "$port" ||
      warn "Couldn't add $name.$DNS_DOMAIN: add it from the DNS stack's menu (Add a name → $CT_IP:$port)."
  done <"$INSTALL_DIR/.dns-names"
}

px_install() {
  START_TIME=$SECONDS
  (( BANNER_SHOWN )) || banner
  preflight
  choose_container
  get_template
  make_container
  inner_install
  px_names
  px_summary
  log "install finished"
}

px_summary() {
  step "Done"
  printf '\n  %s%s★ Container %s (%s) runs your Cloud Stack at %s%s\n' "$C_BOLD" "$C_GREEN" "$CTID" "$CT_HOSTNAME" "$CT_IP" "$C_RESET"
  printf '    %sThe logins and links are in the summary above, and in %s/credentials.txt (host, root only).%s\n' "$C_GRAY" "$INSTALL_DIR" "$C_RESET"
  printf '    %sMenu:%s       %s   %s(install · lock sign-ups · back up · uninstall)%s\n' "$C_GRAY" "$C_RESET" "$(run_hint)" "$C_GRAY" "$C_RESET"
  printf '    %sShell:%s      pct enter %s   %s(then: cd %s && docker compose ps)%s\n' "$C_GRAY" "$C_RESET" "$CTID" "$C_GRAY" "$CT_SETTINGS" "$C_RESET"
  printf '    %sYour files:%s %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$HOST_DATA" "$CT_DATA"
  printf '    %sSettings:%s   %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR" "$CT_SETTINGS"
  printf '    %sLogs:%s       %s%s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE" "${INNER_LOG:+ and $INNER_LOG}"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s       %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
  printf '  %sBack it up:%s the nightly job saves the databases into %s/backups. For the rest,\n' "$C_GRAY" "$C_RESET" "$HOST_DATA"
  printf '  %sback up %s and %s (or the container: vzdump %s --mode snapshot).%s\n\n' "$C_GRAY" "$HOST_DATA" "$INSTALL_DIR" "$CTID" "$C_RESET"
}

# ── Lock sign-ups / back up (run inside) ─────────────────────────────────────
px_inside() { # px_inside action → finds the container, then runs the core with that action
  (( BANNER_SHOWN )) || banner
  px_need_root " --$1"
  CTID=$(px_ct_by_tag || true)
  [[ -n $CTID ]] || die "No Cloud Stack container yet. Install first:  $(run_hint " --install")"
  local s; s=$(px_mount_source "$CTID" "$CT_SETTINGS"); [[ -n $s ]] && INSTALL_DIR=$s
  px_start
  local a=("--$1")
  (( ASSUME_YES )) && a+=(--yes)
  px_core "${a[@]}" || exit $?
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
px_names_delete() { # px_names_delete settings_dir → removes the names Install added to the DNS container
  local list="$1/.dns-names" host f name port
  [[ -s $list ]] || return 0
  host=$(sed -n 's/^DNS_HOST=//p' "$1/.state" 2>/dev/null | tail -n1)
  px_find_dns
  if [[ -z $DNS_CT_IP || $host != "$DNS_CT_IP" ]]; then
    info "App names (cloud.…) stay in the DNS stack: delete them from its menu if you used them."; return 0
  fi
  f=$(px_dns_file) || { warn "Couldn't download the DNS stack's script: delete the names from its menu."; return 0; }
  while read -r name port; do
    [[ -n $name ]] || continue
    run "Removing $name.$DNS_DOMAIN" bash "$f" "--delete=$name" --yes </dev/null ||
      warn "Couldn't remove $name.$DNS_DOMAIN: delete it from the DNS stack's menu."
  done <"$list"
}

uninstall() {
  (( BANNER_SHOWN )) || banner
  px_need_root " --uninstall"
  local s d
  CTID=$(px_ct_by_tag || true)
  if [[ -n $CTID ]]; then
    s=$(px_mount_source "$CTID" "$CT_SETTINGS"); d=$(px_mount_source "$CTID" "$CT_DATA")
  else
    [[ -f $INSTALL_DIR/.proxmox ]] || die "No sudo homelab Cloud Stack container (tag $CT_TAG) on this host."
    s=$INSTALL_DIR; d=$(px_saved HOST_DATA)
    info "The container is already gone; its settings are still in $s."
  fi
  [[ -n $CTID ]] && warn "This stops and deletes container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')): Nextcloud and the other apps."
  if (( ! PURGE )) && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Keep the data?" 1 \
      "Keep it|settings, databases and your files stay on the host: re-run Install to bring it all back" \
      "Delete settings|delete ${s:-the settings} (databases, calendars, vault…); keep your files in ${d:-?}" \
      "Delete all|also delete your files in ${d:-?}: Documents, Notes, Photos, backups") in
      2) PURGE=1 ;;
      3) PURGE=1; DELETE_FILES=1 ;;
    esac
  fi
  if (( DELETE_FILES )) && [[ -n $d ]]; then
    warn "Your files in $d (Documents, Notes, Photos, Immich uploads, backups) will be DELETED."
    if (( ! ASSUME_YES )) && has_tty; then
      [[ $(ask "Type DELETE to confirm" "") == DELETE ]] || { info "Cancelled. Nothing was changed."; exit 0; }
    fi
  elif (( PURGE )); then
    warn "Settings and databases in ${s:-?} will be deleted (calendars, contacts, Immich albums, your vault…)."
    info "Your files in ${d:-?} stay."
  else
    info "Everything stays on the host: ${s:-?} and ${d:-?}."
  fi
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  if [[ -n $CTID ]]; then
    px_running && run "Stopping container $CTID" pct stop "$CTID"
    run "Deleting container $CTID" pct destroy "$CTID" --purge 1
  fi
  # Kept settings mean a re-run brings the stack back on the same names, so they stay.
  if (( PURGE )) && [[ -n $s && $s != / && -d $s ]]; then
    px_names_delete "$s"
    run "Deleting $s" rm -rf "$s"
  elif [[ -s ${s:-/nonexistent}/.dns-names ]]; then
    info "App names (cloud.…) stay in the DNS stack, ready for a re-run of Install."
  fi
  if (( DELETE_FILES )) && [[ -n $d && $d != / && -d $d ]]; then run "Deleting $d" rm -rf "$d"; fi
  ok "Uninstalled."
}

# ── Menu + actions (the core's menu loop calls these) ────────────────────────
run_action() {
  log "action: $ACTION"
  case $ACTION in
    uninstall) uninstall ;;
    lock) px_inside lock-signups ;;
    backup) px_inside backup ;;
    *) px_install ;;
  esac
}

choose_action() {
  (( BANNER_SHOWN )) || { banner; BANNER_SHOWN=1; }
  local installed=0
  [[ -n $(px_ct_by_tag || true) ]] && installed=1
  case $(menu "What would you like to do?" 1 \
    "Install|$( (( installed )) && echo "already installed: re-run the setup to change settings" || echo "a container with Nextcloud + Office, Immich, Vaultwarden, Stirling PDF, Obsidian")" \
    "Lock sign-ups|close Vaultwarden sign-ups once your account exists" \
    "Back up now|save the databases and Vaultwarden into the backups folder" \
    "Uninstall|delete the container (asks whether to keep the data)" \
    "Quit|close the menu") in
    1) ACTION=install ;; 2) ACTION=lock ;; 3) ACTION=backup ;; 4) ACTION=uninstall ;; 5) ACTION=quit ;;
  esac
}

main "$@"
