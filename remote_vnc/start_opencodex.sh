#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
environment_rootfs="${3:?environment rootfs is required}"
environment_home="${4:?environment home is required}"
environment_name="${5:?environment name is required}"
startup_timeout_seconds="${6:-600}"

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
opencodex_supervisor_script="${release_directory}/opencodex_supervisor.sh"
opencodex_supervisor_log_file="${service_directory}/supervisor.log"
opencodex_supervisor_state_file="${service_directory}/supervisor.env"
opencodex_supervisor_control_directory="${service_directory}/supervisor"
opencodex_supervisor_pid_file="${opencodex_supervisor_control_directory}/supervisor.pid"
opencodex_supervisor_poll_interval_seconds=2
opencodex_supervisor_initial_backoff_seconds=2
opencodex_supervisor_maximum_backoff_seconds=60
opencodex_supervisor_stable_runtime_seconds=60
opencodex_supervisor_probe_timeout_seconds=30
opencodex_supervisor_readiness_refresh_seconds=30
opencodex_supervisor_publish_timeout_seconds=60
# XDG_RUNTIME_DIR and the container /tmp bind both come from this path, so it
# has to resolve to the same location inside the instance. A node-local path
# does not: only its tmp subdirectory is bound, and the services see a
# runtime directory that is not there.
runtime_directory="${service_directory}/runtime"
environment_common_helpers="${release_directory}/environment_common.sh"
container_codex_home="${container_home}/.codex"
persistent_codex_home="${environment_home}/.codex"
codex_seed_standalone_directory="/opt/codex-home/packages/standalone"
container_codex_standalone_directory="${container_codex_home}/packages/standalone"
managed_codex_executable="${container_codex_standalone_directory}/current/bin/codex"
opencodex_npm_prefix="${container_home}/.local/share/remote-vnc/npm"
managed_opencodex_executable="${opencodex_npm_prefix}/bin/ocx"
opencodex_listen_port=10100
if [[ -r "${environment_home}/.opencodex/config.json" ]]; then
    configured_opencodex_port="$(
        sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            "${environment_home}/.opencodex/config.json" | head -n 1
    )"
    if [[ "${configured_opencodex_port}" =~ ^[1-9][0-9]*$ ]] &&
       (( configured_opencodex_port <= 65535 )); then
        opencodex_listen_port="${configured_opencodex_port}"
    fi
