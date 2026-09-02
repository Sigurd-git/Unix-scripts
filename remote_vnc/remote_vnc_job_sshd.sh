#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

user_service_directory="${1:?user service directory is required}"
expected_job_id="${2:?job ID is required}"
expected_node="${3:?node is required}"
vnc_port="${4:?VNC port is required}"
authorized_keys_file="${5:?authorized keys file is required}"
current_user="$(id -un)"

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
[[ -s "${authorized_keys_file}" ]] || {
    printf 'Authorized key file is missing: %s\n' "${authorized_keys_file}" >&2
    exit 2
}
ssh-keygen -lf "${authorized_keys_file}" >/dev/null || {
    printf 'Authorized key file is invalid: %s\n' "${authorized_keys_file}" >&2
    exit 2
}

job_state_directory="${user_service_directory}/state/jobs/${SLURM_JOB_ID}"
host_shell_directory="${job_state_directory}/host-shell"
remote_ssh_directory="${job_state_directory}/remote-ssh"
remote_ssh_connection_file="${remote_ssh_directory}/connection.env"
remote_ssh_log_file="${remote_ssh_directory}/sshd.log"
remote_ssh_lock_file="${remote_ssh_directory}/service.lock"
host_shell_entry_script="${host_shell_directory}/entry.sh"
host_shell_server_key="${host_shell_directory}/server-key"
sshd_process_id=""

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

choose_remote_ssh_port() {
    local candidate_port
    local first_candidate_port=$((44000 + SLURM_JOB_ID % 500))

    for ((candidate_port = first_candidate_port; candidate_port <= 44999; candidate_port++)); do
        if ! port_is_listening "${candidate_port}"; then
            printf '%s\n' "${candidate_port}"
            return 0
        fi
    done
    for ((candidate_port = 44000; candidate_port < first_candidate_port; candidate_port++)); do
        if ! port_is_listening "${candidate_port}"; then
            printf '%s\n' "${candidate_port}"
            return 0
        fi
    done

    return 1
}

write_connection_state() {
    local status_value="$1"
    local ssh_port_value="${2:-}"
    local temporary_connection_file="${remote_ssh_connection_file}.tmp.$$"
    local cgroup_path

    cgroup_path="$(tr '\n' ';' < "/proc/$$/cgroup")"
    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'JOB_ID=%s\n' "${SLURM_JOB_ID}"
        printf 'NODE=%s\n' "${expected_node}"
        printf 'NODE_IPV4=%s\n' "${node_ipv4_address}"
        printf 'SSH_PORT=%s\n' "${ssh_port_value}"
        printf 'SSHD_PID=%s\n' "${sshd_process_id}"
        printf 'VNC_PORT=%s\n' "${vnc_port}"
        printf 'HOST_KEY_PUBLIC_FILE=%s\n' "${host_shell_server_key}.pub"
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

remote_ssh_port="$(choose_remote_ssh_port)" || {
    printf 'No free SSH port found in the range 44000-44999.\n' >&2
    exit 4
}
write_connection_state "STARTING" "${remote_ssh_port}"

/sbin/sshd -D -e -f /dev/null \
    -o "Port=${remote_ssh_port}" \
    -o ListenAddress=127.0.0.1 \
    -o "ListenAddress=${node_ipv4_address}" \
    -o "HostKey=${host_shell_server_key}" \
    -o "AuthorizedKeysFile=${authorized_keys_file}" \
    -o "AllowUsers=${current_user}" \
    -o "ForceCommand=${host_shell_entry_script}" \
    -o AuthenticationMethods=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ChallengeResponseAuthentication=no \
    -o HostbasedAuthentication=no \
    -o GSSAPIAuthentication=no \
    -o PermitEmptyPasswords=no \
    -o UsePAM=no \
    -o StrictModes=no \
    -o X11Forwarding=no \
    -o AllowAgentForwarding=no \
    -o AllowStreamLocalForwarding=no \
    -o AllowTcpForwarding=local \
    -o "PermitOpen=127.0.0.1:${vnc_port}" \
    -o PermitTunnel=no \
    -o GatewayPorts=no \
    -o PermitUserEnvironment=no \
    -o PermitUserRC=no \
    -o UseDNS=no \
    -o LoginGraceTime=30 \
    -o MaxAuthTries=3 \
    -o ClientAliveInterval=60 \
    -o ClientAliveCountMax=3 \
    -o "PidFile=${remote_ssh_directory}/sshd.pid" \
    > "${remote_ssh_log_file}" 2>&1 &
sshd_process_id=$!

listener_ready=false
for ((attempt_number = 1; attempt_number <= 30; attempt_number++)); do
    if ! kill -0 "${sshd_process_id}" 2>/dev/null; then
        printf 'Remote VNC SSH process exited before opening port %s.\n' \
            "${remote_ssh_port}" >&2
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
    printf 'Remote VNC SSH process did not open port %s within 30 seconds.\n' \
        "${remote_ssh_port}" >&2
    exit 5
fi

write_connection_state "READY" "${remote_ssh_port}"
printf 'REMOTE_VNC_SSH_READY job=%s node=%s port=%s\n' \
    "${SLURM_JOB_ID}" "${expected_node}" "${remote_ssh_port}"

wait "${sshd_process_id}"
