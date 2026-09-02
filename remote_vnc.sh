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
start_opencodex=false
restart_existing_job=false
startup_timeout_seconds=300
image_build_timeout_seconds=1800
opencodex_startup_timeout_seconds=120

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

Start or reuse an independent VNC Slurm job. The script also starts a
public-key-only SSH service inside that allocation, updates the existing Mac
SSH entry "blhc3", creates the VNC tunnel, and opens macOS Screen Sharing.

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
  --opencodex   Start ocx in a detached screen, then restart Codex app server
                (default: off)
  --restart     Replace the current VNC job with a newly managed job
  --no-open     Prepare SSH and VNC without opening Screen Sharing
  -h, --help    Show this help

After startup:
  ssh blhc3
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
        --opencodex)
            start_opencodex=true
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
if [[ -n "${requested_node}" ]]; then
    [[ "${requested_node}" =~ ^[A-Za-z0-9._-]+$ ]] ||
        fail "invalid node name: ${requested_node}"
fi

for required_command in ssh scp ssh-keygen lsof awk sed mktemp launchctl plutil; do
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
managed_launcher_comment="remote-vnc-managed-v3"

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
# shellcheck disable=SC1090
source "${read_user_password_script}"
remote_user_name="${USER}"
[[ "${remote_user_name}" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail "invalid remote user name: ${remote_user_name}"

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
log_message "REMOTE_SHARED_ROOT=${REMOTE_SHARED_ROOT}"
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

remote_tools_ssh_bash_args "${vnc_user_service_directory}" <<'REMOTE_PREPARE'
set -Eeuo pipefail
user_service_directory="$1"
umask 077
private_directories=(
    "${user_service_directory}"
    "${user_service_directory}/state"
    "${user_service_directory}/state/jobs"
    "${user_service_directory}/logs"
    "${user_service_directory}/images"
)
mkdir -p "${private_directories[@]}"
chmod 700 "${private_directories[@]}"
chmod g-s "${private_directories[@]}"
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
        "${restart_existing_job}" <<'REMOTE_START'
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
managed_launcher_version="3"

if [[ "${requested_node}" == "__REMOTE_VNC_SCHEDULER__" ]]; then
    requested_node=""
fi

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
    "${release_directory}/build_vnc_image.sh" \
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
    [[ "${job_comment}" == "${managed_launcher_comment}" ]]
}

managed_launcher_is_ready() {
    local requested_job_id="$1"
    local launcher_state_file

    launcher_state_file="$(managed_launcher_state_file "${requested_job_id}")"
    [[ "$(read_state_value "${launcher_state_file}" STATUS || true)" == "READY" ]] &&
        [[ "$(read_state_value "${launcher_state_file}" LAUNCHER_VERSION || true)" == \
           "${managed_launcher_version}" ]] &&
        [[ "$(read_state_value "${launcher_state_file}" JOB_ID || true)" == \
           "${requested_job_id}" ]]
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
            printf '[remote-vnc] Waiting for existing VNC Job %s.\n' \
                "${job_id}" >&2
        else
            printf 'VNC Job %s was started without the managed SSH service.\n' \
                "${job_id}" >&2
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
            'exec %q %q %q %q %q %q %q %q' \
            "${remote_job_launcher_file}" \
            "${release_directory}" \
            "${user_service_directory}" \
            "${shared_image_path}" \
            "${remote_helper_file}" \
            "${remote_authorized_keys_file}" \
            "${startup_timeout_seconds}" \
            "${image_build_timeout_seconds}"
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

    wait_deadline=$((SECONDS + image_build_timeout_seconds + startup_timeout_seconds))
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
        reported_stage="${launcher_stage:-${image_stage:-WAITING_FOR_JOB}}"
        if [[ "${image_stage}" == "BUILDING_IMAGE" ||
              "${launcher_stage}" == "CHECKING_IMAGE" ]]; then
            reported_stage="${image_stage:-${launcher_stage}}"
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
            "$((image_build_timeout_seconds + startup_timeout_seconds))" \
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
    local connection_ssh_port

    connection_status="$(read_state_value "${remote_ssh_connection_file}" STATUS || true)"
    connection_job_id="$(read_state_value "${remote_ssh_connection_file}" JOB_ID || true)"
    connection_node="$(read_state_value "${remote_ssh_connection_file}" NODE || true)"
    connection_vnc_port="$(read_state_value "${remote_ssh_connection_file}" VNC_PORT || true)"
    connection_ssh_port="$(read_state_value "${remote_ssh_connection_file}" SSH_PORT || true)"

    [[ "${connection_status}" == "READY" ]] &&
        [[ "${connection_job_id}" == "${job_id}" ]] &&
        [[ "${connection_node}" == "${vnc_node}" ]] &&
        [[ "${connection_vnc_port}" == "${vnc_port}" ]] &&
        [[ "${connection_ssh_port}" =~ ^[0-9]+$ ]] &&
        tcp_port_is_open "${vnc_node}" "${connection_ssh_port}"
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
host_key_public_file="$(
    read_state_value "${remote_ssh_connection_file}" HOST_KEY_PUBLIC_FILE
)"
[[ "${remote_ssh_port}" =~ ^[0-9]+$ ]] || {
    printf 'Invalid remote SSH port: %s\n' "${remote_ssh_port}" >&2
    exit 6
}
[[ "${host_key_public_file}" == \
   "${user_service_directory}/state/jobs/${job_id}/host-shell/server-key.pub" ]] || {
    printf 'Unexpected host-key path: %s\n' "${host_key_public_file}" >&2
    exit 6
}

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${job_id}" "${vnc_node}" "${vnc_port}" "${remote_ssh_port}" \
    "${host_key_public_file}" "${actual_partition}" "${actual_cpu_count}" \
    "${actual_gpu_count}" "${actual_memory}" "${actual_time_limit}"
REMOTE_START
)" || fail "remote VNC startup failed"