fi
container_command_path="${opencodex_npm_prefix}/bin:${container_codex_standalone_directory}/current/bin:${container_home}/.local/state/remote-vnc/ssh/${job_id}/bin:${container_home}/.local/bin:/usr/local/cuda/bin:/opt/matlab/R2025b/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${container_home}/.local/state/remote-vnc/ssh/${job_id}/custom-bin"
service_instance_name="remote-vnc-${current_user}-${job_id}"
service_instance_uri="instance://${service_instance_name}"
service_instance_pid_file="${service_directory}/instance.pid"
service_instance_process_id=""
service_instance_cgroup="unavailable"
service_instance_started=false
opencodex_process_id=""
opencodex_status="NOT_STARTED"
opencodex_process_cgroup="unavailable"
opencodex_port=""
opencodex_supervisor_launcher_process_id=""
opencodex_supervisor_process_id=""
opencodex_supervisor_status="NOT_STARTED"
opencodex_supervisor_process_cgroup="unavailable"
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
    "${environment_common_helpers}" "${opencodex_supervisor_script}"; do
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
[[ -x "${opencodex_supervisor_script}" ]] || {
    printf 'OpenCodex supervisor is not executable: %s\n' \
        "${opencodex_supervisor_script}" >&2
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

mkdir -p "${service_directory}" "${runtime_directory}" \
    "${opencodex_supervisor_control_directory}"
chmod 700 "${service_directory}" "${runtime_directory}" \
    "${opencodex_supervisor_control_directory}"
touch "${service_log_file}" "${opencodex_log_file}" \
    "${opencodex_supervisor_log_file}"
chmod 600 "${service_log_file}" "${opencodex_log_file}" \
    "${opencodex_supervisor_log_file}"

container_start_options=()
bh_env_append_runtime_options \
    container_start_options "${environment_home}" "${runtime_directory}" "" service
container_start_options+=(
    --env "OPENCODEX_HOME=${container_home}/.opencodex"
    --env "BH_ENV_NAME=${environment_name}"
    --env "BH_ENV_SERVICE_INSTANCE=${service_instance_name}"
    --env "npm_config_prefix=${opencodex_npm_prefix}"
    --env "PATH=${container_command_path}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_SCRIPT=${opencodex_supervisor_script}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_LOG=${opencodex_supervisor_log_file}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_STATE=${opencodex_supervisor_state_file}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_CONTROL=${opencodex_supervisor_control_directory}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_PID_FILE=${opencodex_supervisor_pid_file}"
    --env "BH_ENV_OPENCODEX_SUPERVISOR_STARTUP_TIMEOUT=${startup_timeout_seconds}"
    --env "BH_ENV_OPENCODEX_PORT=${opencodex_listen_port}"
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
    timeout 10 "${apptainer_executable}" "${instance_exec_options[@]}" \
        "${service_instance_uri}" /bin/bash -c '
        set -eu
        process_id="$1"
        expected_job_id="$2"
        kill -0 "${process_id}" 2>/dev/null
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

read_supervisor_state_value() {
    local requested_key="$1"

    [[ -s "${opencodex_supervisor_state_file}" ]] || return 1
    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${opencodex_supervisor_state_file}"
}

# Apptainer runs this environment through its fakeroot helper, and the faked
# daemon behind FAKEROOTKEY lives exactly as long as the apptainer session that
# started it. A process detached from that session keeps
# LD_PRELOAD=libfakeroot.so bound to a dead daemon and blocks forever in
# semop() the first time it needs one, which leaves no output at all. The
# supervisor therefore runs as the foreground process of its own session, like
# the Codex app-server launcher, and this script owns that session.
supervisor_session_is_running() {
    [[ "${opencodex_supervisor_launcher_process_id}" =~ ^[0-9]+$ ]] &&
        kill -0 "${opencodex_supervisor_launcher_process_id}" 2>/dev/null
}

start_opencodex_supervisor() {
    local publish_deadline
    local candidate_process_id

    supervisor_session_is_running && return 0
    [[ "${service_instance_started}" == "true" ]] || return 1

    rm -f "${opencodex_supervisor_state_file}" \
        "${opencodex_supervisor_pid_file}"
    "${apptainer_executable}" "${instance_exec_options[@]}" \
        "${service_instance_uri}" "${opencodex_supervisor_script}" \
        "${managed_opencodex_executable}" "${opencodex_log_file}" \
        "${opencodex_supervisor_log_file}" \
        "${opencodex_supervisor_control_directory}" \
        "${opencodex_supervisor_state_file}" \
        "${opencodex_supervisor_pid_file}" \
        "${startup_timeout_seconds}" \
        "${opencodex_supervisor_poll_interval_seconds}" \
        "${opencodex_supervisor_initial_backoff_seconds}" \
        "${opencodex_supervisor_maximum_backoff_seconds}" \
        "${opencodex_supervisor_stable_runtime_seconds}" \
        "${opencodex_supervisor_probe_timeout_seconds}" \
        "${opencodex_supervisor_readiness_refresh_seconds}" \
        </dev/null >> "${opencodex_supervisor_log_file}" 2>&1 &
    opencodex_supervisor_launcher_process_id=$!

    publish_deadline=$((
        SECONDS + opencodex_supervisor_publish_timeout_seconds
    ))
    while (( SECONDS < publish_deadline )); do
        candidate_process_id="$(
            read_supervisor_state_value SUPERVISOR_PID || true
        )"
        if [[ "${candidate_process_id}" =~ ^[0-9]+$ ]]; then
            opencodex_supervisor_process_id="${candidate_process_id}"
            opencodex_supervisor_status="starting"
            opencodex_supervisor_process_cgroup="$(
                instance_process_cgroup_record \
                    "${opencodex_supervisor_process_id}"
            )"
            return 0
        fi
        supervisor_session_is_running || break
        sleep 1
    done
    printf 'OpenCodex supervisor did not publish its state within %s seconds. Log: %s\n' \
        "${opencodex_supervisor_publish_timeout_seconds}" \
        "${opencodex_supervisor_log_file}" >&2
    return 1
}

