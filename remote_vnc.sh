#!/usr/bin/env bash

set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_directory}/cluster_helpers.sh"

cluster_name="bluehive3"
partition_name="doppelbock"
cpu_count=16
gpu_count=1
memory_gb=256
time_hours=24
requested_node=""
root_override=""
open_vnc_viewer=true
restart_existing_job=false
startup_timeout_seconds=300
image_build_timeout_seconds=1800
environment_build_timeout_seconds=10800
environment_name="default"
environment_mode="mutable"
vnc_geometry="2560x1440"
local_opencodex_port=10102

start_ssh_control_script="${script_directory}/start_ssh_control.sh"
read_user_password_script="${script_directory}/read_user_password.sh"
update_ssh_config_script="${script_directory}/update_ssh_config.sh"
remote_tools_script="${script_directory}/remote_tools.sh"
vnc_bundle_directory="${script_directory}/remote_vnc"
identity_file="${REMOTE_VNC_IDENTITY_FILE:-${HOME}/.ssh/id_ed25519}"
shared_image_default="/scratch/snormanh_lab/shared/remote-vnc/images/ubuntu-vnc-xfce-g3_24.04.sif"

print_usage() {
    cat <<'EOF'
Usage: remote_vnc.sh [options]

Start or reuse an independent VNC Slurm job. A mutable job starts OpenCodex,
Codex app-server, and a public-key-only SSH service inside its persistent
Apptainer environment. The script updates the existing Mac SSH entry "blhc3",
creates the VNC tunnel, and opens TigerVNC when installed. Direct SSH opens Fish
inside the container; bluehive-host-shell returns to the allocated host.

The resource options match remote_sshd.sh. They apply when a new VNC job is
submitted; an already-running VNC job is reused and its actual allocation is
reported.

Options:
  -p, --partition PARTITION  Slurm partition (default: doppelbock)
  -a, --cluster CLUSTER      Cluster name (default: bluehive3)
  -c, --cpus CPUS            CPUs for a new job (default: 16)
  -g, --gpus GPUS            GPUs for a new job; 0 disables GPUs (default: 1)
  -m, --memory MEMORY        Memory in GiB for a new job (default: 256)
  -t, --time HOURS           Time limit in hours for a new job (default: 24)
  -w, --node NODE            Request a specific compute node
  -r, --root PATH            Override REMOTE_SHARED_ROOT
  --env NAME                 Persistent environment name (default: default)
  --geometry WIDTHxHEIGHT    Initial/fallback VNC size (default: 2560x1440)
  --immutable                Run the original read-only VNC image
  --restart     Replace the current VNC job with a newly managed job
  --no-open     Prepare SSH and VNC without opening a VNC viewer
  -h, --help    Show this help

After startup:
  ssh blhc3

Configuration:
  user_password.txt line 4  Fixed remote SSH port (44000-44999; auto-created)
EOF
}

log_message() {
    printf '[remote-vnc] %s\n' "$*"
}

fail() {
    printf '[remote-vnc] Error: %s\n' "$*" >&2
    exit 1
}

require_option_value() {
    local option_name="$1"
    local option_value="${2:-}"

    [[ -n "${option_value}" && "${option_value}" != -* ]] ||
        fail "${option_name} requires a value"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--partition)
            require_option_value "$1" "${2:-}"
            partition_name="$2"
            shift 2
            ;;
        -a|--cluster)
            require_option_value "$1" "${2:-}"
            cluster_name="$2"
            shift 2
            ;;
        --cluster=*)
            cluster_name="${1#*=}"
            shift
            ;;
        -c|--cpus)
            require_option_value "$1" "${2:-}"
            cpu_count="$2"
            shift 2
            ;;
        -g|--gpus)
            require_option_value "$1" "${2:-}"
            gpu_count="$2"
            shift 2
            ;;
        -m|--memory)
            require_option_value "$1" "${2:-}"
            memory_gb="$2"
            shift 2
            ;;
        -t|--time)
            require_option_value "$1" "${2:-}"
            time_hours="$2"
            shift 2
            ;;
        -w|--node)
            require_option_value "$1" "${2:-}"
            requested_node="$2"
            shift 2
            ;;
        -r|--root)
            require_option_value "$1" "${2:-}"
            root_override="$2"
            shift 2
            ;;
        --root=*)
            root_override="${1#*=}"
            [[ -n "${root_override}" ]] || fail "--root requires a value"
            shift
            ;;
        --env)
            require_option_value "$1" "${2:-}"
            environment_name="$2"
            shift 2
            ;;
        --env=*)
            environment_name="${1#*=}"
            [[ -n "${environment_name}" ]] || fail "--env requires a value"
            shift
            ;;
        --geometry)
            require_option_value "$1" "${2:-}"
            vnc_geometry="$2"
            shift 2
            ;;
        --geometry=*)
            vnc_geometry="${1#*=}"
            [[ -n "${vnc_geometry}" ]] || fail "--geometry requires a value"
            shift
            ;;
        --immutable)
            environment_mode="immutable"
            shift
            ;;
        --no-open)
            open_vnc_viewer=false
            shift
            ;;
        --restart)
            restart_existing_job=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done
