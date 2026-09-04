#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

print_usage() {
    cat <<'EOF'
Usage: bh-env [--env NAME] COMMAND [arguments]

Commands:
  shell                       Open an interactive Fish shell in the environment
  exec -- COMMAND [ARG ...]   Run one command in the environment
  admin [-- COMMAND ...]      Open a writable fakeroot shell or run a command
  sbatch SCRIPT [ARG ...]     Submit a Bash script inside the environment
  status                      Show the current generation and installed versions
  list                        List available environments
  checkpoint [LABEL]          Save the current rootfs as a SIF checkpoint
  restore CHECKPOINT          Restore a checkpoint as a new generation
  rebuild                     Build and select a clean generation

Examples:
  bh-env shell
  bh-env exec -- python --version
  bh-env admin -- apt-get install -y ffmpeg
  bh-env sbatch analysis.sh
EOF
}

fail() {
    printf '[bh-env] Error: %s\n' "$*" >&2
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ||
      "${1:-}" == "help" ]]; then
    print_usage
    exit 0
fi

config_file="${BH_ENV_CONFIG:-}"
if [[ "${1:-}" == "--config" ]]; then
    [[ -n "${2:-}" ]] || fail "--config requires a path"
    config_file="$2"
    shift 2
fi
if [[ -z "${config_file}" ]]; then
    config_file="${XDG_CONFIG_HOME:-${HOME}/.config}/bh-env/config.env"
fi
[[ -r "${config_file}" ]] || fail "configuration is missing: ${config_file}"
# shellcheck disable=SC1090
source "${config_file}"

: "${BH_ENV_RELEASE_DIRECTORY:?missing BH_ENV_RELEASE_DIRECTORY}"
: "${BH_ENV_USER_SERVICE_DIRECTORY:?missing BH_ENV_USER_SERVICE_DIRECTORY}"
: "${BH_ENV_DEFAULT_NAME:=default}"
: "${BH_ENV_BASE_IMAGE:?missing BH_ENV_BASE_IMAGE}"
: "${BH_ENV_BUILD_TIMEOUT_SECONDS:=10800}"

common_helpers="${BH_ENV_RELEASE_DIRECTORY}/environment_common.sh"
prepare_environment_script="${BH_ENV_RELEASE_DIRECTORY}/prepare_environment.sh"
[[ -r "${common_helpers}" ]] || fail "helper is missing: ${common_helpers}"
# shellcheck disable=SC1090
source "${common_helpers}"

environment_name="${BH_ENV_DEFAULT_NAME}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            [[ -n "${2:-}" && "${2:-}" != -* ]] ||
                fail "--env requires a name"
            environment_name="$2"
            shift 2
            ;;
        --env=*)
            environment_name="${1#*=}"
            [[ -n "${environment_name}" ]] || fail "--env requires a name"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done
bh_env_validate_name "${environment_name}" ||
    fail "invalid environment name: ${environment_name}"

