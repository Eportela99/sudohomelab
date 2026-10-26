#!/usr/bin/env bash
# Variables set in this file are read by the shared core (sourced at runtime),
# which shellcheck can't follow:
# shellcheck disable=SC2034,SC2120
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Media Stack installer (Proxmox VE 8 / 9)
#  https://github.com/Eportela99/sudohomelab
#
#  Run on the Proxmox host shell (as root). It creates one unprivileged Debian
#  LXC with Docker, mounts your media and the app settings from the host, and
#  runs the Ubuntu/Debian installer inside it, with the same apps and wiring.
#
#    Proxmox host
#     └── LXC "media-stack" (tag sudohomelab-mediastack)
#          ├── /opt/sudohomelab/media-stack  ← settings  (host: --settings-dir)
#          └── /srv/media                     ← media     (host: --data-dir)
#
#  Usage (Proxmox shell):
#    bash -c "$(curl -fsSL <url>/Media_Stack/proxmox/media-stack.sh)"
#    bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PX_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack"
LIB_URL="$PX_REPO_RAW/linux/media-stack.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
px_load_core() {
  local here=""
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/media-stack.sh ]]; then
    CORE_FILE="$here/../linux/media-stack.sh"
  else
    CORE_FILE=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$CORE_FILE" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
  fi
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$CORE_FILE"
}
px_load_core

# ── Proxmox defaults ──────────────────────────────────────────────────────────
VERSION="0.1.1-proxmox (core $VERSION)"
SCRIPT_URL="$PX_REPO_RAW/proxmox/media-stack.sh"
LOG_FILE="$LOG_DIR/media-stack-proxmox-$(date +%Y%m%d-%H%M%S).log"
TOTAL_STEPS=7
INSTALL_DIR="/opt/sudohomelab/media-stack"   # settings on the HOST, mounted into the container
DATA_DIR="/mnt/media"                        # media on the HOST, mounted at /srv/media
CT_TAG="sudohomelab-mediastack"
CT_DATA=/srv/media
CT_SETTINGS=/opt/sudohomelab/media-stack
CTID=""; CT_EXISTS=0; CT_STORAGE=""; CT_BRIDGE=vmbr0; CT_IP_MODE=dhcp; CT_IP=""; CT_GW=""
CT_CORES=""; CT_MEMORY=""; CT_DISK=""
CT_HOSTNAME=media-stack
UID_SHIFT=100000                             # unprivileged LXC: container uid N = host uid 100000+N
APP_UID=1000                                 # the apps run as uid 1000 inside the container

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
  printf '    %s❯%s %sMedia Stack%s installer %sv%s · Proxmox VE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }
pyj() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

copy_fn usage core_usage
usage() {
  core_usage | sed 's/media-stack.sh \[options\]/media-stack.sh [options]   (Proxmox VE host)/'
  cat <<EOF

Proxmox options:
  --ctid=N                           Container ID (default: next free)
  --storage=NAME                     Storage for the container disk (e.g. local-lvm, local-zfs)
  --bridge=NAME                      Network bridge (default vmbr0)
  --ip=dhcp|CIDR                     Container IP, e.g. 192.168.1.50/24 (default dhcp)
  --gateway=IP                       Gateway when using a static IP
  --cores=N --memory=MB --disk=GB    Container size (default: sized from the apps you pick)
  --settings-dir=PATH                Host folder for app settings (default $INSTALL_DIR)
  --data-dir=PATH                    Host folder for media + downloads (default $DATA_DIR,
                                     or /<pool>/media when a ZFS data pool exists)
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
      --settings-dir=*) INSTALL_DIR=${arg#*=} ;;
      *) rest+=("$arg") ;;
    esac
  done
  core_parse_args "${rest[@]}"
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