wait_for_opencodex_supervisor() {
    local supervisor_deadline=$((SECONDS + startup_timeout_seconds))
    local candidate_process_id
    local candidate_port
    local candidate_status

    while (( SECONDS < supervisor_deadline )); do
        candidate_status="$(read_supervisor_state_value STATUS || true)"
        candidate_process_id="$(read_supervisor_state_value PID || true)"
        candidate_port="$(read_supervisor_state_value PORT || true)"
        if [[ "${candidate_status}" == "running" &&
              "${candidate_process_id}" =~ ^[0-9]+$ &&
              "${candidate_port}" =~ ^[0-9]+$ ]] &&
           instance_process_belongs_to_job "${candidate_process_id}"; then
            opencodex_process_id="${candidate_process_id}"
            opencodex_port="${candidate_port}"
            opencodex_status="running"
            opencodex_supervisor_status="running"
            return 0
        fi
        if ! supervisor_session_is_running; then
            printf 'OpenCodex supervisor exited before becoming ready. Log: %s\n' \
                "${opencodex_supervisor_log_file}" >&2
            return 1
        fi
        sleep 1
    done
    printf 'OpenCodex supervisor did not become ready within %s seconds. Log: %s\n' \
        "${startup_timeout_seconds}" "${opencodex_supervisor_log_file}" >&2
    return 1
}