command_name="${1:-shell}"
[[ $# -eq 0 ]] || shift
environment_directory="$(
    bh_env_environment_directory \
        "${BH_ENV_USER_SERVICE_DIRECTORY}" "${environment_name}"
)"
persistent_home="${environment_directory}/home"
checkpoint_directory="${environment_directory}/checkpoints"
runtime_root="${SLURM_TMPDIR:-/tmp}/bh-env-$(id -un)-${SLURM_JOB_ID:-outside}-${environment_name}"
base_image_state_file="${BH_ENV_USER_SERVICE_DIRECTORY}/state/base-image-path"
if [[ -s "${base_image_state_file}" ]]; then
    current_base_image="$(head -n 1 "${base_image_state_file}")"
else
    current_base_image="${BH_ENV_BASE_IMAGE}"
fi

read_current_generation() {
    bh_env_read_current_generation "${environment_directory}" ||
        fail "environment '${environment_name}' is not ready; start remote_vnc.sh --env ${environment_name}"
}

validate_generation() {
    local generation_directory="$1"
    local rootfs_path="${generation_directory}/rootfs"

    [[ -d "${rootfs_path}" && -s "${generation_directory}/metadata.env" ]] ||
        return 1
    apptainer exec --cleanenv "${rootfs_path}" /bin/bash -c '
        set -eu
        export PATH="/usr/local/cuda/bin:/opt/matlab/R2025b/bin:${PATH}"
        test -s /etc/bh-env/build-manifest.env
        grep -Fxq "MATLAB_RELEASE=R2025b" /etc/bh-env/build-manifest.env
        for command_name in fish gcc g++ node npm ocx codex uv pixi nvcc \
            google-chrome-stable \
            chatgpt matlab mpm vncserver; do
            command -v "${command_name}" >/dev/null
        done
        test -x /opt/matlab/R2025b/bin/matlab
    ' >/dev/null 2>&1
}

append_working_directory() {
    local options_array_name="$1"
    local mapped_working_directory
    local -n requested_options="${options_array_name}"

    mapped_working_directory="$(bh_env_map_host_path "${PWD}" "${HOME}")"
    requested_options+=(--pwd "${mapped_working_directory}")
}

run_in_environment() {
    local access_mode="$1"
    shift
    local generation_directory
    local rootfs_path
    local -a apptainer_options

    bh_env_require_slurm_allocation || exit 2
    bh_env_load_apptainer || fail "Apptainer 1.4.1 could not be loaded"
    if [[ "${access_mode}" == "admin" ]]; then
        [[ -d "${environment_directory}" ]] ||
            fail "environment '${environment_name}' is not ready"
        exec 9> "${environment_directory}/mutation.lock"
        flock -w "${BH_ENV_BUILD_TIMEOUT_SECONDS}" 9 ||
            fail "timed out waiting for the environment mutation lock"
    fi
    generation_directory="$(read_current_generation)"
    rootfs_path="${generation_directory}/rootfs"
    validate_generation "${generation_directory}" ||
        fail "current generation failed validation: ${generation_directory}"
    mkdir -p "${persistent_home}" "${runtime_root}"
    chmod 700 "${persistent_home}" "${runtime_root}"
    bh_env_append_runtime_options \
        apptainer_options "${persistent_home}" "${runtime_root}" \
        "${DISPLAY:-}" "${access_mode}"
    apptainer_options+=(
        --env "BH_ENV_NAME=${environment_name}"
        --env "BH_ENV_GENERATION=$(basename "${generation_directory}")"
    )
    append_working_directory apptainer_options
    exec apptainer "${apptainer_options[@]}" "${rootfs_path}" "$@"
}

show_status() {
    local generation_directory
    local rootfs_path

    printf 'Environment: %s\n' "${environment_name}"
    printf 'Directory: %s\n' "${environment_directory}"
    if ! generation_directory="$(
        bh_env_read_current_generation "${environment_directory}" 2>/dev/null
    )"; then
        printf 'Status: not built\n'
        return 1
    fi
    rootfs_path="${generation_directory}/rootfs"
    printf 'Status: ready\n'
    printf 'Generation: %s\n' "$(basename "${generation_directory}")"
    printf 'Rootfs: %s\n' "${rootfs_path}"
    printf 'Home: %s\n' "${persistent_home}"
    printf 'Metadata:\n'
    sed 's/^/  /' "${generation_directory}/metadata.env"
    if [[ -s "${rootfs_path}/etc/bh-env/build-manifest.env" ]]; then
        printf 'Installed software:\n'
        sed 's/^/  /' "${rootfs_path}/etc/bh-env/build-manifest.env"
    fi
}

list_environments() {
    local environments_root="${BH_ENV_USER_SERVICE_DIRECTORY}/environments"
    local environment_path
    local generation_directory

    [[ -d "${environments_root}" ]] || return 0
    while IFS= read -r environment_path; do
        [[ -d "${environment_path}" ]] || continue
        if generation_directory="$(
            bh_env_read_current_generation "${environment_path}" 2>/dev/null
        )"; then
            printf '%s\t%s\n' "$(basename "${environment_path}")" \
                "$(basename "${generation_directory}")"
        else
            printf '%s\tnot-ready\n' "$(basename "${environment_path}")"
        fi
    done < <(find "${environments_root}" -mindepth 1 -maxdepth 1 -type d | sort)
}

