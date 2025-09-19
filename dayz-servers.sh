#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIG — tweak to your environment
############################################

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

# Env file with STEAM_USERNAME (and optional STEAM_PASSWORD)
ENV_FILE="${SCRIPT_DIR}/dayz-fleet.env"

# Shared state + default mods file next to the script
PORT_STATE_FILE="${SCRIPT_DIR}/ports.state"     # instance:port lines
GLOBAL_MODS_FILE="${SCRIPT_DIR}/mods.txt"       # fallback if no mods-<instance>.txt
BASE_MODS_FILE="${SCRIPT_DIR}/mods-base.txt"
DEFAULT_MAP="chernarus"
DEFAULT_DIFFICULTY="regular"

# SteamCMD
STEAMCMD_DIR="${HOME}/servers/steamcmd"
STEAMCMD_BIN="${STEAMCMD_DIR}/steamcmd.sh"

# Installation roots (override with DAYZ_SERVERS_HOME if you prefer a custom path)
set_instance_roots(){
  INSTANCES_ROOT="${DAYZ_SERVERS_HOME:-${HOME}/dayz-instances}"
  INSTANCES_ROOT="${INSTANCES_ROOT%/}"
  [[ -n "${INSTANCES_ROOT}" ]] || INSTANCES_ROOT="${HOME}/dayz-instances"

  LEGACY_INSTANCES_ROOT="${DAYZ_SERVERS_LEGACY_HOME:-${HOME}/servers/dayz-instances}"
  LEGACY_INSTANCES_ROOT="${LEGACY_INSTANCES_ROOT%/}"
}
set_instance_roots

# Steam app IDs
DAYZ_SERVER_APPID="223350"    # DayZ Dedicated Server
DAYZ_WORKSHOP_APPID="221100"  # DayZ (Workshop)

# Port range (inclusive) for -port
PORT_RANGE_START="${PORT_RANGE_START:-12301}"
PORT_RANGE_END="${PORT_RANGE_END:-12399}"

# Runtime defaults
DEFAULT_MAX_FD="100000"
DEFAULT_FLAGS=(-dologs -adminlog -netlog -freezecheck)
SERVICE_PREFIX="dayz"
RUN_USER="${USER}"
RUN_GROUP="${USER}"

############################################
# Helpers
############################################

die(){ echo "ERROR: $*" >&2; exit 1; }
need_bin(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

ensure_paths(){
  set_instance_roots
  mkdir -p "${INSTANCES_ROOT}" "${STEAMCMD_DIR}"
  touch "${PORT_STATE_FILE}"
}

ensure_env(){
  if [[ ! -f "${ENV_FILE}" ]]; then
    cat > "${ENV_FILE}" <<'ENV'
# Required:
# STEAM_USERNAME=your_steam_username
# Optional (avoid storing passwords if possible; let SteamCMD cache tokens):
# STEAM_PASSWORD=your_password
ENV
    echo "Created ${ENV_FILE}. Please set STEAM_USERNAME in it."
    die "Set STEAM_USERNAME in ${ENV_FILE} and rerun."
  fi
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  : "${STEAM_USERNAME:?STEAM_USERNAME must be set in ${ENV_FILE}}"
  set_instance_roots
}

to_lower(){ echo "$1" | tr '[:upper:]' '[:lower:]'; }

resolve_map_name(){
  local raw="$(to_lower "$1")"
  local name
  case "${raw}" in
    chernarus|chernarusplus|chernarus+) name="chernarus";;
    sakhal|sakhalislands|sakhal+) name="sakhal";;
    *) name="${raw}";;
  esac
  name="$(printf '%s' "${name}" | tr ' ' '-' | tr -cs 'a-z0-9-' '-')"
  name="${name##-}"
  name="${name%%-}"
  [[ -n "${name}" ]] || name="${DEFAULT_MAP}"
  echo "${name}"
}

