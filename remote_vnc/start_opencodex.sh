#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
environment_rootfs="${3:?environment rootfs is required}"
environment_home="${4:?environment home is required}"
environment_name="${5:?environment name is required}"
startup_timeout_seconds="${6:-120}"

job_id="${SLURM_JOB_ID:?SLURM_JOB_ID is required}"
current_user="$(id -un)"
current_user_id="$(id -u)"
host_home="${HOME:?HOME is required}"
container_home="/home/${current_user}"
shared_codex_home="${host_home}/.codex"
job_state_directory="${user_service_directory}/state/jobs/${job_id}"
service_directory="${job_state_directory}/opencodex"
service_state_file="${service_directory}/service.env"
service_log_file="${service_directory}/service.log"
opencodex_log_file="${service_directory}/opencodex.log"
runtime_directory="${service_directory}/runtime"
environment_common_helpers="${release_directory}/environment_common.sh"
container_codex_home="${container_home}/.codex"
persistent_codex_home="${environment_home}/.codex"
codex_seed_standalone_directory="/opt/codex-home/packages/standalone"
container_codex_standalone_directory="${container_codex_home}/packages/standalone"
managed_codex_executable="${container_codex_standalone_directory}/current/bin/codex"
container_command_path="${container_codex_standalone_directory}/current/bin:/usr/local/cuda/bin:/opt/matlab/R2025b/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
service_instance_name="remote-vnc-${current_user}-${job_id}"
service_instance_uri="instance://${service_instance_name}"
service_instance_pid_file="${service_directory}/instance.pid"
service_instance_process_id=""
service_instance_cgroup="unavailable"
service_instance_started=false
opencodex_launcher_process_id=""
opencodex_process_id=""
opencodex_process_cgroup="unavailable"
opencodex_port=""
app_server_launcher_process_id=""
app_server_process_id=""
app_server_process_cgroup="unavailable"
app_server_updater_process_id=""
app_server_restart_marker="${service_directory}/app-server-restarted"
app_server_status="NOT_STARTED"
migration_status="NOT_STARTED"

[[ "${startup_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid OpenCodex startup timeout: %s\n' \
        "${startup_timeout_seconds}" >&2
    exit 2
}
for required_path in \
    "${environment_rootfs}" "${environment_home}" \
    "${environment_common_helpers}"; do
    [[ -e "${required_path}" ]] || {
        printf 'Required OpenCodex path is missing: %s\n' \
            "${required_path}" >&2
        exit 2
    }
done
[[ -x "${environment_common_helpers}" ]] || {
    printf 'Required OpenCodex launcher is not executable.\n' >&2
    exit 2
}

# shellcheck disable=SC1090
source "${environment_common_helpers}"
bh_env_validate_name "${environment_name}" || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 2
}
bh_env_require_slurm_allocation
bh_env_load_apptainer || {
    printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
    exit 2
}
apptainer_executable="$(command -v apptainer)"

mkdir -p "${service_directory}" "${runtime_directory}"
chmod 700 "${service_directory}" "${runtime_directory}"
touch "${service_log_file}" "${opencodex_log_file}"
chmod 600 "${service_log_file}" "${opencodex_log_file}"

container_start_options=()
bh_env_append_runtime_options \
    container_start_options "${environment_home}" "${runtime_directory}" "" service