create_checkpoint() {
    local checkpoint_label="${1:-manual}"
    local generation_directory
    local checkpoint_name
    local checkpoint_path
    local temporary_checkpoint
    local checksum_file
    local temporary_checksum
    local checkpoint_checksum
    local operation_tmp_directory

    [[ "${checkpoint_label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        fail "invalid checkpoint label: ${checkpoint_label}"
    bh_env_require_slurm_allocation || exit 2
    bh_env_load_apptainer || fail "Apptainer 1.4.1 could not be loaded"
    mkdir -p "${checkpoint_directory}"
    chmod 700 "${checkpoint_directory}"
    exec 9> "${environment_directory}/mutation.lock"
    flock -w "${BH_ENV_BUILD_TIMEOUT_SECONDS}" 9 ||
        fail "timed out waiting for the environment mutation lock"
    generation_directory="$(read_current_generation)"
    checkpoint_name="$(date -u '+%Y%m%dT%H%M%SZ')-${checkpoint_label}"
    checkpoint_path="${checkpoint_directory}/${checkpoint_name}.sif"
    temporary_checkpoint="${checkpoint_path}.tmp.$$"
    checksum_file="${checkpoint_path}.sha256"
    temporary_checksum="${checksum_file}.tmp.$$"
    operation_tmp_directory="${environment_directory}/build/checkpoint-tmp-$$"
    mkdir -p "${operation_tmp_directory}" "${environment_directory}/cache"
    chmod 700 "${operation_tmp_directory}" "${environment_directory}/cache"
    export APPTAINER_TMPDIR="${operation_tmp_directory}"
    export APPTAINER_CACHEDIR="${environment_directory}/cache"
    [[ ! -e "${checkpoint_path}" ]] ||
        fail "checkpoint already exists: ${checkpoint_path}"

    cleanup_temporary_checkpoint() {
        local exit_status=$?

        trap - EXIT INT TERM
        rm -f -- "${temporary_checkpoint}" "${temporary_checksum}"
        case "${operation_tmp_directory}" in
            "${environment_directory}/build/checkpoint-tmp-"*)
                rm -rf -- "${operation_tmp_directory}"
                ;;
        esac
        exit "${exit_status}"
    }
    trap cleanup_temporary_checkpoint EXIT INT TERM

    printf '[bh-env] Creating checkpoint %s.\n' "${checkpoint_path}" >&2
    timeout "${BH_ENV_BUILD_TIMEOUT_SECONDS}" \
        apptainer build --fakeroot "${temporary_checkpoint}" \
            "${generation_directory}/rootfs"
    checkpoint_checksum="$(
        sha256sum "${temporary_checkpoint}" | awk '{ print $1; exit }'
    )"
    printf '%s  %s\n' "${checkpoint_checksum}" \
        "$(basename "${checkpoint_path}")" > "${temporary_checksum}"
    chmod 400 "${temporary_checkpoint}" "${temporary_checksum}"
    mv "${temporary_checkpoint}" "${checkpoint_path}"
    mv "${temporary_checksum}" "${checksum_file}"
    trap - EXIT INT TERM
    rm -rf -- "${operation_tmp_directory}"
    printf '%s\n' "${checkpoint_path}"
}