mods_map_file(){ local map="$1"; echo "${SCRIPT_DIR}/mods-${map}.txt"; }
mods_instance_file(){ local inst="$1"; echo "${SCRIPT_DIR}/mods-${inst}.txt"; }

ensure_map_mod_stub(){
  local map="$1" file
  file="$(mods_map_file "${map}")"
  if [[ ! -f "${file}" ]]; then
    cat > "${file}" <<MAP
# Mods for the '${map}' map. One workshop ID per line.
MAP
    echo "Created ${file}. Add map-specific workshop IDs."
  fi
}

mission_template_for_map(){
  local map="$1" override="$2"
  if [[ -n "${override}" ]]; then
    echo "${override}"
    return 0
  fi
  case "${map}" in
    chernarus) echo "dayzOffline.chernarusplus";;
    sakhal) echo "dayzOffline.sakhal";;
    *)
      echo "dayzOffline.${map}"
      echo "Warning: mission template for map '${map}' not recognised. Guessing 'dayzOffline.${map}'. Override with --mission-template if needed." >&2
      ;;
  esac
}

ensure_mod_stubs(){
  if [[ ! -f "${GLOBAL_MODS_FILE}" ]]; then
    cat > "${GLOBAL_MODS_FILE}" <<'MODS'
# One workshop mod ID per line. Lines starting with # are ignored.
# Entries here apply to every server unless a per-instance file overrides them.
# 1559212036
# 1564026768
MODS
    echo "Created ${GLOBAL_MODS_FILE}. Add your mod IDs (one per line)."
  fi

  if [[ ! -f "${BASE_MODS_FILE}" ]]; then
    cat > "${BASE_MODS_FILE}" <<'BASE'
# Mods listed here are applied to every DayZ server instance.
# Example:
# 2283329970
BASE
    echo "Created ${BASE_MODS_FILE}. Add workshop IDs you always want installed."
  fi

  for map in chernarus sakhal; do
    ensure_map_mod_stub "${map}"
  done
}

port_in_use(){ local p="$1"; awk -F: -v p="${p}" 'NF==2 && $2==p {f=1} END{exit !f}' "${PORT_STATE_FILE}" 2>/dev/null || return 1; }
port_for_instance(){ local i="$1"; awk -F: -v i="${i}" 'NF==2 && $1==i {print $2; f=1} END{exit !f}' "${PORT_STATE_FILE}" 2>/dev/null || return 1; }
assign_port(){ local p; for ((p=PORT_RANGE_START;p<=PORT_RANGE_END;p++)); do ! port_in_use "$p" && { echo "$p"; return; }; done; die "No free ports in ${PORT_RANGE_START}-${PORT_RANGE_END}"; }
reserve_port(){ local i="$1" p="$2"; grep -v -E "^${i}:" "${PORT_STATE_FILE}" > "${PORT_STATE_FILE}.tmp" || true; mv "${PORT_STATE_FILE}.tmp" "${PORT_STATE_FILE}"; echo "${i}:${p}" >> "${PORT_STATE_FILE}"; }
release_port(){ local i="$1"; grep -v -E "^${i}:" "${PORT_STATE_FILE}" > "${PORT_STATE_FILE}.tmp" || true; mv "${PORT_STATE_FILE}.tmp" "${PORT_STATE_FILE}"; }

instance_dir(){
  local inst="$1"
  local primary="${INSTANCES_ROOT%/}/${inst}"
  local legacy="${LEGACY_INSTANCES_ROOT%/}/${inst}"
  if [[ -d "${primary}" || "${INSTANCES_ROOT%/}" == "${LEGACY_INSTANCES_ROOT%/}" ]]; then
    echo "${primary}"
  elif [[ -d "${legacy}" ]]; then
    echo "${legacy}"
  else
    echo "${primary}"
  fi
}
instance_exists(){ [[ -d "$(instance_dir "$1")" ]]; }