IFS='|' read -r \
    vnc_job_id vnc_node remote_vnc_port remote_ssh_port \
    host_key_public_file actual_partition actual_cpu_count actual_gpu_count \
    actual_memory actual_time_limit <<< "${ready_record}"
[[ "${vnc_job_id}" =~ ^[0-9]+$ ]] || fail "invalid VNC Job ID: ${vnc_job_id}"
[[ "${vnc_node}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid VNC node: ${vnc_node}"
[[ "${remote_vnc_port}" =~ ^[0-9]+$ ]] || fail "invalid VNC port: ${remote_vnc_port}"
[[ "${remote_ssh_port}" =~ ^[0-9]+$ ]] || fail "invalid SSH port: ${remote_ssh_port}"

server_host_key="$(
    remote_tools_ssh_bash_args "${host_key_public_file}" <<'REMOTE_HOST_KEY'
set -Eeuo pipefail
host_key_public_file="$1"
[[ -r "${host_key_public_file}" ]] || exit 2
awk 'NF >= 2 { print $1 " " $2; exit }' "${host_key_public_file}"
REMOTE_HOST_KEY
)" || fail "could not retrieve the VNC Job SSH host key"
[[ "${server_host_key}" =~ ^ssh-[A-Za-z0-9@._+-]+\ [A-Za-z0-9+/=]+$ ]] ||
    fail "the VNC Job SSH host key is invalid"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
known_hosts_temporary_file="$(mktemp "${known_hosts_file}.XXXXXX")"
printf '%s %s\n' "${vnc_host_key_alias}" "${server_host_key}" \
    > "${known_hosts_temporary_file}"
ssh-keygen -lf "${known_hosts_temporary_file}" >/dev/null || {
    unlink "${known_hosts_temporary_file}"
    fail "could not validate the VNC Job SSH host key"
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
fi
listener_uses_ssh_master "${local_vnc_port}" ||
    fail "SSH did not listen on local VNC port ${local_vnc_port}"

validation_record="$(
    /usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        "${vnc_ssh_alias}" \
        /bin/bash -s <<'REMOTE_VALIDATE'
set -Eeuo pipefail
printf 'JOB_ID=%s\n' "${SLURM_JOB_ID:-}"
printf 'NODE=%s\n' "$(hostname -s)"
printf 'CPUS=%s\n' "${SLURM_CPUS_PER_TASK:-}"
printf 'CUDA=%s\n' "${CUDA_VISIBLE_DEVICES:-}"
printf 'CGROUP='
tr '\n' ';' < "/proc/$$/cgroup"
printf '\n'
[[ -d /scratch/snormanh_lab/shared ]] && printf 'DATA=available\n'
[[ -x /gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2024b/bin/matlab ]] &&
    printf 'MATLAB=available\n'
type module >/dev/null 2>&1 && printf 'MODULE=available\n'
true
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
    fail "the SSH shell cannot access /scratch/snormanh_lab/shared"

if [[ "${start_opencodex}" == "true" ]]; then
    log_message "Starting OpenCodex inside Job ${vnc_job_id}..."
    opencodex_record="$(
        /usr/bin/ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            "${vnc_ssh_alias}" \
            /bin/bash -s -- \
            "${vnc_job_id}" \
            "${vnc_node}" \
            "${opencodex_startup_timeout_seconds}" \
            "${vnc_ssh_alias}" <<'REMOTE_OPENCODEX'
set -Eeuo pipefail

expected_job_id="$1"
expected_node="$2"
startup_timeout_seconds="$3"
ssh_alias="$4"

[[ "${SLURM_JOB_ID:-}" == "${expected_job_id}" ]] || {
    printf 'OpenCodex shell entered Job %s, expected %s\n' \
        "${SLURM_JOB_ID:-unknown}" "${expected_job_id}" >&2
    exit 2
}
[[ "$(hostname -s)" == "${expected_node}" ]] || {
    printf 'OpenCodex shell reached %s, expected %s\n' \
        "$(hostname -s)" "${expected_node}" >&2
    exit 2
}
shell_cgroup="$(tr '\n' ';' < "/proc/$$/cgroup")"
[[ "${shell_cgroup}" == *"/job_${expected_job_id}/step_batch/"* ]] || {
    printf 'OpenCodex shell is outside the batch Step cgroup for Job %s\n' \
        "${expected_job_id}" >&2
    exit 2
}

for required_command in screen ocx pgrep; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        printf 'Required remote command is unavailable: %s\n' \
            "${required_command}" >&2
        exit 2
    }
done

ocx_executable="$(command -v ocx)"
codex_home_directory="${CODEX_HOME:-${HOME}/.codex}"
managed_codex_executable="${codex_home_directory}/packages/standalone/current/codex"
[[ -x "${managed_codex_executable}" ]] || {
    printf 'Managed Codex executable is unavailable: %s\n' \
        "${managed_codex_executable}" >&2
    exit 2
}

screen_session_name="remote-vnc-opencodex-${expected_job_id}"

screen_session_exists() {
    screen -ls 2>/dev/null | awk -v requested_name="${screen_session_name}" '
        $1 ~ /^[0-9]+\./ && index($0, "(Dead") == 0 {
            first_dot = index($1, ".")
            if (substr($1, first_dot + 1) == requested_name) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

ready_record=""
screen_action="existing proxy"
if ! ready_record="$("${ocx_executable}" ready --json 2>/dev/null)"; then
    screen -wipe "${screen_session_name}" >/dev/null 2>&1 || true
    if screen_session_exists; then
        screen_action="existing screen"
    else
        screen -h 10000 -dmS "${screen_session_name}" \
            /bin/bash -c 'exec "$1" start </dev/null' \
            remote-vnc-opencodex "${ocx_executable}"
        screen_action="new screen"

        for _ in {1..10}; do
            screen_session_exists && break
            sleep 0.2
        done
        screen_session_exists || {
            printf 'OpenCodex screen exited during startup: %s\n' \
                "${screen_session_name}" >&2
            exit 3
        }
    fi

    startup_deadline=$((SECONDS + startup_timeout_seconds))
    while (( SECONDS < startup_deadline )); do
        if ready_record="$("${ocx_executable}" ready --json 2>/dev/null)"; then
            break
        fi
        screen_session_exists || {
            printf 'OpenCodex screen exited before the proxy became ready: %s\n' \
                "${screen_session_name}" >&2
            exit 3
        }
        sleep 1
    done
elif screen_session_exists; then
    screen_action="existing screen"
fi

[[ -n "${ready_record}" ]] &&
    grep -Eq '"ready"[[:space:]]*:[[:space:]]*true' <<< "${ready_record}" || {
        printf 'OpenCodex did not become ready within %s seconds. Inspect it with: screen -r %s\n' \
            "${startup_timeout_seconds}" "${screen_session_name}" >&2
        exit 3
    }

proxy_process_id="$(
    sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        <<< "${ready_record}"
)"
proxy_port="$(
    sed -n 's/.*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        <<< "${ready_record}"
)"
[[ "${proxy_process_id}" =~ ^[0-9]+$ ]] &&
    [[ -r "/proc/${proxy_process_id}/cgroup" ]] || {
        printf 'Could not determine the OpenCodex proxy process\n' >&2
        exit 3
    }
proxy_cgroup="$(tr '\n' ';' < "/proc/${proxy_process_id}/cgroup")"
[[ "${proxy_cgroup}" == *"/job_${expected_job_id}/step_batch/"* ]] || {
    printf 'OpenCodex proxy PID %s is outside Job %s; stop that proxy and rerun this command\n' \
        "${proxy_process_id}" "${expected_job_id}" >&2
    exit 3
}

"${managed_codex_executable}" app-server daemon restart >/dev/null || {
    printf 'codex app-server daemon restart failed\n' >&2
    exit 4
}

find_managed_app_server_process_id() {
    local candidate_process_id
    local command_line
    local selected_process_id=""

    while IFS= read -r candidate_process_id; do
        [[ -r "/proc/${candidate_process_id}/cmdline" ]] || continue
        command_line="$(
            tr '\0' ' ' < "/proc/${candidate_process_id}/cmdline" 2>/dev/null || true
        )"
        if [[ "${command_line}" == \
            "${managed_codex_executable} app-server --remote-control --listen unix://"* ]]; then
            selected_process_id="${candidate_process_id}"
        fi
    done < <(pgrep -u "$(id -u)" -x codex || true)

    [[ -n "${selected_process_id}" ]] || return 1
    printf '%s\n' "${selected_process_id}"
}