px_zfs_dataset_for() { # px_zfs_dataset_for /path → "pool/ds" if /path would sit in a ZFS dataset's mountpoint
  command -v zfs >/dev/null 2>&1 || return 1
  zfs list -H -o name,mountpoint 2>/dev/null | awk -v p="$1" '$2 != "none" && $2 != "-" && index(p "/", $2 "/") == 1 {print length($2), $1, $2}' |
    sort -rn | head -n1 | awk '{print $2 " " $3}'
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Run this in the Proxmox host shell as root:  $(run_hint)"
  command -v pveversion >/dev/null 2>&1 && command -v pct >/dev/null 2>&1 ||
    die "This is the Proxmox version, but pveversion/pct aren't here. On Ubuntu/Debian use the Linux script."
  local ver major minor
  ver=$(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p')
  major=${ver%%.*}; minor=$(cut -d. -f2 <<<"$ver")
  (( major >= 8 )) || die "Proxmox VE $ver is too old. This installer needs Proxmox VE 8 or newer."
  PVE_DEV_OK=$(( major > 8 || (major == 8 && minor >= 2) ))   # devN passthrough with mode=
  ok "Proxmox VE $ver on $(hostname)"
  ok "$(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM on the host"
  HOST_IP=$(host_ip); ok "Host IP: $HOST_IP"
  TZ_NAME=$(detect_tz)
  OWNER="uid $APP_UID in the container (host uid $((UID_SHIFT + APP_UID)))"
  PUID=$APP_UID; PGID=$APP_UID
  if compgen -G '/dev/dri/renderD*' >/dev/null; then
    HAS_DRI=1; ok "GPU found ($(compgen -G '/dev/dri/renderD*' | head -n1)): it'll be passed into the container"
  else
    HAS_DRI=0; info "No GPU render device: media servers will use CPU transcoding"
  fi
  if (( HAS_DRI )) && (( ! PVE_DEV_OK )); then
    warn "Proxmox $ver can't pass devices with the dev0 option (needs 8.2+). The GPU will be skipped."
    HAS_DRI=0
  fi
}

# ── Choices ───────────────────────────────────────────────────────────────────
copy_fn choose_options core_choose_options
choose_options() {
  # Existing install? Reuse its container and its host folders.
  local existing
  existing=$(px_ct_by_tag || true)
  if [[ -n $existing ]]; then
    CTID=$existing; CT_EXISTS=1
    local s d
    s=$(px_mount_source "$CTID" "$CT_SETTINGS"); d=$(px_mount_source "$CTID" "$CT_DATA")
    [[ -n $s ]] && INSTALL_DIR=$s
    [[ -n $d ]] && { DATA_DIR=$d; DATA_DIR_SET=1; }
    info "Existing container $CTID ($(pct config "$CTID" | sed -n 's/^hostname: //p')) found: it'll be updated in place"
  elif [[ -f $INSTALL_DIR/.proxmox ]] && (( ! DATA_DIR_SET )); then
    # Reinstall after `--uninstall` (settings kept): reuse the host media folder.
    DATA_DIR=$(sed -n 's/^HOST_DATA_DIR=//p' "$INSTALL_DIR/.proxmox"); DATA_DIR_SET=1
    info "Previous install found in $INSTALL_DIR: reusing media folder $DATA_DIR"
  else
    # Prefer a ZFS data pool (not the boot pool) for media.
    if (( ! DATA_DIR_SET )) && command -v zpool >/dev/null 2>&1; then
      local pool
      pool=$(zpool list -H -o name 2>/dev/null | grep -vx rpool | head -n1 || true)
      [[ -n $pool ]] && DATA_DIR="$(zfs get -H -o value mountpoint "$pool" 2>/dev/null || echo "/$pool")/media"
    fi
  fi
  core_choose_options
  [[ $DATA_DIR == /* ]] || die "The media folder must be an absolute host path."
}

px_size_defaults() { # size the container from the chosen apps, unless set by flags
  local gb=0 img
  for img in $(stack_images); do gb=$(awk -v a="$gb" -v b="$(image_gb "$img")" 'BEGIN {print a + b}'); done
  : "${CT_DISK:=$(awk -v g="$gb" 'BEGIN {d = int(g + 12.999); print (d < 24 ? 24 : d)}')}"
  local cores=2 mem=3072
  want jellyfin && want plex && mem=$((mem + 1024))
  want lidarr && mem=$((mem + 512))
  want bazarr && mem=$((mem + 512))
  want audiobookshelf && mem=$((mem + 256))
  want komga && mem=$((mem + 1024))
  want tdarr && { cores=4; mem=$((mem + 2048)); }
  : "${CT_CORES:=$cores}"; : "${CT_MEMORY:=$mem}"
}

px_storages() { pvesm status -content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}'; }

plan_extra() {
  px_size_defaults
  if (( CT_EXISTS )); then
    printf '    %-16s %s\n' "Container" "$CTID (existing, updated in place)"
  else
    printf '    %-16s %s\n' "Container" "${CTID:-next free ID} · Debian · ${CT_CORES} cores · $((CT_MEMORY / 1024)) GB RAM · ${CT_DISK} GB disk"
    printf '    %-16s %s\n' "Network" "$CT_BRIDGE · ${CT_IP_MODE}${CT_GW:+ via $CT_GW}"
  fi
}

pre_plan() { px_ask_container; }

# The container lives on its own IP, so host port and host Docker checks don't apply.
report_ports() { :; }
report_disk() { :; }

# Proxmox questions: asked before the confirmation, after the app choices.
px_ask_container() {
  (( CT_EXISTS )) && return 0
  [[ -n $CTID ]] || CTID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"')
  [[ $CTID =~ ^[0-9]+$ ]] || die "Couldn't get a free container ID (pvesh get /cluster/nextid)."
  pct status "$CTID" >/dev/null 2>&1 && die "Container ID $CTID is already in use. Pick another with --ctid=N."

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

  ip -br link show "$CT_BRIDGE" >/dev/null 2>&1 || die "Network bridge '$CT_BRIDGE' doesn't exist (see --bridge)."
  if [[ $CT_IP_MODE == dhcp ]] && (( ! ASSUME_YES )) && has_tty; then
    case $(menu "Container network" 1 "DHCP|your router hands out the address" "Static IP|you type the address") in
      2) CT_IP_MODE=$(ask "Static IP with prefix (e.g. 192.168.1.50/24)" "")
         CT_GW=$(ask "Gateway" "$(ip -4 route show default | awk '{print $3; exit}')") ;;
    esac
  fi
  if [[ $CT_IP_MODE != dhcp ]]; then
    [[ $CT_IP_MODE =~ ^[0-9.]+/[0-9]+$ ]] || die "Static IP must look like 192.168.1.50/24 (got '$CT_IP_MODE')."
    [[ -n $CT_GW ]] || die "A static IP needs --gateway=IP."
  fi
  ok "Container $CTID on $CT_STORAGE, network $CT_BRIDGE ($CT_IP_MODE)"
}

# ── Host checks + template (step 3) ──────────────────────────────────────────
install_deps() {
  step "Checking Proxmox"
  local t
  for t in curl python3 pveam pvesm pct; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing on this Proxmox host."; done
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

# ── Host storage (step 4) ─────────────────────────────────────────────────────
px_own() { chown "$@" 2>/dev/null || true; }

install_docker() {
  step "Preparing storage on the host"
  # Settings: owned by the container's root (host uid 100000), the apps' files by uid 1000 → 101000.
  mkdir -p "$INSTALL_DIR"
  px_own "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR"; chmod 750 "$INSTALL_DIR"
  ok "Settings folder: $INSTALL_DIR"

  if [[ ! -d $DATA_DIR ]]; then
    local zfs_hit
    zfs_hit=$(px_zfs_dataset_for "$DATA_DIR" || true)
    if [[ -n $zfs_hit ]]; then
      local parent_ds=${zfs_hit%% *} parent_mnt=${zfs_hit#* }
      run "Creating ZFS dataset ${parent_ds}${DATA_DIR#"$parent_mnt"}" zfs create -p "${parent_ds}${DATA_DIR#"$parent_mnt"}"
    else
      mkdir -p "$DATA_DIR"
    fi
    FRESH_DATA=1
  else
    FRESH_DATA=0
  fi
  local d dirs=(Movies TV_Shows Active_Downloads)
  want lidarr && dirs+=(Music)
  want tdarr && dirs+=(Transcode_Cache)
  want audiobookshelf && dirs+=(Audiobooks)
  want komga && dirs+=(Books Books/Comics Books/Ebooks Books/Manga)
  for d in "${dirs[@]}"; do mkdir -p "$DATA_DIR/$d"; done
  local h=$((UID_SHIFT + APP_UID))
  px_own "$h:$h" "$DATA_DIR"
  for d in "${dirs[@]}"; do px_own "$h:$h" "$DATA_DIR/$d"; chmod 775 "$DATA_DIR/$d"; done
  ok "Media folder: $DATA_DIR → $CT_DATA in the container (owned by host uid $h = uid $APP_UID inside)"

  # An existing library may belong to other users; re-owning it is the user's call.
  if (( ! FRESH_DATA )) && [[ -n $(find "$DATA_DIR" -mindepth 2 -maxdepth 3 ! -uid "$h" -print -quit 2>/dev/null) ]]; then
    warn "Some existing files in $DATA_DIR aren't owned by host uid $h, so the apps may not be able to rename or import them."
    if (( ! ASSUME_YES )) && has_tty && confirm "Give the media stack ownership of everything in $DATA_DIR? (changes file owners)"; then
      run "Setting owner of existing media" chown -R "$h:$h" "$DATA_DIR"
    else
      info "Left as is. Later: chown -R $h:$h \"$DATA_DIR\""
    fi
  fi
  check_disk_px
}

check_disk_px() {
  (( CT_EXISTS )) && return 0
  local free
  free=$(pvesm status -storage "$CT_STORAGE" 2>/dev/null | awk 'NR == 2 {printf "%.0f", $6 / 1048576}')
  if [[ -n $free ]] && (( free < CT_DISK )); then
    die "Storage $CT_STORAGE has ${free} GB free; the container needs ${CT_DISK} GB. Free space, pick another --storage, or set --disk."
  fi
  ok "Storage $CT_STORAGE: ${free:-?} GB free, container disk ${CT_DISK} GB"
}

# ── Container (step 5) ────────────────────────────────────────────────────────
prepare_folders() {
  step "Creating the container"
  if (( CT_EXISTS )); then
    [[ $(pct status "$CTID" | awk '{print $2}') == running ]] || run "Starting container $CTID" pct start "$CTID"
  else
    local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_MODE${CT_GW:+,gw=$CT_GW}"
    # shellcheck disable=SC2054  # commas belong inside pct option values
    local args=(
      "$CTID" "$TEMPLATE_STORE:vztmpl/$TEMPLATE"
      --hostname "$CT_HOSTNAME" --tags "$CT_TAG" --description "sudo homelab media stack · $SCRIPT_URL"
      --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --timezone host
      --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 512
      --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net"
      --mp0 "$INSTALL_DIR,mp=$CT_SETTINGS" --mp1 "$DATA_DIR,mp=$CT_DATA"
    )
    if (( HAS_DRI )); then
      local i=0 dev
      for dev in /dev/dri/renderD* /dev/dri/card*; do
        [[ -e $dev ]] && { args+=(--"dev$i" "$dev,mode=0666"); i=$((i + 1)); }
      done
    fi
    run "Creating container $CTID (Debian, unprivileged, Docker-ready)" pct create "${args[@]}"
    run "Starting container $CTID" pct start "$CTID"
  fi

  local i ip=""
  for i in $(seq 1 60); do
    ip=$(px_ct_ip "$CTID" || true)
    [[ -n $ip ]] && pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
  done
  [[ -n $ip ]] || die "Container $CTID has no network after 2 minutes. Check bridge $CT_BRIDGE / DHCP."
  CT_IP=$ip
  ok "Container $CTID is up at $CT_IP"
}

# ── Install inside (step 6) ───────────────────────────────────────────────────
write_compose() { :; }   # done inside the container

SMB_PLAN_HOST="<container IP>"   # the share lives in the container

px_inner_args() {
  local a=(--yes --skip-data-perms "--server=$SERVER" "--downloader=$DOWNLOADER" "--extras=${EXTRAS:-none}"
    "--data-dir=$CT_DATA")
  [[ -n $SUB_LANGS ]] && a+=("--subtitle-langs=$SUB_LANGS")
  if [[ $SMB == yes ]]; then a+=(--smb); else a+=(--no-smb); fi   # Samba runs in the container
  [[ -n $PLEX_CLAIM ]] && a+=("--plex-claim=$PLEX_CLAIM")
  printf '%s\n' "${a[@]}"
}

start_stack() {
  step "Installing the stack inside container $CTID"
  # The login reaches the inner installer as a file on the shared settings mount,
  # never as a command argument.
  if [[ ! -f $INSTALL_DIR/.secrets ]]; then
    ( umask 077; printf 'APP_USER=%s\nAPP_PASS=%s\n' "$APP_USER" "$APP_PASS" >"$INSTALL_DIR/.secrets" )
    px_own "$UID_SHIFT:$UID_SHIFT" "$INSTALL_DIR/.secrets"
  fi
  printf 'HOST_DATA_DIR=%s\nCTID=%s\n' "$DATA_DIR" "$CTID" >"$INSTALL_DIR/.proxmox"
  run "Copying the installer into the container" pct push "$CTID" "$CORE_FILE" /root/media-stack.sh --perms 0755
  info "Live output from inside the container:"
  local args rc=0
  mapfile -t args < <(px_inner_args)
  log "inner: pct exec $CTID -- bash /root/media-stack.sh ${args[*]}"
  # Not wrapped in run(): the inner installer draws its own live view on this terminal.
  pct exec "$CTID" -- bash /root/media-stack.sh "${args[@]}" || rc=$?
  local inner
  inner=$(pct exec "$CTID" -- sh -c 'ls -t /var/log/sudohomelab/*.log 2>/dev/null | head -n1' 2>/dev/null || true)
  if [[ -n $inner ]]; then
    INNER_LOG="$LOG_DIR/$(basename "$inner" .log)-ct$CTID.log"
    pct pull "$CTID" "$inner" "$INNER_LOG" 2>/dev/null && log "inner log copied to $INNER_LOG"
  fi
  (( rc == 0 )) || die "The installer inside container $CTID failed (exit $rc). Its log: ${INNER_LOG:-/var/log/sudohomelab/ in the container}"
}

wire_stack() { :; }   # done by the inner installer
verify() { :; }

summary() {
  step "Done"
  printf '\n  %s%s★ Container %s (%s) is running the media stack%s\n' "$C_BOLD" "$C_GREEN" "$CTID" "$CT_HOSTNAME" "$C_RESET"
  printf '    %sApps:%s       http://%s:<port>  (the list is just above)\n' "$C_GRAY" "$C_RESET" "$CT_IP"
  printf '    %sShell:%s      pct enter %s\n' "$C_GRAY" "$C_RESET" "$CTID"
  printf '    %sSettings:%s   %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$INSTALL_DIR" "$CT_SETTINGS"
  printf '    %sMedia:%s      %s (host)  →  %s\n' "$C_GRAY" "$C_RESET" "$DATA_DIR" "$CT_DATA"
  printf '    %sLogin:%s      %s (password in %s/credentials.txt)\n' "$C_GRAY" "$C_RESET" "$APP_USER" "$INSTALL_DIR"
  [[ $SMB == yes ]] && printf '    %sShare:%s      \\\\%s\\%s  (Mac: smb://%s/%s, same login)\n' "$C_GRAY" "$C_RESET" "$CT_IP" "$SMB_SHARE" "$CT_IP" "$SMB_SHARE"
  printf '    %sLogs:%s       %s%s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE" "${INNER_LOG:+ and $INNER_LOG}"
  local t=$((SECONDS - START_TIME))
  printf '    %sTime:%s       %dm %02ds\n\n' "$C_GRAY" "$C_RESET" $((t / 60)) $((t % 60))
  printf '  %sBack it up:%s Datacenter → Backup, or  vzdump %s --mode snapshot\n\n' "$C_GRAY" "$C_RESET" "$CTID"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  banner
  [[ $EUID -eq 0 ]] || die "Run this in the Proxmox host shell as root."
  local id s
  id=$(px_ct_by_tag || true)
  [[ -n $id ]] || die "No sudo homelab media stack container (tag $CT_TAG) on this host."
  s=$(px_mount_source "$id" "$CT_SETTINGS")
  warn "This stops and deletes container $id ($(pct config "$id" | sed -n 's/^hostname: //p'))."
  if (( PURGE )); then warn "--purge: the app settings in ${s:-?} on the host will be deleted too."
  else info "App settings stay in ${s:-?} on the host, so a reinstall brings back your logins and wiring."; fi
  info "Your media folder is never touched."
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  [[ $(pct status "$id" | awk '{print $2}') == running ]] && run "Stopping container $id" pct stop "$id"
  run "Deleting container $id" pct destroy "$id" --purge 1
  if (( PURGE )) && [[ -n $s && $s != / && -d $s ]]; then
    local ds
    ds=$(zfs list -H -o name,mountpoint 2>/dev/null | awk -v m="$s" '$2 == m {print $1}' || true)
    if [[ -n $ds ]]; then run "Destroying dataset $ds" zfs destroy -r "$ds"
    else run "Deleting $s" rm -rf "$s"; fi
  fi
  ok "Uninstalled."
}

main "$@"
