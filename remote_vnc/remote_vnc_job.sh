#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
shared_image_path="${3:?shared image path is required}"
remote_sshd_helper="${4:?remote SSH helper is required}"
authorized_keys_file="${5:?authorized keys file is required}"
startup_timeout_seconds="${6:-300}"
image_build_timeout_seconds="${7:-1800}"

launcher_version="3"
job_id="${SLURM_JOB_ID:?SLURM_JOB_ID is required}"
state_directory="${user_service_directory}/state"
job_state_directory="${state_directory}/jobs/${job_id}"
vnc_connection_file="${state_directory}/connection.env"
launcher_state_file="${job_state_directory}/managed-launcher.env"
image_status_file="${job_state_directory}/image-status"
remote_ssh_connection_file="${job_state_directory}/remote-ssh/connection.env"
start_vnc_script="${release_directory}/start_vnc.sh"
build_vnc_image_script="${release_directory}/build_vnc_image.sh"
canonical_checksum_file="${release_directory}/ubuntu-vnc-xfce-g3_24.04.sha256"
definition_file="${release_directory}/ubuntu-vnc-xfce-g3_24.04.def"
user_image_path="${user_service_directory}/images/ubuntu-vnc-xfce-g3_24.04.sif"
selected_image_path=""
vnc_launcher_process_id=""
remote_ssh_launcher_process_id=""

for timeout_value in "${startup_timeout_seconds}" "${image_build_timeout_seconds}"; do
    [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'Invalid startup timeout: %s\n' "${timeout_value}" >&2
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

current_timestamp() {
    date --iso-8601=seconds 2>/dev/null ||
        date -u '+%Y-%m-%dT%H:%M:%SZ'
}

write_current_cgroup() {
    if [[ -r "/proc/$$/cgroup" ]]; then
        tr '\n' ';' < "/proc/$$/cgroup"
    else
        printf 'unavailable'
    fi
}

read_image_status() {
    if [[ -s "${image_status_file}" ]]; then
        head -n 1 "${image_status_file}"
    else
        printf 'NOT_STARTED'
    fi
}

write_launcher_state() {
    local status_value="$1"
    local temporary_state_file="${launcher_state_file}.tmp.$$"

    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'LAUNCHER_VERSION=%s\n' "${launcher_version}"
        printf 'JOB_ID=%s\n' "${job_id}"
        printf 'NODE=%s\n' "$(hostname -s)"
        printf 'IMAGE_STATUS=%s\n' "$(read_image_status)"
        printf 'IMAGE=%s\n' "${selected_image_path}"
        printf 'VNC_LAUNCHER_PID=%s\n' "${vnc_launcher_process_id}"
        printf 'SSH_LAUNCHER_PID=%s\n' "${remote_ssh_launcher_process_id}"
        printf 'CGROUP='
        write_current_cgroup
        printf '\n'
        printf 'UPDATED_AT=%s\n' "$(current_timestamp)"
    } > "${temporary_state_file}"
    mv "${temporary_state_file}" "${launcher_state_file}"
}

stop_child_process() {
    local process_id="$1"

    [[ "${process_id}" =~ ^[0-9]+$ ]] || return 0
    if kill -0 "${process_id}" 2>/dev/null; then
        kill -TERM "${process_id}" 2>/dev/null || true
        wait "${process_id}" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM
    stop_child_process "${remote_ssh_launcher_process_id}"
    stop_child_process "${vnc_launcher_process_id}"

    if [[ -d "${job_state_directory}" ]]; then
        if [[ ${exit_status} -eq 0 ]]; then
            write_launcher_state "STOPPED"
        else
            write_launcher_state "FAILED:${exit_status}"
        fi
    fi
    exit "${exit_status}"
}
trap cleanup EXIT INT TERM

for required_file in \
    "${start_vnc_script}" \
    "${build_vnc_image_script}" \
    "${canonical_checksum_file}" \
    "${definition_file}" \
    "${remote_sshd_helper}" \
    "${authorized_keys_file}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done
for required_executable in \
    "${start_vnc_script}" "${build_vnc_image_script}" "${remote_sshd_helper}"; do
    [[ -x "${required_executable}" ]] || {
        printf 'Required script is not executable: %s\n' \
            "${required_executable}" >&2
        exit 2
    }
done
ssh-keygen -lf "${authorized_keys_file}" >/dev/null || {
    printf 'Authorized key file is invalid: %s\n' \
        "${authorized_keys_file}" >&2
    exit 2
}

mkdir -p "${job_state_directory}" "${user_service_directory}/images"
chmod 700 "${user_service_directory}" "${state_directory}" \
    "${job_state_directory}" "${user_service_directory}/images"
write_launcher_state "CHECKING_IMAGE"

selected_image_path="$(
    "${build_vnc_image_script}" \
        "${shared_image_path}" \
        "${user_image_path}" \
        "${canonical_checksum_file}" \
        "${definition_file}" \
        "${image_status_file}" \
        "${image_build_timeout_seconds}"
)"
[[ -r "${selected_image_path}" ]] || {
    printf 'Selected VNC image is unavailable: %s\n' \
        "${selected_image_path:-not set}" >&2
    exit 2
}

