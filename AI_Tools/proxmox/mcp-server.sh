#!/usr/bin/env bash
# Variables set here are read by the shared core (sourced at runtime):
# shellcheck disable=SC2034
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · MCP Server for Proxmox VE 8 / 9
#  https://github.com/Eportela99/sudohomelab
#
#  Run on the Proxmox host shell (as root). It creates one unprivileged Debian
#  LXC (Docker inside) and runs the Ubuntu/Debian installer in it:
#
#    Proxmox host
#     ├── /opt/sudohomelab/mcp   ← settings, tokens, database, files (survive a rebuild)
#     └── LXC "mcp" (tag sudohomelab-mcp)
#          └── gateway · router · knowledge (Postgres + CPU embeddings) · search
#
#  Tailscale: inside the container (HTTPS via tailscale serve), on this host
#  (subnet route to the container), or none (LAN only).
#
#  Usage (Proxmox shell; when it's installed, no options = a menu):
#    bash -c "$(curl -fsSL <url>/AI_Tools/proxmox/mcp-server.sh)"
#    bash -c "$(curl -fsSL <url>)" _ --info | --status | --rotate | --update | --webui=install|sync|remove
#    bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

PX_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AI_Tools"
LIB_URL="$PX_REPO_RAW/linux/mcp-server.sh"

# ── Load the shared core (sibling file in a checkout, else download) ─────────
CORE_FILE=""; LOCAL_SRC=""
px_load_core() {
  local here=""
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../linux/mcp-server.sh ]]; then
    CORE_FILE="$here/../linux/mcp-server.sh"
    [[ -f $here/../mcp-server/gateway/app/server.py ]] && LOCAL_SRC=$(cd "$here/../mcp-server" && pwd)
  else
    CORE_FILE=$(mktemp /tmp/sudohomelab-mcp-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$CORE_FILE" || { echo "Couldn't download $LIB_URL" >&2; exit 1; }
  fi
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$CORE_FILE"
}
px_load_core

VERSION="$VERSION-proxmox"
LOG_FILE="$LOG_DIR/mcp-server-proxmox-$(date +%Y%m%d-%H%M%S).log"
TOTAL_STEPS=5
CT_TAG="sudohomelab-mcp"
CT_HOSTNAME="mcp"
CTID=""; CT_STORAGE=""; CT_BRIDGE=vmbr0; CT_IP="dhcp"; CT_GW=""
CT_CORES=4; CT_MEMORY=6144; CT_DISK=24
PX_TS=""          # inside | host | none
PASS=()           # options handed to the installer inside

usage() {
  cat <<EOF
Usage: bash mcp-server.sh [action] [options]   (Proxmox VE host, as root)

Actions: --install (default) --status --info --rotate --update --uninstall [--purge]
         --webui=install|sync|remove   (Open WebUI next to the MCP; installed by default)
Models:  --models  --add-model [--model-url=HOST:PORT --model-name=NAME --model-ids=all]
         --remove-model --model=MODEL@MACHINE   --default-model --model=MODEL@MACHINE

Options:
  --profile=minimal|standard|full   --tools=LIST|all|none   -y, --yes
  --webui=on|none                   Install Open WebUI with it (default on)
  --tailscale=inside|host|none      inside = the container joins your tailnet (HTTPS)
                                    host   = this Proxmox host routes to the container
  --ts-authkey-file=FILE            Tailscale auth key (else a login link is shown)
  --ctid=N --storage=NAME --bridge=NAME (default vmbr0)
  --ip=CIDR|dhcp --gateway=IP       Container network (default dhcp: reserve it in your router)
  --cores=N --memory=MB --disk=GB   Default 4 cores, 6144 MB, 24 GB
EOF
}

px_parse() {
  local rest=() a
  for a in "$@"; do
    case $a in
      --ctid=*) CTID=${a#*=} ;;
      --storage=*) CT_STORAGE=${a#*=} ;;
      --bridge=*) CT_BRIDGE=${a#*=} ;;
      --ip=*) CT_IP=${a#*=} ;;
      --gateway=*) CT_GW=${a#*=} ;;
      --cores=*) CT_CORES=${a#*=} ;;
      --memory=*) CT_MEMORY=${a#*=} ;;
      --disk=*) CT_DISK=${a#*=} ;;
      --tailscale=*) PX_TS=${a#*=} ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$a")
         case $a in --install|--status|--info|--rotate|--update|--uninstall|--purge) ;; *) PASS+=("$a") ;; esac ;;
    esac
  done
  [[ -z $PX_TS || $PX_TS =~ ^(inside|host|none)$ ]] || { echo "--tailscale: inside, host or none" >&2; exit 2; }
  parse_args "${rest[@]}"
}

