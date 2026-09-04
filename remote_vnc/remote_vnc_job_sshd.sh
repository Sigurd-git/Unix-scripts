#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

user_service_directory="${1:?user service directory is required}"
expected_job_id="${2:?job ID is required}"
expected_node="${3:?node is required}"
vnc_port="${4:?VNC port is required}"
authorized_keys_file="${5:?authorized keys file is required}"
opencodex_port="${6:-}"
release_directory="${7:?release directory is required}"
runtime_image_path="${8:?runtime image path is required}"
environment_home="${9:?environment home is required}"
environment_name="${10:?environment name is required}"
environment_mode="${11:?environment mode is required}"
environment_generation="${12:?environment generation is required}"
requested_remote_ssh_port="${13:?fixed remote SSH port is required}"
current_user="$(id -un)"
host_home="${HOME:?HOME is required}"
container_home="/home/${current_user}"

[[ "${SLURM_JOB_ID:-}" == "${expected_job_id}" ]] || {
    printf 'Expected Slurm Job %s, received %s.\n' \
        "${expected_job_id}" "${SLURM_JOB_ID:-unset}" >&2
    exit 2
}
[[ "$(hostname -s)" == "${expected_node}" ]] || {
    printf 'Expected node %s, reached %s.\n' \
        "${expected_node}" "$(hostname -s)" >&2
    exit 2
}
[[ "${vnc_port}" =~ ^[0-9]+$ ]] || {
    printf 'Invalid VNC port: %s\n' "${vnc_port}" >&2
    exit 2
}
[[ "${requested_remote_ssh_port}" =~ ^[0-9]+$ ]] &&
    ((requested_remote_ssh_port >= 44000 && requested_remote_ssh_port <= 44999)) || {
    printf 'Invalid fixed remote SSH port: %s\n' \
        "${requested_remote_ssh_port}" >&2
    exit 2
}
if [[ -n "${opencodex_port}" ]]; then
    [[ "${opencodex_port}" =~ ^[1-9][0-9]*$ &&
       ${opencodex_port} -le 65535 ]] || {
        printf 'Invalid OpenCodex port: %s\n' "${opencodex_port}" >&2
        exit 2
    }
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
[[ -d "${environment_home}" ]] || {
    printf 'Environment home is missing: %s\n' "${environment_home}" >&2
    exit 2
}
[[ -d "${runtime_image_path}" || -r "${runtime_image_path}" ]] || {
    printf 'Runtime image is unavailable: %s\n' "${runtime_image_path}" >&2
    exit 2
}
[[ -s "${authorized_keys_file}" ]] || {
    printf 'Authorized key file is missing: %s\n' "${authorized_keys_file}" >&2
    exit 2
}
ssh-keygen -lf "${authorized_keys_file}" >/dev/null || {
    printf 'Authorized key file is invalid: %s\n' "${authorized_keys_file}" >&2
    exit 2
}

state_directory="${user_service_directory}/state"
job_state_directory="${state_directory}/jobs/${SLURM_JOB_ID}"
vnc_connection_file="${state_directory}/connection.env"
host_shell_directory="${job_state_directory}/host-shell"
remote_ssh_directory="${job_state_directory}/remote-ssh"
remote_ssh_connection_file="${remote_ssh_directory}/connection.env"
remote_ssh_log_file="${remote_ssh_directory}/sshd.log"
remote_ssh_lock_file="${remote_ssh_directory}/service.lock"
host_shell_entry_script="${host_shell_directory}/entry.sh"
host_shell_server_key="${host_shell_directory}/server-key"
persistent_server_key="${state_directory}/remote-ssh/server-key"
persistent_server_public_key="${persistent_server_key}.pub"
environment_common_helpers="${release_directory}/environment_common.sh"
container_host_proxy_source="${release_directory}/container_host_proxy.sh"
container_ssh_host_directory="${environment_home}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}"
container_ssh_directory="${container_home}/.local/state/remote-vnc/ssh/${SLURM_JOB_ID}"
container_command_host_directory="${container_ssh_host_directory}/bin"
container_command_directory="${container_ssh_directory}/bin"
container_ssh_entry_host_file="${container_ssh_host_directory}/entry.sh"
container_ssh_entry_file="${container_ssh_directory}/entry.sh"
container_group_file="${container_ssh_host_directory}/group"
runtime_directory="${SLURM_TMPDIR:-/tmp}/remote-vnc-${current_user}-${SLURM_JOB_ID}/container-ssh"
sshd_process_id=""
ssh_target="HOST"
sftp_status="DISABLED"
sshd_executable="/sbin/sshd"
sshd_force_command="${host_shell_entry_script}"
sshd_launch_prefix=()
sshd_extra_arguments=()

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

