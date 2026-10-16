#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  sudo homelab · Media Stack installer (TrueNAS SCALE 24.10+)
#  https://github.com/Eportela99/sudohomelab
#
#  Same apps and wiring as the Ubuntu version, two ways to deploy:
#    · custom   one TrueNAS "Custom App" holding the whole stack (one compose)
#    · catalog  each app installed from the TrueNAS catalog, joined to a
#               shared Docker network so they still find each other by name
#
#  All the wiring (logins, API keys, root folders, download clients, Prowlarr,
#  Seerr, Bazarr, Tdarr) is the Linux script's code, loaded as a library.
#
#  Usage (TrueNAS shell, as root or with sudo):
#    sudo bash -c "$(curl -fsSL <url>/truenas/stack/media-stack.sh)"
#    sudo bash -c "$(curl -fsSL <url>)" _ --mode=catalog --pool=tank --yes
# ──────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
# Variables set here are read by the shared core (sourced at runtime), which
# shellcheck can't follow:
# shellcheck disable=SC2034

TN_REPO_RAW="https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts"
LIB_URL="$TN_REPO_RAW/linux/stack/media-stack.sh"

# ── Load the shared core ──────────────────────────────────────────────────────
# Running from a git checkout: use the sibling file, so both are always in step.
# Running from curl: download the matching core from the same branch.
tn_load_core() {
  local here="" lib
  [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -n $here && -f $here/../../linux/stack/media-stack.sh ]]; then
    lib="$here/../../linux/stack/media-stack.sh"
  else
    lib=$(mktemp /tmp/sudohomelab-core.XXXXXX)
    curl -fsSL "$LIB_URL" -o "$lib" || { echo "Couldn't download the installer core from $LIB_URL" >&2; exit 1; }
  fi
  # shellcheck disable=SC1090
  SHL_LIBRARY=1 source "$lib"
}
tn_load_core

# ── TrueNAS defaults (override the core's) ────────────────────────────────────
VERSION="0.1.0-truenas (core $VERSION)"
SCRIPT_URL="$TN_REPO_RAW/truenas/stack/media-stack.sh"
LOG_FILE="$LOG_DIR/media-stack-truenas-$(date +%Y%m%d-%H%M%S).log"
PUID=568; PGID=568          # TrueNAS's built-in "apps" user
SEERR_UID=568
MODE=""                     # custom | catalog
POOL=""
NET=mediastack              # shared Docker network for catalog mode
CUSTOM_APP=mediastack       # TrueNAS app name in custom mode

copy_fn() { eval "$2 () $(declare -f "$1" | tail -n +2)"; }   # copy_fn existing new_name

# Small JSON helper that doesn't need jq (jq may be missing on TrueNAS).
pyj() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

mid() { midclt call "$@"; }
mid_job() { midclt call -j "$@"; }   # waits for the job and prints its progress