find_ct() { # the container with our tag, if any
  local id
  for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    grep -qE "^tags:.*\b$CT_TAG\b" "/etc/pve/lxc/$id.conf" 2>/dev/null && { echo "$id"; return; }
  done
}

in_ct() { pct exec "$CTID" -- "$@"; }

core_in_ct() { # run the installer inside the container with these arguments
  in_ct bash /root/mcp-server.sh "$@"
}

push_core() {
  pct push "$CTID" "$CORE_FILE" /root/mcp-server.sh --perms 755
  if [[ -n $LOCAL_SRC ]]; then
    local t; t=$(mktemp /tmp/shl-mcp-src.XXXXXX.tgz)
    tar -czf "$t" --owner=0 --group=0 --exclude=__pycache__ -C "$LOCAL_SRC" .
    pct push "$CTID" "$t" /root/mcp-src.tgz; rm -f "$t"
    in_ct bash -c 'rm -rf /root/mcp-src && mkdir -p /root/mcp-src && tar --no-same-owner -xzf /root/mcp-src.tgz -C /root/mcp-src && rm /root/mcp-src.tgz'
  fi
}

# ── Choices ───────────────────────────────────────────────────────────────────
px_preflight() {
  [[ $EUID == 0 ]] || die "Run as root on the Proxmox host."
  command -v pveversion >/dev/null || die "This is the Proxmox version; on Ubuntu/Debian use AI_Tools/linux/mcp-server.sh."
  info "Proxmox: $(pveversion | cut -d/ -f2), $(nproc) CPU, $(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo) GB RAM"
}

px_choose() {
  local c stores
  [[ -n $CTID ]] || CTID=$(ask "Container ID" "$(pvesh get /cluster/nextid)")
  pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID already exists."
  stores=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  [[ -n $stores ]] || die "No active storage for containers."
  if [[ -z $CT_STORAGE ]]; then
    CT_STORAGE=$(grep -qx local-lvm <<<"$stores" && echo local-lvm || head -n1 <<<"$stores")
    CT_STORAGE=$(ask "Storage for the container disk ($(tr '\n' ' ' <<<"$stores"))" "$CT_STORAGE")
  fi
  grep -qx "$CT_STORAGE" <<<"$stores" || die "Storage $CT_STORAGE can't hold containers."
  CT_IP=$(ask "Container IP (CIDR like 192.168.1.90/24, or dhcp)" "$CT_IP")
  if [[ $CT_IP != dhcp && -z $CT_GW ]]; then
    CT_GW=$(ask "Gateway" "$(ip -4 route show default | awk '{print $3; exit}')")
  fi
  if [[ -z $PX_TS ]]; then
    c=$(menu "Tailscale (reach the MCP from anywhere on your tailnet)" 1 \
      "Inside the container  HTTPS address via tailscale serve, no change to this host" \
      "On this Proxmox host  subnet route to the container (approve it in the admin page)" \
      "None                  LAN only")
    PX_TS=$(case $c in 1) echo inside ;; 2) echo host ;; *) echo none ;; esac)
  fi
  [[ $PX_TS == inside ]] && TAILSCALE=on || TAILSCALE=none
  choose_options     # tools (and the auth key for "inside")
  if [[ $PX_TS == host && -z $TS_AUTHKEY && $ASSUME_YES == 0 ]] && has_tty; then
    TS_AUTHKEY=$(ask_secret "Tailscale auth key for this host (Enter = login link)")
  fi
}

px_plan() {
  say ""
  say "  ${C_BOLD}Plan${C_RESET}"
  say "    container  $CTID \"$CT_HOSTNAME\" on $CT_STORAGE · $CT_CORES CPU · $CT_MEMORY MB · $CT_DISK GB · $CT_IP"
  say "    tools      ${TOOLS//,/, }"
  say "    tailscale  $PX_TS"
  say "    open webui $([[ $WEBUI == on ]] && echo "yes, port $P_WEBUI" || echo no)"
  say "    settings   /opt/sudohomelab/mcp on this host (mounted into the container)"
  say ""
}