daemon_record=""
app_server_process_id=""
app_server_cgroup=""
for _ in {1..30}; do
    daemon_record="$(
        "${managed_codex_executable}" app-server daemon version 2>/dev/null || true
    )"
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' \
        <<< "${daemon_record}"; then
        app_server_process_id="$(find_managed_app_server_process_id || true)"
        if [[ "${app_server_process_id}" =~ ^[0-9]+$ ]] &&
           [[ -r "/proc/${app_server_process_id}/cgroup" ]]; then
            app_server_cgroup="$(
                tr '\n' ';' < "/proc/${app_server_process_id}/cgroup"
            )"
            [[ "${app_server_cgroup}" == \
                *"/job_${expected_job_id}/step_batch/"* ]] && break
        fi
    fi
    sleep 1
done

grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' \
    <<< "${daemon_record}" || {
        printf 'Codex app server did not report running after restart\n' >&2
        exit 4
    }
[[ "${app_server_process_id}" =~ ^[0-9]+$ ]] &&
    [[ "${app_server_cgroup}" == *"/job_${expected_job_id}/step_batch/"* ]] || {
        printf 'Codex app server is outside the batch Step cgroup for Job %s\n' \
            "${expected_job_id}" >&2
        exit 4
    }

printf 'OpenCodex: ready on port %s (PID %s, %s)\n' \
    "${proxy_port:-unknown}" "${proxy_process_id}" "${screen_action}"