stop_opencodex_supervisor() {
    local wait_deadline

    if supervisor_session_is_running; then
        kill -TERM "${opencodex_supervisor_launcher_process_id}" 2>/dev/null ||
            true
        wait_deadline=$((SECONDS + 45))
        while supervisor_session_is_running &&
              (( SECONDS < wait_deadline )); do
            sleep 1
        done
        if supervisor_session_is_running; then
            kill -KILL "${opencodex_supervisor_launcher_process_id}" \
                2>/dev/null || true
        fi
        wait "${opencodex_supervisor_launcher_process_id}" 2>/dev/null || true
    fi
    opencodex_supervisor_launcher_process_id=""

    if instance_process_belongs_to_job "${opencodex_process_id}"; then
        timeout 15 "${apptainer_executable}" "${instance_exec_options[@]}" \
            "${service_instance_uri}" "${managed_opencodex_executable}" stop \
            >> "${service_log_file}" 2>&1 || true
    fi
    opencodex_supervisor_status="stopped"
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
        printf 'OPENCODEX_STATUS=%s\n' "${opencodex_status}"
        printf 'OPENCODEX_PORT=%s\n' "${opencodex_port}"
        printf 'OPENCODEX_LOG=%s\n' "${opencodex_log_file}"
        printf 'OPENCODEX_CGROUP=%s\n' "${opencodex_process_cgroup}"
        printf 'OPENCODEX_SUPERVISOR_LAUNCHER_PID=%s\n' \
            "${opencodex_supervisor_launcher_process_id}"
        printf 'OPENCODEX_SUPERVISOR_PID=%s\n' \
            "${opencodex_supervisor_process_id}"
        printf 'OPENCODEX_SUPERVISOR_STATUS=%s\n' \
            "${opencodex_supervisor_status}"
        printf 'OPENCODEX_SUPERVISOR_LOG=%s\n' \
            "${opencodex_supervisor_log_file}"
        printf 'OPENCODEX_SUPERVISOR_STATE=%s\n' \
            "${opencodex_supervisor_state_file}"
        printf 'OPENCODEX_SUPERVISOR_CGROUP=%s\n' \
            "${opencodex_supervisor_process_cgroup}"
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
    stop_opencodex_supervisor || true
    if instance_process_belongs_to_job "${app_server_process_id}"; then
        timeout 15 \
            "${apptainer_executable}" "${instance_exec_options[@]}" \
            "${service_instance_uri}" \
            "${managed_codex_executable}" app-server daemon stop \
            >> "${service_log_file}" 2>&1 || true
    fi
    for launcher_process_id in "${app_server_launcher_process_id}"; do
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

# The rootfs is mounted read-only. Both tools update in the persistent home.
# Bound the complete preflight independently of the service readiness timeout.
write_service_state "UPDATING_AI_TOOLS"
printf 'Checking OpenCodex and Codex updates before starting services.\n'
timeout 900 "${apptainer_executable}" "${instance_exec_options[@]}" \
    "${service_instance_uri}" "${release_directory}/update_ai_tools.sh" \
    "${managed_codex_executable}" >> "${service_log_file}" 2>&1 || {
    printf 'AI tool update preflight failed. Log: %s\n' "${service_log_file}" >&2
    exit 3
}

write_container_wrapper() {
    local destination_file="$1"
    local container_command="$2"
    local command_name="$(basename "${destination_file}")"
    local temporary_wrapper_file="${destination_file}.tmp.$$"
    local container_wrapper="${container_home}/.local/bin/${command_name}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'if [[ "${BH_ENV_SERVICE_INSTANCE:-}" == %q ]]; then\n' \
            "${service_instance_name}"
        if [[ "${command_name}" == "ocx" ]]; then
            printf '    exec %q %q %q %q "$@"\n' \
                "${release_directory}/opencodex_command.sh" \
                "${container_command}" "${managed_codex_executable}" \
                "${opencodex_log_file}"
        else
            printf '    if [[ "${1:-}" == update && $# == 1 ]]; then\n'
            printf '        exec %q %q codex\n' \
                "${release_directory}/update_ai_tools.sh" "${managed_codex_executable}"
            printf '    fi\n'
            printf '    exec %q "$@"\n' "${container_command}"
        fi
        printf 'fi\n'
        # Normal Codex terminal work stays in the caller's working directory.
        # Daemon management must enter the same PID namespace as the daemon.
        if [[ "${command_name}" == "codex" ]]; then
            printf 'if [[ "${BH_ENV_ACTIVE:-}" == 1 && "${1:-}" != update && "${1:-} ${2:-}" != "app-server daemon" ]]; then\n'
            printf '    exec %q "$@"\n' "${container_command}"
            printf 'fi\n'
        fi
        printf 'if [[ "${BH_ENV_ACTIVE:-}" == 1 ]]; then\n'
        printf '    printf -v host_command "%%q " %q "$@"\n' "${destination_file}"
        printf '    exec %q "${host_command%% }"\n' \
            "${container_home}/.local/bin/bluehive-host-shell"
        printf 'fi\n'
        printf 'exec %q' "${apptainer_executable}"
        for wrapper_option in "${instance_exec_options[@]}"; do
            printf ' %q' "${wrapper_option}"
        done
        printf ' %q %q "$@"\n' "${service_instance_uri}" "${container_wrapper}"
    } > "${temporary_wrapper_file}"
    chmod 700 "${temporary_wrapper_file}"
    mv "${temporary_wrapper_file}" "${destination_file}"
}

write_container_wrapper "${environment_home}/.local/bin/codex" \
    "${managed_codex_executable}"
write_container_wrapper "${environment_home}/.local/bin/ocx" \
    "${managed_opencodex_executable}"

write_service_state "CHECKING_COMMANDS"
run_in_container /bin/bash -c '
    set -Eeuo pipefail
    for command_name in node npm ocx codex jq flock timeout; do
        command -v "${command_name}" >/dev/null
    done
    [[ "$(command -v codex)" == "$1" ]]
' -- "${managed_codex_executable}" >> "${service_log_file}" 2>&1 || {
    printf 'OpenCodex or Codex is unavailable in the mutable environment.\n' >&2
    exit 3
}
run_in_container "${managed_opencodex_executable}" --version \
    >> "${service_log_file}" 2>&1
run_in_container "${managed_codex_executable}" --version \
    >> "${service_log_file}" 2>&1

read_json_integer() {
    local json_record="$1"
    local field_name="$2"

    sed -n \
        "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        <<< "${json_record}" | head -n 1
}