banner() {
  printf '%s' "$C_GREEN"
  cat <<'EOF'

     ___ _   _  __| | ___    | |__   ___  _ __ ___   ___| | __ _| |__
    / __| | | |/ _` |/ _ \   | '_ \ / _ \| '_ ` _ \ / _ \ |/ _` | '_ \
    \__ \ |_| | (_| | (_) |  | | | | (_) | | | | | |  __/ | (_| | |_) |
    |___/\__,_|\__,_|\___/   |_| |_|\___/|_| |_| |_|\___|_|\__,_|_.__/
EOF
  printf '%s\n' "$C_RESET"
  printf '    %s❯%s %sMedia Stack%s installer %sv%s · TrueNAS SCALE%s\n\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_GRAY" "$VERSION" "$C_RESET"
}

copy_fn usage core_usage
usage() {
  core_usage | sed 's/media-stack.sh \[options\]/media-stack.sh [options]   (TrueNAS SCALE)/'
  cat <<EOF

TrueNAS options:
  --mode=custom|catalog              One Custom App, or individual catalog apps
  --pool=NAME                        Pool for the config and media datasets
EOF
}

copy_fn parse_args core_parse_args
parse_args() {
  local rest=() arg
  for arg in "$@"; do
    case $arg in
      --mode=*) MODE=${arg#*=} ;;
      --pool=*) POOL=${arg#*=} ;;
      *) rest+=("$arg") ;;
    esac
  done
  core_parse_args "${rest[@]}"
  [[ -z $MODE || $MODE =~ ^(custom|catalog)$ ]] || { echo "--mode must be custom or catalog" >&2; exit 2; }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight() {
  step "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Please run as root:  sudo bash -c \"\$(curl -fsSL $SCRIPT_URL)\""
  command -v midclt >/dev/null 2>&1 || die "This is the TrueNAS version, but midclt isn't here. On Ubuntu/Debian use the Linux script."

  local ver major minor
  ver=$(mid system.version 2>/dev/null | tr -d '"') || die "Couldn't talk to the TrueNAS middleware (midclt)."
  major=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1/' <<<"$ver"); minor=$(sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\2/' <<<"$ver")
  if (( major < 24 || (major == 24 && minor < 10) )); then
    die "$ver uses the old Kubernetes apps. This installer needs TrueNAS SCALE 24.10 (Electric Eel) or newer."
  fi
  ok "$ver"

  local st
  st=$(mid docker.status | pyj 'd.get("status", "")')
  if [[ $st != RUNNING ]]; then
    die "TrueNAS Apps isn't running ($st). Open Apps → Configuration → Choose Pool, pick a pool, then re-run."
  fi
  DOCKER_POOL=$(mid docker.config | pyj 'd.get("pool") or ""')
  ok "Apps service running on pool '$DOCKER_POOL'"

  ok "$(nproc) CPU · $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo) RAM"
  TZ_NAME=$(mid system.general.config | pyj 'd.get("timezone") or "Etc/UTC"'); ok "Timezone: $TZ_NAME"
  HOST_IP=$(host_ip); ok "NAS IP: $HOST_IP"
  OWNER="apps (568)"; ok "Apps will run as TrueNAS's 'apps' user (568:568)"
  if compgen -G '/dev/dri/renderD*' >/dev/null; then
    HAS_DRI=1; ok "GPU render device found: hardware transcoding enabled"
  else
    HAS_DRI=0; info "No GPU render device: media servers will use CPU transcoding"
  fi
}

# ── Choices ───────────────────────────────────────────────────────────────────
tn_pools() { mid pool.query | pyj '"\n".join(p["name"] for p in d)'; }

copy_fn choose_options core_choose_options
choose_options() {
  # A previous install? Its config dataset holds .env: reuse pool and mode.
  local prev_env
  prev_env=$(ls -1 /mnt/*/apps/mediastack/.env 2>/dev/null | head -n1 || true)
  if [[ -n $prev_env ]]; then
    [[ -z $POOL ]] && POOL=$(cut -d/ -f3 <<<"$prev_env")
    [[ -z $MODE ]] && MODE=$(sed -n 's/^STACK_MODE=//p' "$prev_env")
  fi

  if [[ -z $MODE ]]; then
    case $(menu "How should the stack appear in TrueNAS?" 1 \
      "Custom App|one app called '$CUSTOM_APP' holding everything (one compose file)" \
      "Catalog apps|each app from the TrueNAS catalog, listed separately in Apps") in
      1) MODE=custom ;; 2) MODE=catalog ;;
    esac
  fi
  [[ $MODE =~ ^(custom|catalog)$ ]] || die "Invalid --mode '$MODE'."

  local pools n
  pools=$(tn_pools)
  [[ -n $pools ]] || die "No storage pools found. Create one in Storage first."
  if [[ -z $POOL ]]; then
    n=$(wc -l <<<"$pools")
    if (( n == 1 )); then POOL=$pools; else
      local opts=() p def=1 i=1
      while read -r p; do
        opts+=("$p|$(mid pool.dataset.query "[[\"id\",\"=\",\"$p\"]]" | pyj 'f"{int(d[0][\"available\"][\"parsed\"]) / 1e12:.1f} TB free" if d else ""')")
        [[ $p == "${DOCKER_POOL:-}" ]] && def=$i; i=$((i + 1))
      done <<<"$pools"
      POOL=$(sed -n "$(menu "Which pool should hold your media and app settings?" "$def" "${opts[@]}")p" <<<"$pools")
    fi
  fi
  grep -qx "$POOL" <<<"$pools" || die "Pool '$POOL' doesn't exist. Pools: $(paste -sd, - <<<"$pools")"
  ok "Pool: $POOL · mode: $MODE"

  INSTALL_DIR="/mnt/$POOL/apps/mediastack"
  (( DATA_DIR_SET )) || DATA_DIR="/mnt/$POOL/media"
  core_choose_options
  [[ $DATA_DIR == /mnt/*/* ]] || die "On TrueNAS the media folder must be inside a pool, e.g. /mnt/$POOL/media."
}

# ── Dependencies: nothing gets installed on the TrueNAS OS ───────────────────
install_deps() {
  step "Checking tools"
  local t
  for t in curl python3 ss docker; do command -v "$t" >/dev/null 2>&1 || die "'$t' is missing; this doesn't look like a standard TrueNAS SCALE."; done
  if command -v jq >/dev/null 2>&1; then
    ok "curl, python3, jq available"
  else
    # TrueNAS's OS is read-only: fetch a static jq for this run instead of apt.
    local arch bin=/tmp/sudohomelab-bin
    arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64 || arch=arm64
    mkdir -p "$bin"
    run "Fetching jq (static binary, this run only)" curl -fsSL -o "$bin/jq" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$arch"
    chmod +x "$bin/jq"; PATH="$bin:$PATH"
  fi
  CURL_FAIL=--fail-with-body
  curl --help all 2>/dev/null | grep -- --fail-with-body >/dev/null || CURL_FAIL=--fail
}

tn_app_exists() { [[ $(mid app.query "[[\"name\",\"=\",\"$1\"]]" | pyj 'len(d)') != 0 ]]; }

install_docker() {
  step "Checking TrueNAS Apps"
  docker info >/dev/null 2>&1 || die "Docker isn't reachable. Is the Apps service running?"
  ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null)"
  # Catalog mode: don't clobber apps the user installed by hand under the same name.
  if [[ $MODE == catalog ]]; then
    local prev a clash=()
    prev=$(sed -n 's/^STACK_APPS=//p' "$INSTALL_DIR/.env" 2>/dev/null || true)
    for a in $(tn_wanted_apps); do
      if tn_app_exists "$a" && [[ ",$prev," != *",$a,"* ]]; then clash+=("$a"); fi
    done
    (( ${#clash[@]} == 0 )) || die "These apps already exist in TrueNAS and weren't installed by this script: ${clash[*]}. Remove them in Apps (or use --mode=custom) and re-run."
  elif tn_app_exists "$CUSTOM_APP" && [[ ! -f $INSTALL_DIR/.env ]]; then
    die "A TrueNAS app named '$CUSTOM_APP' already exists and wasn't installed by this script."
  fi
  check_ports
  check_disk
}

# Compose projects that are "this stack": ix-mediastack, or ix-<app> in catalog mode.
our_project() {
  [[ $1 == "ix-$CUSTOM_APP" ]] && return 0
  local a
  for a in $(tn_wanted_apps 2>/dev/null) ${PREV_APPS:-}; do [[ $1 == "ix-$a" ]] && return 0; done
  return 1
}

tn_wanted_apps() { # install order: downloaders, *arrs, media servers, extras, Seerr last
  local a=()
  want qbittorrent && a+=(qbittorrent); want sabnzbd && a+=(sabnzbd)
  a+=(prowlarr radarr sonarr); want lidarr && a+=(lidarr)
  want jellyfin && a+=(jellyfin); want plex && a+=(plex)
  want bazarr && a+=(bazarr); want tdarr && a+=(tdarr)
  a+=(seerr)
  echo "${a[@]}"
}

# ── Datasets + folders ────────────────────────────────────────────────────────
tn_ensure_dataset() { # tn_ensure_dataset pool/path
  local ds=$1 parent=${1%/*}
  [[ $(mid pool.dataset.query "[[\"id\",\"=\",\"$ds\"]]" | pyj 'len(d)') != 0 ]] && return 0
  [[ $parent != "$ds" && $parent == */* ]] && tn_ensure_dataset "$parent"
  mid pool.dataset.create "{\"name\": \"$ds\", \"share_type\": \"GENERIC\"}" >/dev/null
  echo "created dataset $ds"
}

copy_fn prepare_folders core_prepare_folders
prepare_folders() {
  tn_set_addresses    # before config.xml is seeded: catalog apps listen on their published port
  local cfg_ds="$POOL/apps/mediastack" media_ds
  media_ds=${DATA_DIR#/mnt/}
  run "Dataset $cfg_ds (app settings)" tn_ensure_dataset "$cfg_ds"
  # The media dataset holds Movies, TV_Shows and Active_Downloads as FOLDERS:
  # hardlinks can't cross datasets, so splitting them would turn every import into a copy.
  if [[ ! -d $DATA_DIR ]]; then
    run "Dataset $media_ds (media + downloads, one dataset so imports are instant hardlinks)" tn_ensure_dataset "$media_ds"
  else
    ok "Using existing $DATA_DIR"
  fi
  core_prepare_folders
}

# ── Compose / catalog values ──────────────────────────────────────────────────
copy_fn write_compose core_write_compose
write_compose() {
  core_write_compose            # .env, .secrets and the compose file (used as-is in custom mode)
  local apps
  apps=$( [[ $MODE == catalog ]] && tn_wanted_apps | tr ' ' ',' || echo "$CUSTOM_APP")
  {
    echo "STACK_MODE=$MODE"
    echo "STACK_APPS=$apps"
  } >>"$INSTALL_DIR/.env"
  if [[ $MODE == custom ]]; then
    run "Rendering the compose file for TrueNAS" tn_render_custom
  else
    run "Building catalog app settings" tn_build_catalog_values
  fi
}

# Resolve .env variables and relative paths, add TrueNAS specifics, output JSON.
tn_render_custom() {
  docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/docker-compose.yml" config --format json >"$INSTALL_DIR/.compose.json"
  python3 - "$INSTALL_DIR/.compose.json" "$SEERR_UID" <<'PY'
import json, sys
path, uid = sys.argv[1], sys.argv[2]
c = json.load(open(path))
c.pop("name", None)                      # TrueNAS names the project ix-<app>
c["services"]["seerr"]["user"] = f"{uid}:{uid}"
json.dump(c, open(path, "w"), indent=1)
PY
}

tn_build_catalog_values() {
  mkdir -p "$INSTALL_DIR/.catalog"
  local a
  for a in $(tn_wanted_apps); do
    APP=$a CFG="$INSTALL_DIR/config" DATA="$DATA_DIR" NET=$NET TZ_NAME=$TZ_NAME HAS_DRI=$HAS_DRI PLEX_CLAIM=$PLEX_CLAIM \
    P_APP=$(tn_port_of "$a") P_TORRENT=$P_TORRENT P_TDARR_SRV=$P_TDARR_SRV UID_=$PUID \
      python3 - >"$INSTALL_DIR/.catalog/$a.json" <<'PY'
import json, os
e = os.environ
app, cfg, data = e["APP"], e["CFG"], e["DATA"]
port = int(e["P_APP"])

def hp(path, mount=None, ro_field=True):
    v = {"type": "host_path", "host_path_config": {"acl_enable": False, "path": path}}
    if mount:
        v["mount_path"] = mount
        if ro_field:            # additional_storage entries have read_only; fixed mounts don't
            v["read_only"] = False
    return v

v = {
    "TZ": e["TZ_NAME"],
    "run_as": {"user": int(e["UID_"]), "group": int(e["UID_"])},
    "network": {
        "host_network": False,
        "web_port": {"bind_mode": "published", "port_number": port, "host_ips": []},
        # Shared network + alias = the apps find each other by name, like one compose project.
        "networks": [{"name": e["NET"], "containers": [{"name": app, "config": {"aliases": [app]}}]}],
    },
    "storage": {"config": hp(f"{cfg}/{app}"), "additional_storage": [hp(data, "/data")]},
}
if app in ("radarr", "sonarr", "prowlarr", "lidarr"):
    v[app] = {"instance_name": app.capitalize(), "additional_envs": []}
elif app in ("bazarr", "sabnzbd", "seerr"):
    v[app] = {"additional_envs": []}
elif app == "qbittorrent":
    v[app] = {"additional_envs": []}
    v["network"]["bt_port"] = {"bind_mode": "published", "port_number": int(e["P_TORRENT"]), "host_ips": []}
    # Required by the catalog app; the stack itself uses /data/Active_Downloads/torrents.
    v["storage"]["downloads"] = hp(f"{data}/Active_Downloads/torrents", "/downloads", ro_field=False)
elif app == "jellyfin":
    v[app] = {"additional_envs": [], "devices": [{"host_device": "/dev/dri", "container_device": "/dev/dri"}] if e["HAS_DRI"] == "1" else []}
elif app == "plex":
    # Host network like the Ubuntu stack: local discovery + first-run setup just work.
    v["network"] = {"host_network": True, "web_port": {"bind_mode": "published", "port_number": 32400, "host_ips": []}}
    v[app] = {"claim_token": e.get("PLEX_CLAIM", ""), "additional_envs": [],
              "devices": [{"host_device": "/dev/dri", "container_device": "/dev/dri"}] if e["HAS_DRI"] == "1" else []}
    v["storage"] = {"config": hp(f"{cfg}/plex"), "data": hp(data), "additional_storage": []}
elif app == "tdarr":
    v[app] = {"internal_node": True, "node_name": "InternalNode", "additional_envs": []}
    v["network"]["server_port"] = {"bind_mode": "published", "port_number": int(e["P_TDARR_SRV"]), "host_ips": []}
    v["storage"].update({
        "server": hp(f"{cfg}/tdarr/server"), "configs": hp(f"{cfg}/tdarr/configs"),
        "logs": hp(f"{cfg}/tdarr/logs"), "transcodes": hp(f"{data}/Transcode_Cache"),
    })
    del v["storage"]["config"]
print(json.dumps(v))
PY
  done
}

tn_port_of() {
  case $1 in
    radarr) echo "$P_RADARR" ;; sonarr) echo "$P_SONARR" ;; prowlarr) echo "$P_PROWLARR" ;; lidarr) echo "$P_LIDARR" ;;
    qbittorrent) echo "$P_QBIT" ;; sabnzbd) echo "$P_SAB" ;; jellyfin) echo "$P_JELLYFIN" ;; plex) echo "$P_PLEX" ;;
    bazarr) echo "$P_BAZARR" ;; tdarr) echo "$P_TDARR" ;; seerr) echo "$P_SEERR" ;;
  esac
}

tn_train() { [[ $1 == plex ]] && echo stable || echo community; }

# In catalog mode each app listens INSIDE its container on the port it publishes
# (the catalog passes it via RADARR__SERVER__PORT, SABNZBD__PORT, QBT_WEBUI_PORT…),
# so the wiring uses <alias>:<that port>. Jellyfin keeps its internal 8096.
tn_set_addresses() {
  [[ $MODE == catalog ]] || return 0
  I_RADARR=$P_RADARR; I_SONARR=$P_SONARR; I_PROWLARR=$P_PROWLARR; I_LIDARR=$P_LIDARR; I_SAB=$P_SAB
}

# ── Deploy ────────────────────────────────────────────────────────────────────
pull_images() {
  if [[ $MODE == custom ]]; then
    run "Downloading images" dc --progress plain pull
  else
    info "TrueNAS downloads each catalog app's image while installing it"
  fi
}

tn_job() { # tn_job method args... : run a middleware job, fail with its error message
  local out rc=0
  out=$(mid_job "$@" 2>&1) || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || return "$rc"
}

deploy_stack() {
  if [[ $MODE == custom ]]; then
    local cfg; cfg=$(cat "$INSTALL_DIR/.compose.json")
    if tn_app_exists "$CUSTOM_APP"; then
      run "Updating TrueNAS app '$CUSTOM_APP'" tn_job app.update "$CUSTOM_APP" "{\"custom_compose_config\": $cfg}"
    else
      run "Creating TrueNAS app '$CUSTOM_APP' ($1 containers)" tn_job app.create \
        "{\"custom_app\": true, \"app_name\": \"$CUSTOM_APP\", \"custom_compose_config\": $cfg}"
    fi
    return 0
  fi

  if ! docker network inspect "$NET" >/dev/null 2>&1; then
    run "Creating shared network '$NET'" docker network create "$NET"
  fi
  local a values
  for a in $(tn_wanted_apps); do
    values=$(cat "$INSTALL_DIR/.catalog/$a.json")
    if tn_app_exists "$a"; then
      run "Updating $a" tn_job app.update "$a" "{\"values\": $values}"
    else
      run "Installing $a from the catalog ($(tn_train "$a") train)" tn_job app.create \
        "{\"app_name\": \"$a\", \"catalog_app\": \"$a\", \"train\": \"$(tn_train "$a")\", \"values\": $values}"
    fi
  done
}

copy_fn start_stack core_start_stack
start_stack() { tn_set_addresses; core_start_stack; }

# Container names: fixed in custom mode; ix-<app>-<service>-N for catalog apps.
ctr() {
  if [[ $MODE == custom ]]; then echo "$1"; return; fi
  docker ps -a --filter "label=com.docker.compose.project=ix-$1" --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -n1
}
svc_up() { docker start "$(ctr "$1")" >/dev/null; }
svc_start() { docker start "$(ctr "$1")" >/dev/null; }
svc_stop() { docker stop "$(ctr "$1")" >/dev/null; }
svc_restart() { docker restart "$(ctr "$1")" >/dev/null; }

manage_hint() {
  printf '\n    %sManage:%s TrueNAS → Apps (%s). Settings: %s, media: %s\n' "$C_GRAY" "$C_RESET" \
    "$( [[ $MODE == custom ]] && echo "app '$CUSTOM_APP'" || echo "one app per service" )" "$INSTALL_DIR" "$DATA_DIR"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  banner
  [[ $EUID -eq 0 ]] || die "Please run as root (sudo)."
  local env
  env=$(ls -1 /mnt/*/apps/mediastack/.env 2>/dev/null | head -n1 || true)
  [[ -n $env ]] || die "No sudo homelab media stack found on this NAS."
  INSTALL_DIR=${env%/.env}; POOL=$(cut -d/ -f3 <<<"$env")
  MODE=$(sed -n 's/^STACK_MODE=//p' "$env"); local apps; apps=$(sed -n 's/^STACK_APPS=//p' "$env")
  warn "This removes the media stack apps from TrueNAS: ${apps//,/, }"
  (( PURGE )) && warn "--purge: the app settings dataset $POOL/apps/mediastack will be deleted too."
  info "Your media dataset is never touched."
  confirm "Continue?" || { info "Cancelled. Nothing was changed."; exit 0; }
  local a
  for a in ${apps//,/ }; do
    if tn_app_exists "$a"; then run "Removing app $a" tn_job app.delete "$a" '{"remove_images": false}'; fi
  done
  if [[ $MODE == catalog ]] && docker network inspect "$NET" >/dev/null 2>&1; then
    run "Removing network '$NET'" docker network rm "$NET"
  fi
  if (( PURGE )); then
    run "Deleting dataset $POOL/apps/mediastack" mid pool.dataset.delete "$POOL/apps/mediastack" '{"recursive": true}'
  fi
  ok "Uninstalled."
}

main "$@"