printf 'Codex app server: running (PID %s)\n' \
    "${app_server_process_id}"
if screen_session_exists; then
    printf 'OpenCodex screen: ssh -t %s screen -r %s\n' \
        "${ssh_alias}" "${screen_session_name}"
else
    printf 'OpenCodex screen: reused a proxy without session %s\n' \
        "${screen_session_name}"
fi
REMOTE_OPENCODEX
    )" || fail "could not start OpenCodex and restart the Codex app server"

    while IFS= read -r opencodex_line; do
        [[ -n "${opencodex_line}" ]] && log_message "${opencodex_line}"
    done <<< "${opencodex_record}"
fi

local_state_temporary_file="$(mktemp "${local_connection_state_file}.XXXXXX")"
{
    printf 'JOB_ID=%s\n' "${vnc_job_id}"
    printf 'NODE=%s\n' "${vnc_node}"
    printf 'REMOTE_SSH_PORT=%s\n' "${remote_ssh_port}"
    printf 'REMOTE_VNC_PORT=%s\n' "${remote_vnc_port}"
    printf 'LOCAL_VNC_PORT=%s\n' "${local_vnc_port}"
    printf 'REMOTE_SHARED_ROOT=%s\n' "${REMOTE_SHARED_ROOT}"
    printf 'REMOTE_VNC_USER_DIRECTORY=%s\n' "${vnc_user_service_directory}"
} > "${local_state_temporary_file}"
chmod 600 "${local_state_temporary_file}"
mv "${local_state_temporary_file}" "${local_connection_state_file}"

vnc_url="vnc://127.0.0.1:${local_vnc_port}"
log_message \
    "Job ${vnc_job_id}: node=${vnc_node} partition=${actual_partition}" \
    "CPUs=${actual_cpu_count} GPUs=${actual_gpu_count}" \
    "memory=${actual_memory} time=${actual_time_limit}"
log_message "Compute shell: ssh ${vnc_ssh_alias}"
log_message "VNC address: ${vnc_url}"
log_message \
    "VNC password file: ${vnc_user_service_directory}/state/vnc-password.txt"

if [[ "${open_vnc_viewer}" == "true" ]]; then
    command -v open >/dev/null 2>&1 || fail "open is unavailable; use ${vnc_url}"
    log_message "Opening Screen Sharing; enter the VNC password manually."
    open "${vnc_url}"
else
    log_message "Viewer launch skipped (--no-open)."
fi