container_start_options+=(
    --env "OPENCODEX_HOME=${container_home}/.opencodex"
    --env "PATH=${container_command_path}"
)
instance_start_options=("${container_start_options[@]:1}")
instance_exec_options=(exec --cleanenv)
for ((option_index = 0;
      option_index < ${#container_start_options[@]};
      option_index++)); do
    if [[ "${container_start_options[option_index]}" == "--env" ]]; then
        instance_exec_options+=(
            --env "${container_start_options[option_index + 1]}"
        )
        option_index=$((option_index + 1))
    fi
done

run_in_container() {
    [[ "${service_instance_started}" == "true" ]] || return 1
    "${apptainer_executable}" "${instance_exec_options[@]}" \
        "${service_instance_uri}" "$@"
}

process_belongs_to_job() {
    local process_id="$1"
    local process_user_id
    local process_cgroup

    [[ "${process_id}" =~ ^[0-9]+$ && -r "/proc/${process_id}/cgroup" ]] ||
        return 1
    process_user_id="$(stat -c '%u' "/proc/${process_id}" 2>/dev/null || true)"
    [[ "${process_user_id}" == "${current_user_id}" ]] || return 1
    process_cgroup="$(tr '\n' ';' < "/proc/${process_id}/cgroup")"
    [[ "${process_cgroup}" == *"/job_${job_id}/step_batch/"* ]]
}

process_cgroup_record() {
    local process_id="$1"

    if [[ "${process_id}" =~ ^[0-9]+$ && -r "/proc/${process_id}/cgroup" ]]; then
        tr '\n' ';' < "/proc/${process_id}/cgroup"
    else
        printf 'unavailable'
    fi
}

instance_process_belongs_to_job() {
    local process_id="$1"

    [[ "${process_id}" =~ ^[0-9]+$ ]] || return 1
    run_in_container /bin/bash -c '
        set -eu
        process_id="$1"
        expected_job_id="$2"
        [[ -r "/proc/${process_id}/cgroup" ]]
        process_cgroup="$(tr "\n" ";" < "/proc/${process_id}/cgroup")"
        [[ "${process_cgroup}" == \
           *"/job_${expected_job_id}/step_batch/"* ]]
    ' -- "${process_id}" "${job_id}" >/dev/null 2>&1
}

instance_process_cgroup_record() {
    local process_id="$1"
    local process_cgroup

    if [[ "${process_id}" =~ ^[0-9]+$ ]]; then
        process_cgroup="$(
            run_in_container /bin/bash -c '
                process_id="$1"
                if [[ -r "/proc/${process_id}/cgroup" ]]; then
                    tr "\n" ";" < "/proc/${process_id}/cgroup"
                fi
            ' -- "${process_id}" 2>/dev/null || true
        )"
    fi
    printf '%s' "${process_cgroup:-unavailable}"
}

write_service_state() {
    local status_value="$1"
    local temporary_state_file="${service_state_file}.tmp.$$"

    {
        printf 'STATUS=%s\n' "${status_value}"
        printf 'JOB_ID=%s\n' "${job_id}"
        printf 'NODE=%s\n' "$(hostname -s)"
        printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
        printf 'ENVIRONMENT_HOME=%s\n' "${environment_home}"
        printf 'CODEX_HOME=%s\n' "${persistent_codex_home}"
        printf 'CODEX_SQLITE_HOME=%s\n' "${shared_codex_home}"
        printf 'CODEX_SESSION_STORE=%s\n' \
            "${shared_codex_home}/sessions"
        printf 'CODEX_SESSION_SHARING=HOST\n'
        printf 'CODEX_EXECUTABLE=%s\n' "${managed_codex_executable}"
        printf 'MIGRATION_STATUS=%s\n' "${migration_status}"
        printf 'CONTAINER_INSTANCE_NAME=%s\n' "${service_instance_name}"
        printf 'CONTAINER_INSTANCE_PID=%s\n' \
            "${service_instance_process_id}"
        printf 'CONTAINER_INSTANCE_CGROUP=%s\n' \
            "${service_instance_cgroup}"
        printf 'OPENCODEX_PID=%s\n' "${opencodex_process_id}"
        printf 'OPENCODEX_PORT=%s\n' "${opencodex_port}"
        printf 'OPENCODEX_LOG=%s\n' "${opencodex_log_file}"
        printf 'OPENCODEX_CGROUP=%s\n' "${opencodex_process_cgroup}"
        printf 'CODEX_APP_SERVER_STATUS=%s\n' "${app_server_status}"
        printf 'CODEX_APP_SERVER_LAUNCHER_PID=%s\n' \
            "${app_server_launcher_process_id}"
        printf 'CODEX_APP_SERVER_PID=%s\n' "${app_server_process_id}"
        printf 'CODEX_APP_SERVER_CGROUP=%s\n' \
            "${app_server_process_cgroup}"
        printf 'CODEX_APP_SERVER_UPDATER_PID=%s\n' \
            "${app_server_updater_process_id}"
        printf 'SERVICE_LOG=%s\n' "${service_log_file}"
        printf 'UPDATED_AT=%s\n' "$(date --iso-8601=seconds)"
    } > "${temporary_state_file}"
    mv "${temporary_state_file}" "${service_state_file}"
}