write_server_cfg(){
  local inst_dir="$1" mission_template="$2" difficulty="$3" map="$4" game_port="$5" query_port="$6" master_port="$7"
  local cfg="${inst_dir}/serverDZ.cfg"
  [[ -f "${cfg}" ]] && return 0
  cat > "${cfg}" <<CFG
// Auto-generated by dayz-servers.sh. Review and adjust as needed.
hostname = "My DayZ Server (${map})";
password = "";
passwordAdmin = "adminpass";
enableWhitelist = 0;
whitelistFile = "whitelist.txt";
maxPlayers = 60;
verifySignatures = 2;
forceSameBuild = 1;
forceSameBuildType = 0;
requiredBuild = 0;
disableVoN = 0;
vonCodecQuality = 20;
disable3rdPerson = 0;
disableCrosshair = 0;
lightingConfig = 0;
allowFilePatching = 1;
guaranteedUpdates = 1;
loginQueueConcurrentPlayers = 5;
loginQueueMaxPlayers = 500;
instanceId = ${game_port};
storageAutoFix = 1;
BattlEye = 1;
serverTime = "SystemTime";
serverTimePersistent = 1;
serverTimeAcceleration = 1;
serverNightTimeAcceleration = 1;
serverTimeOffset = "0000";
serverTimeRandom = 0;
timeStampFormat = "Short";
logAverageFPS = 1;
logMemory = 0;
logPlayers = 1;
logFile = "server_console.log";
steamQueryPort = ${query_port};
steamMasterServerPort = ${master_port};
steamStatistics = 1;
enablePlayerDiagLogs = 0;
motd[] = {
  "Welcome to My DayZ Server",
  "Configure motd[] in serverDZ.cfg"
};
motdInterval = 1;

class Missions
{
  class DayZ
  {
    template = "${mission_template}";
    difficulty = "${difficulty}";
  };
};
CFG
}

############################################
# Generators (use account login, never anonymous)
############################################

write_update_sh(){
  local inst="$1" inst_dir="$2" base_mods="$3" map_mods="$4" inst_mods="$5"
  cat > "${inst_dir}/update.sh" <<UPD
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated by dayz-servers.sh for instance: ${inst}
# Uses credentials from: ${ENV_FILE}

ENV_FILE="${ENV_FILE}"
# shellcheck disable=SC1090
source "\${ENV_FILE}"

: "\${STEAM_USERNAME:?Set STEAM_USERNAME in \${ENV_FILE}}"

STEAMCMD_BIN="${STEAMCMD_BIN}"
SERVER_DIR="${inst_dir}"
WORKSHOP_APPID="${DAYZ_WORKSHOP_APPID}"
SERVER_APPID="${DAYZ_SERVER_APPID}"
BASE_MODS_FILE="${base_mods}"
MAP_MODS_FILE="${map_mods}"
INSTANCE_MODS_FILE="${inst_mods}"
GLOBAL_MODS_FILE="${GLOBAL_MODS_FILE}"
MOD_SOURCES=(
  "\${BASE_MODS_FILE}"
  "\${MAP_MODS_FILE}"
  "\${INSTANCE_MODS_FILE}"
  "\${GLOBAL_MODS_FILE}"
)

die(){ echo "ERROR: \$*" >&2; exit 1; }
[[ -x "\${STEAMCMD_BIN}" ]] || die "steamcmd not found at \${STEAMCMD_BIN}"

read_mods(){
  declare -A seen=()
  local src line key
  for src in "\${MOD_SOURCES[@]}"; do
    [[ -f "\${src}" ]] || continue
    while IFS= read -r line; do
      [[ "\${line}" =~ ^[0-9]+$ ]] || continue
      key="\${line}"
      [[ -n \${seen[\$key]:-} ]] && continue
      seen[\$key]=1
      echo "\${line}"
    done < "\${src}"
  done
}

# Build steamcmd commands
cmds=( +force_install_dir "\${SERVER_DIR}" )
if [[ -n "\${STEAM_PASSWORD:-}" ]]; then
  cmds+=( +login "\${STEAM_USERNAME}" "\${STEAM_PASSWORD}" )
else
  cmds+=( +login "\${STEAM_USERNAME}" )
fi
cmds+=( +app_update "\${SERVER_APPID}" )

while IFS= read -r mod; do
  [[ -n "\${mod}" ]] && cmds+=( +workshop_download_item "\${WORKSHOP_APPID}" "\${mod}" )
done < <(read_mods)
cmds+=( +quit )

# shellcheck disable=SC2068
"\${STEAMCMD_BIN}" \${cmds[@]}

# Refresh links/keys
BASE="\${SERVER_DIR}/steamapps/workshop/content/\${WORKSHOP_APPID}"
mkdir -p "\${SERVER_DIR}/keys"
while IFS= read -r mod; do
  [[ -z "\${mod}" ]] && continue
  mp="\${BASE}/\${mod}"
  if [[ -d "\${mp}" ]]; then
    ln -sfn "\${mp}" "\${SERVER_DIR}/\${mod}"
    if [[ -d "\${mp}/keys" ]]; then
      find "\${mp}/keys" -type f -name "*.bikey" -print0 \
        | xargs -0 -I{} ln -sf "{}" "\${SERVER_DIR}/keys/"
    fi
  else
    echo "Warning: mod \${mod} not found at \${mp} (maybe not downloaded yet?)"
  fi
done < <(read_mods)

echo "Update complete for instance: ${inst}"
UPD
  chmod +x "${inst_dir}/update.sh"
}