[[ $# -eq 0 ]] || fail "unexpected positional arguments: $*"

require_cluster "${cluster_name}" || exit 1
[[ "${partition_name}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "invalid partition name: ${partition_name}"
[[ "${cpu_count}" =~ ^[1-9][0-9]*$ ]] || fail "CPUS must be a positive integer"
[[ "${gpu_count}" =~ ^[0-9]+$ ]] || fail "GPUS must be a non-negative integer"
[[ "${memory_gb}" =~ ^[1-9][0-9]*$ ]] || fail "MEMORY must be a positive integer"
[[ "${time_hours}" =~ ^[1-9][0-9]*$ ]] || fail "HOURS must be a positive integer"
[[ "${environment_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    fail "invalid environment name: ${environment_name}"
if [[ "${vnc_geometry}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    vnc_width="${BASH_REMATCH[1]}"
    vnc_height="${BASH_REMATCH[2]}"
else
    fail "invalid VNC geometry: ${vnc_geometry} (expected WIDTHxHEIGHT)"
fi
((vnc_width >= 1024 && vnc_width <= 7680 &&
  vnc_height >= 768 && vnc_height <= 4320)) ||
    fail "VNC geometry must be between 1024x768 and 7680x4320"
if [[ -n "${requested_node}" ]]; then
    [[ "${requested_node}" =~ ^[A-Za-z0-9._-]+$ ]] ||
        fail "invalid node name: ${requested_node}"
fi

for required_command in ssh scp sftp ssh-keygen lsof nc curl awk sed cksum mktemp launchctl plutil; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "required command is unavailable: ${required_command}"
done
[[ -x "${start_ssh_control_script}" ]] ||
    fail "SSH control script is missing or is not executable: ${start_ssh_control_script}"
[[ -r "${read_user_password_script}" ]] ||
    fail "user configuration script is missing: ${read_user_password_script}"
[[ -x "${update_ssh_config_script}" ]] ||
    fail "SSH config script is missing or is not executable: ${update_ssh_config_script}"
[[ -r "${remote_tools_script}" ]] ||
    fail "remote tool helper is missing: ${remote_tools_script}"
[[ -d "${vnc_bundle_directory}" ]] ||
    fail "VNC bundle is missing: ${vnc_bundle_directory}"
[[ -r "${identity_file}" && -r "${identity_file}.pub" ]] ||
    fail "SSH identity or public key is missing: ${identity_file}"
ssh-keygen -lf "${identity_file}.pub" >/dev/null ||
    fail "invalid SSH public key: ${identity_file}.pub"

login_host_alias="${cluster_name}"
case "${cluster_name}" in
    bluehive3) vnc_ssh_alias="blhc3" ;;
    bluehive) vnc_ssh_alias="blhc" ;;
    bhward) vnc_ssh_alias="bhwc" ;;
esac
vnc_host_key_alias="remote-vnc-${cluster_name}"
legacy_vnc_ssh_alias="bhvnc"
legacy_ssh_control_path="/tmp/ssh_remote_vnc_${cluster_name}"
known_hosts_file="${HOME}/.ssh/known_hosts_remote_vnc_${cluster_name}"
ssh_config_file="${HOME}/.ssh/config"
local_connection_state_file="${HOME}/.ssh/remote_vnc_${cluster_name}.env"
local_user_name="$(id -un)"
launch_agent_label="com.${local_user_name}.remote-vnc.${cluster_name}"
launch_agent_domain="gui/$(id -u)"
launch_agent_directory="${HOME}/Library/LaunchAgents"
launch_agent_file="${launch_agent_directory}/${launch_agent_label}.plist"
launch_agent_stdout="${HOME}/Library/Logs/remote-vnc-${cluster_name}.out.log"
launch_agent_stderr="${HOME}/Library/Logs/remote-vnc-${cluster_name}.err.log"
remote_requested_node="${requested_node:-__REMOTE_VNC_SCHEDULER__}"

login_control_path="$(
    /usr/bin/ssh -G "${login_host_alias}" 2>/dev/null |
        awk '$1 == "controlpath" { print $2; exit }'
)"
if [[ -z "${login_control_path}" || "${login_control_path}" == "none" ]]; then
    login_control_path="/tmp/ssh_${cluster_name}"
fi
[[ "${login_control_path}" == /* && "${login_control_path}" != *%* ]] ||
    fail "could not resolve the login SSH ControlPath: ${login_control_path}"

ensure_login_control_master() {
    local control_check

    control_check="$(
        /usr/bin/ssh -S "${login_control_path}" -O check \
            "${login_host_alias}" 2>&1 || true
    )"
    if [[ "${control_check}" == *"Master running"* ]]; then
        return 0
    fi

    if [[ -S "${login_control_path}" ]]; then
        unlink "${login_control_path}"
    elif [[ -e "${login_control_path}" ]]; then
        fail "login ControlPath exists but is not a socket: ${login_control_path}"
    fi

    log_message "Starting the login SSH master; approve the Duo request."
    "${start_ssh_control_script}" -a "${cluster_name}" ||
        fail "could not start the login SSH master"

    control_check="$(
        /usr/bin/ssh -S "${login_control_path}" -O check \
            "${login_host_alias}" 2>&1 || true
    )"
    [[ "${control_check}" == *"Master running"* ]] ||
        fail "the login SSH master is not running at ${login_control_path}"
}

export PASSWORD="${PASSWORD:-}"
READ_USER_PASSWORD_INITIALIZE_VNC_PORT=true
# shellcheck disable=SC1090
source "${read_user_password_script}"
unset READ_USER_PASSWORD_INITIALIZE_VNC_PORT
remote_user_name="${USER}"
[[ "${remote_user_name}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "invalid remote user name: ${remote_user_name}"
configured_remote_ssh_port="${REMOTE_VNC_SSH_PORT}"
[[ "${configured_remote_ssh_port}" =~ ^[0-9]+$ ]] &&
    ((configured_remote_ssh_port >= 44000 && configured_remote_ssh_port <= 44999)) ||
    fail "line 4 of ${USER_PASSWORD_FILE} must be a port from 44000 to 44999"
managed_launcher_comment="remote-vnc-managed-v13:${environment_name}:${environment_mode}:${configured_remote_ssh_port}:${vnc_geometry}"

CLUSTER="${cluster_name}"
HOSTNAME="$(cluster_hostname "${cluster_name}")" || exit 1
if [[ -n "${root_override}" ]]; then
    REMOTE_SHARED_ROOT="${root_override}"
    export REMOTE_SHARED_ROOT
fi
[[ -n "${REMOTE_SHARED_ROOT}" ]] || fail "REMOTE_SHARED_ROOT is empty"
shared_image_path="${REMOTE_VNC_SHARED_IMAGE:-${shared_image_default}}"

log_message \
    "Cluster=${cluster_name} partition=${partition_name} CPUs=${cpu_count}" \
    "GPUs=${gpu_count} memory=${memory_gb}G time=${time_hours}h" \
    "node=${requested_node:-scheduler}"
log_message "Environment=${environment_name} mode=${environment_mode}"
log_message "VNC geometry=${vnc_geometry}"
log_message "REMOTE_SHARED_ROOT=${REMOTE_SHARED_ROOT}"
if [[ "${REMOTE_VNC_SSH_PORT_CREATED}" == "true" ]]; then
    log_message \
        "Saved fixed remote SSH port ${configured_remote_ssh_port} to line 4 of ${USER_PASSWORD_FILE}."
else
    log_message "Fixed remote SSH port=${configured_remote_ssh_port}"
fi
ensure_login_control_master

REMOTE_TOOLS_CONTROL_PATH="${login_control_path}"
export CLUSTER HOSTNAME USER REMOTE_SHARED_ROOT REMOTE_TOOLS_CONTROL_PATH
# shellcheck disable=SC1090
source "${remote_tools_script}"
log_message "Checking and copying the VNC bundle when needed..."
ensure_remote_vnc_bundle || fail "could not prepare the remote VNC bundle"

vnc_root_directory="${REMOTE_SHARED_ROOT%/}/remote-vnc"
vnc_release_directory="${REMOTE_VNC_RELEASE_DIRECTORY}"
vnc_user_service_directory="${vnc_root_directory}/users/${remote_user_name}"
remote_job_launcher_file="${vnc_release_directory}/remote_vnc_job.sh"
remote_helper_file="${vnc_release_directory}/remote_vnc_job_sshd.sh"
remote_authorized_keys_file="${vnc_user_service_directory}/state/remote-vnc-authorized-key.pub"
remote_key_temporary_file="${remote_authorized_keys_file}.tmp.$$"
remote_bh_env_config_file="${vnc_user_service_directory}/state/bh-env-config.env"
remote_bh_env_wrapper="${vnc_user_service_directory}/bin/bh-env"

remote_tools_ssh_bash_args "${vnc_user_service_directory}" <<'REMOTE_PREPARE'
set -Eeuo pipefail
user_service_directory="$1"
umask 077
private_directories=(
    "${user_service_directory}"
    "${user_service_directory}/state"
    "${user_service_directory}/state/jobs"
    "${user_service_directory}/state/remote-ssh"
    "${user_service_directory}/state/sbatch"
    "${user_service_directory}/logs"
    "${user_service_directory}/images"
    "${user_service_directory}/environments"
    "${user_service_directory}/bin"
)
mkdir -p "${private_directories[@]}"
chmod 700 "${private_directories[@]}"
chmod g-s "${private_directories[@]}"

persistent_ssh_directory="${user_service_directory}/state/remote-ssh"
persistent_server_key="${persistent_ssh_directory}/server-key"
persistent_server_public_key="${persistent_server_key}.pub"
persistent_server_key_lock="${persistent_ssh_directory}/server-key.lock"
temporary_key_directory=""

cleanup_temporary_key_directory() {
    if [[ -n "${temporary_key_directory}" &&
          -d "${temporary_key_directory}" ]]; then
        rm -f \
            "${temporary_key_directory}/server-key" \
            "${temporary_key_directory}/server-key.pub"
        rmdir "${temporary_key_directory}" 2>/dev/null || true
    fi
}
trap cleanup_temporary_key_directory EXIT

validate_persistent_server_key() {
    local derived_public_key
    local recorded_public_key

    [[ -s "${persistent_server_key}" &&
       -s "${persistent_server_public_key}" ]] || return 1
    ssh-keygen -lf "${persistent_server_key}" >/dev/null 2>&1 || return 1
    ssh-keygen -lf "${persistent_server_public_key}" >/dev/null 2>&1 || return 1
    derived_public_key="$(
        ssh-keygen -y -f "${persistent_server_key}" |
            awk 'NF >= 2 { print $1 " " $2; exit }'
    )" || return 1
    recorded_public_key="$(
        awk 'NF >= 2 { print $1 " " $2; exit }' \
            "${persistent_server_public_key}"
    )"
    [[ -n "${derived_public_key}" &&
       "${derived_public_key}" == "${recorded_public_key}" ]]
}

exec 9> "${persistent_server_key_lock}"
flock -w 30 9 || {
    printf 'Timed out waiting for the persistent SSH host-key lock: %s\n' \
        "${persistent_server_key_lock}" >&2
    exit 2
}

[[ ! -L "${persistent_server_key}" &&
   ! -L "${persistent_server_public_key}" ]] || {
    printf 'Persistent SSH host-key files must not be symbolic links: %s\n' \
        "${persistent_ssh_directory}" >&2
    exit 2
}

if [[ ! -e "${persistent_server_key}" &&
      ! -e "${persistent_server_public_key}" ]]; then
    temporary_key_directory="$(
        mktemp -d "${persistent_ssh_directory}/.server-key.XXXXXX"
    )"
    ssh-keygen -q -t ed25519 -N '' \
        -f "${temporary_key_directory}/server-key"
    chmod 600 "${temporary_key_directory}/server-key"
    chmod 644 "${temporary_key_directory}/server-key.pub"
    mv "${temporary_key_directory}/server-key" "${persistent_server_key}"
    mv "${temporary_key_directory}/server-key.pub" \
        "${persistent_server_public_key}"
    rmdir "${temporary_key_directory}"
    temporary_key_directory=""
    persistent_server_key_status="created"
elif [[ -s "${persistent_server_key}" &&
        ! -e "${persistent_server_public_key}" ]]; then
    temporary_key_directory="$(
        mktemp -d "${persistent_ssh_directory}/.server-key.XXXXXX"
    )"
    ssh-keygen -y -f "${persistent_server_key}" \
        > "${temporary_key_directory}/server-key.pub"
    chmod 644 "${temporary_key_directory}/server-key.pub"
    mv "${temporary_key_directory}/server-key.pub" \
        "${persistent_server_public_key}"
    rmdir "${temporary_key_directory}"
    temporary_key_directory=""
    persistent_server_key_status="repaired public key"
elif [[ ! -s "${persistent_server_key}" ]]; then
    printf 'Persistent SSH host-key private file is missing or empty: %s\n' \
        "${persistent_server_key}" >&2
    exit 2
else
    persistent_server_key_status="reused"
fi

chmod 600 "${persistent_server_key}" "${persistent_server_key_lock}"
chmod 644 "${persistent_server_public_key}"
validate_persistent_server_key || {
    printf 'Persistent SSH host-key pair is invalid or mismatched under %s.\n' \
        "${persistent_ssh_directory}" >&2
    exit 2
}
printf '[remote-vnc] Persistent SSH host key %s: %s\n' \
    "${persistent_server_key_status}" "${persistent_server_public_key}" >&2
REMOTE_PREPARE

/usr/bin/scp -q -O -o BatchMode=yes -o "ControlPath=${login_control_path}" \
    "${identity_file}.pub" \
    "${login_host_alias}:${remote_key_temporary_file}" ||
    fail "could not upload the Mac public key"
remote_tools_ssh_bash_args \
    "${remote_key_temporary_file}" "${remote_authorized_keys_file}" <<'REMOTE_INSTALL_KEY'
set -Eeuo pipefail
temporary_key_file="$1"
authorized_keys_file="$2"
ssh-keygen -lf "${temporary_key_file}" >/dev/null
chmod 600 "${temporary_key_file}"
mv "${temporary_key_file}" "${authorized_keys_file}"
REMOTE_INSTALL_KEY

remote_tools_ssh_bash_args \
    "${vnc_release_directory}" \
    "${vnc_user_service_directory}" \
    "${remote_bh_env_config_file}" \
    "${remote_bh_env_wrapper}" \
    "default" \
    "${shared_image_path}" \
    "${environment_build_timeout_seconds}" <<'REMOTE_INSTALL_BH_ENV'
set -Eeuo pipefail
release_directory="$1"
user_service_directory="$2"
config_file="$3"
wrapper_file="$4"
default_environment_name="$5"
base_image_path="$6"
environment_build_timeout_seconds="$7"
bh_env_script="${release_directory}/bh-env.sh"

[[ -x "${bh_env_script}" ]] || {
    printf 'bh-env release script is missing: %s\n' "${bh_env_script}" >&2
    exit 2
}
mkdir -p \
    "${user_service_directory}/bin" \
    "$(dirname "${config_file}")" \
    "${HOME}/.local/bin"
chmod 700 \
    "${user_service_directory}/bin" \
    "$(dirname "${config_file}")" \
    "${HOME}/.local/bin" 2>/dev/null || true

temporary_config_file="${config_file}.tmp.$$"
{
    printf 'BH_ENV_RELEASE_DIRECTORY=%q\n' "${release_directory}"
    printf 'BH_ENV_USER_SERVICE_DIRECTORY=%q\n' "${user_service_directory}"
    printf 'BH_ENV_DEFAULT_NAME=%q\n' "${default_environment_name}"
    printf 'BH_ENV_BASE_IMAGE=%q\n' "${base_image_path}"
    printf 'BH_ENV_BUILD_TIMEOUT_SECONDS=%q\n' \
        "${environment_build_timeout_seconds}"
} > "${temporary_config_file}"
chmod 600 "${temporary_config_file}"
mv "${temporary_config_file}" "${config_file}"

temporary_wrapper_file="${wrapper_file}.tmp.$$"
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'exec %q --config %q "$@"\n' "${bh_env_script}" "${config_file}"
} > "${temporary_wrapper_file}"
chmod 700 "${temporary_wrapper_file}"
mv "${temporary_wrapper_file}" "${wrapper_file}"

home_command="${HOME}/.local/bin/bh-env"
if [[ ! -e "${home_command}" && ! -L "${home_command}" ]]; then
    ln -s "${wrapper_file}" "${home_command}"
elif [[ -L "${home_command}" ]]; then
    existing_target="$(readlink "${home_command}")"
    case "${existing_target}" in
        */remote-vnc/users/*/bin/bh-env|"${wrapper_file}")
            ln -sfn "${wrapper_file}" "${home_command}"
            ;;
        *)
            printf '[remote-vnc] Existing bh-env symlink was left unchanged: %s -> %s\n' \
                "${home_command}" "${existing_target}" >&2
            ;;
    esac
else
    printf '[remote-vnc] Existing file was left unchanged: %s\n' \
        "${home_command}" >&2
    printf '[remote-vnc] Use %s directly.\n' "${wrapper_file}" >&2
fi
REMOTE_INSTALL_BH_ENV

ready_record="$(
    remote_tools_ssh_bash_args \
        "${vnc_release_directory}" \
        "${vnc_user_service_directory}" \
        "${shared_image_path}" \
        "${partition_name}" \
        "${cpu_count}" \
        "${gpu_count}" \
        "${memory_gb}" \
        "${time_hours}" \
        "${remote_requested_node}" \
        "${startup_timeout_seconds}" \
        "${image_build_timeout_seconds}" \
        "${remote_job_launcher_file}" \
        "${remote_helper_file}" \
        "${remote_authorized_keys_file}" \
        "${managed_launcher_comment}" \
        "${restart_existing_job}" \
        "${environment_name}" \
        "${environment_mode}" \
        "${environment_build_timeout_seconds}" \
        "${configured_remote_ssh_port}" \
        "${vnc_geometry}" <<'REMOTE_START'
set -Eeuo pipefail

release_directory="$1"
user_service_directory="$2"
shared_image_path="$3"
requested_partition="$4"
requested_cpu_count="$5"
requested_gpu_count="$6"
requested_memory_gb="$7"
requested_time_hours="$8"
requested_node="$9"
startup_timeout_seconds="${10}"
image_build_timeout_seconds="${11}"
remote_job_launcher_file="${12}"
remote_helper_file="${13}"
remote_authorized_keys_file="${14}"
managed_launcher_comment="${15}"
restart_existing_job="${16}"
environment_name="${17}"
environment_mode="${18}"
environment_build_timeout_seconds="${19}"
requested_remote_ssh_port="${20}"
vnc_geometry="${21}"
managed_launcher_version="13"

if [[ "${requested_node}" == "__REMOTE_VNC_SCHEDULER__" ]]; then
    requested_node=""
fi
[[ "${environment_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 2
}
[[ "${environment_mode}" == "mutable" ||
   "${environment_mode}" == "immutable" ]] || {
    printf 'Invalid environment mode: %s\n' "${environment_mode}" >&2
    exit 2
}
[[ "${environment_build_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid environment build timeout: %s\n' \
        "${environment_build_timeout_seconds}" >&2
    exit 2
}
[[ "${requested_remote_ssh_port}" =~ ^[0-9]+$ ]] &&
    ((requested_remote_ssh_port >= 44000 && requested_remote_ssh_port <= 44999)) || {
    printf 'Invalid fixed remote SSH port: %s\n' \
        "${requested_remote_ssh_port}" >&2
    exit 2
}
if [[ "${vnc_geometry}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    vnc_width="${BASH_REMATCH[1]}"
    vnc_height="${BASH_REMATCH[2]}"
else
    printf 'Invalid VNC geometry: %s\n' "${vnc_geometry}" >&2
    exit 2
fi
((vnc_width >= 1024 && vnc_width <= 7680 &&
  vnc_height >= 768 && vnc_height <= 4320)) || {
    printf 'VNC geometry must be between 1024x768 and 7680x4320: %s\n' \
        "${vnc_geometry}" >&2
    exit 2
}

slurm_binary_directory="/sfw/rhel9-x86_64/slurm/24.05.0.b1/bin"
squeue_executable="${slurm_binary_directory}/squeue"
sbatch_executable="${slurm_binary_directory}/sbatch"
scontrol_executable="${slurm_binary_directory}/scontrol"
scancel_executable="${slurm_binary_directory}/scancel"
current_user="$(id -un)"
job_name="${current_user}-vnc"
legacy_gpu_job_name="${current_user}-vnc-gpu"
connection_file="${user_service_directory}/state/connection.env"

for required_file in \
    "${release_directory}/start_vnc.sh" \
    "${release_directory}/configure_desktop.sh" \
    "${release_directory}/macos_shortcut.sh" \
    "${release_directory}/bluehive-aurora.svg" \
    "${release_directory}/build_vnc_image.sh" \
    "${release_directory}/bh-env.sh" \
    "${release_directory}/environment_common.sh" \
    "${release_directory}/prepare_environment.sh" \
    "${release_directory}/provision_environment.sh" \
    "${release_directory}/environment-packages.txt" \
    "${release_directory}/matlab-products.txt" \
    "${release_directory}/ubuntu-vnc-xfce-g3_24.04.def" \
    "${release_directory}/ubuntu-vnc-xfce-g3_24.04.sha256" \
    "${remote_job_launcher_file}" \
    "${remote_helper_file}" \
    "${remote_authorized_keys_file}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required remote file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done
for slurm_executable in \
    "${squeue_executable}" "${sbatch_executable}" \
    "${scontrol_executable}" "${scancel_executable}"; do
    [[ -x "${slurm_executable}" ]] || {
        printf 'Slurm command is unavailable: %s\n' "${slurm_executable}" >&2
        exit 2
    }
done

read_state_value() {
    local state_file="$1"
    local requested_key="$2"

    [[ -s "${state_file}" ]] || return 1
    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${state_file}"
}

managed_launcher_state_file() {
    local requested_job_id="$1"

    printf '%s/state/jobs/%s/managed-launcher.env\n' \
        "${user_service_directory}" "${requested_job_id}"
}

job_uses_managed_launcher() {
    local requested_job_id="$1"
    local launcher_state_file
    local job_record
    local job_comment

    launcher_state_file="$(managed_launcher_state_file "${requested_job_id}")"
    if [[ "$(read_state_value "${launcher_state_file}" LAUNCHER_VERSION || true)" == \
          "${managed_launcher_version}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" JOB_ID || true)" == \
          "${requested_job_id}" ]]; then
        return 0
    fi

    job_record="$(
        "${scontrol_executable}" show job -o "${requested_job_id}" 2>/dev/null || true
    )"
    job_comment="$(
        tr ' ' '\n' <<< "${job_record}" |
            awk -F= '$1 == "Comment" { print $2; exit }'
    )"
    [[ "${job_comment}" == remote-vnc-managed-v13:* ]]
}

managed_launcher_is_ready() {
    local requested_job_id="$1"
    local launcher_state_file

    launcher_state_file="$(managed_launcher_state_file "${requested_job_id}")"
    [[ "$(read_state_value "${launcher_state_file}" STATUS || true)" == "READY" ]] &&
        [[ "$(read_state_value "${launcher_state_file}" LAUNCHER_VERSION || true)" == \
           "${managed_launcher_version}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" JOB_ID || true)" == \
           "${requested_job_id}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" ENVIRONMENT_NAME || true)" == \
           "${environment_name}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" ENVIRONMENT_MODE || true)" == \
           "${environment_mode}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" REMOTE_SSH_PORT || true)" == \
           "${requested_remote_ssh_port}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" VNC_GEOMETRY || true)" == \
           "${vnc_geometry}" ]]
}

job_matches_requested_configuration() {
    local requested_job_id="$1"
    local launcher_state_file
    local job_record
    local job_comment

    launcher_state_file="$(managed_launcher_state_file "${requested_job_id}")"
    if [[ "$(read_state_value "${launcher_state_file}" ENVIRONMENT_NAME || true)" == \
          "${environment_name}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" ENVIRONMENT_MODE || true)" == \
          "${environment_mode}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" REMOTE_SSH_PORT || true)" == \
          "${requested_remote_ssh_port}" ]] &&
       [[ "$(read_state_value "${launcher_state_file}" VNC_GEOMETRY || true)" == \
          "${vnc_geometry}" ]]; then
        return 0
    fi

    job_record="$(
        "${scontrol_executable}" show job -o "${requested_job_id}" 2>/dev/null || true
    )"
    job_comment="$(
        tr ' ' '\n' <<< "${job_record}" |
            awk -F= '$1 == "Comment" { print $2; exit }'
    )"
    [[ "${job_comment}" == "${managed_launcher_comment}" ]]
}

opencodex_connection_is_ready() {
    if [[ "${environment_mode}" == "immutable" ]]; then
        [[ "$(read_state_value "${connection_file}" OPENCODEX_STATUS || true)" == \
           "DISABLED_IMMUTABLE" ]]
        return
    fi

    [[ "$(read_state_value "${connection_file}" OPENCODEX_STATUS || true)" == \
       "READY" ]] &&
        [[ "$(read_state_value "${connection_file}" CONTAINER_INSTANCE_NAME || true)" =~ \
           ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
        [[ "$(read_state_value "${connection_file}" CONTAINER_INSTANCE_PID || true)" =~ \
           ^[0-9]+$ ]] &&
        [[ "$(read_state_value "${connection_file}" OPENCODEX_PID || true)" =~ \
           ^[0-9]+$ ]] &&
        [[ "$(read_state_value "${connection_file}" OPENCODEX_PORT || true)" =~ \
           ^[0-9]+$ ]] &&
        [[ "$(read_state_value "${connection_file}" CODEX_APP_SERVER_STATUS || true)" == \
           "running" ]] &&
        [[ "$(read_state_value "${connection_file}" CODEX_APP_SERVER_PID || true)" =~ \
           ^[0-9]+$ ]]
}

vnc_connection_is_ready() {
    local requested_job_id="$1"
    local job_state

    job_state="$(
        "${squeue_executable}" -h -j "${requested_job_id}" -o '%T' |
            awk 'NF { print; exit }'
    )"
    [[ "$(read_state_value "${connection_file}" STATUS || true)" == "READY" ]] &&
        [[ "$(read_state_value "${connection_file}" JOB_ID || true)" == "${requested_job_id}" ]] &&
        [[ "$(read_state_value "${connection_file}" NODE || true)" =~ ^[A-Za-z0-9._-]+$ ]] &&
        [[ "$(read_state_value "${connection_file}" VNC_PORT || true)" =~ ^[0-9]+$ ]] &&
        [[ "$(read_state_value "${connection_file}" ENVIRONMENT_NAME || true)" == \
           "${environment_name}" ]] &&
       [[ "$(read_state_value "${connection_file}" ENVIRONMENT_MODE || true)" == \
           "${environment_mode}" ]] &&
       [[ "$(read_state_value "${connection_file}" VNC_GEOMETRY || true)" == \
           "${vnc_geometry}" ]] &&
       [[ "$(read_state_value "${connection_file}" VNC_CLIPBOARD || true)" == \
           "ENABLED" ]] &&
       opencodex_connection_is_ready &&
        managed_launcher_is_ready "${requested_job_id}" &&
        [[ "${job_state}" == "RUNNING" ]]
}

job_id="$(read_state_value "${connection_file}" JOB_ID || true)"
if [[ "${restart_existing_job}" != "true" && "${job_id}" =~ ^[0-9]+$ ]] &&
   vnc_connection_is_ready "${job_id}"; then
    printf '[remote-vnc] Reusing running VNC Job %s.\n' "${job_id}" >&2
else
    active_job_record="$(
        "${squeue_executable}" -h -u "${USER}" -o '%i|%T|%j|%N|%R' |
            awk -F'|' -v job_name="${job_name}" \
                -v legacy_gpu_job_name="${legacy_gpu_job_name}" \
                '$3 == job_name || $3 == legacy_gpu_job_name { print }' |
            sort -t'|' -k1,1nr |
            head -n 1
    )"
    if [[ -n "${active_job_record}" ]]; then
        IFS='|' read -r job_id job_state active_job_name job_node job_reason \
            <<< "${active_job_record}"

        if [[ "${restart_existing_job}" == "true" ]]; then
            printf '[remote-vnc] Cancelling VNC Job %s before replacement.\n' \
                "${job_id}" >&2
            "${scancel_executable}" "${job_id}"
            cancel_deadline=$((SECONDS + 60))
            while ((SECONDS < cancel_deadline)); do
                if [[ -z "$(
                    "${squeue_executable}" -h -j "${job_id}" -o '%i' |
                        awk 'NF { print; exit }'
                )" ]]; then
                    break
                fi
                sleep 1
            done
            [[ -z "$(
                "${squeue_executable}" -h -j "${job_id}" -o '%i' |
                    awk 'NF { print; exit }'
            )" ]] || {
                printf 'VNC Job %s did not stop within 60 seconds.\n' \
                    "${job_id}" >&2
                exit 7
            }
            active_job_record=""
        elif job_uses_managed_launcher "${job_id}"; then
            if job_matches_requested_configuration "${job_id}"; then
                printf '[remote-vnc] Waiting for existing VNC Job %s.\n' \
                    "${job_id}" >&2
            else
                active_environment_name="$(
                    read_state_value \
                        "$(managed_launcher_state_file "${job_id}")" \
                        ENVIRONMENT_NAME || true
                )"
                active_environment_mode="$(
                    read_state_value \
                        "$(managed_launcher_state_file "${job_id}")" \
                        ENVIRONMENT_MODE || true
                )"
                active_remote_ssh_port="$(
                    read_state_value \
                        "$(managed_launcher_state_file "${job_id}")" \
                        REMOTE_SSH_PORT || true
                )"
                active_vnc_geometry="$(
                    read_state_value \
                        "$(managed_launcher_state_file "${job_id}")" \
                        VNC_GEOMETRY || true
                )"
                printf 'VNC Job %s uses environment %s (%s), SSH port %s, and geometry %s.\n' \
                    "${job_id}" \
                    "${active_environment_name:-unknown}" \
                    "${active_environment_mode:-unknown}" \
                    "${active_remote_ssh_port:-unknown}" \
                    "${active_vnc_geometry:-unknown}" >&2
                printf 'Run remote_vnc.sh --restart with the requested configuration.\n' \
                    >&2
                exit 7
            fi
        else
            existing_launcher_version="$(
                read_state_value \
                    "$(managed_launcher_state_file "${job_id}")" \
                    LAUNCHER_VERSION || true
            )"
            if [[ -n "${existing_launcher_version}" ]]; then
                printf 'VNC Job %s uses launcher version %s; version %s is required.\n' \
                    "${job_id}" "${existing_launcher_version}" \
                    "${managed_launcher_version}" >&2
            else
                printf 'VNC Job %s was started without the current managed launcher.\n' \
                    "${job_id}" >&2
            fi
            printf 'Run remote_vnc.sh --restart with the same resource options to replace it.\n' \
                >&2
            exit 7
        fi
    fi

    if [[ -z "${active_job_record}" ]]; then
        partition_record="$(
            "${scontrol_executable}" show partition "${requested_partition}" -o
        )"
        partition_qos="$(
            tr ' ' '\n' <<< "${partition_record}" |
                awk -F= '$1 == "QoS" { print $2; exit }'
        )"
        submit_options=(
            --parsable
            "--job-name=${job_name}"
            "--comment=${managed_launcher_comment}"
            "--partition=${requested_partition}"
            --nodes=1
            --ntasks=1
            "--cpus-per-task=${requested_cpu_count}"
            "--mem=${requested_memory_gb}G"
            "--time=${requested_time_hours}:00:00"
            "--chdir=${user_service_directory}"
            "--output=${user_service_directory}/logs/%x_%j.out"
            "--error=${user_service_directory}/logs/%x_%j.err"
            --mail-type=FAIL
            --export=NONE
            --signal=B:TERM@60
        )
        if [[ -n "${partition_qos}" && "${partition_qos}" != "N/A" ]]; then
            submit_options+=("--qos=${partition_qos}")
        fi
        if ((requested_gpu_count > 0)); then
            submit_options+=("--gres=gpu:${requested_gpu_count}")
        fi
        if [[ -n "${requested_node}" ]]; then
            submit_options+=("--nodelist=${requested_node}")
        fi

        mkdir -p "${user_service_directory}/logs"
        printf -v job_wrap_command \
            'exec %q %q %q %q %q %q %q %q %q %q %q %q %q' \
            "${remote_job_launcher_file}" \
            "${release_directory}" \
            "${user_service_directory}" \
            "${shared_image_path}" \
            "${remote_helper_file}" \
            "${remote_authorized_keys_file}" \
            "${startup_timeout_seconds}" \
            "${image_build_timeout_seconds}" \
            "${environment_name}" \
            "${environment_mode}" \
            "${environment_build_timeout_seconds}" \
            "${requested_remote_ssh_port}" \
            "${vnc_geometry}"
        job_id="$(
            "${sbatch_executable}" "${submit_options[@]}" \
                --wrap="${job_wrap_command}"
        )"
        job_id="${job_id%%;*}"
        [[ "${job_id}" =~ ^[0-9]+$ ]] || {
            printf 'sbatch returned an invalid Job ID: %s\n' "${job_id}" >&2
            exit 3
        }
        printf '[remote-vnc] Submitted VNC Job %s.\n' "${job_id}" >&2
    fi

    wait_deadline=$((
        SECONDS + image_build_timeout_seconds +
        environment_build_timeout_seconds + startup_timeout_seconds
    ))
    last_job_description=""
    last_launcher_stage=""
    while ((SECONDS < wait_deadline)); do
        active_job_record="$(
            "${squeue_executable}" -h -j "${job_id}" -o '%T|%N|%R' |
                awk 'NF { print; exit }'
        )"
        [[ -n "${active_job_record}" ]] || {
            printf 'VNC Job %s left the queue before becoming ready.\n' \
                "${job_id}" >&2
            tail -n 120 "${user_service_directory}/logs/${job_name}_${job_id}.err" \
                2>/dev/null || true
            exit 4
        }

        IFS='|' read -r job_state job_node job_reason <<< "${active_job_record}"
        job_description="${job_state}|${job_node}|${job_reason}"
        if [[ "${job_description}" != "${last_job_description}" ]]; then
            printf '[remote-vnc] Job %s: state=%s node=%s reason=%s\n' \
                "${job_id}" "${job_state}" "${job_node:-pending}" \
                "${job_reason}" >&2
            last_job_description="${job_description}"
        fi

        launcher_state_file="$(managed_launcher_state_file "${job_id}")"
        launcher_stage="$(read_state_value "${launcher_state_file}" STATUS || true)"
        image_status_file="${user_service_directory}/state/jobs/${job_id}/image-status"
        image_stage="$(head -n 1 "${image_status_file}" 2>/dev/null || true)"
        environment_status_file="${user_service_directory}/state/jobs/${job_id}/environment-status"
        environment_stage="$(
            head -n 1 "${environment_status_file}" 2>/dev/null || true
        )"
        reported_stage="${launcher_stage:-${environment_stage:-${image_stage:-WAITING_FOR_JOB}}}"
        if [[ "${image_stage}" == "BUILDING_IMAGE" ||
              "${launcher_stage}" == "CHECKING_IMAGE" ]]; then
            reported_stage="${image_stage:-${launcher_stage}}"
        elif [[ "${launcher_stage}" == "PREPARING_ENVIRONMENT" ]]; then
            reported_stage="${environment_stage:-${launcher_stage}}"
        fi
        if [[ "${reported_stage}" != "${last_launcher_stage}" ]]; then
            printf '[remote-vnc] Job %s stage=%s\n' \
                "${job_id}" "${reported_stage}" >&2
            last_launcher_stage="${reported_stage}"
        fi

        if vnc_connection_is_ready "${job_id}"; then
            break
        fi
        sleep 2
    done
    vnc_connection_is_ready "${job_id}" || {
        printf 'Timed out after %s seconds waiting for VNC Job %s.\n' \
            "$((image_build_timeout_seconds + environment_build_timeout_seconds + startup_timeout_seconds))" \
            "${job_id}" >&2
        exit 5
    }
fi

vnc_node="$(read_state_value "${connection_file}" NODE)"
vnc_port="$(read_state_value "${connection_file}" VNC_PORT)"
[[ "${vnc_node}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Invalid VNC node: %s\n' "${vnc_node}" >&2
    exit 5
}
[[ "${vnc_port}" =~ ^[0-9]+$ ]] || {
    printf 'Invalid VNC port: %s\n' "${vnc_port}" >&2
    exit 5
}

job_record="$("${scontrol_executable}" show job -o "${job_id}")"
job_field() {
    local requested_field="$1"
    tr ' ' '\n' <<< "${job_record}" |
        awk -F= -v requested_field="${requested_field}" \
            '$1 == requested_field { print $2; exit }'
}
actual_partition="$(job_field Partition)"
actual_cpu_count="$(job_field NumCPUs)"
actual_memory="$(job_field MinMemoryNode)"
actual_time_limit="$(job_field TimeLimit)"
actual_gpu_count=0
if [[ "${job_record}" =~ AllocTRES=[^[:space:]]*gres/gpu=([0-9]+) ]]; then
    actual_gpu_count="${BASH_REMATCH[1]}"
fi
[[ "${actual_cpu_count}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Could not read the CPU allocation for Job %s.\n' "${job_id}" >&2
    exit 5
}

remote_ssh_directory="${user_service_directory}/state/jobs/${job_id}/remote-ssh"
remote_ssh_connection_file="${remote_ssh_directory}/connection.env"
remote_ssh_log="${remote_ssh_directory}/sshd.log"

tcp_port_is_open() {
    local requested_host="$1"
    local requested_port="$2"

    timeout 2 /bin/bash -c \
        "exec 3<>/dev/tcp/${requested_host}/${requested_port}" \
        >/dev/null 2>&1
}

remote_ssh_is_ready() {
    local connection_status
    local connection_job_id
    local connection_node
    local connection_vnc_port
    local connection_opencodex_port
    local connection_ssh_port
    local connection_ssh_target
    local connection_environment_name
    local connection_environment_generation
    local expected_opencodex_port
    local expected_ssh_target

    connection_status="$(read_state_value "${remote_ssh_connection_file}" STATUS || true)"
    connection_job_id="$(read_state_value "${remote_ssh_connection_file}" JOB_ID || true)"
    connection_node="$(read_state_value "${remote_ssh_connection_file}" NODE || true)"
    connection_vnc_port="$(read_state_value "${remote_ssh_connection_file}" VNC_PORT || true)"
    connection_opencodex_port="$(
        read_state_value "${remote_ssh_connection_file}" OPENCODEX_PORT || true
    )"
    connection_ssh_port="$(read_state_value "${remote_ssh_connection_file}" SSH_PORT || true)"
    connection_ssh_target="$(
        read_state_value "${remote_ssh_connection_file}" SSH_TARGET || true
    )"
    connection_environment_name="$(
        read_state_value "${remote_ssh_connection_file}" ENVIRONMENT_NAME || true
    )"
    connection_environment_generation="$(
        read_state_value "${remote_ssh_connection_file}" \
            ENVIRONMENT_GENERATION || true
    )"
    expected_opencodex_port="$(
        read_state_value "${connection_file}" OPENCODEX_PORT || true
    )"
    if [[ "${environment_mode}" == "mutable" ]]; then
        expected_ssh_target="CONTAINER"
    else
        expected_ssh_target="HOST"
    fi

    [[ "${connection_status}" == "READY" ]] &&
        [[ "${connection_job_id}" == "${job_id}" ]] &&
        [[ "${connection_node}" == "${vnc_node}" ]] &&
        [[ "${connection_vnc_port}" == "${vnc_port}" ]] &&
        [[ "${connection_ssh_target}" == "${expected_ssh_target}" ]] &&
        [[ "${connection_environment_name}" == "${environment_name}" ]] &&
        [[ "${connection_environment_generation}" == \
           "$(read_state_value "${connection_file}" ENVIRONMENT_GENERATION)" ]] &&
        [[ "${connection_ssh_port}" == "${requested_remote_ssh_port}" ]] &&
        tcp_port_is_open "${vnc_node}" "${connection_ssh_port}" || return 1

    if [[ "${environment_mode}" == "mutable" ]]; then
        [[ "${expected_opencodex_port}" =~ ^[0-9]+$ &&
           "${connection_opencodex_port}" == "${expected_opencodex_port}" ]]
    else
        [[ -z "${connection_opencodex_port}" ]]
    fi
}

remote_ssh_is_ready || {
    printf 'Managed SSH service for VNC Job %s is not reachable.\n' \
        "${job_id}" >&2
    tail -n 160 "${remote_ssh_log}" >&2 2>/dev/null || true
    exit 6
}
remote_ssh_cgroup="$(
    read_state_value "${remote_ssh_connection_file}" CGROUP || true
)"
[[ "${remote_ssh_cgroup}" == *"/job_${job_id}/step_batch/"* ]] || {
    printf 'Managed SSH service is outside the batch Step cgroup: %s\n' \
        "${remote_ssh_cgroup:-unknown}" >&2
    exit 6
}
printf '[remote-vnc] Managed SSH service is ready for Job %s.\n' \
    "${job_id}" >&2

remote_ssh_port="$(read_state_value "${remote_ssh_connection_file}" SSH_PORT)"
remote_ssh_target="$(
    read_state_value "${remote_ssh_connection_file}" SSH_TARGET
)"
remote_sftp_status="$(
    read_state_value "${remote_ssh_connection_file}" SFTP_STATUS
)"
host_key_public_file="$(
    read_state_value "${remote_ssh_connection_file}" HOST_KEY_PUBLIC_FILE
)"
[[ "${remote_ssh_port}" == "${requested_remote_ssh_port}" ]] || {
    printf 'Remote SSH port %s does not match configured port %s.\n' \
        "${remote_ssh_port:-unset}" "${requested_remote_ssh_port}" >&2
    exit 6
}
[[ "${host_key_public_file}" == \
   "${user_service_directory}/state/remote-ssh/server-key.pub" ]] || {
    printf 'Unexpected host-key path: %s\n' "${host_key_public_file}" >&2
    exit 6
}
if [[ "${environment_mode}" == "mutable" ]]; then
    [[ "${remote_ssh_target}" == "CONTAINER" &&
       "${remote_sftp_status}" == "ENABLED" ]] || {
        printf 'Mutable environment SSH did not enter the container: %s/%s\n' \
            "${remote_ssh_target:-unset}" "${remote_sftp_status:-unset}" >&2
        exit 6
    }
else
    [[ "${remote_ssh_target}" == "HOST" ]] || {
        printf 'Immutable environment SSH target is invalid: %s\n' \
            "${remote_ssh_target:-unset}" >&2
        exit 6
    }
fi

active_environment_name="$(read_state_value "${connection_file}" ENVIRONMENT_NAME)"
active_environment_mode="$(read_state_value "${connection_file}" ENVIRONMENT_MODE)"
active_environment_generation="$(
    read_state_value "${connection_file}" ENVIRONMENT_GENERATION
)"
active_vnc_geometry="$(
    read_state_value "${connection_file}" VNC_GEOMETRY
)"
active_macos_shortcuts_status="$(
    read_state_value "${connection_file}" MACOS_SHORTCUTS_STATUS || true
)"
active_container_instance_name="$(
    read_state_value "${connection_file}" CONTAINER_INSTANCE_NAME
)"
active_container_instance_process_id="$(
    read_state_value "${connection_file}" CONTAINER_INSTANCE_PID
)"
active_opencodex_status="$(
    read_state_value "${connection_file}" OPENCODEX_STATUS
)"
active_opencodex_process_id="$(
    read_state_value "${connection_file}" OPENCODEX_PID
)"
active_opencodex_port="$(
    read_state_value "${connection_file}" OPENCODEX_PORT
)"
active_opencodex_migration_status="$(
    read_state_value "${connection_file}" OPENCODEX_MIGRATION_STATUS
)"
active_codex_app_server_status="$(
    read_state_value "${connection_file}" CODEX_APP_SERVER_STATUS
)"
active_codex_app_server_process_id="$(
    read_state_value "${connection_file}" CODEX_APP_SERVER_PID
)"
[[ "${active_environment_name}" == "${environment_name}" &&
   "${active_environment_mode}" == "${environment_mode}" &&
   "${active_vnc_geometry}" == "${vnc_geometry}" ]] || {
    printf 'VNC environment state does not match the request.\n' >&2
    exit 6
}

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${job_id}" "${vnc_node}" "${vnc_port}" "${remote_ssh_port}" \
    "${host_key_public_file}" "${actual_partition}" "${actual_cpu_count}" \
    "${actual_gpu_count}" "${actual_memory}" "${actual_time_limit}" \
    "${active_environment_name}" "${active_environment_mode}" \
    "${active_environment_generation}" "${active_container_instance_name}" \
    "${active_container_instance_process_id}" "${active_opencodex_status}" \
    "${active_opencodex_process_id}" "${active_opencodex_port}" \
    "${active_opencodex_migration_status}" \
    "${active_codex_app_server_status}" \
    "${active_codex_app_server_process_id}" \
    "${remote_ssh_target}" "${remote_sftp_status}" "${active_vnc_geometry}" \
    "${active_macos_shortcuts_status}"
REMOTE_START
)" || fail "remote VNC startup failed"

IFS='|' read -r \
    vnc_job_id vnc_node remote_vnc_port remote_ssh_port \
    host_key_public_file actual_partition actual_cpu_count actual_gpu_count \
    actual_memory actual_time_limit active_environment_name \
    active_environment_mode active_environment_generation \
    active_container_instance_name active_container_instance_process_id \
    active_opencodex_status active_opencodex_process_id active_opencodex_port \
    active_opencodex_migration_status active_codex_app_server_status \
    active_codex_app_server_process_id active_remote_ssh_target \
    active_remote_sftp_status active_vnc_geometry \
    active_macos_shortcuts_status <<< "${ready_record}"
[[ "${vnc_job_id}" =~ ^[0-9]+$ ]] || fail "invalid VNC Job ID: ${vnc_job_id}"
[[ "${vnc_node}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid VNC node: ${vnc_node}"
[[ "${remote_vnc_port}" =~ ^[0-9]+$ ]] || fail "invalid VNC port: ${remote_vnc_port}"
[[ "${remote_ssh_port}" == "${configured_remote_ssh_port}" ]] ||
    fail "remote SSH port ${remote_ssh_port:-unset} does not match configured port ${configured_remote_ssh_port}"
[[ "${active_environment_name}" == "${environment_name}" ]] ||
    fail "active environment name does not match: ${active_environment_name}"
[[ "${active_environment_mode}" == "${environment_mode}" ]] ||
    fail "active environment mode does not match: ${active_environment_mode}"
[[ "${active_vnc_geometry}" == "${vnc_geometry}" ]] ||
    fail "active VNC geometry does not match: ${active_vnc_geometry}"
if [[ "${active_environment_mode}" == "mutable" ]]; then
    [[ "${active_remote_ssh_target}" == "CONTAINER" ]] ||
        fail "mutable environment SSH target is not the container"
    [[ "${active_remote_sftp_status}" == "ENABLED" ]] ||
        fail "mutable environment SFTP is unavailable"
    [[ "${active_container_instance_name}" =~ \
       ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        fail "invalid container service instance: ${active_container_instance_name}"
    [[ "${active_container_instance_process_id}" =~ ^[0-9]+$ ]] ||
        fail "invalid container service instance PID: ${active_container_instance_process_id}"
else
    [[ "${active_remote_ssh_target}" == "HOST" ]] ||
        fail "immutable environment SSH target is not the host"
fi

server_host_key="$(
    remote_tools_ssh_bash_args "${host_key_public_file}" <<'REMOTE_HOST_KEY'
set -Eeuo pipefail
host_key_public_file="$1"
[[ -r "${host_key_public_file}" ]] || exit 2
awk 'NF >= 2 { print $1 " " $2; exit }' "${host_key_public_file}"
REMOTE_HOST_KEY
)" || fail "could not retrieve the persistent SSH host key"
[[ "${server_host_key}" =~ ^ssh-[A-Za-z0-9@._+-]+\ [A-Za-z0-9+/=]+$ ]] ||
    fail "the persistent SSH host key is invalid"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
known_hosts_temporary_file="$(mktemp "${known_hosts_file}.XXXXXX")"
printf '%s %s\n' "${vnc_host_key_alias}" "${server_host_key}" \
    > "${known_hosts_temporary_file}"
ssh-keygen -lf "${known_hosts_temporary_file}" >/dev/null || {
    unlink "${known_hosts_temporary_file}"
    fail "could not validate the persistent SSH host key"
}
chmod 600 "${known_hosts_temporary_file}"
mv "${known_hosts_temporary_file}" "${known_hosts_file}"

legacy_managed_block_begin="# BEGIN remote_vnc.sh ${cluster_name}"
legacy_managed_block_end="# END remote_vnc.sh ${cluster_name}"
if grep -Fqx "${legacy_managed_block_begin}" "${ssh_config_file}" ||
   [[ -S "${legacy_ssh_control_path}" ]]; then
    log_message "Removing the old ${legacy_vnc_ssh_alias} SSH entry."
    launchctl bootout "${launch_agent_domain}/${launch_agent_label}" \
        >/dev/null 2>&1 || true
    /usr/bin/ssh \
        -S "${legacy_ssh_control_path}" \
        -O exit \
        "${legacy_vnc_ssh_alias}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        [[ ! -S "${legacy_ssh_control_path}" ]] && break
        sleep 1
    done
    if [[ -S "${legacy_ssh_control_path}" ]]; then
        unlink "${legacy_ssh_control_path}"
    fi

    ssh_config_temporary_file="$(mktemp "${ssh_config_file}.XXXXXX")"
    awk \
        -v managed_block_begin="${legacy_managed_block_begin}" \
        -v managed_block_end="${legacy_managed_block_end}" '
            $0 == managed_block_begin { in_managed_block = 1; next }
            $0 == managed_block_end { in_managed_block = 0; next }
            !in_managed_block { print }
        ' "${ssh_config_file}" > "${ssh_config_temporary_file}"
    chmod 600 "${ssh_config_temporary_file}"
    mv "${ssh_config_temporary_file}" "${ssh_config_file}"
fi

"${update_ssh_config_script}" \
    -a "${cluster_name}" \
    -p "${actual_partition}" \
    -o "${remote_ssh_port}" \
    -w "${vnc_node}"

ssh_control_path="$(
    /usr/bin/ssh -G "${vnc_ssh_alias}" 2>/dev/null |
        awk '$1 == "controlpath" { print $2; exit }'
)"
[[ "${ssh_control_path}" == /* && "${ssh_control_path}" != *%* ]] ||
    fail "could not resolve the ${vnc_ssh_alias} SSH ControlPath: ${ssh_control_path:-unset}"

/usr/bin/ssh -G "${vnc_ssh_alias}" >/dev/null 2>&1 ||
    fail "the ${vnc_ssh_alias} SSH config is invalid"

local_listener_process_ids() {
    lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sort -u
}

listener_uses_ssh_master() {
    local requested_port="$1"
    local listener_process_id

    while IFS= read -r listener_process_id; do
        [[ "${listener_process_id}" == "${ssh_master_process_id}" ]] && return 0
    done < <(local_listener_process_ids "${requested_port}")
    return 1
}

read_local_rfb_banner() {
    local requested_port="$1"
    local rfb_banner=""

    rfb_banner="$(
        /usr/bin/nc -G 3 -w 1 127.0.0.1 "${requested_port}" 2>/dev/null |
            /usr/bin/head -c 12
    )" || true
    printf '%s' "${rfb_banner}"
}

local_vnc_rfb_is_ready() {
    local requested_port="$1"

    [[ "$(read_local_rfb_banner "${requested_port}")" == RFB\ * ]]
}

wait_for_local_vnc_rfb() {
    local requested_port="$1"

    local_vnc_rfb_is_ready "${requested_port}"
}

local_opencodex_http_is_ready() {
    local requested_port="$1"

    /usr/bin/curl \
        --fail --silent --show-error \
        --noproxy '*' \
        --connect-timeout 3 --max-time 5 \
        "http://127.0.0.1:${requested_port}/" \
        --output /dev/null 2>/dev/null
}

wait_for_local_opencodex_http() {
    local requested_port="$1"

    for _ in {1..30}; do
        local_opencodex_http_is_ready "${requested_port}" && return 0
        sleep 1
    done
    return 1
}

read_local_state_value() {
    local requested_key="$1"

    [[ -s "${local_connection_state_file}" ]] || return 1
    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${local_connection_state_file}"
}

choose_local_vnc_port() {
    local first_candidate_port=$((remote_vnc_port + 10000))
    local candidate_port

    for ((candidate_port = first_candidate_port;
          candidate_port <= first_candidate_port + 50;
          candidate_port++)); do
        if [[ -z "$(local_listener_process_ids "${candidate_port}")" ]]; then
            printf '%s\n' "${candidate_port}"
            return 0
        fi
    done
    return 1
}

launch_agent_is_loaded() {
    launchctl print "${launch_agent_domain}/${launch_agent_label}" \
        >/dev/null 2>&1
}

stop_local_vnc_connection() {
    if launch_agent_is_loaded; then
        launchctl bootout "${launch_agent_domain}/${launch_agent_label}" \
            >/dev/null 2>&1 || true
    fi
    /usr/bin/ssh -S "${ssh_control_path}" -O exit "${vnc_ssh_alias}" \
        >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        [[ ! -S "${ssh_control_path}" ]] && break
        sleep 1
    done
    if [[ -S "${ssh_control_path}" ]]; then
        unlink "${ssh_control_path}"
    fi
}

master_check_output="$(
    /usr/bin/ssh -S "${ssh_control_path}" -O check "${vnc_ssh_alias}" 2>&1 || true
)"
local_vnc_port=""
ssh_master_process_id=""
verify_new_vnc_forward=false

if [[ "${master_check_output}" == *"Master running"* ]]; then
    ssh_master_process_id="$(
        sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<< "${master_check_output}"
    )"
    connected_job_id="$(
        /usr/bin/ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            "${vnc_ssh_alias}" \
            'printf "%s\n" "${SLURM_JOB_ID:-}"' \
            2>/dev/null || true
    )"
    if [[ "${connected_job_id}" == "${vnc_job_id}" ]]; then
        saved_job_id="$(read_local_state_value JOB_ID || true)"
        saved_remote_vnc_port="$(read_local_state_value REMOTE_VNC_PORT || true)"
        saved_local_vnc_port="$(read_local_state_value LOCAL_VNC_PORT || true)"
        if [[ "${saved_job_id}" == "${vnc_job_id}" &&
              "${saved_remote_vnc_port}" == "${remote_vnc_port}" &&
              "${saved_local_vnc_port}" =~ ^[0-9]+$ ]] &&
           listener_uses_ssh_master "${saved_local_vnc_port}"; then
            local_vnc_port="${saved_local_vnc_port}"
        else
            for ((candidate_port = remote_vnc_port + 10000;
                  candidate_port <= remote_vnc_port + 10050;
                  candidate_port++)); do
                if listener_uses_ssh_master "${candidate_port}"; then
                    local_vnc_port="${candidate_port}"
                    break
                fi
            done
        fi
    else
        log_message "Closing the stale ${vnc_ssh_alias} control connection."
        stop_local_vnc_connection
        master_check_output=""
        ssh_master_process_id=""
    fi
elif [[ -S "${ssh_control_path}" ]] || launch_agent_is_loaded; then
    stop_local_vnc_connection
fi

if [[ "${master_check_output}" != *"Master running"* ]]; then
    local_vnc_port="$(choose_local_vnc_port)" ||
        fail "no free local VNC port was found"
    local_forward_specification="127.0.0.1:${local_vnc_port}:127.0.0.1:${remote_vnc_port}"

    mkdir -p "${launch_agent_directory}" "${HOME}/Library/Logs"
    launch_agent_temporary_file="$(mktemp "${launch_agent_file}.XXXXXX")"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '%s\n' '<dict>'
        printf '%s\n' '    <key>Label</key>'
        printf '    <string>%s</string>\n' "${launch_agent_label}"
        printf '%s\n' '    <key>ProgramArguments</key>'
        printf '%s\n' '    <array>'
        printf '%s\n' '        <string>/usr/bin/ssh</string>'
        printf '%s\n' '        <string>-MN</string>'
        printf '%s\n' '        <string>-S</string>'
        printf '        <string>%s</string>\n' "${ssh_control_path}"
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>BatchMode=yes</string>'
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>ConnectTimeout=15</string>'
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>ControlPersist=no</string>'
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>ExitOnForwardFailure=yes</string>'
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>StrictHostKeyChecking=yes</string>'
        printf '%s\n' '        <string>-o</string>'
        printf '        <string>UserKnownHostsFile=%s</string>\n' "${known_hosts_file}"
        printf '%s\n' '        <string>-o</string>'
        printf '        <string>HostKeyAlias=%s</string>\n' "${vnc_host_key_alias}"
        printf '%s\n' '        <string>-o</string>'
        printf '        <string>IdentityFile=%s</string>\n' "${identity_file}"
        printf '%s\n' '        <string>-o</string>'
        printf '%s\n' '        <string>IdentitiesOnly=yes</string>'
        printf '%s\n' '        <string>-L</string>'
        printf '        <string>%s</string>\n' "${local_forward_specification}"
        printf '        <string>%s</string>\n' "${vnc_ssh_alias}"
        printf '%s\n' '    </array>'
        printf '%s\n' '    <key>RunAtLoad</key>'
        printf '%s\n' '    <true/>'
        printf '%s\n' '    <key>KeepAlive</key>'
        printf '%s\n' '    <false/>'
        printf '%s\n' '    <key>ProcessType</key>'
        printf '%s\n' '    <string>Background</string>'
        printf '%s\n' '    <key>StandardOutPath</key>'
        printf '    <string>%s</string>\n' "${launch_agent_stdout}"
        printf '%s\n' '    <key>StandardErrorPath</key>'
        printf '    <string>%s</string>\n' "${launch_agent_stderr}"
        printf '%s\n' '</dict>'
        printf '%s\n' '</plist>'
    } > "${launch_agent_temporary_file}"
    plutil -lint "${launch_agent_temporary_file}" >/dev/null || {
        unlink "${launch_agent_temporary_file}"
        fail "the generated LaunchAgent file is invalid"
    }
    chmod 600 "${launch_agent_temporary_file}"
    mv "${launch_agent_temporary_file}" "${launch_agent_file}"

    launch_agent_is_loaded && stop_local_vnc_connection
    log_message "Starting the Slurm SSH connection and VNC tunnel..."
    launchctl bootstrap "${launch_agent_domain}" "${launch_agent_file}" ||
        fail "could not start the VNC SSH LaunchAgent"

    for _ in {1..30}; do
        master_check_output="$(
            /usr/bin/ssh -S "${ssh_control_path}" -O check "${vnc_ssh_alias}" \
                2>&1 || true
        )"
        if [[ "${master_check_output}" == *"Master running"* ]] &&
           [[ -n "$(local_listener_process_ids "${local_vnc_port}")" ]]; then
            break
        fi
        sleep 1
    done
    [[ "${master_check_output}" == *"Master running"* ]] || {
        tail -n 80 "${launch_agent_stderr}" >&2 2>/dev/null || true
        fail "the Slurm SSH control connection is not running"
    }
    ssh_master_process_id="$(
        sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<< "${master_check_output}"
    )"
    verify_new_vnc_forward=true
fi

[[ "${ssh_master_process_id}" =~ ^[0-9]+$ ]] ||
    fail "could not determine the SSH control process"

if [[ -z "${local_vnc_port}" ]]; then
    local_vnc_port="$(choose_local_vnc_port)" ||
        fail "no free local VNC port was found"
    log_message "Adding VNC forwarding to the existing SSH connection..."
    /usr/bin/ssh \
        -S "${ssh_control_path}" \
        -O forward \
        -L "127.0.0.1:${local_vnc_port}:127.0.0.1:${remote_vnc_port}" \
        "${vnc_ssh_alias}" || fail "could not create the VNC tunnel"
    verify_new_vnc_forward=true
fi
listener_uses_ssh_master "${local_vnc_port}" ||
    fail "SSH did not listen on local VNC port ${local_vnc_port}"
if [[ "${verify_new_vnc_forward}" == "true" ]]; then
    wait_for_local_vnc_rfb "${local_vnc_port}" || {
        tail -n 80 "${launch_agent_stderr}" >&2 2>/dev/null || true
        fail "local VNC tunnel on port ${local_vnc_port} did not return an RFB banner"
    }
fi

if [[ "${active_environment_mode}" == "mutable" ]]; then
    opencodex_forward_specification="127.0.0.1:${local_opencodex_port}"
    opencodex_forward_specification+=":127.0.0.1:${active_opencodex_port}"
    if ! listener_uses_ssh_master "${local_opencodex_port}"; then
        [[ -z "$(local_listener_process_ids "${local_opencodex_port}")" ]] ||
            fail "local OpenCodex port ${local_opencodex_port} is already in use"
        log_message \
            "Adding OpenCodex forwarding on localhost:${local_opencodex_port}..."
        /usr/bin/ssh \
            -S "${ssh_control_path}" \
            -O forward \
            -L "${opencodex_forward_specification}" \
            "${vnc_ssh_alias}" || fail "could not create the OpenCodex tunnel"
    fi
    listener_uses_ssh_master "${local_opencodex_port}" ||
        fail "SSH did not listen on local OpenCodex port ${local_opencodex_port}"
    wait_for_local_opencodex_http "${local_opencodex_port}" || {
        tail -n 80 "${launch_agent_stderr}" >&2 2>/dev/null || true
        fail "OpenCodex dashboard did not respond on localhost:${local_opencodex_port}"
    }
else
    local_opencodex_port=""
fi

validation_record="$(
    /usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        "${vnc_ssh_alias}" \
        /bin/bash -s -- \
        "${REMOTE_SHARED_ROOT}" "${active_environment_name}" \
        "${active_environment_mode}" <<'REMOTE_VALIDATE'
set -Eeuo pipefail
remote_shared_root="$1"
environment_name="$2"
environment_mode="$3"
printf 'JOB_ID=%s\n' "${SLURM_JOB_ID:-}"
printf 'NODE=%s\n' "$(hostname -s)"
printf 'CPUS=%s\n' "${SLURM_CPUS_PER_TASK:-}"
printf 'CUDA=%s\n' "${CUDA_VISIBLE_DEVICES:-}"
printf 'CGROUP='
tr '\n' ';' < "/proc/$$/cgroup"
printf '\n'
[[ -d "${remote_shared_root}" ]] && printf 'DATA=available\n'

if [[ "${environment_mode}" == "mutable" ]]; then
    printf 'SSH_TARGET=CONTAINER\n'
    printf 'ENVIRONMENT=%s\n' "${BH_ENV_NAME:-}"
    printf 'HOME=%s\n' "${HOME}"
    [[ "${BH_ENV_ACTIVE:-}" == "1" ]]
    [[ "${BH_ENV_NAME:-}" == "${environment_name}" ]]
    [[ "${HOME}" == "/home/$(id -un)" ]]
    for command_name in \
        fish gcc g++ node npm ocx codex uv pixi nvcc \
        google-chrome-stable chatgpt matlab mpm vncserver sshd \
        bh-env bh-admin sbatch bluehive-host-shell; do
        command -v "${command_name}" >/dev/null
    done
    test -x /opt/matlab/R2025b/bin/matlab
    test -x /usr/lib/openssh/sftp-server
    test -d /gpfs/fs1
    test -d /gpfs/fs2
    test -d /scratch
    test -d /bluehive-home
    test -d /host
    printf 'SOFTWARE=available\n'

    host_record="$(
        bluehive-host-shell \
            'printf "job=%s node=%s cgroup=" "${SLURM_JOB_ID:-}" "$(hostname -s)"; tr "\n" ";" < /proc/self/cgroup; printf " module=%s data=%s\n" "$(type -t module || true)" "$(test -d /gpfs/fs2 && printf yes || printf no)"' \
            </dev/null
    )"
    printf 'HOST_RECORD=%s\n' "${host_record}"
    bh-env --env "${environment_name}" status >/dev/null </dev/null
    printf 'BH_ENV_PROXY=available\n'
    admin_user_id="$(bh-admin -- id -u </dev/null)"
    printf 'ADMIN_UID=%s\n' "${admin_user_id}"
else
    printf 'SSH_TARGET=HOST\n'
    [[ -x /gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/bin/matlab ]] &&
        printf 'MATLAB=available\n'
    type module >/dev/null 2>&1 && printf 'MODULE=available\n'
fi
REMOTE_VALIDATE
)" || fail "direct SSH into the VNC allocation failed"

validation_job_id="$(awk -F= '$1 == "JOB_ID" { print $2; exit }' <<< "${validation_record}")"
validation_node="$(awk -F= '$1 == "NODE" { print $2; exit }' <<< "${validation_record}")"
validation_cgroup="$(awk -F= '$1 == "CGROUP" { sub(/^[^=]*=/, ""); print; exit }' <<< "${validation_record}")"
[[ "${validation_job_id}" == "${vnc_job_id}" ]] ||
    fail "SSH entered Job ${validation_job_id:-unknown}, expected ${vnc_job_id}"
[[ "${validation_node}" == "${vnc_node}" ]] ||
    fail "SSH reached ${validation_node:-unknown}, expected ${vnc_node}"
[[ "${validation_cgroup}" == *"/job_${vnc_job_id}/step_batch/"* ]] ||
    fail "SSH shell is outside the batch Step cgroup for Job ${vnc_job_id}"
grep -q '^DATA=available$' <<< "${validation_record}" ||
    fail "the SSH shell cannot access ${REMOTE_SHARED_ROOT}"

if [[ "${active_environment_mode}" == "mutable" ]]; then
    grep -q '^SSH_TARGET=CONTAINER$' <<< "${validation_record}" ||
        fail "SSH did not enter the mutable Apptainer environment"
    grep -q "^ENVIRONMENT=${active_environment_name}$" \
        <<< "${validation_record}" ||
        fail "SSH entered the wrong mutable environment"
    grep -q "^HOME=/home/${remote_user_name}$" <<< "${validation_record}" ||
        fail "the container SSH home is incorrect"
    grep -q '^SOFTWARE=available$' <<< "${validation_record}" ||
        fail "the container SSH shell is missing required software or mounts"
    grep -q '^BH_ENV_PROXY=available$' <<< "${validation_record}" ||
        fail "the container bh-env host proxy failed"
    grep -q '^ADMIN_UID=0$' <<< "${validation_record}" ||
        fail "the short-lived bh-admin fakeroot command failed"
    expected_host_record_pattern="^HOST_RECORD=job=${vnc_job_id}"
    expected_host_record_pattern+=" node=${vnc_node} cgroup=.*"
    expected_host_record_pattern+="/job_${vnc_job_id}/step_batch/.*"
    expected_host_record_pattern+=" module=function data=yes$"
    grep -Eq "${expected_host_record_pattern}" <<< "${validation_record}" ||
        fail "the container cannot return to the Slurm-bound host shell"

    if ! pty_validation_record="$(
        /usr/bin/ssh \
            -tt \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            "${vnc_ssh_alias}" \
            'printf "TTY=%s\n" "$(tty)"' 2>&1 |
            tr -d '\r'
    )"; then
        printf '%s\n' "${pty_validation_record}" >&2
        fail "the mutable Apptainer SSH service could not allocate a PTY"
    fi
    grep -Eq '^TTY=/dev/pts/[0-9]+$' <<< "${pty_validation_record}" || {
        printf '%s\n' "${pty_validation_record}" >&2
        fail "the mutable Apptainer SSH service returned an invalid PTY"
    }

    sftp_batch_file="$(mktemp /tmp/remote-vnc-sftp.XXXXXX)"
    printf 'pwd\nquit\n' > "${sftp_batch_file}"
    if ! sftp_validation_record="$(
        /usr/bin/sftp \
            -q -b "${sftp_batch_file}" \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=yes \
            -o "UserKnownHostsFile=${known_hosts_file}" \
            -o "HostKeyAlias=${vnc_host_key_alias}" \
            -o "IdentityFile=${identity_file}" \
            -o IdentitiesOnly=yes \
            "${vnc_ssh_alias}" 2>&1
    )"; then
        unlink "${sftp_batch_file}"
        printf '%s\n' "${sftp_validation_record}" >&2
        fail "SFTP into the mutable Apptainer environment failed"
    fi
    unlink "${sftp_batch_file}"
    grep -Fq "Remote working directory: /home/${remote_user_name}" \
        <<< "${sftp_validation_record}" ||
        fail "SFTP entered an unexpected container directory"
else
    grep -q '^SSH_TARGET=HOST$' <<< "${validation_record}" ||
        fail "SSH did not enter the immutable allocation host"
fi

local_state_temporary_file="$(mktemp "${local_connection_state_file}.XXXXXX")"
{
    printf 'JOB_ID=%s\n' "${vnc_job_id}"
    printf 'NODE=%s\n' "${vnc_node}"
    printf 'REMOTE_SSH_PORT=%s\n' "${remote_ssh_port}"
    printf 'REMOTE_SSH_TARGET=%s\n' "${active_remote_ssh_target}"
    printf 'REMOTE_SFTP_STATUS=%s\n' "${active_remote_sftp_status}"
    printf 'REMOTE_VNC_PORT=%s\n' "${remote_vnc_port}"
    printf 'LOCAL_VNC_PORT=%s\n' "${local_vnc_port}"
    printf 'VNC_GEOMETRY=%s\n' "${active_vnc_geometry}"
    printf 'MACOS_SHORTCUTS_STATUS=%s\n' \
        "${active_macos_shortcuts_status}"
    printf 'LOCAL_OPENCODEX_PORT=%s\n' "${local_opencodex_port}"
    printf 'REMOTE_SHARED_ROOT=%s\n' "${REMOTE_SHARED_ROOT}"
    printf 'REMOTE_VNC_USER_DIRECTORY=%s\n' "${vnc_user_service_directory}"
    printf 'ENVIRONMENT_NAME=%s\n' "${active_environment_name}"
    printf 'ENVIRONMENT_MODE=%s\n' "${active_environment_mode}"
    printf 'ENVIRONMENT_GENERATION=%s\n' "${active_environment_generation}"
    printf 'CONTAINER_INSTANCE_NAME=%s\n' \
        "${active_container_instance_name}"
    printf 'CONTAINER_INSTANCE_PID=%s\n' \
        "${active_container_instance_process_id}"
    printf 'OPENCODEX_STATUS=%s\n' "${active_opencodex_status}"
    printf 'OPENCODEX_PID=%s\n' "${active_opencodex_process_id}"
    printf 'OPENCODEX_PORT=%s\n' "${active_opencodex_port}"
    printf 'OPENCODEX_MIGRATION_STATUS=%s\n' \
        "${active_opencodex_migration_status}"
    printf 'CODEX_APP_SERVER_STATUS=%s\n' \
        "${active_codex_app_server_status}"
    printf 'CODEX_APP_SERVER_PID=%s\n' \
        "${active_codex_app_server_process_id}"
} > "${local_state_temporary_file}"
chmod 600 "${local_state_temporary_file}"
mv "${local_state_temporary_file}" "${local_connection_state_file}"

vnc_url="vnc://127.0.0.1:${local_vnc_port}"
log_message \
    "Job ${vnc_job_id}: node=${vnc_node} partition=${actual_partition}" \
    "CPUs=${actual_cpu_count} GPUs=${actual_gpu_count}" \
    "memory=${actual_memory} time=${actual_time_limit}"
if [[ "${active_environment_mode}" == "mutable" ]]; then
    log_message "Environment shell: ssh ${vnc_ssh_alias}"
    log_message "Host shell from the container: bluehive-host-shell"
    log_message "Writable admin command: bh-admin"
    log_message "Container batch submission: sbatch SCRIPT [ARG ...]"
    log_message \
        "Environment=${active_environment_name} generation=${active_environment_generation}"
    log_message \
        "Container service instance=${active_container_instance_name}" \
        "host PID=${active_container_instance_process_id}"
    log_message \
        "OpenCodex=${active_opencodex_status} port=${active_opencodex_port}" \
        "PID=${active_opencodex_process_id}" \
        "migration=${active_opencodex_migration_status}"
    log_message \
        "Codex app server=${active_codex_app_server_status}" \
        "PID=${active_codex_app_server_process_id}"
    log_message \
        "OpenCodex dashboard: http://127.0.0.1:${local_opencodex_port}"
else
    log_message "Compute shell: ssh ${vnc_ssh_alias}"
fi
log_message "VNC address: ${vnc_url}"
log_message "Initial/fallback VNC geometry: ${active_vnc_geometry}"
log_message "Text clipboard: enabled."
log_message \
    "macOS application shortcuts: ${active_macos_shortcuts_status:-UNAVAILABLE}"
log_message \
    "VNC password file: ${vnc_user_service_directory}/state/vnc-password.txt"

if [[ "${open_vnc_viewer}" == "true" ]]; then
    command -v open >/dev/null 2>&1 || fail "open is unavailable; use ${vnc_url}"
    tiger_vnc_application="/Applications/TigerVNC.app"
    tiger_vnc_executable="${tiger_vnc_application}/Contents/MacOS/vncviewer"
    if [[ -x "${tiger_vnc_executable}" ]]; then
        log_message \
            "Opening TigerVNC in full screen; enter the VNC password manually."
        log_message \
            "The desktop will match this monitor and use lossless full-color encoding."
        log_message \
            "macOS system shortcuts are captured automatically;" \
            "Control+Option releases them and Control+Option+G recaptures them."
        open -na "${tiger_vnc_application}" --args \
            -AcceptClipboard=1 \
            -AutoSelect=0 \
            -FullColor=1 \
            -FullScreen=1 \
            -FullScreenMode=Current \
            -FullscreenSystemKeys=1 \
            -NoJPEG=1 \
            -PreferredEncoding=Tight \
            -SendClipboard=1 \
            -MaxCutText=1048576 \
            -RemoteResize=1 \
            -SecurityTypes=VncAuth \
            -Shared=1 \
            -ShortcutModifiers=Ctrl,Alt \
            "127.0.0.1::${local_vnc_port}"
    else
        log_message \
            "TigerVNC is not installed; opening Screen Sharing instead."
        log_message "Enter the VNC password manually."
        open "${vnc_url}"
    fi
else
    log_message "Viewer launch skipped (--no-open)."
fi