stop_owned_process() {
    local process_id="$1"

    if process_belongs_to_job "${process_id}" &&
       kill -0 "${process_id}" 2>/dev/null; then
        kill -TERM "${process_id}" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM
    if instance_process_belongs_to_job "${app_server_process_id}"; then
        timeout 15 \
            "${apptainer_executable}" "${instance_exec_options[@]}" \
            "${service_instance_uri}" \
            "${managed_codex_executable}" app-server daemon stop \
            >> "${service_log_file}" 2>&1 || true
    fi
    if instance_process_belongs_to_job "${opencodex_process_id}"; then
        timeout 15 \
            "${apptainer_executable}" "${instance_exec_options[@]}" \
            "${service_instance_uri}" /usr/local/bin/ocx stop \
            >> "${service_log_file}" 2>&1 || true
    fi
    for launcher_process_id in \
        "${app_server_launcher_process_id}" \
        "${opencodex_launcher_process_id}"; do
        if [[ "${launcher_process_id}" =~ ^[0-9]+$ ]] &&
           kill -0 "${launcher_process_id}" 2>/dev/null; then
            kill -TERM "${launcher_process_id}" 2>/dev/null || true
            wait "${launcher_process_id}" 2>/dev/null || true
        fi
    done
    if [[ "${service_instance_started}" == "true" ]]; then
        timeout 20 "${apptainer_executable}" instance stop \
            "${service_instance_name}" >> "${service_log_file}" 2>&1 || true
        service_instance_started=false
    fi
    stop_owned_process "${service_instance_process_id}"

    if [[ ${exit_status} -eq 0 ]]; then
        app_server_status="STOPPED"
        write_service_state "STOPPED"
    else
        write_service_state "FAILED:${exit_status}"
    fi
    exit "${exit_status}"
}
trap cleanup EXIT INT TERM

copy_private_file_if_missing() {
    local source_file="$1"
    local destination_file="$2"
    local relative_name="$3"

    [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 0
    [[ ! -e "${destination_file}" && ! -L "${destination_file}" ]] || return 0
    install -m 0600 "${source_file}" "${destination_file}"
    printf '%s\n' "${relative_name}" >> "${migration_items_file}"
    migrated_item_count=$((migrated_item_count + 1))
}

copy_private_directory_if_missing() {
    local source_directory="$1"
    local destination_directory="$2"
    local relative_name="$3"

    [[ -d "${source_directory}" && ! -L "${source_directory}" ]] || return 0
    [[ ! -e "${destination_directory}" && ! -L "${destination_directory}" ]] ||
        return 0
    cp -a "${source_directory}" "${destination_directory}"
    chmod -R go-rwx "${destination_directory}"
    printf '%s/\n' "${relative_name}" >> "${migration_items_file}"
    migrated_item_count=$((migrated_item_count + 1))
}

migration_directory="${environment_home}/.config/bh-env/migrations"
migration_marker="${migration_directory}/opencodex-from-bluehive-home-v2.env"
migration_items_file="${migration_directory}/opencodex-from-bluehive-home-v2.items"
mkdir -p \
    "${migration_directory}" "${environment_home}/.opencodex" \
    "${environment_home}/.codex" "${environment_home}/.local/bin"
chmod 700 \
    "${environment_home}" "${environment_home}/.opencodex" \
    "${environment_home}/.codex" "${environment_home}/.local" \
    "${environment_home}/.local/bin" "${migration_directory}"

if [[ -s "${migration_marker}" ]]; then
    migration_status="EXISTING"
else
    migrated_item_count=0
    : > "${migration_items_file}"
    for configuration_name in \
        config.json auth.json admin-api-token codex-accounts.json \
        thought-signature-replay.salt .star-prompted version.json; do
        copy_private_file_if_missing \
            "${host_home}/.opencodex/${configuration_name}" \
            "${environment_home}/.opencodex/${configuration_name}" \
            ".opencodex/${configuration_name}"
    done
    for configuration_name in \
        config.toml auth.json installation_id opencodex-catalog.json \
        opencodex.config.toml AGENTS.md version.json \
        .personality_migration .sandbox_migration; do
        copy_private_file_if_missing \
            "${host_home}/.codex/${configuration_name}" \
            "${environment_home}/.codex/${configuration_name}" \
            ".codex/${configuration_name}"
    done
    for configuration_directory in skills plugins memories vendor_imports; do
        copy_private_directory_if_missing \
            "${host_home}/.codex/${configuration_directory}" \
            "${environment_home}/.codex/${configuration_directory}" \
            ".codex/${configuration_directory}"
    done

    if ((migrated_item_count > 0)); then
        temporary_migration_marker="${migration_marker}.tmp.$$"
        {
            printf 'SCHEMA_VERSION=2\n'
            printf 'SOURCE_HOME=%s\n' "${host_home}"
            printf 'MIGRATED_ITEMS=%s\n' "${migrated_item_count}"
            printf 'MIGRATED_AT=%s\n' "$(date --iso-8601=seconds)"
        } > "${temporary_migration_marker}"
        chmod 600 "${temporary_migration_marker}" "${migration_items_file}"
        mv "${temporary_migration_marker}" "${migration_marker}"
        migration_status="MIGRATED:${migrated_item_count}"
    else
        rm -f "${migration_items_file}"
        migration_status="NO_SOURCE_SETTINGS"
    fi
fi

write_service_state "STARTING_CONTAINER_INSTANCE"
: > "${service_instance_pid_file}"
chmod 600 "${service_instance_pid_file}"
"${apptainer_executable}" instance start \
    --pid-file "${service_instance_pid_file}" \
    "${instance_start_options[@]}" \
    "${environment_rootfs}" "${service_instance_name}" \
    >> "${service_log_file}" 2>&1 || {
    printf 'Could not start Apptainer service instance %s. Log: %s\n' \
        "${service_instance_name}" "${service_log_file}" >&2
    exit 3
}
service_instance_started=true
service_instance_process_id="$(head -n 1 "${service_instance_pid_file}")"
process_belongs_to_job "${service_instance_process_id}" || {
    printf 'Apptainer instance PID %s is outside Slurm Job %s.\n' \
        "${service_instance_process_id:-unknown}" "${job_id}" >&2
    exit 3
}
run_in_container /bin/true || {
    printf 'Could not enter Apptainer service instance %s.\n' \
        "${service_instance_name}" >&2
    exit 3
}
service_instance_cgroup="$(
    process_cgroup_record "${service_instance_process_id}"
)"