write_service_state "STARTING_OPENCODEX_SUPERVISOR"
start_opencodex_supervisor || {
    printf 'OpenCodex supervisor failed to start. Log: %s\n' \
        "${opencodex_supervisor_log_file}" >&2
    exit 4
}
wait_for_opencodex_supervisor || {
    printf 'OpenCodex supervisor did not start OpenCodex. Log: %s\n' \
        "${opencodex_supervisor_log_file}" >&2
    exit 4
}

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
opencodex_status="running"

app_server_pid_file="${persistent_codex_home}/app-server-daemon/app-server.pid"
app_server_updater_pid_file="${persistent_codex_home}/app-server-daemon/app-server-updater.pid"
app_server_control_socket="${persistent_codex_home}/app-server-control/app-server-control.sock"
app_server_startup_timeout_seconds=240

write_service_state "STARTING_CODEX_APP_SERVER"
# The control socket and the daemon's PID records live in the persistent
# environment home, but every process they name belonged to a container that
# died with its allocation. A leftover socket makes bind() report "control
# socket is already in use", and a leftover PID record makes `daemon restart`
# fail with "failed to read start time for pid-managed app server". This
# instance is new and the launcher runs one managed VNC job at a time, so any
# record still present predates this allocation.
for stale_daemon_record in \
    "${app_server_control_socket}" "${app_server_pid_file}" \
    "${app_server_updater_pid_file}"; do
    [[ -e "${stale_daemon_record}" ]] || continue
    printf '%s Removing app-server state left by an earlier allocation: %s\n' \
        "$(date --iso-8601=seconds)" "${stale_daemon_record}" \
        >> "${service_log_file}"
    rm -f "${stale_daemon_record}"
done
rm -f "${app_server_restart_marker}"
run_in_container /bin/bash -c '
        set -Eeuo pipefail
        managed_codex="$1"
        restart_marker="$2"
        startup_timeout="$3"
        # The managed daemon detaches by design, so it cannot hold an apptainer
        # session open the way the OpenCodex supervisor does. Drop the fakeroot
        # preload for it: this instance already maps the user to root, while a
        # detached process that keeps libfakeroot bound to the dead faked
        # daemon of a finished session blocks in semop() before it can create
        # the control socket.
        unset LD_PRELOAD FAKEROOTKEY FAKED_MODE FAKEROOTDONTTRYCHOWN
        if [[ ! -s "${CODEX_HOME}/app-server-daemon/settings.json" ]]; then
            "${managed_codex}" app-server daemon bootstrap --remote-control
        fi
        # The app server opens its SQLite state on shared storage before it
        # binds the control socket, and that first open can outlast the daemon
        # command own readiness wait. Retry inside this window rather than
        # failing the allocation: restart also retires a half-started server,
        # so the socket is not left reported as in use.
        restart_deadline=$((SECONDS + startup_timeout))
        until "${managed_codex}" app-server daemon restart; do
            (( SECONDS < restart_deadline )) || exit 1
            sleep 5
        done
        temporary_restart_marker="${restart_marker}.tmp.$$"
        printf "READY\n" > "${temporary_restart_marker}"
        mv "${temporary_restart_marker}" "${restart_marker}"
    ' -- "${managed_codex_executable}" "${app_server_restart_marker}" \
        "${app_server_startup_timeout_seconds}" \
    >> "${service_log_file}" 2>&1 &
app_server_launcher_process_id=$!

for ((attempt_number = 1;
      attempt_number <= app_server_startup_timeout_seconds + 120;
      attempt_number++)); do
    if [[ ! -s "${app_server_restart_marker}" ]] &&
       ! kill -0 "${app_server_launcher_process_id}" 2>/dev/null; then
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
wait "${app_server_launcher_process_id}"
app_server_launcher_process_id=""
app_server_process_cgroup="$(
    instance_process_cgroup_record "${app_server_process_id}"
)"
write_service_state "READY"
printf 'OPENCODEX_READY job=%s node=%s instance=%s port=%s proxy_pid=%s app_server_pid=%s\n' \
    "${job_id}" "$(hostname -s)" "${service_instance_name}" \
    "${opencodex_port}" "${opencodex_process_id}" \
    "${app_server_process_id}"

