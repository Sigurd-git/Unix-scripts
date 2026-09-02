#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

shared_image_path="${1:?shared image path is required}"
user_image_path="${2:?user image path is required}"
canonical_checksum_file="${3:?canonical checksum file is required}"
definition_file="${4:?Apptainer definition file is required}"
image_status_file="${5:?image status file is required}"
build_timeout_seconds="${6:-1800}"

expected_source_digest="sha256:99e3b0197ec645ac616f67a55768330955529c9da43f39f8c8cc4c4d0c28a3fa"
expected_vcs_reference="2c27f9f"
expected_version_sticker="ubuntu24.04.4"
user_checksum_file="${user_image_path}.sha256"
image_directory="$(dirname "${user_image_path}")"
build_lock_file="${image_directory}/.build.lock"

[[ "${build_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid image build timeout: %s\n' "${build_timeout_seconds}" >&2
    exit 2
}
for required_file in "${canonical_checksum_file}" "${definition_file}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required image file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done
for required_command in awk sha256sum flock timeout; do
    command -v "${required_command}" >/dev/null 2>&1 || {
        printf 'Required image command is unavailable: %s\n' \
            "${required_command}" >&2
        exit 2
    }
done

mkdir -p "${image_directory}" "$(dirname "${image_status_file}")"
chmod 700 "${image_directory}" "$(dirname "${image_status_file}")"

write_image_status() {
    local status_value="$1"
    local temporary_status_file="${image_status_file}.tmp.$$"

    printf '%s\n' "${status_value}" > "${temporary_status_file}"
    mv "${temporary_status_file}" "${image_status_file}"
}

load_apptainer() {
    if command -v apptainer >/dev/null 2>&1; then
        return 0
    fi

    [[ -r /etc/profile.d/modules.sh ]] || {
        printf 'Environment Modules initialization is unavailable.\n' >&2
        return 1
    }
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh
    module purge
    module load apptainer/1.4.1
    command -v apptainer >/dev/null 2>&1
}

read_expected_canonical_checksum() {
    awk 'NF >= 1 && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); exit }' \
        "${canonical_checksum_file}"
}

file_matches_checksum() {
    local requested_file="$1"
    local expected_checksum="$2"
    local actual_checksum

    [[ -r "${requested_file}" && -n "${expected_checksum}" ]] || return 1
    actual_checksum="$(sha256sum "${requested_file}" | awk '{ print $1; exit }')"
    [[ "${actual_checksum}" == "${expected_checksum}" ]]
}

runtime_image_is_valid() {
    local requested_image="$1"
    local labels

    [[ -r "${requested_image}" ]] || return 1
    load_apptainer || return 1
    labels="$(apptainer inspect --json "${requested_image}" 2>/dev/null)" || return 1
    grep -Fq "\"org.label-schema.vcs-ref\": \"${expected_vcs_reference}\"" \
        <<< "${labels}" || return 1
    grep -Fq "\"any.accetto.version-sticker\": \"${expected_version_sticker}\"" \
        <<< "${labels}" || return 1
    apptainer exec "${requested_image}" /bin/sh -c \
        'command -v vncserver >/dev/null && command -v vncpasswd >/dev/null && command -v xfce4-session >/dev/null' \
        >/dev/null 2>&1
}

user_image_is_valid() {
    local recorded_checksum
    local recorded_filename
    local definition_record

    [[ -r "${user_image_path}" && -r "${user_checksum_file}" ]] || return 1
    read -r recorded_checksum recorded_filename < "${user_checksum_file}" || return 1
    [[ "${recorded_checksum}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "${recorded_filename}" == "$(basename "${user_image_path}")" ]] || return 1
    file_matches_checksum "${user_image_path}" "${recorded_checksum}" || return 1
    runtime_image_is_valid "${user_image_path}" || return 1
    definition_record="$(apptainer inspect --deffile "${user_image_path}" 2>/dev/null)" || \
        return 1
    grep -Fq "${expected_source_digest}" <<< "${definition_record}"
}

write_image_status "CHECKING_IMAGE"
expected_canonical_checksum="$(read_expected_canonical_checksum)"
[[ "${expected_canonical_checksum}" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'Canonical image checksum file is invalid: %s\n' \
        "${canonical_checksum_file}" >&2
    exit 2
}

if file_matches_checksum "${shared_image_path}" "${expected_canonical_checksum}" &&
   runtime_image_is_valid "${shared_image_path}"; then
    write_image_status "IMAGE_READY:shared"
    printf '[remote-vnc] Using shared VNC image: %s\n' "${shared_image_path}" >&2
    printf '%s\n' "${shared_image_path}"
    exit 0
fi
if [[ -e "${shared_image_path}" ]]; then
    printf '[remote-vnc] Shared VNC image is unreadable or failed validation: %s\n' \
        "${shared_image_path}" >&2
else
    printf '[remote-vnc] Shared VNC image is unavailable: %s\n' \
        "${shared_image_path}" >&2
fi

if user_image_is_valid; then
    write_image_status "IMAGE_READY:user"
    printf '[remote-vnc] Using user VNC image: %s\n' "${user_image_path}" >&2
    printf '%s\n' "${user_image_path}"
    exit 0
fi

exec 9> "${build_lock_file}"
build_deadline=$((SECONDS + build_timeout_seconds))
if ! flock -w "${build_timeout_seconds}" 9; then
    printf 'Timed out waiting for the VNC image build lock: %s\n' \
        "${build_lock_file}" >&2
    exit 3
fi

if user_image_is_valid; then
    write_image_status "IMAGE_READY:user"
    printf '[remote-vnc] Using user VNC image built by another job: %s\n' \
        "${user_image_path}" >&2
    printf '%s\n' "${user_image_path}"
    exit 0
fi

load_apptainer || {
    printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
    exit 4
}
grep -Fq "${expected_source_digest}" "${definition_file}" || {
    printf 'Apptainer definition does not contain the pinned source digest.\n' >&2
    exit 4
}

write_image_status "BUILDING_IMAGE"
remaining_build_seconds=$((build_deadline - SECONDS))
((remaining_build_seconds > 0)) || {
    printf 'The VNC image build deadline expired while waiting for the lock.\n' >&2
    exit 3
}
build_root="${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/remote-vnc-image-${SLURM_JOB_ID:-$$}"
temporary_image="${user_image_path}.tmp.${SLURM_JOB_ID:-$$}"
temporary_checksum_file="${user_checksum_file}.tmp.${SLURM_JOB_ID:-$$}"
mkdir -p "${build_root}/cache" "${build_root}/tmp"
chmod 700 "${build_root}" "${build_root}/cache" "${build_root}/tmp"
export APPTAINER_CACHEDIR="${build_root}/cache"
export APPTAINER_TMPDIR="${build_root}/tmp"

cleanup_build_files() {
    local exit_status=$?

    trap - EXIT INT TERM
    rm -f -- "${temporary_image}" "${temporary_checksum_file}"
    exit "${exit_status}"
}
trap cleanup_build_files EXIT INT TERM
rm -f -- "${temporary_image}" "${temporary_checksum_file}"

printf '[remote-vnc] Building a private VNC image in Slurm Job %s.\n' \
    "${SLURM_JOB_ID:-unknown}" >&2
timeout "${remaining_build_seconds}" \
    apptainer build --force "${temporary_image}" "${definition_file}"
runtime_image_is_valid "${temporary_image}" || {
    printf 'Built VNC image failed its runtime checks.\n' >&2
    exit 5
}
definition_record="$(apptainer inspect --deffile "${temporary_image}")"
grep -Fq "${expected_source_digest}" <<< "${definition_record}" || {
    printf 'Built VNC image does not record the pinned source digest.\n' >&2
    exit 5
}

built_checksum="$(sha256sum "${temporary_image}" | awk '{ print $1; exit }')"
printf '%s  %s\n' "${built_checksum}" "$(basename "${user_image_path}")" \
    > "${temporary_checksum_file}"
chmod 400 "${temporary_image}" "${temporary_checksum_file}"
mv "${temporary_image}" "${user_image_path}"
mv "${temporary_checksum_file}" "${user_checksum_file}"
trap - EXIT INT TERM

write_image_status "IMAGE_READY:built"
printf '[remote-vnc] Private VNC image is ready: %s\n' "${user_image_path}" >&2
printf '%s\n' "${user_image_path}"