write_service_state "PREPARING_CODEX"
codex_install_lock_file="${migration_directory}/codex-standalone.lock"
exec 8> "${codex_install_lock_file}"
flock -w 120 8 || {
    printf 'Timed out waiting for the persistent Codex install lock: %s\n' \
        "${codex_install_lock_file}" >&2
    exit 3
}
run_in_container /bin/bash -c '
    set -Eeuo pipefail
    source_directory="$1"
    destination_directory="$2"
    incoming_directory=""

    cleanup_incoming_directory() {
        local exit_status=$?

        trap - EXIT INT TERM
        case "${incoming_directory}" in
            "${destination_directory}.incoming."*)
                [[ -d "${incoming_directory}" ]] &&
                    rm -rf -- "${incoming_directory}"
                ;;
        esac
        exit "${exit_status}"
    }
    trap cleanup_incoming_directory EXIT INT TERM

    if [[ -x "${destination_directory}/current/bin/codex" &&
          -f "${destination_directory}/current/codex-package.json" ]]; then
        exit 0
    fi
    if [[ -e "${destination_directory}" || -L "${destination_directory}" ]]; then
        printf "Incomplete persistent Codex install: %s\\n" \
            "${destination_directory}" >&2
        exit 2
    fi
    [[ -x "${source_directory}/current/bin/codex" &&
       -f "${source_directory}/current/codex-package.json" ]] || {
        printf "Codex seed install is incomplete: %s\\n" \
            "${source_directory}" >&2
        exit 2
    }

    for stale_directory in "${destination_directory}.incoming."*; do
        [[ -e "${stale_directory}" || -L "${stale_directory}" ]] || continue
        case "${stale_directory}" in
            "${destination_directory}.incoming."*)
                rm -rf -- "${stale_directory}"
                ;;
        esac
    done
    incoming_directory="${destination_directory}.incoming.$$"
    mkdir -p "$(dirname "${destination_directory}")"
    cp -R "${source_directory}" "${incoming_directory}"
    [[ -x "${incoming_directory}/current/bin/codex" &&
       -f "${incoming_directory}/current/codex-package.json" ]] || {
        printf "Copied Codex install failed validation: %s\\n" \
            "${incoming_directory}" >&2
        exit 2
    }
    mv "${incoming_directory}" "${destination_directory}"
    incoming_directory=""
' -- "${codex_seed_standalone_directory}" \
    "${container_codex_standalone_directory}" \
    >> "${service_log_file}" 2>&1 || {
    printf 'Could not prepare the persistent standalone Codex install. Log: %s\n' \
        "${service_log_file}" >&2
    exit 3
}
flock -u 8