write_run_sh(){
  local inst="$1" inst_dir="$2" cfg="$3" be_path="$4" profiles="$5" port="$6" base_mods="$7" map_mods="$8" inst_mods="$9"
  cat > "${inst_dir}/run.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated by dayz-servers.sh for instance: ${inst}

SERVER_DIR="${inst_dir}"
SERVER_BIN="\${SERVER_DIR}/DayZServer"
SERVER_CFG="${cfg}"
BE_PATH="${be_path}"
PROFILES_DIR="${profiles}"
PORT="${port}"
BASE_MODS_FILE="${base_mods}"
MAP_MODS_FILE="${map_mods}"
INSTANCE_MODS_FILE="${inst_mods}"
GLOBAL_MODS_FILE="${GLOBAL_MODS_FILE}"
MOD_SOURCES=(
  "\${BASE_MODS_FILE}"
  "\${MAP_MODS_FILE}"
  "\${INSTANCE_MODS_FILE}"
  "\${GLOBAL_MODS_FILE}"
)
EXTRA_FLAGS=(${DEFAULT_FLAGS[*]})

read_mods(){
  declare -A seen=()
  local src line key
  for src in "\${MOD_SOURCES[@]}"; do
    [[ -f "\${src}" ]] || continue
    while IFS= read -r line; do
      [[ "\${line}" =~ ^[0-9]+$ ]] || continue
      key="\${line}"
      [[ -n \${seen[\$key]:-} ]] && continue
      seen[\$key]=1
      echo "\${line}"
    done < "\${src}"
  done
}

build_mod_string(){
  local mods=() m
  while IFS= read -r m; do mods+=("\$m"); done < <(read_mods)
  local IFS=';'
  local joined="\${mods[*]}"
  [[ -n "\$joined" && "\${joined: -1}" != ";" ]] && joined="\${joined};"
  echo "\$joined"
}

[[ -x "\${SERVER_BIN}" ]] || { echo "DayZServer not found at \${SERVER_BIN}"; exit 1; }

mod_str="\$(build_mod_string)"
args=(
  -config="\$(basename "\${SERVER_CFG}")"
  -port="\${PORT}"
  "-mod=\${mod_str}"
  -BEpath="\$(basename "\${BE_PATH}")"
  -profiles="\$(basename "\${PROFILES_DIR}")"
  "\${EXTRA_FLAGS[@]}"
)

cd "\${SERVER_DIR}"
exec "\${SERVER_BIN}" "\${args[@]}"
RUN
  chmod +x "${inst_dir}/run.sh"
}

