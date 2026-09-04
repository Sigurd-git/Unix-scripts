#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
base_image_path="${3:?base image path is required}"
environment_name="${4:?environment name is required}"
environment_status_file="${5:?environment status file is required}"
build_timeout_seconds="${6:-10800}"
force_rebuild="${7:-false}"

common_helpers="${release_directory}/environment_common.sh"
provision_script="${release_directory}/provision_environment.sh"
bundle_manifest="${release_directory}/bundle.sha256"

for required_file in \
    "${common_helpers}" "${provision_script}" "${bundle_manifest}" \
    "${release_directory}/environment-packages.txt" \
    "${release_directory}/matlab-products.txt"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required environment file is missing: %s\n' \
            "${required_file}" >&2
        exit 2
    }
done
# shellcheck disable=SC1090
source "${common_helpers}"

bh_env_validate_name "${environment_name}" || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 2
}
[[ "${build_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid environment build timeout: %s\n' \
        "${build_timeout_seconds}" >&2
    exit 2
}
[[ "${force_rebuild}" == "true" || "${force_rebuild}" == "false" ]] || {
    printf 'force rebuild must be true or false.\n' >&2
    exit 2
}
[[ -r "${base_image_path}" ]] || {
    printf 'Base VNC image is unavailable: %s\n' "${base_image_path}" >&2
    exit 2
}
for required_command in awk flock readlink sha256sum timeout; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        printf 'Required environment command is unavailable: %s\n' \
            "${required_command}" >&2
        exit 2
    }
done
bh_env_require_slurm_allocation
bh_env_load_apptainer || {
    printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
    exit 2
}

environment_directory="$(
    bh_env_environment_directory \
        "${user_service_directory}" "${environment_name}"
)"
generation_root="${environment_directory}/generations"
persistent_home="${environment_directory}/home"
checkpoint_directory="${environment_directory}/checkpoints"
cache_directory="${environment_directory}/cache"
build_root="${environment_directory}/build"
lock_file="${environment_directory}/build.lock"
bundle_digest="$(sha256sum "${bundle_manifest}" | awk '{ print $1; exit }')"
base_recipe_digest="$(
    awk 'NF && $1 ~ /^[0-9a-f]{64}$/ { print $1; exit }' \
        "${release_directory}/ubuntu-vnc-xfce-g3_24.04.sha256"
)"
recipe_digest="$(
    printf '%s\n%s\n' "${bundle_digest}" "${base_recipe_digest}" |
        sha256sum | awk '{ print $1; exit }'
)"
build_deadline=$((SECONDS + build_timeout_seconds))

mkdir -p \
    "$(dirname "${environment_status_file}")" \
    "${environment_directory}" "${generation_root}" "${persistent_home}" \
    "${checkpoint_directory}" "${cache_directory}" "${build_root}"
chmod 700 \
    "${environment_directory}" "${generation_root}" "${persistent_home}" \
    "${checkpoint_directory}" "${cache_directory}" "${build_root}" \
    "$(dirname "${environment_status_file}")"

write_environment_status() {
    local status_value="$1"
    local temporary_status_file="${environment_status_file}.tmp.$$"

    printf '%s\n' "${status_value}" > "${temporary_status_file}"
    mv "${temporary_status_file}" "${environment_status_file}"
}

generation_is_valid() {
    local generation_directory="$1"
    local rootfs_path="${generation_directory}/rootfs"

    [[ -d "${rootfs_path}" ]] || return 1
    [[ -s "${generation_directory}/metadata.env" ]] || return 1
    apptainer exec --cleanenv "${rootfs_path}" /bin/bash -c '
        set -eu
        export PATH="/usr/local/cuda/bin:/opt/matlab/R2024b/bin:${PATH}"
        test -s /etc/bh-env/build-manifest.env
        for command_name in gcc g++ gfortran git screen ssh node npm ocx codex \
            uv pixi nvcc \
            google-chrome-stable chatgpt matlab mpm vncserver xfce4-session; do
            command -v "${command_name}" >/dev/null
        done
        test -x /opt/matlab/R2024b/bin/matlab
    ' >/dev/null 2>&1
}