write_container_wrapper() {
    local destination_file="$1"
    local container_command="$2"
    local temporary_wrapper_file="${destination_file}.tmp.$$"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'if [[ "${BH_ENV_ACTIVE:-}" == "1" ]]; then\n'
        printf '    exec %q "$@"\n' "${container_command}"
        printf 'fi\n'
        printf 'exec %q' "${apptainer_executable}"
        for wrapper_option in "${instance_exec_options[@]}"; do
            printf ' %q' "${wrapper_option}"
        done
        printf ' %q %q "$@"\n' \
            "${service_instance_uri}" "${container_command}"
    } > "${temporary_wrapper_file}"
    chmod 700 "${temporary_wrapper_file}"
    mv "${temporary_wrapper_file}" "${destination_file}"
}

write_container_wrapper "${environment_home}/.local/bin/codex" \
    "${managed_codex_executable}"
write_container_wrapper "${environment_home}/.local/bin/ocx" \
    /usr/local/bin/ocx

write_service_state "CHECKING_COMMANDS"
run_in_container /bin/bash -c '
    set -Eeuo pipefail
    for command_name in node npm ocx codex jq; do
        command -v "${command_name}" >/dev/null
    done
    [[ "$(command -v codex)" == "$1" ]]
' -- "${managed_codex_executable}" >> "${service_log_file}" 2>&1 || {
    printf 'OpenCodex or Codex is unavailable in the mutable environment.\n' >&2
    exit 3
}
run_in_container /usr/local/bin/ocx --version \
    >> "${service_log_file}" 2>&1
run_in_container "${managed_codex_executable}" --version \
    >> "${service_log_file}" 2>&1

read_opencodex_ready_record() {
    run_in_container /usr/local/bin/ocx ready --json 2>/dev/null || true
}

json_reports_true() {
    local json_record="$1"
    local field_name="$2"

    grep -Eq \
        "\"${field_name}\"[[:space:]]*:[[:space:]]*true" \
        <<< "${json_record}"
}

read_json_integer() {
    local json_record="$1"
    local field_name="$2"

    sed -n \
        "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        <<< "${json_record}" | head -n 1
}

ready_record="$(read_opencodex_ready_record)"
if json_reports_true "${ready_record}" ready; then
    opencodex_process_id="$(read_json_integer "${ready_record}" pid)"
    opencodex_port="$(read_json_integer "${ready_record}" port)"
    instance_process_belongs_to_job "${opencodex_process_id}" || {
        printf 'OpenCodex PID %s is outside Slurm Job %s.\n' \
            "${opencodex_process_id:-unknown}" "${job_id}" >&2
        exit 4
    }
else
    write_service_state "STARTING_OPENCODEX"
    run_in_container /usr/local/bin/ocx start \
        > "${opencodex_log_file}" 2>&1 &
    opencodex_launcher_process_id=$!

    startup_deadline=$((SECONDS + startup_timeout_seconds))
    while ((SECONDS < startup_deadline)); do
        if ! kill -0 "${opencodex_launcher_process_id}" 2>/dev/null; then
            printf 'OpenCodex exited before becoming ready. Log: %s\n' \
                "${opencodex_log_file}" >&2
            exit 4
        fi
        ready_record="$(read_opencodex_ready_record)"
        if json_reports_true "${ready_record}" ready; then
            break
        fi
        sleep 1
    done
    json_reports_true "${ready_record}" ready || {
        printf 'OpenCodex did not become ready within %s seconds. Log: %s\n' \
            "${startup_timeout_seconds}" "${opencodex_log_file}" >&2
        exit 4
    }
    opencodex_process_id="$(read_json_integer "${ready_record}" pid)"
    opencodex_port="$(read_json_integer "${ready_record}" port)"
fi

[[ "${opencodex_port}" =~ ^[0-9]+$ ]] || {
    printf 'OpenCodex returned an invalid port: %s\n' \
        "${opencodex_port:-unset}" >&2
    exit 4
}
instance_process_belongs_to_job "${opencodex_process_id}" || {
    printf 'OpenCodex PID %s is outside Slurm Job %s.\n' \
        "${opencodex_process_id:-unknown}" "${job_id}" >&2
    exit 4
}
opencodex_process_cgroup="$(
    instance_process_cgroup_record "${opencodex_process_id}"
)"
process_belongs_to_job "${opencodex_launcher_process_id}" || {
    printf 'OpenCodex launcher is outside Slurm Job %s. Log: %s\n' \
        "${job_id}" "${opencodex_log_file}" >&2
    exit 4
}