write_service_unit(){
  local inst="$1" inst_dir="$2" port="$3"
  local unit="/etc/systemd/system/${SERVICE_PREFIX}-${inst}.service"
  local tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<SVC
[Unit]
Description=DayZ Dedicated Server (${inst}) on port ${port}
Wants=network-online.target
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
WorkingDirectory=${inst_dir}
User=${RUN_USER}
Group=${RUN_GROUP}
LimitNOFILE=${DEFAULT_MAX_FD}
# Load Steam credentials (STEAM_USERNAME required; STEAM_PASSWORD optional)
EnvironmentFile=${ENV_FILE}
ExecStartPre=/bin/bash -lc '${inst_dir}/update.sh'
ExecStart=/bin/bash -lc '${inst_dir}/run.sh'
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s INT \$MAINPID
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVC

  echo "Installing systemd unit for ${inst} (sudo required)…"
  sudo cp "${tmp}" "${unit}"
  sudo chmod 644 "${unit}"
  rm -f "${tmp}"
  echo "  sudo systemctl daemon-reload"
  echo "  sudo systemctl enable --now ${SERVICE_PREFIX}-${inst}.service"
}

############################################
# Commands
############################################

assign_port(){
  local p
  for (( p=PORT_RANGE_START; p<=PORT_RANGE_END; p++ )); do
    if ! port_in_use "${p}"; then echo "${p}"; return 0; fi
  done
  die "No free ports in range ${PORT_RANGE_START}-${PORT_RANGE_END}"
}

cmd_install(){
  local inst=""
  local map="${DEFAULT_MAP}"
  local mission_override=""
  local difficulty="${DEFAULT_DIFFICULTY}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --map=*) map="${1#*=}"; shift ;;
      --map)
        shift
        [[ $# -gt 0 ]] || die "--map requires an argument"
        map="$1"
        shift ;;
      --mission-template=*) mission_override="${1#*=}"; shift ;;
      --mission-template)
        shift
        [[ $# -gt 0 ]] || die "--mission-template requires an argument"
        mission_override="$1"
        shift ;;
      --difficulty=*) difficulty="${1#*=}"; shift ;;
      --difficulty)
        shift
        [[ $# -gt 0 ]] || die "--difficulty requires an argument"
        difficulty="$1"
        shift ;;
      --help|-h)
        echo "Usage: $0 install <instance> [--map <name>] [--mission-template <template>] [--difficulty <level>]"
        return 0 ;;
      --)
        shift
        break ;;
      -*)
        die "Unknown option: $1" ;;
      *)
        if [[ -z "${inst}" ]]; then
          inst="$1"
          shift
        else
          die "Usage: $0 install <instance> [--map <name>] [--mission-template <template>] [--difficulty <level>]"
        fi
        ;;
    esac
  done

  [[ -n "${inst}" ]] || die "Usage: $0 install <instance> [--map <name>] [--mission-template <template>] [--difficulty <level>]"

  need_bin awk; need_bin sed
  ensure_paths
  ensure_env
  ensure_mod_stubs

  map="$(resolve_map_name "${map}")"
  ensure_map_mod_stub "${map}"
  local mission_template
  mission_template="$(mission_template_for_map "${map}" "${mission_override}")"

  local inst_dir cfg be profiles
  inst_dir="$(instance_dir "${inst}")"
  cfg="${inst_dir}/serverDZ.cfg"
  be="${inst_dir}/battleye"
  profiles="${inst_dir}/profiles"

  if instance_exists "${inst}"; then
    echo "Instance '${inst}' already exists."
  else
    mkdir -p "${inst_dir}" "${be}" "${profiles}" "${inst_dir}/keys" \
             "${inst_dir}/steamapps/workshop/content/${DAYZ_WORKSHOP_APPID}"
  fi

  # Port allocation
  local port
  if ! port="$(port_for_instance "${inst}")"; then
    port="$(assign_port)"
    reserve_port "${inst}" "${port}"
  fi

  local steam_query_port steam_master_port
  steam_query_port=$((port + 100))
  steam_master_port=$((port + 200))

  write_server_cfg "${inst_dir}" "${mission_template}" "${difficulty}" "${map}" "${port}" "${steam_query_port}" "${steam_master_port}"

  local base_mods map_mods inst_mods
  base_mods="${BASE_MODS_FILE}"
  map_mods="$(mods_map_file "${map}")"
  inst_mods="$(mods_instance_file "${inst}")"
  if [[ ! -f "${inst_mods}" ]]; then
    cat > "${inst_mods}" <<INST