display_value="$(read_state_value "${vnc_connection_file}" DISPLAY || true)"
[[ "${display_value}" =~ ^:[0-9]+$ ]] || {
    printf 'Invalid VNC display: %s\n' "${display_value:-unset}" >&2
    exit 2
}

mkdir -p "${remote_ssh_directory}"
chmod 700 "${remote_ssh_directory}"

exec 9> "${remote_ssh_lock_file}"
if ! flock -n 9; then
    printf 'A remote VNC SSH service is already running for Job %s.\n' \
        "${SLURM_JOB_ID}" >&2
    exit 3
fi

[[ -x "${host_shell_entry_script}" ]] || {
    printf 'Host-shell entry script is missing: %s\n' \
        "${host_shell_entry_script}" >&2
    exit 2
}
[[ -s "${host_shell_server_key}" && -s "${host_shell_server_key}.pub" ]] || {
    printf 'Host-shell server key is missing under %s.\n' \
        "${host_shell_directory}" >&2
    exit 2
}
persistent_server_key_public="$(
    ssh-keygen -y -f "${persistent_server_key}" 2>/dev/null |
        awk 'NF >= 2 { print $1 " " $2; exit }' || true
)"
recorded_persistent_server_key_public="$(
    awk 'NF >= 2 { print $1 " " $2; exit }' \
        "${persistent_server_public_key}" 2>/dev/null || true
)"
[[ -n "${persistent_server_key_public}" &&
   "${persistent_server_key_public}" == \
       "${recorded_persistent_server_key_public}" ]] &&
    ssh-keygen -lf "${persistent_server_key}" >/dev/null 2>&1 &&
    ssh-keygen -lf "${persistent_server_public_key}" >/dev/null 2>&1 || {
    printf 'Persistent SSH host-key pair is invalid or mismatched under %s.\n' \
        "${state_directory}/remote-ssh" >&2
    exit 2
}