write_service_state "STARTING_CODEX_APP_SERVER"
rm -f "${app_server_restart_marker}"
run_in_container /bin/bash -c '
        set -Eeuo pipefail
        managed_codex="$1"
        restart_marker="$2"
        if [[ ! -s "${CODEX_HOME}/app-server-daemon/settings.json" ]]; then
            "${managed_codex}" app-server daemon bootstrap --remote-control
        fi
        "${managed_codex}" app-server daemon restart
        temporary_restart_marker="${restart_marker}.tmp.$$"
        printf "READY\n" > "${temporary_restart_marker}"
        mv "${temporary_restart_marker}" "${restart_marker}"
        while "${managed_codex}" app-server daemon version |
                grep -Eq '\''"status"[[:space:]]*:[[:space:]]*"running"'\''; do
            sleep 5
        done
        exit 1
    ' -- "${managed_codex_executable}" "${app_server_restart_marker}" \
    >> "${service_log_file}" 2>&1 &
app_server_launcher_process_id=$!

app_server_pid_file="${persistent_codex_home}/app-server-daemon/app-server.pid"
app_server_updater_pid_file="${persistent_codex_home}/app-server-daemon/app-server-updater.pid"
app_server_control_socket="${persistent_codex_home}/app-server-control/app-server-control.sock"
for ((attempt_number = 1; attempt_number <= 60; attempt_number++)); do
    if ! kill -0 "${app_server_launcher_process_id}" 2>/dev/null; then
        printf 'Codex app-server launcher exited before becoming ready. Log: %s\n' \
            "${service_log_file}" >&2
        exit 5
    fi
    if [[ -s "${app_server_restart_marker}" &&
          -s "${app_server_pid_file}" &&
          -S "${app_server_control_socket}" ]]; then
        app_server_process_id="$(
            read_json_integer "$(head -n 1 "${app_server_pid_file}")" pid
        )"
        if instance_process_belongs_to_job "${app_server_process_id}"; then
            if [[ -s "${app_server_updater_pid_file}" ]]; then
                updater_process_candidate="$(
                    read_json_integer \
                        "$(head -n 1 "${app_server_updater_pid_file}")" pid
                )"
                if instance_process_belongs_to_job \
                    "${updater_process_candidate}"; then
                    app_server_updater_process_id="${updater_process_candidate}"
                fi
            fi
            app_server_status="running"
            break
        fi
    fi
    sleep 1
done
[[ "${app_server_status}" == "running" ]] || {
    printf 'Codex app server did not become ready inside Slurm Job %s. Log: %s\n' \
        "${job_id}" "${service_log_file}" >&2
    exit 5
}
process_belongs_to_job "${app_server_launcher_process_id}" || {
    printf 'Codex app-server launcher is outside Slurm Job %s. Log: %s\n' \
        "${job_id}" "${service_log_file}" >&2
    exit 5
}
app_server_process_cgroup="$(
    instance_process_cgroup_record "${app_server_process_id}"
)"
write_service_state "READY"
printf 'OPENCODEX_READY job=%s node=%s instance=%s port=%s proxy_pid=%s app_server_pid=%s\n' \
    "${job_id}" "$(hostname -s)" "${service_instance_name}" \
    "${opencodex_port}" "${opencodex_process_id}" \
    "${app_server_process_id}"

while process_belongs_to_job "${service_instance_process_id}" &&
      kill -0 "${service_instance_process_id}" 2>/dev/null &&
      process_belongs_to_job "${opencodex_launcher_process_id}" &&
      kill -0 "${opencodex_launcher_process_id}" 2>/dev/null &&
      process_belongs_to_job "${app_server_launcher_process_id}" &&
      kill -0 "${app_server_launcher_process_id}" 2>/dev/null; do
    sleep 5
done

if ! kill -0 "${service_instance_process_id}" 2>/dev/null; then
    printf 'Apptainer service instance stopped unexpectedly. Log: %s\n' \
        "${service_log_file}" >&2
    exit 6
fi
if ! kill -0 "${opencodex_launcher_process_id}" 2>/dev/null; then
    printf 'OpenCodex stopped unexpectedly. Log: %s\n' \
        "${opencodex_log_file}" >&2
    exit 6
fi
if ! kill -0 "${app_server_launcher_process_id}" 2>/dev/null; then
    printf 'Codex app-server launcher stopped unexpectedly. Log: %s\n' \
        "${service_log_file}" >&2
    exit 7
fi
printf 'Codex app server stopped unexpectedly. Log: %s\n' \
    "${service_log_file}" >&2
exit 7