# ── Install ───────────────────────────────────────────────────────────────────
px_template() {
  local tpl store
  store=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
  [[ -n $store ]] || die "No storage for container templates (content vztmpl)."
  run pveam update || warn "pveam update failed; using the template list we have."
  # Same CPU architecture as this host (the list also has arm64 builds).
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  tpl=$(pveam available --section system | awk -v a="_$arch.tar" '/debian-13-standard/ && index($2, a) {print $2}' | sort -V | tail -n1)
  [[ -n $tpl ]] || tpl=$(pveam available --section system | awk -v a="_$arch.tar" '/debian-12-standard/ && index($2, a) {print $2}' | sort -V | tail -n1)
  [[ -n $tpl ]] || die "No Debian template found (pveam available)."
  if ! pveam list "$store" | grep -q "$tpl"; then
    info "Downloading $tpl…"
    run pveam download "$store" "$tpl" || die "Template download failed."
  fi
  TEMPLATE="$store:vztmpl/$tpl"
  ok "Template $tpl"
}

px_create() {
  local net="name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP" settings=/opt/sudohomelab/mcp
  [[ $CT_IP != dhcp && -n $CT_GW ]] && net+=",gw=$CT_GW"
  mkdir -p "$settings"
  chown 100000:100000 "$settings"     # container root = host uid 100000
  run pct create "$CTID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --unprivileged 1 \
    --features nesting=1,keyctl=1 --cores "$CT_CORES" --memory "$CT_MEMORY" --swap 512 \
    --rootfs "$CT_STORAGE:$CT_DISK" --net0 "$net" --onboot 1 --tags "$CT_TAG" \
    --mp0 "$settings,mp=$settings" --description "sudo homelab MCP server (AI_Tools/proxmox/mcp-server.sh)" \
    || die "pct create failed."
  if [[ $PX_TS == inside ]]; then
    cat >>"/etc/pve/lxc/$CTID.conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  fi
  if ! run pct start "$CTID"; then
    run pct destroy "$CTID" --purge 1 || true    # ours, just created: don't leave it half-made
    die "The container didn't start (it was removed again)."
  fi
  local i
  for ((i = 0; i < 40; i++)); do
    in_ct bash -c 'ip -4 route | grep -q default && getent hosts deb.debian.org' >/dev/null 2>&1 && break
    sleep 2
  done
  CT_ADDR=$(in_ct bash -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)
  [[ -n $CT_ADDR ]] || die "The container has no network (bridge $CT_BRIDGE, ip $CT_IP)."
  ok "Container $CTID running at $CT_ADDR"
}