node_ipv4_address="$(
    getent ahostsv4 "${expected_node}" |
        awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $1; exit }'
)"
[[ "${node_ipv4_address}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Could not resolve an IPv4 address for %s.\n' "${expected_node}" >&2
    exit 2
}

port_is_listening() {
    local requested_port="$1"

    ss -H -ltn | awk -v requested_port="${requested_port}" '
        {
            address = $4
            sub(/^.*:/, "", address)
            if (address == requested_port) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

if [[ -n "${opencodex_port}" ]] &&
   ! port_is_listening "${opencodex_port}"; then
    printf 'OpenCodex port is not listening: 127.0.0.1:%s\n' \
        "${opencodex_port}" >&2
    exit 2
fi

permit_open_targets="127.0.0.1:${vnc_port}"
if [[ -n "${opencodex_port}" ]]; then
    permit_open_targets+=" 127.0.0.1:${opencodex_port}"
fi

write_container_ssh_files() {
    local installed_proxy="${container_command_host_directory}/container-host-proxy"
    local current_group_id
    local current_group_name
    local temporary_group_file="${container_group_file}.tmp.$$"
    local slurm_variable_name

    [[ -x "${container_host_proxy_source}" ]] || {
        printf 'Container host proxy is missing: %s\n' \
            "${container_host_proxy_source}" >&2
        return 1
    }
    mkdir -p "${container_command_host_directory}"
    chmod 700 "${container_ssh_host_directory}" \
        "${container_command_host_directory}"
    install -m 0700 "${container_host_proxy_source}" "${installed_proxy}"
    ln -sfn container-host-proxy "${container_command_host_directory}/bh-env"
    ln -sfn container-host-proxy "${container_command_host_directory}/bh-admin"
    ln -sfn container-host-proxy "${container_command_host_directory}/sbatch"

    current_group_id="$(id -g)"
    current_group_name="$(id -gn)"
    [[ "${current_group_id}" =~ ^[0-9]+$ &&
       "${current_group_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf 'Invalid current group: %s/%s\n' \
            "${current_group_name}" "${current_group_id}" >&2
        return 1
    }
    [[ -r "${runtime_image_path}/etc/group" ]] || {
        printf 'Container group file is unavailable: %s/etc/group\n' \
            "${runtime_image_path}" >&2
        return 1
    }
    awk -F: \
        -v current_group_id="${current_group_id}" \
        -v current_group_name="${current_group_name}" \
        '$1 != "tty" && $1 != current_group_name && $3 != current_group_id' \
        "${runtime_image_path}/etc/group" > "${temporary_group_file}"
    printf '%s:x:%s:%s\n' \
        "${current_group_name}" "${current_group_id}" "${current_user}" \
        >> "${temporary_group_file}"
    chmod 600 "${temporary_group_file}"
    mv "${temporary_group_file}" "${container_group_file}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'umask 077\n'
        printf 'export HOME=%q\n' "${container_home}"
        printf 'export USER=%q\n' "${current_user}"
        printf 'export LOGNAME=%q\n' "${current_user}"
        printf 'export BH_ENV_ACTIVE=1\n'
        printf 'export BH_ENV_NAME=%q\n' "${environment_name}"
        printf 'export BH_ENV_GENERATION=%q\n' "${environment_generation}"
        printf 'export BH_ENV_HOST_HOME=%q\n' "${host_home}"
        printf 'export BH_ENV_HOST_PERSISTENT_HOME=%q\n' "${environment_home}"
        printf 'export BH_ENV_CONTAINER_HOME=%q\n' "${container_home}"
        printf 'export BH_ENV_HOST_SHELL=%q\n' \
            "${container_home}/.local/bin/bluehive-host-shell"
        printf 'export BH_ENV_HOST_COMMAND=%q\n' \
            "${host_home}/.local/bin/bh-env"
        printf 'export CODEX_HOME=%q\n' "${container_home}/.codex"
        printf 'export DISPLAY=%q\n' "${display_value}"
        printf 'export XAUTHORITY=%q\n' "${container_home}/.Xauthority"
        printf 'export XDG_CONFIG_HOME=%q\n' "${container_home}/.config"
        printf 'export XDG_CACHE_HOME=%q\n' "${container_home}/.cache"
        printf 'export XDG_DATA_HOME=%q\n' "${container_home}/.local/share"
        printf 'export XDG_RUNTIME_DIR=%q\n' "${runtime_directory}"
        printf 'export LANG=C.UTF-8\n'
        printf 'export TERM=%q\n' "${TERM:-xterm-256color}"
        printf 'export LD_LIBRARY_PATH=/.singularity.d/libs\n'
        printf 'export PATH=%q\n' \
            "${container_command_directory}:${container_home}/.local/bin:/usr/local/cuda/bin:/opt/matlab/R2025b/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        printf 'export MLM_LICENSE_FILE=%q\n' \
            "${MLM_LICENSE_FILE:-/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/licenses/network.lic}"
        for slurm_variable_name in \
            CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES \
            SLURM_CLUSTER_NAME SLURM_CPUS_PER_TASK SLURM_JOB_ACCOUNT \
            SLURM_JOB_ID SLURM_JOB_GPUS SLURM_JOB_NAME \
            SLURM_JOB_NODELIST SLURM_JOB_PARTITION SLURM_GPUS \
            SLURM_GPUS_ON_NODE SLURM_MEM_PER_NODE SLURM_STEP_GPUS \
            SLURM_SUBMIT_DIR SLURM_TMPDIR; do
            if [[ -n "${!slurm_variable_name:-}" ]]; then
                printf 'export %s=%q\n' \
                    "${slurm_variable_name}" "${!slurm_variable_name}"
            fi
        done
        printf 'cd "${HOME}"\n'
        printf 'case "${SSH_ORIGINAL_COMMAND:-}" in\n'
        printf '    internal-sftp|internal-sftp\\ *|sftp|/usr/lib/openssh/sftp-server|/usr/lib/openssh/sftp-server\\ *)\n'
        printf '        exec /usr/lib/openssh/sftp-server\n'
        printf '        ;;\n'
        printf '    "")\n'
        printf '        exec /usr/bin/fish -l\n'
        printf '        ;;\n'
        printf '    *)\n'
        printf '        exec /bin/bash -c "${SSH_ORIGINAL_COMMAND}"\n'
        printf '        ;;\n'
        printf 'esac\n'
    } > "${container_ssh_entry_host_file}"
    chmod 700 "${container_ssh_entry_host_file}"
}

if [[ "${environment_mode}" == "mutable" ]]; then
    [[ -x "${environment_common_helpers}" ]] || {
        printf 'Environment helper is missing: %s\n' \
            "${environment_common_helpers}" >&2
        exit 2
    }
    # shellcheck disable=SC1090
    source "${environment_common_helpers}"
    bh_env_load_apptainer || {
        printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
        exit 2
    }
    apptainer_executable="$(command -v apptainer)"
    mkdir -p "${runtime_directory}"
    chmod 700 "${runtime_directory}"
    write_container_ssh_files
    container_options=()
    bh_env_append_runtime_options \
        container_options "${environment_home}" "${runtime_directory}" \
        "${display_value}" normal
    container_options+=(
        --bind "${container_group_file}:/etc/group:ro"
    )
    sshd_launch_prefix=(
        "${apptainer_executable}"
        "${container_options[@]}"
        "${runtime_image_path}"
    )
    "${sshd_launch_prefix[@]}" /bin/sh -c \
        'test -x /usr/sbin/sshd && test -x /usr/lib/openssh/sftp-server' \
        >/dev/null 2>&1 || {
        printf 'The mutable environment does not contain sshd and sftp-server.\n' \
            >&2
        exit 2
    }
    ssh_target="CONTAINER"
    sftp_status="ENABLED"
    sshd_executable="/usr/sbin/sshd"
    sshd_force_command="${container_ssh_entry_file}"
    sshd_extra_arguments+=(
        -o "Subsystem=sftp /usr/lib/openssh/sftp-server"
    )
fi

write_connection_state() {
    local status_value="$1"
    local ssh_port_value="${2:-}"
    local temporary_connection_file="${remote_ssh_connection_file}.tmp.$$"
    local cgroup_process_id="$$"
    local cgroup_path

    if [[ "${sshd_process_id}" =~ ^[0-9]+$ &&
          -r "/proc/${sshd_process_id}/cgroup" ]]; then
        cgroup_process_id="${sshd_process_id}"
    fi
    cgroup_path="$(tr '\n' ';' < "/proc/${cgroup_process_id}/cgroup")"
    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'JOB_ID=%s\n' "${SLURM_JOB_ID}"
        printf 'NODE=%s\n' "${expected_node}"
        printf 'NODE_IPV4=%s\n' "${node_ipv4_address}"
        printf 'SSH_PORT=%s\n' "${ssh_port_value}"
        printf 'SSH_TARGET=%s\n' "${ssh_target}"
        printf 'SSHD_PID=%s\n' "${sshd_process_id}"
        printf 'SFTP_STATUS=%s\n' "${sftp_status}"
        printf 'VNC_PORT=%s\n' "${vnc_port}"
        printf 'OPENCODEX_PORT=%s\n' "${opencodex_port}"
        printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
        printf 'ENVIRONMENT_MODE=%s\n' "${environment_mode}"
        printf 'ENVIRONMENT_GENERATION=%s\n' "${environment_generation}"
        printf 'ENVIRONMENT_ROOTFS=%s\n' "${runtime_image_path}"
        printf 'HOST_KEY_PUBLIC_FILE=%s\n' "${persistent_server_public_key}"
        printf 'LOG=%s\n' "${remote_ssh_log_file}"
        printf 'CGROUP=%s\n' "${cgroup_path}"
        printf 'STARTED_AT=%s\n' "$(date --iso-8601=seconds)"
    } > "${temporary_connection_file}"
    mv "${temporary_connection_file}" "${remote_ssh_connection_file}"
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM
    if [[ -n "${sshd_process_id}" ]] && kill -0 "${sshd_process_id}" 2>/dev/null; then
        kill -TERM "${sshd_process_id}" 2>/dev/null || true
        wait "${sshd_process_id}" 2>/dev/null || true
    fi

    if [[ ${exit_status} -eq 0 ]]; then
        write_connection_state "STOPPED" "${remote_ssh_port:-}"
    else
        write_connection_state "FAILED:${exit_status}" "${remote_ssh_port:-}"
    fi
    exit "${exit_status}"
}
trap cleanup EXIT INT TERM

remote_ssh_port="${requested_remote_ssh_port}"
if port_is_listening "${remote_ssh_port}"; then
    printf 'Configured remote SSH port %s is already in use on %s.\n' \
        "${remote_ssh_port}" "${expected_node}" >&2
    printf 'Choose another port from 44000 to 44999 on line 4 of user_password.txt, then restart.\n' \
        >&2
    exit 4
fi
write_connection_state "STARTING" "${remote_ssh_port}"

sshd_arguments=(
    -D -e -f /dev/null
    -o "Port=${remote_ssh_port}"
    -o ListenAddress=127.0.0.1
    -o "ListenAddress=${node_ipv4_address}"
    -o "HostKey=${persistent_server_key}"
    -o "AuthorizedKeysFile=${authorized_keys_file}"
    -o "AllowUsers=${current_user}"
    -o "ForceCommand=${sshd_force_command}"
    -o AuthenticationMethods=publickey
    -o PubkeyAuthentication=yes
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o ChallengeResponseAuthentication=no
    -o HostbasedAuthentication=no
    -o GSSAPIAuthentication=no
    -o PermitEmptyPasswords=no
    -o PermitRootLogin=no
    -o UsePAM=no
    -o StrictModes=no
    -o PermitTTY=yes
    -o X11Forwarding=no
    -o AllowAgentForwarding=no
    -o AllowStreamLocalForwarding=no
    -o AllowTcpForwarding=local
    -o "PermitOpen=${permit_open_targets}"
    -o PermitTunnel=no
    -o GatewayPorts=no
    -o PermitUserEnvironment=no
    -o PermitUserRC=no
    -o UseDNS=no
    -o LoginGraceTime=30
    -o MaxAuthTries=3
    -o ClientAliveInterval=60
    -o ClientAliveCountMax=3
    -o "PidFile=${remote_ssh_directory}/sshd.pid"
    "${sshd_extra_arguments[@]}"
)
"${sshd_launch_prefix[@]}" "${sshd_executable}" "${sshd_arguments[@]}" \
    > "${remote_ssh_log_file}" 2>&1 &
sshd_process_id=$!

listener_ready=false
for ((attempt_number = 1; attempt_number <= 30; attempt_number++)); do
    if ! kill -0 "${sshd_process_id}" 2>/dev/null; then
        printf '%s SSH process exited before opening port %s.\n' \
            "${ssh_target}" "${remote_ssh_port}" >&2
        sed -n '1,160p' "${remote_ssh_log_file}" >&2 || true
        exit 5
    fi

    if port_is_listening "${remote_ssh_port}"; then
        listener_ready=true
        break
    fi
    sleep 1
done

if [[ "${listener_ready}" != "true" ]]; then
    printf '%s SSH process did not open port %s within 30 seconds.\n' \
        "${ssh_target}" "${remote_ssh_port}" >&2
    sed -n '1,160p' "${remote_ssh_log_file}" >&2 || true
    exit 5
fi

write_connection_state "READY" "${remote_ssh_port}"
printf 'REMOTE_VNC_SSH_READY job=%s node=%s port=%s target=%s\n' \
    "${SLURM_JOB_ID}" "${expected_node}" "${remote_ssh_port}" \
    "${ssh_target}"

wait "${sshd_process_id}"