write_launcher_state "STARTING_VNC"
"${start_vnc_script}" \
    "${release_directory}" "${user_service_directory}" "${selected_image_path}" &
vnc_launcher_process_id=$!
write_launcher_state "STARTING_VNC"

vnc_ready=false
for ((attempt_number = 1;
      attempt_number <= startup_timeout_seconds;
      attempt_number++)); do
    if ! kill -0 "${vnc_launcher_process_id}" 2>/dev/null; then
        vnc_exit_status=0
        wait "${vnc_launcher_process_id}" || vnc_exit_status=$?
        vnc_launcher_process_id=""
        printf 'VNC launcher exited before becoming ready with status %s.\n' \
            "${vnc_exit_status}" >&2
        if [[ ${vnc_exit_status} -eq 0 ]]; then
            exit 3
        fi
        exit "${vnc_exit_status}"
    fi

    if [[ "$(read_state_value "${vnc_connection_file}" STATUS || true)" == "READY" ]] &&
       [[ "$(read_state_value "${vnc_connection_file}" JOB_ID || true)" == "${job_id}" ]] &&
       [[ "$(read_state_value "${vnc_connection_file}" NODE || true)" == "$(hostname -s)" ]] &&
       [[ "$(read_state_value "${vnc_connection_file}" VNC_PORT || true)" =~ ^[0-9]+$ ]]; then
        vnc_ready=true
        break
    fi
    sleep 1
done
[[ "${vnc_ready}" == "true" ]] || {
    printf 'VNC did not become ready within %s seconds.\n' \
        "${startup_timeout_seconds}" >&2
    exit 3
}

vnc_port="$(read_state_value "${vnc_connection_file}" VNC_PORT)"
vnc_node="$(read_state_value "${vnc_connection_file}" NODE)"
write_launcher_state "STARTING_SSH"

"${remote_sshd_helper}" \
    "${user_service_directory}" "${job_id}" "${vnc_node}" "${vnc_port}" \
    "${authorized_keys_file}" &
remote_ssh_launcher_process_id=$!
write_launcher_state "STARTING_SSH"

remote_ssh_ready=false
for ((attempt_number = 1; attempt_number <= 60; attempt_number++)); do
    if ! kill -0 "${remote_ssh_launcher_process_id}" 2>/dev/null; then
        remote_ssh_exit_status=0
        wait "${remote_ssh_launcher_process_id}" || remote_ssh_exit_status=$?
        remote_ssh_launcher_process_id=""
        printf 'Remote SSH launcher exited before becoming ready with status %s.\n' \
            "${remote_ssh_exit_status}" >&2
        if [[ ${remote_ssh_exit_status} -eq 0 ]]; then
            exit 4
        fi
        exit "${remote_ssh_exit_status}"
    fi

    if [[ "$(read_state_value "${remote_ssh_connection_file}" STATUS || true)" == "READY" ]] &&
       [[ "$(read_state_value "${remote_ssh_connection_file}" JOB_ID || true)" == "${job_id}" ]] &&
       [[ "$(read_state_value "${remote_ssh_connection_file}" NODE || true)" == "${vnc_node}" ]] &&
       [[ "$(read_state_value "${remote_ssh_connection_file}" VNC_PORT || true)" == "${vnc_port}" ]] &&
       [[ "$(read_state_value "${remote_ssh_connection_file}" SSH_PORT || true)" =~ ^[0-9]+$ ]]; then
        remote_ssh_ready=true
        break
    fi
    sleep 1
done
[[ "${remote_ssh_ready}" == "true" ]] || {
    printf 'Remote SSH did not become ready within 60 seconds.\n' >&2
    exit 4
}

write_launcher_state "READY"
printf 'REMOTE_VNC_JOB_READY job=%s node=%s vnc_port=%s ssh_port=%s\n' \
    "${job_id}" "${vnc_node}" "${vnc_port}" \
    "$(read_state_value "${remote_ssh_connection_file}" SSH_PORT)"

while kill -0 "${vnc_launcher_process_id}" 2>/dev/null &&
      kill -0 "${remote_ssh_launcher_process_id}" 2>/dev/null; do
    sleep 5
done

if ! kill -0 "${vnc_launcher_process_id}" 2>/dev/null; then
    vnc_exit_status=0
    wait "${vnc_launcher_process_id}" || vnc_exit_status=$?
    vnc_launcher_process_id=""
    printf 'VNC launcher stopped with status %s.\n' "${vnc_exit_status}" >&2
    exit "${vnc_exit_status}"
fi

remote_ssh_exit_status=0
wait "${remote_ssh_launcher_process_id}" || remote_ssh_exit_status=$?
remote_ssh_launcher_process_id=""
printf 'Remote SSH launcher stopped with status %s.\n' \
    "${remote_ssh_exit_status}" >&2
if [[ ${remote_ssh_exit_status} -eq 0 ]]; then
    exit 5
fi
exit "${remote_ssh_exit_status}"