# Mods for the '${inst}' instance. One workshop ID per line.
INST
    echo "Created ${inst_mods}. Populate it for per-instance mods or leave empty."
  fi

  # Per-instance scripts using account login
  write_update_sh "${inst}" "${inst_dir}" "${base_mods}" "${map_mods}" "${inst_mods}"
  write_run_sh "${inst}" "${inst_dir}" "${cfg}" "${be}" "${profiles}" "${port}" "${base_mods}" "${map_mods}" "${inst_mods}"

  echo "Running initial update for '${inst}' on port ${port}…"
  echo "If prompted for Steam Guard, complete it; SteamCMD will cache a token for future systemd runs."
  "${inst_dir}/update.sh"

  write_service_unit "${inst}" "${inst_dir}" "${port}"

  echo
  echo "Instance '${inst}' installed."
  echo "  Map:        ${map} (mission: ${mission_template}, difficulty: ${difficulty})"
  echo "  Base mods:  ${base_mods}"
  echo "  Map mods:   ${map_mods}"
  echo "  Instance:   ${inst_mods}"
  echo "  Global:     ${GLOBAL_MODS_FILE}"
  echo "  Service:    ${SERVICE_PREFIX}-${inst}.service"
  echo "  Port:       ${port} (steam query ${steam_query_port}, master ${steam_master_port})"
  echo
  echo "Start/Stop:"
  echo "  sudo systemctl restart ${SERVICE_PREFIX}-${inst}.service"
}

cmd_update(){
  local inst="${1:-}"; [[ -z "${inst}" ]] && die "Usage: $0 update <instance>"
  ensure_env
  instance_exists "${inst}" || die "Instance not found: ${inst}"
  "$(instance_dir "${inst}")/update.sh"
}

cmd_list(){
  ensure_paths
  echo "Instances:"
  if [[ ! -s "${PORT_STATE_FILE}" ]]; then
    echo "  (none yet)"
    return 0
  fi
  while IFS=: read -r inst port; do
    [[ -z "${inst}" || -z "${port}" ]] && continue
    printf "  %-20s port %s\n" "${inst}" "${port}"
  done < "${PORT_STATE_FILE}"
}

cmd_remove(){
  local inst="${1:-}"; [[ -z "${inst}" ]] && die "Usage: $0 remove <instance> [--purge]"
  local purge="${2:-}"
  instance_exists "${inst}" || die "Instance not found: ${inst}"

  local svc="${SERVICE_PREFIX}-${inst}.service"
  echo "Disabling and stopping ${svc} (sudo required)…"
  sudo systemctl disable --now "${svc}" || true
  sudo rm -f "/etc/systemd/system/${svc}"
  sudo systemctl daemon-reload || true

  release_port "${inst}"

  if [[ "${purge}" == "--purge" ]]; then
    rm -rf "$(instance_dir "${inst}")"
    echo "Removed files for instance '${inst}'."
  else
    echo "Left files intact at $(instance_dir "${inst}")"
  fi
}

case "${1:-}" in
  install) shift; cmd_install "$@";;
  update)  shift; cmd_update  "$@";;
  list)    shift; cmd_list    "$@";;
  remove)  shift; cmd_remove  "$@";;
  *) echo "Usage: $0 {install <instance> [--map <name>] [--mission-template <template>] [--difficulty <level>]|update <instance>|list|remove <instance> [--purge]}"; exit 1;;
esac