px_host_tailscale() {
  [[ $PX_TS == host ]] || return 0
  command -v tailscale >/dev/null || { info "Installing Tailscale on this host…"; curl -fsSL https://tailscale.com/install.sh | run sh || die "Couldn't install Tailscale."; }
  local routes; routes=$(tailscale debug prefs 2>/dev/null | sed -n 's/.*"AdvertiseRoutes": *\[\(.*\)\].*/\1/p' | tr -d ' "')
  routes=$(printf '%s\n' ${routes//,/ } "$CT_ADDR/32" | sort -u | paste -sd,)
  echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-sudohomelab-tailscale.conf; run sysctl -p /etc/sysctl.d/99-sudohomelab-tailscale.conf
  if [[ -n $TS_AUTHKEY ]]; then run tailscale up --authkey="$TS_AUTHKEY" --advertise-routes="$routes" --reset=false || die "tailscale up failed."
  else tailscale up --advertise-routes="$routes" || die "tailscale up failed."; fi
  ok "This host advertises $CT_ADDR/32 to your tailnet"
  warn "Approve the route in the Tailscale admin page (Machines → this host → Edit route settings)."
}

px_install() {
  banner
  px_preflight
  px_choose
  px_plan
  confirm "Create the container and install?" || { say "  Nothing changed."; exit 0; }
  step "Debian template";  px_template
  step "Container";        px_create
  step "Installer";        push_core; ok "Installer copied into the container"
  step "Tailscale (host)"; if [[ $PX_TS == host ]]; then px_host_tailscale; else info "Not on the host ($PX_TS)"; fi
  step "MCP server (inside the container; this takes a while)"
  local opt=() optional=${TOOLS#"$ALWAYS_TOOLS"}; optional=${optional#,}
  opt+=(--install --yes "--tools=${optional:-none}" "--tailscale=$TAILSCALE" "--webui=${WEBUI:-on}")
  [[ -n $LOCAL_SRC ]] && opt+=(--src=/root/mcp-src)
  if [[ $TAILSCALE == on && -n $TS_AUTHKEY ]]; then
    local k; k=$(mktemp); printf '%s\n' "$TS_AUTHKEY" >"$k"
    pct push "$CTID" "$k" /root/.ts-authkey --perms 600; rm -f "$k"
    opt+=(--ts-authkey-file=/root/.ts-authkey)
  fi
  local rc=0
  in_ct env TS_HOSTNAME="$CT_HOSTNAME" bash /root/mcp-server.sh "${opt[@]}" || rc=$?
  in_ct rm -f /root/.ts-authkey 2>/dev/null || true
  [[ $rc == 0 ]] || die "The installer inside container $CTID failed (log: pct exec $CTID -- ls /var/log/sudohomelab)."
  say ""
  ok "Done. Container $CTID ($CT_ADDR). Run this script again for the menu."
}

px_action() { # px_action ACTION — runs one action against the container
  push_core
  case $1 in
    install) core_in_ct --install "${PASS[@]}" ${LOCAL_SRC:+--src=/root/mcp-src} ;;
    update) core_in_ct --update ${LOCAL_SRC:+--src=/root/mcp-src} ;;
    webui) core_in_ct "${PASS[@]:---webui}" ;;
    uninstall)
      if [[ $PURGE == 1 ]]; then
        confirm "Remove container $CTID AND all MCP data (memory, vault, files, tokens)? This can't be undone." || return 0
      else
        confirm "Remove container $CTID? Your data stays in /opt/sudohomelab/mcp for a re-install." || return 0
      fi
      # Tailscale "inside" leaves with the container; "host" mode keeps this host's route.
      run pct stop "$CTID" || true
      run pct destroy "$CTID" --purge 1 || die "pct destroy failed."
      ok "Container $CTID removed."
      if [[ $PURGE == 1 ]]; then rm -rf /opt/sudohomelab/mcp; ok "Data removed (/opt/sudohomelab/mcp)."
      else info "Data kept in /opt/sudohomelab/mcp (re-run the installer to use it again)."; fi
      if command -v tailscale >/dev/null && tailscale debug prefs 2>/dev/null | grep -q '/32'; then
        info "If this host advertised a route to the container, remove it: tailscale set --advertise-routes=<the others>"
      fi ;;
    *) core_in_ct "--$1" "${PASS[@]}" ;;
  esac
}

px_main() {
  px_parse "$@"
  mkdir -p "$LOG_DIR"
  local found; found=$(find_ct)
  if [[ -z $found ]]; then
    [[ -z $ACTION || $ACTION == install ]] || die "The MCP server isn't installed on this host (no container tagged $CT_TAG)."
    px_install
    { has_tty && [[ $ASSUME_YES == 0 ]]; } || return 0
    found=$(find_ct); [[ -n $found ]] || return 0
    read -r -p "  ${C_GRAY}Enter = open the menu${C_RESET} " _ </dev/tty || true
  fi
  CTID=$found
  pct status "$CTID" | grep -q running || run pct start "$CTID"
  if [[ -n $ACTION && $ACTION != install ]] || ! has_tty || [[ $ASSUME_YES == 1 ]]; then
    px_action "${ACTION:-status}"; return
  fi
  banner
  # The menu comes back after each action (subshell: an error returns here); Quit leaves.
  while :; do
    case $(menu "MCP server is installed in container $CTID. What now?" 2 \
           "Install / repair / change tools (keeps data)" "List models" "Add model (one you already run)" \
           "Remove model" "Set default model" "Status" "Connection info + join code" \
           "Open WebUI (install, refresh, remove)" "Rotate tokens" "Update" \
           "Uninstall: remove the container, KEEP the data in /opt/sudohomelab/mcp" \
           "Uninstall: remove the container AND all data (memory, vault, files)" "Quit") in
      1) ACTION=install ;; 2) ACTION=models ;; 3) ACTION=add-model ;; 4) ACTION=remove-model ;;
      5) ACTION=default-model ;; 6) ACTION=status ;; 7) ACTION=info ;; 8) ACTION=webui ;;
      9) ACTION=rotate ;; 10) ACTION=update ;; 11) ACTION=uninstall; PURGE=0 ;; 12) ACTION=uninstall; PURGE=1 ;;
      *) return 0 ;;
    esac
    PASS=()
    ( px_action "$ACTION" ) || true
    [[ $ACTION == uninstall ]] && [[ -z $(find_ct) ]] && return 0
    read -r -p "  ${C_GRAY}Enter = back to the menu${C_RESET} " _ </dev/tty || true
  done
}

px_main "$@"
