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
environment_name="${8:-default}"
environment_mode="${9:-mutable}"
environment_build_timeout_seconds="${10:-10800}"

launcher_version="8"
job_id="${SLURM_JOB_ID:?SLURM_JOB_ID is required}"
state_directory="${user_service_directory}/state"
job_state_directory="${state_directory}/jobs/${job_id}"
vnc_connection_file="${state_directory}/connection.env"
launcher_state_file="${job_state_directory}/managed-launcher.env"
image_status_file="${job_state_directory}/image-status"
environment_status_file="${job_state_directory}/environment-status"
remote_ssh_connection_file="${job_state_directory}/remote-ssh/connection.env"
start_vnc_script="${release_directory}/start_vnc.sh"
build_vnc_image_script="${release_directory}/build_vnc_image.sh"
prepare_environment_script="${release_directory}/prepare_environment.sh"
environment_common_helpers="${release_directory}/environment_common.sh"
canonical_checksum_file="${release_directory}/ubuntu-vnc-xfce-g3_24.04.sha256"
definition_file="${release_directory}/ubuntu-vnc-xfce-g3_24.04.def"
user_image_path="${user_service_directory}/images/ubuntu-vnc-xfce-g3_24.04.sif"
selected_image_path=""
runtime_image_path=""
environment_home=""
environment_generation=""
environment_preparation_result=""
vnc_launcher_process_id=""
remote_ssh_launcher_process_id=""

for timeout_value in \
    "${startup_timeout_seconds}" "${image_build_timeout_seconds}" \
    "${environment_build_timeout_seconds}"; do
    [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'Invalid startup timeout: %s\n' "${timeout_value}" >&2
        exit 2
    }
done

[[ -r "${environment_common_helpers}" ]] || {
    printf 'Required environment helper is missing: %s\n' \
        "${environment_common_helpers}" >&2
    exit 2
}
# shellcheck disable=SC1090
source "${environment_common_helpers}"
bh_env_validate_name "${environment_name}" || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 2
}
[[ "${environment_mode}" == "mutable" ||
   "${environment_mode}" == "immutable" ]] || {
    printf 'Invalid environment mode: %s\n' "${environment_mode}" >&2
    exit 2
}

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

read_environment_status() {
    if [[ -s "${environment_status_file}" ]]; then
        head -n 1 "${environment_status_file}"
    elif [[ "${environment_mode}" == "immutable" ]]; then
        printf 'ENVIRONMENT_READY:immutable'
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
        printf 'ENVIRONMENT_STATUS=%s\n' "$(read_environment_status)"
        printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
        printf 'ENVIRONMENT_MODE=%s\n' "${environment_mode}"
        printf 'ENVIRONMENT_GENERATION=%s\n' "${environment_generation}"
        printf 'ENVIRONMENT_ROOTFS=%s\n' "${runtime_image_path}"
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
    "${release_directory}/start_opencodex.sh" \
    "${build_vnc_image_script}" \
    "${prepare_environment_script}" \
    "${environment_common_helpers}" \
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
    "${start_vnc_script}" "${build_vnc_image_script}" \
    "${release_directory}/start_opencodex.sh" \
    "${prepare_environment_script}" "${environment_common_helpers}" \
    "${remote_sshd_helper}"; do
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

mkdir -p \
    "${job_state_directory}" "${user_service_directory}/images" \
    "${user_service_directory}/environments"
chmod 700 "${user_service_directory}" "${state_directory}" \
    "${job_state_directory}" "${user_service_directory}/images" \
    "${user_service_directory}/environments"
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

base_image_state_file="${state_directory}/base-image-path"
temporary_base_image_state_file="${base_image_state_file}.tmp.$$"
printf '%s\n' "${selected_image_path}" > "${temporary_base_image_state_file}"
chmod 600 "${temporary_base_image_state_file}"
mv "${temporary_base_image_state_file}" "${base_image_state_file}"

if [[ "${environment_mode}" == "mutable" ]]; then
    write_launcher_state "PREPARING_ENVIRONMENT"
    environment_record="$(
        "${prepare_environment_script}" \
            "${release_directory}" \
            "${user_service_directory}" \
            "${selected_image_path}" \
            "${environment_name}" \
            "${environment_status_file}" \
            "${environment_build_timeout_seconds}" \
            false
    )"
    IFS='|' read -r \
        runtime_image_path environment_home environment_generation \
        environment_recipe_digest environment_preparation_result \
        <<< "${environment_record}"
    [[ -d "${runtime_image_path}" && -d "${environment_home}" ]] || {
        printf 'Prepared environment is invalid: %s\n' \
            "${environment_record}" >&2
        exit 2
    }
else
    runtime_image_path="${selected_image_path}"
    environment_home="${job_state_directory}/home"
    environment_generation="base-image"
    environment_preparation_result="immutable"
    mkdir -p "${environment_home}"
    chmod 700 "${environment_home}"
    printf 'ENVIRONMENT_READY:immutable\n' > "${environment_status_file}"
fi

write_launcher_state "STARTING_VNC"
"${start_vnc_script}" \
    "${release_directory}" \
    "${user_service_directory}" \
    "${runtime_image_path}" \
    "${environment_name}" \
    "${environment_mode}" \
    "${environment_home}" \
    "${environment_generation}" &
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
opencodex_port="$(
    read_state_value "${vnc_connection_file}" OPENCODEX_PORT || true
)"
if [[ "${environment_mode}" == "mutable" ]]; then
    [[ "${opencodex_port}" =~ ^[1-9][0-9]*$ &&
       ${opencodex_port} -le 65535 ]] || {
        printf 'VNC returned an invalid OpenCodex port: %s\n' \
            "${opencodex_port:-unset}" >&2
        exit 3
    }
else
    opencodex_port=""
fi
write_launcher_state "STARTING_SSH"

"${remote_sshd_helper}" \
    "${user_service_directory}" "${job_id}" "${vnc_node}" "${vnc_port}" \
    "${authorized_keys_file}" "${opencodex_port}" &
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
       [[ "$(read_state_value "${remote_ssh_connection_file}" OPENCODEX_PORT || true)" == "${opencodex_port}" ]] &&
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
printf 'REMOTE_VNC_JOB_READY job=%s node=%s vnc_port=%s opencodex_port=%s ssh_port=%s\n' \
    "${job_id}" "${vnc_node}" "${vnc_port}" \
    "${opencodex_port:-disabled}" \
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