# The instance belongs to the allocation. AI processes may stay stopped for as
# long as maintenance requires; observe them without ending the instance/job.
while process_belongs_to_job "${service_instance_process_id}" &&
      kill -0 "${service_instance_process_id}" 2>/dev/null; do
    sleep 5
    previous_service_record="${opencodex_supervisor_status}|${opencodex_supervisor_process_id}|${opencodex_status}|${opencodex_process_id}|${app_server_status}|${app_server_process_id}"

    if ! supervisor_session_is_running; then
        printf '%s OpenCodex supervisor stopped; restarting it inside the service instance.\n' \
            "$(date --iso-8601=seconds)" >> "${service_log_file}"
        if [[ "${opencodex_supervisor_launcher_process_id}" =~ ^[0-9]+$ ]]; then
            wait "${opencodex_supervisor_launcher_process_id}" 2>/dev/null ||
                true
            opencodex_supervisor_launcher_process_id=""
        fi
        if start_opencodex_supervisor; then
            opencodex_supervisor_status="starting"
        else
            opencodex_supervisor_process_id=""
            opencodex_supervisor_status="stopped"
            opencodex_supervisor_process_cgroup="unavailable"
        fi
    fi

    supervisor_state_status="$(read_supervisor_state_value STATUS || true)"
    supervisor_state_pid="$(read_supervisor_state_value SUPERVISOR_PID || true)"
    if supervisor_session_is_running &&
       [[ "${supervisor_state_pid}" =~ ^[0-9]+$ &&
          "${supervisor_state_pid}" != "${opencodex_supervisor_process_id}" ]]; then
        opencodex_supervisor_process_id="${supervisor_state_pid}"
        opencodex_supervisor_process_cgroup="$(
            instance_process_cgroup_record "${opencodex_supervisor_process_id}"
        )"
    fi
    if supervisor_session_is_running; then
        opencodex_supervisor_status="${supervisor_state_status:-starting}"
    else
        opencodex_supervisor_status="stopped"
    fi

    candidate_opencodex_process_id="$(read_supervisor_state_value PID || true)"
    candidate_opencodex_port="$(read_supervisor_state_value PORT || true)"
    opencodex_status="stopped"
    if [[ "${opencodex_supervisor_status}" == "running" &&
          "${candidate_opencodex_process_id}" =~ ^[0-9]+$ &&
          "${candidate_opencodex_port}" =~ ^[0-9]+$ ]] &&
       instance_process_belongs_to_job "${candidate_opencodex_process_id}"; then
        opencodex_process_id="${candidate_opencodex_process_id}"
        opencodex_port="${candidate_opencodex_port}"
        opencodex_status="running"
    else
        opencodex_process_id=""
        opencodex_port=""
    fi

    app_server_process_id="$(
        read_json_integer "$(head -n 1 "${app_server_pid_file}" 2>/dev/null || true)" pid
    )"
    app_server_status="stopped"
    if instance_process_belongs_to_job "${app_server_process_id}"; then
        app_server_status="running"
    else
        app_server_process_id=""
    fi
    current_service_record="${opencodex_supervisor_status}|${opencodex_supervisor_process_id}|${opencodex_status}|${opencodex_process_id}|${app_server_status}|${app_server_process_id}"
    if [[ "${current_service_record}" != "${previous_service_record}" ]]; then
        opencodex_process_cgroup="$(instance_process_cgroup_record "${opencodex_process_id}")"
        app_server_process_cgroup="$(instance_process_cgroup_record "${app_server_process_id}")"
        printf '%s AI services: OpenCodex supervisor=%s PID=%s; OpenCodex=%s PID=%s port=%s; Codex daemon=%s PID=%s. VNC job remains running.\n' \
            "$(date --iso-8601=seconds)" "${opencodex_supervisor_status}" \
            "${opencodex_supervisor_process_id:-none}" "${opencodex_status}" \
            "${opencodex_process_id:-none}" "${opencodex_port:-none}" \
            "${app_server_status}" "${app_server_process_id:-none}" >> "${service_log_file}"
        write_service_state "READY"
    fi
done

printf 'Apptainer service instance stopped unexpectedly. Log: %s\n' \
    "${service_log_file}" >&2
exit 6
