#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

managed_codex_executable="${1:?managed Codex executable is required}"
update_scope="${2:-all}"

case "${update_scope}" in
    all|ocx|codex) ;;
    *)
        printf 'Usage: %s <managed-codex-executable> [all|ocx|codex]\n' \
            "${0##*/}" >&2
        exit 2
        ;;
esac

[[ "${BH_ENV_ACTIVE:-}" == "1" && -n "${BH_ENV_SERVICE_INSTANCE:-}" ]] || {
    printf 'AI tool updates must run inside a remote-vnc service instance.\n' >&2
    exit 2
}
[[ -n "${HOME:-}" && "${HOME}" == /* ]] || {
    printf 'A persistent absolute HOME is required for AI tool updates.\n' >&2
    exit 2
}

state_directory="${XDG_STATE_HOME:-${HOME}/.local/state}/remote-vnc"
log_file="${AI_TOOLS_UPDATE_LOG_FILE:-${state_directory}/ai-tools-update.log}"
lock_file="${state_directory}/ai-tools-update.lock"
query_timeout_seconds="${AI_TOOLS_QUERY_TIMEOUT_SECONDS:-45}"
install_timeout_seconds="${AI_TOOLS_INSTALL_TIMEOUT_SECONDS:-600}"
lock_timeout_seconds="${AI_TOOLS_LOCK_TIMEOUT_SECONDS:-120}"
version_timeout_seconds="${AI_TOOLS_VERSION_TIMEOUT_SECONDS:-30}"
opencodex_package="@bitkyc08/opencodex"
codex_latest_metadata_url="https://releases.openai.com/codex/channels/latest"
codex_installer_url="https://chatgpt.com/codex/install.sh"

for timeout_value in \
    "${query_timeout_seconds}" "${install_timeout_seconds}" \
    "${lock_timeout_seconds}" "${version_timeout_seconds}"; do
    [[ "${timeout_value}" =~ ^[1-9][0-9]*$ ]] || {
        printf 'AI tool timeout values must be positive integers.\n' >&2
        exit 2
    }
done

mkdir -p "${state_directory}"
chmod 700 "${state_directory}"
touch "${log_file}"
chmod 600 "${log_file}"

log_message() {
    local message="$1"
    local timestamp

    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '[remote-vnc update] %s %s\n' "${timestamp}" "${message}" >&2
    printf '[remote-vnc update] %s %s\n' "${timestamp}" "${message}" \
        >> "${log_file}"
}

fail_update() {
    log_message "ERROR: $1"
    exit 1
}

for required_command in date flock grep head timeout; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail_update "Required command is unavailable: ${required_command}"
done

if [[ "${update_scope}" == "all" || "${update_scope}" == "ocx" ]]; then
    command -v npm >/dev/null 2>&1 ||
        fail_update "Required command is unavailable: npm"
fi
if [[ "${update_scope}" == "all" || "${update_scope}" == "codex" ]]; then
    for required_command in curl jq mktemp; do
        command -v "${required_command}" >/dev/null 2>&1 ||
            fail_update "Required command is unavailable: ${required_command}"
    done
fi

exec 9> "${lock_file}"
flock -w "${lock_timeout_seconds}" 9 ||
    fail_update "Timed out waiting for AI tool update lock: ${lock_file}"

temporary_installer=""
cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM
    if [[ -n "${temporary_installer}" && -f "${temporary_installer}" ]]; then
        rm -f -- "${temporary_installer}"
    fi
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
    exit "${exit_status}"
}
trap cleanup EXIT INT TERM

normalize_version() {
    local version_value="$1"

    version_value="${version_value#rust-v}"
    version_value="${version_value#v}"
    printf '%s\n' "${version_value}"
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]
}

extract_version() {
    LC_ALL=C grep -Eo \
        '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?' |
        head -n 1
}

# Print -1, 0, or 1 when the left semantic version is older, equal, or newer.
compare_versions() {
    local left_version right_version left_core right_core
    local left_prerelease right_prerelease left_part right_part
    local component_index identifier_index maximum_identifiers
    local -a left_components right_components left_identifiers right_identifiers

    left_version="$(normalize_version "$1")"
    right_version="$(normalize_version "$2")"
    left_version="${left_version%%+*}"
    right_version="${right_version%%+*}"
    left_core="${left_version%%-*}"
    right_core="${right_version%%-*}"
    left_prerelease=""
    right_prerelease=""
    [[ "${left_version}" == *-* ]] && left_prerelease="${left_version#*-}"
    [[ "${right_version}" == *-* ]] && right_prerelease="${right_version#*-}"
    IFS=. read -r -a left_components <<< "${left_core}"
    IFS=. read -r -a right_components <<< "${right_core}"

    for component_index in 0 1 2; do
        if ((10#${left_components[component_index]} < \
             10#${right_components[component_index]})); then
            printf '%s\n' -1
            return
        fi
        if ((10#${left_components[component_index]} > \
             10#${right_components[component_index]})); then
            printf '%s\n' 1
            return
        fi
    done

    if [[ -z "${left_prerelease}" && -z "${right_prerelease}" ]]; then
        printf '%s\n' 0
        return
    fi
    if [[ -z "${left_prerelease}" ]]; then
        printf '%s\n' 1
        return
    fi
    if [[ -z "${right_prerelease}" ]]; then
        printf '%s\n' -1
        return
    fi

    IFS=. read -r -a left_identifiers <<< "${left_prerelease}"
    IFS=. read -r -a right_identifiers <<< "${right_prerelease}"
    maximum_identifiers=${#left_identifiers[@]}
    (( ${#right_identifiers[@]} > maximum_identifiers )) &&
        maximum_identifiers=${#right_identifiers[@]}
    for ((identifier_index = 0;
          identifier_index < maximum_identifiers;
          identifier_index++)); do
        if ((identifier_index >= ${#left_identifiers[@]})); then
            printf '%s\n' -1
            return
        fi
        if ((identifier_index >= ${#right_identifiers[@]})); then
            printf '%s\n' 1
            return
        fi
        left_part="${left_identifiers[identifier_index]}"
        right_part="${right_identifiers[identifier_index]}"
        [[ "${left_part}" == "${right_part}" ]] && continue
        if [[ "${left_part}" =~ ^[0-9]+$ && "${right_part}" =~ ^[0-9]+$ ]]; then
            if ((10#${left_part} < 10#${right_part})); then
                printf '%s\n' -1
            else
                printf '%s\n' 1
            fi
        elif [[ "${left_part}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' -1
        elif [[ "${right_part}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' 1
        elif [[ "${left_part}" < "${right_part}" ]]; then
            printf '%s\n' -1
        else
            printf '%s\n' 1
        fi
        return
    done
    printf '%s\n' 0
}

read_tool_version() {
    local executable_path="$1"
    local tool_name="$2"
    local version_output version_value

    [[ -x "${executable_path}" ]] ||
        fail_update "${tool_name} executable is unavailable: ${executable_path}"
    version_output="$({
        timeout "${version_timeout_seconds}" \
            "${executable_path}" --version
    } 2>> "${log_file}")" ||
        fail_update "${tool_name} --version failed: ${executable_path}"
    version_value="$(printf '%s\n' "${version_output}" | extract_version || true)"
    [[ -n "${version_value}" ]] ||
        fail_update "Could not parse ${tool_name} version from: ${version_output}"
    validate_version "${version_value}" ||
        fail_update "${tool_name} reported an invalid version: ${version_value}"
    printf '%s\n' "${version_value}"
}

update_opencodex() {
    local npm_prefix ocx_executable latest_output latest_version
    local installed_version="" version_comparison

    npm_prefix="${npm_config_prefix:-}"
    [[ -n "${npm_prefix}" && "${npm_prefix}" == /* ]] ||
        fail_update "npm_config_prefix must name the persistent absolute OpenCodex prefix."
    case "${npm_prefix}" in
        "${HOME}"/*) ;;
        *) fail_update "OpenCodex npm prefix must be inside persistent HOME: ${npm_prefix}" ;;
    esac
    ocx_executable="${npm_prefix}/bin/ocx"

    log_message "Checking OpenCodex registry version."
    latest_output="$({
        timeout "${query_timeout_seconds}" npm view \
            "${opencodex_package}@latest" version \
            --fetch-timeout=30000 --fetch-retries=1
    } 2>> "${log_file}")" ||
        fail_update "OpenCodex registry query failed. See ${log_file}."
    latest_version="$(printf '%s\n' "${latest_output}" | extract_version || true)"
    [[ -n "${latest_version}" ]] && validate_version "${latest_version}" ||
        fail_update "OpenCodex registry returned an invalid version: ${latest_output}"

    if [[ -e "${ocx_executable}" || -L "${ocx_executable}" ]]; then
        installed_version="$(read_tool_version "${ocx_executable}" OpenCodex)"
        version_comparison="$(compare_versions "${latest_version}" "${installed_version}")"
        if [[ "${version_comparison}" == "0" ]]; then
            log_message "OpenCodex ${installed_version} is current."
            return
        fi
        if [[ "${version_comparison}" == "-1" ]]; then
            log_message "OpenCodex ${installed_version} is newer than registry latest ${latest_version}; keeping the installed version."
            return
        fi
        log_message "Updating OpenCodex ${installed_version} -> ${latest_version}."
    else
        log_message "Installing OpenCodex ${latest_version} into ${npm_prefix}."
    fi

    mkdir -p "${npm_prefix}"
    timeout "${install_timeout_seconds}" npm install \
        --global --prefix "${npm_prefix}" --omit=dev --no-audit --no-fund \
        "${opencodex_package}@${latest_version}" \
        >> "${log_file}" 2>&1 ||
        fail_update "OpenCodex ${latest_version} installation failed. See ${log_file}."
    installed_version="$(read_tool_version "${ocx_executable}" OpenCodex)"
    [[ "${installed_version}" == "${latest_version}" ]] ||
        fail_update "OpenCodex validation expected ${latest_version}, found ${installed_version}."
    log_message "OpenCodex ${installed_version} is installed and executable at ${ocx_executable}."
}

update_codex() {
    local codex_path_suffix codex_home codex_standalone_root installer_bin_directory
    local latest_metadata latest_version installed_version="" version_comparison

    codex_path_suffix="/packages/standalone/current/bin/codex"
    [[ "${managed_codex_executable}" == /*"${codex_path_suffix}" ]] ||
        fail_update "Managed Codex path is not a standalone current executable: ${managed_codex_executable}"
    codex_home="${managed_codex_executable%${codex_path_suffix}}"
    [[ -z "${CODEX_HOME:-}" || "${CODEX_HOME}" == "${codex_home}" ]] ||
        fail_update "Managed Codex path does not belong to CODEX_HOME=${CODEX_HOME}."
    codex_standalone_root="${codex_home}/packages/standalone"
    installer_bin_directory="${codex_standalone_root}/installer-bin"

    if [[ -e "${managed_codex_executable}" || -L "${managed_codex_executable}" ]]; then
        installed_version="$(read_tool_version \
            "${managed_codex_executable}" Codex)"
    fi

    log_message "Checking Codex official latest channel."
    latest_metadata="$({
        timeout "${query_timeout_seconds}" curl --fail --location --silent \
            --show-error --connect-timeout 10 --max-time "${query_timeout_seconds}" \
            "${codex_latest_metadata_url}"
    } 2>> "${log_file}")" ||
        fail_update "Codex latest metadata query failed. See ${log_file}."
    latest_version="$(printf '%s\n' "${latest_metadata}" |
        jq -er '.tag_name | strings | select(startswith("rust-v")) | ltrimstr("rust-v")')" ||
        fail_update "Codex latest metadata did not contain a valid tag_name."
    validate_version "${latest_version}" ||
        fail_update "Codex latest metadata returned an invalid version: ${latest_version}"

    if [[ -n "${installed_version}" ]]; then
        version_comparison="$(compare_versions "${latest_version}" "${installed_version}")"
        if [[ "${version_comparison}" == "0" ]]; then
            log_message "Codex ${installed_version} is current."
            return
        fi
        if [[ "${version_comparison}" == "-1" ]]; then
            log_message "Codex ${installed_version} is newer than official latest ${latest_version}; keeping the installed version."
            return
        fi
        log_message "Updating standalone Codex ${installed_version} -> ${latest_version}."
    else
        log_message "Installing standalone Codex ${latest_version}."
    fi

    temporary_installer="$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX")"
    timeout "${query_timeout_seconds}" curl --fail --location --silent \
        --show-error --connect-timeout 10 --max-time "${query_timeout_seconds}" \
        --output "${temporary_installer}" "${codex_installer_url}" \
        >> "${log_file}" 2>&1 ||
        fail_update "Codex official installer download failed. See ${log_file}."
    [[ -s "${temporary_installer}" ]] ||
        fail_update "Codex official installer download was empty."

    mkdir -p "${installer_bin_directory}"
    env \
        CODEX_HOME="${codex_home}" \
        CODEX_INSTALL_DIR="${installer_bin_directory}" \
        CODEX_RELEASE="${latest_version}" \
        CODEX_NON_INTERACTIVE=1 \
        PATH="${installer_bin_directory}:${PATH}" \
        timeout "${install_timeout_seconds}" /bin/sh "${temporary_installer}" \
        >> "${log_file}" 2>&1 ||
        fail_update "Codex ${latest_version} standalone installation failed. See ${log_file}."
    installed_version="$(read_tool_version \
        "${managed_codex_executable}" Codex)"
    [[ "${installed_version}" == "${latest_version}" ]] ||
        fail_update "Codex validation expected ${latest_version}, found ${installed_version}."
    log_message "Codex ${installed_version} is installed and executable at ${managed_codex_executable}."
}

log_message "Starting ${update_scope} update check in service instance ${BH_ENV_SERVICE_INSTANCE}."
case "${update_scope}" in
    all)
        update_opencodex
        update_codex
        ;;
    ocx) update_opencodex ;;
    codex) update_codex ;;
esac
log_message "Completed ${update_scope} update check successfully."