restore_checkpoint() {
    local checkpoint_argument="${1:-}"
    local checkpoint_path
    local checkpoint_checksum_file
    local canonical_checkpoint_directory
    local recorded_checksum
    local recorded_filename
    local actual_checksum
    local generation_id
    local incoming_generation
    local final_generation
    local temporary_current_link
    local lock_file="${environment_directory}/mutation.lock"
    local operation_tmp_directory

    [[ -n "${checkpoint_argument}" ]] || fail "restore requires a checkpoint"
    bh_env_require_slurm_allocation || exit 2
    bh_env_load_apptainer || fail "Apptainer 1.4.1 could not be loaded"
    canonical_checkpoint_directory="$(readlink -f "${checkpoint_directory}")" ||
        fail "checkpoint directory is unavailable: ${checkpoint_directory}"
    if [[ "${checkpoint_argument}" == /* ]]; then
        checkpoint_path="$(readlink -f "${checkpoint_argument}")" ||
            fail "checkpoint is unavailable: ${checkpoint_argument}"
    else
        checkpoint_path="${checkpoint_directory}/${checkpoint_argument}"
        [[ "${checkpoint_path}" == *.sif ]] || checkpoint_path+=".sif"
        checkpoint_path="$(readlink -f "${checkpoint_path}")" ||
            fail "checkpoint is unavailable: ${checkpoint_argument}"
    fi
    case "${checkpoint_path}" in
        "${canonical_checkpoint_directory}/"*) ;;
        *) fail "checkpoint must be under ${checkpoint_directory}" ;;
    esac
    checkpoint_checksum_file="${checkpoint_path}.sha256"
    [[ -r "${checkpoint_path}" && -r "${checkpoint_checksum_file}" ]] ||
        fail "checkpoint or checksum is missing: ${checkpoint_path}"
    read -r recorded_checksum recorded_filename < "${checkpoint_checksum_file}"
    [[ "${recorded_checksum}" =~ ^[0-9a-f]{64}$ ]] ||
        fail "checkpoint checksum file is invalid"
    [[ "${recorded_filename}" == "$(basename "${checkpoint_path}")" ]] ||
        fail "checkpoint checksum filename does not match"
    actual_checksum="$(sha256sum "${checkpoint_path}" | awk '{ print $1; exit }')"
    [[ "${actual_checksum}" == "${recorded_checksum}" ]] ||
        fail "checkpoint checksum validation failed"

    mkdir -p "${environment_directory}/generations" "${persistent_home}"
    exec 9> "${lock_file}"
    flock -w "${BH_ENV_BUILD_TIMEOUT_SECONDS}" 9 ||
        fail "timed out waiting for ${lock_file}"
    generation_id="$(date -u '+%Y%m%dT%H%M%SZ')-${SLURM_JOB_ID}-restore-${actual_checksum:0:12}"
    incoming_generation="${environment_directory}/generations/.incoming-${generation_id}-$$"
    final_generation="${environment_directory}/generations/${generation_id}"
    operation_tmp_directory="${environment_directory}/build/restore-tmp-$$"
    mkdir -p \
        "${incoming_generation}" "${operation_tmp_directory}" \
        "${environment_directory}/cache"
    chmod 700 "${operation_tmp_directory}" "${environment_directory}/cache"
    export APPTAINER_TMPDIR="${operation_tmp_directory}"
    export APPTAINER_CACHEDIR="${environment_directory}/cache"
    cleanup_restored_generation() {
        local exit_status=$?

        trap - EXIT INT TERM
        case "${incoming_generation}" in
            "${environment_directory}/generations/.incoming-"*)
                if [[ -d "${incoming_generation}" ]]; then
                    find "${incoming_generation}" -type d -exec chmod u+rwx {} + \
                        2>/dev/null || true
                    rm -rf -- "${incoming_generation}"
                fi
                ;;
        esac
        case "${operation_tmp_directory}" in
            "${environment_directory}/build/restore-tmp-"*)
                rm -rf -- "${operation_tmp_directory}"
                ;;
        esac
        exit "${exit_status}"
    }
    trap cleanup_restored_generation EXIT INT TERM
    timeout "${BH_ENV_BUILD_TIMEOUT_SECONDS}" \
        apptainer build --sandbox --fakeroot \
            "${incoming_generation}/rootfs" "${checkpoint_path}"
    {
        printf 'SCHEMA_VERSION=1\n'
        printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
        printf 'GENERATION=%s\n' "${generation_id}"
        printf 'RESTORED_FROM=%s\n' "${checkpoint_path}"
        printf 'CHECKPOINT_SHA256=%s\n' "${actual_checksum}"
        printf 'CREATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'SLURM_JOB_ID=%s\n' "${SLURM_JOB_ID}"
    } > "${incoming_generation}/metadata.env"
    validate_generation "${incoming_generation}" || {
        printf 'Restored generation failed validation: %s\n' \
            "${incoming_generation}" >&2
        exit 4
    }
    mv "${incoming_generation}" "${final_generation}"
    temporary_current_link="${environment_directory}/.current.$$"
    ln -s "generations/${generation_id}" "${temporary_current_link}"
    mv -Tf "${temporary_current_link}" "${environment_directory}/current"
    trap - EXIT INT TERM
    rm -rf -- "${operation_tmp_directory}"
    printf '%s\n' "${final_generation}"
}

rebuild_environment() {
    local status_file

    bh_env_require_slurm_allocation || exit 2
    [[ -x "${prepare_environment_script}" ]] ||
        fail "environment builder is missing: ${prepare_environment_script}"
    [[ -r "${current_base_image}" ]] ||
        fail "base image is unavailable: ${current_base_image}"
    mkdir -p "${environment_directory}"
    chmod 700 "${environment_directory}"
    exec 9> "${environment_directory}/mutation.lock"
    flock -w "${BH_ENV_BUILD_TIMEOUT_SECONDS}" 9 ||
        fail "timed out waiting for the environment mutation lock"
    status_file="${BH_ENV_USER_SERVICE_DIRECTORY}/state/jobs/${SLURM_JOB_ID}/environment-status"
    "${prepare_environment_script}" \
        "${BH_ENV_RELEASE_DIRECTORY}" \
        "${BH_ENV_USER_SERVICE_DIRECTORY}" \
        "${current_base_image}" \
        "${environment_name}" \
        "${status_file}" \
        "${BH_ENV_BUILD_TIMEOUT_SECONDS}" \
        true
}

submit_batch_script() {
    local source_script="${1:-}"
    local source_script_path
    local mapped_script_path
    local wrapper_directory
    local wrapper_file
    local sbatch_executable
    local argument

    [[ -n "${source_script}" ]] || fail "sbatch requires a Bash script"
    shift
    [[ -r "${source_script}" ]] || fail "batch script is unreadable: ${source_script}"
    source_script_path="$(readlink -f "${source_script}")"
    mapped_script_path="$(bh_env_map_host_path "${source_script_path}" "${HOME}")"
    read_current_generation >/dev/null

    sbatch_executable="$(bh_env_find_slurm_executable sbatch)" ||
        fail "sbatch is unavailable"

    wrapper_directory="${BH_ENV_USER_SERVICE_DIRECTORY}/state/sbatch"
    mkdir -p "${wrapper_directory}"
    chmod 700 "${wrapper_directory}"
    wrapper_file="${wrapper_directory}/$(date -u '+%Y%m%dT%H%M%SZ')-$$-$(basename "${source_script_path}")"
    {
        printf '#!/usr/bin/env bash\n'
        awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*#/ {
                if ($0 ~ /^[[:space:]]*#SBATCH([[:space:]]|$)/) { print }
                next
            }
            { exit }
        ' "${source_script_path}"
        printf '\nset -Eeuo pipefail\n'
        printf 'exec %q --env %q exec -- /bin/bash %q' \
            "${BH_ENV_USER_SERVICE_DIRECTORY}/bin/bh-env" \
            "${environment_name}" "${mapped_script_path}"
        for argument in "$@"; do
            printf ' %q' "${argument}"
        done
        printf '\n'
    } > "${wrapper_file}"
    chmod 700 "${wrapper_file}"
    "${sbatch_executable}" "${wrapper_file}"
}

case "${command_name}" in
    shell)
        [[ $# -eq 0 ]] || fail "shell does not accept arguments"
        run_in_environment normal /bin/sh -c '
            if [ -x /usr/bin/fish ]; then
                exec /usr/bin/fish -l
            fi
            exec /bin/bash -l
        '
        ;;
    exec)
        [[ "${1:-}" == "--" ]] && shift
        [[ $# -gt 0 ]] || fail "exec requires a command"
        run_in_environment normal "$@"
        ;;
    admin)
        [[ "${1:-}" == "--" ]] && shift
        if [[ $# -gt 0 ]]; then
            run_in_environment admin "$@"
        else
            run_in_environment admin /bin/sh -c '
                if [ -x /usr/bin/fish ]; then
                    exec /usr/bin/fish -l
                fi
                export PS1="(bh-env admin) \u@\h:\w\\$ "
                exec /bin/bash --noprofile --norc -i
            '
        fi
        ;;
    sbatch)
        submit_batch_script "$@"
        ;;
    status)
        [[ $# -eq 0 ]] || fail "status does not accept arguments"
        show_status
        ;;
    list)
        [[ $# -eq 0 ]] || fail "list does not accept arguments"
        list_environments
        ;;
    checkpoint)
        [[ $# -le 1 ]] || fail "checkpoint accepts at most one label"
        create_checkpoint "$@"
        ;;
    restore)
        [[ $# -eq 1 ]] || fail "restore requires one checkpoint"
        restore_checkpoint "$1"
        ;;
    rebuild)
        [[ $# -eq 0 ]] || fail "rebuild does not accept arguments"
        rebuild_environment
        ;;
    -h|--help|help)
        print_usage
        ;;
    *)
        fail "unknown command: ${command_name}"
        ;;
esac