print_environment_record() {
    local generation_directory="$1"
    local preparation_result="$2"

    printf '%s|%s|%s|%s|%s\n' \
        "${generation_directory}/rootfs" \
        "${persistent_home}" \
        "$(basename "${generation_directory}")" \
        "${recipe_digest}" \
        "${preparation_result}"
}

write_environment_status "CHECKING_ENVIRONMENT"
current_generation="$(
    bh_env_read_current_generation "${environment_directory}" 2>/dev/null || true
)"
if [[ "${force_rebuild}" == "false" && -n "${current_generation}" ]] &&
   generation_is_valid "${current_generation}"; then
    current_recipe_digest="$(
        awk -F= '$1 == "RECIPE_DIGEST" { print $2; exit }' \
            "${current_generation}/metadata.env"
    )"
    if [[ "${current_recipe_digest}" == "${recipe_digest}" ]]; then
        preparation_result="existing"
    else
        preparation_result="existing:update-available"
    fi
    write_environment_status "ENVIRONMENT_READY:${preparation_result}"
    print_environment_record "${current_generation}" "${preparation_result}"
    exit 0
fi

exec 9> "${lock_file}"
remaining_seconds=$((build_deadline - SECONDS))
((remaining_seconds > 0)) || {
    printf 'The environment build deadline expired before locking.\n' >&2
    exit 3
}
if ! flock -w "${remaining_seconds}" 9; then
    printf 'Timed out waiting for the environment build lock: %s\n' \
        "${lock_file}" >&2
    exit 3
fi

current_generation="$(
    bh_env_read_current_generation "${environment_directory}" 2>/dev/null || true
)"
if [[ "${force_rebuild}" == "false" && -n "${current_generation}" ]] &&
   generation_is_valid "${current_generation}"; then
    write_environment_status "ENVIRONMENT_READY:existing"
    print_environment_record "${current_generation}" "existing"
    exit 0
fi

generation_id="$(date -u '+%Y%m%dT%H%M%SZ')-${SLURM_JOB_ID}-${recipe_digest:0:12}"
incoming_generation="${generation_root}/.incoming-${generation_id}-$$"
final_generation="${generation_root}/${generation_id}"
build_tmp_directory="${build_root}/tmp-${generation_id}"
container_tmp_directory="${build_root}/container-tmp-${generation_id}"
download_directory="${build_root}/downloads-${generation_id}"
incoming_rootfs="${incoming_generation}/rootfs"
build_log_file="${build_root}/${generation_id}.log"

[[ ! -e "${incoming_generation}" && ! -e "${final_generation}" ]] || {
    printf 'Environment generation path already exists: %s\n' \
        "${generation_id}" >&2
    exit 3
}
mkdir -p \
    "${incoming_generation}" "${build_tmp_directory}" \
    "${container_tmp_directory}" "${download_directory}"
chmod 700 \
    "${incoming_generation}" "${build_tmp_directory}" \
    "${download_directory}"
chmod 1777 "${container_tmp_directory}"

cleanup_incoming_generation() {
    local exit_status=$?

    trap - EXIT INT TERM
    case "${incoming_generation}" in
        "${generation_root}/.incoming-"*)
            if [[ -d "${incoming_generation}" ]]; then
                find "${incoming_generation}" -type d -exec chmod u+rwx {} + \
                    2>/dev/null || true
                rm -rf -- "${incoming_generation}"
            fi
            ;;
    esac
    case "${build_tmp_directory}" in
        "${build_root}/tmp-"*) rm -rf -- "${build_tmp_directory}" ;;
    esac
    case "${container_tmp_directory}" in
        "${build_root}/container-tmp-"*) rm -rf -- "${container_tmp_directory}" ;;
    esac
    case "${download_directory}" in
        "${build_root}/downloads-"*) rm -rf -- "${download_directory}" ;;
    esac
    exit "${exit_status}"
}
trap cleanup_incoming_generation EXIT INT TERM

export APPTAINER_CACHEDIR="${cache_directory}"
export APPTAINER_TMPDIR="${build_tmp_directory}"
write_environment_status "BUILDING_ENVIRONMENT"
printf '[bh-env] Building environment %s generation %s.\n' \
    "${environment_name}" "${generation_id}" >&2
remaining_seconds=$((build_deadline - SECONDS))
((remaining_seconds > 0)) || exit 3
timeout "${remaining_seconds}" \
    apptainer build --sandbox --fakeroot "${incoming_rootfs}" \
        "${base_image_path}" >> "${build_log_file}" 2>&1

# Writable sandboxes require bind destinations to exist before Apptainer
# assembles the container mount namespace.
mkdir -p \
    "${incoming_rootfs}/opt/bh-env-release" \
    "${incoming_rootfs}/var/tmp/bh-env-build" \
    "${incoming_rootfs}/host" \
    "${incoming_rootfs}/bluehive-home" \
    "${incoming_rootfs}/gpfs/fs1" \
    "${incoming_rootfs}/gpfs/fs2" \
    "${incoming_rootfs}/scratch"
chmod 755 \
    "${incoming_rootfs}/opt/bh-env-release" \
    "${incoming_rootfs}/var/tmp/bh-env-build" \
    "${incoming_rootfs}/host" \
    "${incoming_rootfs}/bluehive-home" \
    "${incoming_rootfs}/gpfs" \
    "${incoming_rootfs}/gpfs/fs1" \
    "${incoming_rootfs}/gpfs/fs2" \
    "${incoming_rootfs}/scratch"

write_environment_status "PROVISIONING_ENVIRONMENT"
remaining_seconds=$((build_deadline - SECONDS))
((remaining_seconds > 0)) || exit 3
timeout "${remaining_seconds}" \
    apptainer exec \
        --cleanenv \
        --no-home \
        --writable \
        --fakeroot \
        --bind "${release_directory}:/opt/bh-env-release:ro" \
        --bind "${download_directory}:/var/tmp/bh-env-build" \
        --bind "${container_tmp_directory}:/tmp" \
        --env "BH_ENV_RELEASE_DIRECTORY=/opt/bh-env-release" \
        --env "BH_ENV_BUILD_DIRECTORY=/var/tmp/bh-env-build" \
        --env "TMPDIR=/tmp" \
        --env "BH_ENV_RECIPE_DIGEST=${recipe_digest}" \
        --env "BH_ENV_BUNDLE_DIGEST=${bundle_digest}" \
        "${incoming_rootfs}" \
        /bin/bash /opt/bh-env-release/provision_environment.sh \
        >> "${build_log_file}" 2>&1

{
    printf 'SCHEMA_VERSION=1\n'
    printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
    printf 'GENERATION=%s\n' "${generation_id}"
    printf 'RECIPE_DIGEST=%s\n' "${recipe_digest}"
    printf 'BUNDLE_DIGEST=%s\n' "${bundle_digest}"
    printf 'BASE_IMAGE=%s\n' "${base_image_path}"
    printf 'CREATED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'SLURM_JOB_ID=%s\n' "${SLURM_JOB_ID}"
    printf 'BUILD_LOG=%s\n' "${build_log_file}"
} > "${incoming_generation}/metadata.env"
chmod 600 "${incoming_generation}/metadata.env"

write_environment_status "VALIDATING_ENVIRONMENT"
generation_is_valid "${incoming_generation}" || {
    printf 'The new environment failed validation. Build log: %s\n' \
        "${build_log_file}" >&2
    exit 4
}

mv "${incoming_generation}" "${final_generation}"
temporary_current_link="${environment_directory}/.current.$$"
ln -s "generations/${generation_id}" "${temporary_current_link}"
mv -Tf "${temporary_current_link}" "${environment_directory}/current"
trap - EXIT INT TERM
rm -rf -- \
    "${build_tmp_directory}" "${container_tmp_directory}" \
    "${download_directory}"

write_environment_status "ENVIRONMENT_READY:built"
print_environment_record "$(readlink -f "${final_generation}")" "built"
