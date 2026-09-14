#!/usr/bin/env bash

# Run locally: bash tests/test_remote_vnc_updates.sh
# Network, package-manager, timeout, and lock operations are mocked.
set -Eeuo pipefail

repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
updater="${repository_directory}/remote_vnc/update_ai_tools.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "${fixture_root}"' EXIT
mock_binary_directory="${fixture_root}/mock-bin"
mkdir -p "${mock_binary_directory}"

cat > "${mock_binary_directory}/timeout" <<'MOCK_TIMEOUT'
#!/usr/bin/env bash
shift
exec "$@"
MOCK_TIMEOUT

cat > "${mock_binary_directory}/flock" <<'MOCK_FLOCK'
#!/usr/bin/env bash
exit 0
MOCK_FLOCK

cat > "${mock_binary_directory}/npm" <<'MOCK_NPM'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == "view" ]]; then
    printf 'npm-view\n' >> "${MOCK_EVENT_LOG}"
    [[ "${MOCK_NPM_VIEW_FAIL:-0}" != "1" ]] || exit 31
    printf '%s\n' "${MOCK_OCX_LATEST}"
    exit 0
fi

if [[ "$1" == "install" ]]; then
    package_specification=""
    for argument in "$@"; do
        [[ "${argument}" == @bitkyc08/opencodex@* ]] &&
            package_specification="${argument}"
    done
    version="${package_specification##*@}"
    printf 'npm-install:%s\n' "${version}" >> "${MOCK_EVENT_LOG}"
    [[ "${MOCK_NPM_INSTALL_FAIL:-0}" != "1" ]] || exit 32
    mkdir -p "${npm_config_prefix}/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf "printf 'opencodex %%s\\n' '%s'\n" "${version}"
    } > "${npm_config_prefix}/bin/ocx"
    chmod +x "${npm_config_prefix}/bin/ocx"
    exit 0
fi

exit 33
MOCK_NPM

cat > "${mock_binary_directory}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail

output_file=""
previous_argument=""
for argument in "$@"; do
    if [[ "${previous_argument}" == "--output" || "${previous_argument}" == "-o" ]]; then
        output_file="${argument}"
    fi
    previous_argument="${argument}"
done

if [[ "$*" == *'/codex/channels/latest'* ]]; then
    printf 'codex-metadata\n' >> "${MOCK_EVENT_LOG}"
    [[ "${MOCK_CODEX_QUERY_FAIL:-0}" != "1" ]] || exit 41
    printf '{"tag_name":"rust-v%s"}\n' "${MOCK_CODEX_LATEST}"
    exit 0
fi

if [[ "$*" == *'/codex/install.sh'* ]]; then
    printf 'codex-installer-download\n' >> "${MOCK_EVENT_LOG}"
    [[ "${MOCK_CODEX_DOWNLOAD_FAIL:-0}" != "1" ]] || exit 42
    cp "${MOCK_CODEX_INSTALLER}" "${output_file}"
    exit 0
fi

exit 43
MOCK_CURL

cat > "${fixture_root}/codex-installer.sh" <<'MOCK_INSTALLER'
#!/bin/sh
set -eu

printf 'codex-install:%s\n' "${CODEX_RELEASE}" >> "${MOCK_EVENT_LOG}"
[ "${MOCK_CODEX_INSTALL_FAIL:-0}" != "1" ] || exit 51
target="x86_64-unknown-linux-musl"
release_directory="${CODEX_HOME}/packages/standalone/releases/${CODEX_RELEASE}-${target}"
mkdir -p "${release_directory}/bin"
{
    printf '#!/usr/bin/env bash\n'
    printf "printf 'codex-cli %%s\\n' '%s'\n" "${CODEX_RELEASE}"
} > "${release_directory}/bin/codex"
chmod +x "${release_directory}/bin/codex"
printf '{}\n' > "${release_directory}/codex-package.json"
ln -sfn "releases/${CODEX_RELEASE}-${target}" \
    "${CODEX_HOME}/packages/standalone/current"
MOCK_INSTALLER

chmod +x "${mock_binary_directory}/"* "${fixture_root}/codex-installer.sh"

write_version_executable() {
    local executable_path="$1"
    local product_name="$2"
    local version="$3"

    mkdir -p "$(dirname "${executable_path}")"
    {
        printf '#!/usr/bin/env bash\n'
        printf "printf '%s %%s\\n' '%s'\n" "${product_name}" "${version}"
    } > "${executable_path}"
    chmod +x "${executable_path}"
}

install_fixture_codex() {
    local codex_home="$1"
    local version="$2"
    local target="x86_64-unknown-linux-musl"
    local release_directory="${codex_home}/packages/standalone/releases/${version}-${target}"

    write_version_executable "${release_directory}/bin/codex" codex-cli "${version}"
    printf '{}\n' > "${release_directory}/codex-package.json"
    ln -s "releases/${version}-${target}" \
        "${codex_home}/packages/standalone/current"
}

prepare_case() {
    local case_name="$1"

    case_directory="${fixture_root}/${case_name}"
    export HOME="${case_directory}/home"
    export XDG_STATE_HOME="${HOME}/.local/state"
    export CODEX_HOME="${HOME}/.codex"
    export npm_config_prefix="${HOME}/.local/share/remote-vnc/npm"
    export BH_ENV_ACTIVE=1
    export BH_ENV_SERVICE_INSTANCE="remote-vnc-test-900001"
    export MOCK_EVENT_LOG="${case_directory}/events"
    export MOCK_CODEX_INSTALLER="${fixture_root}/codex-installer.sh"
    export MOCK_NPM_VIEW_FAIL=0
    export MOCK_NPM_INSTALL_FAIL=0
    export MOCK_CODEX_QUERY_FAIL=0
    export MOCK_CODEX_DOWNLOAD_FAIL=0
    export MOCK_CODEX_INSTALL_FAIL=0
    export PATH="${mock_binary_directory}:/usr/bin:/bin:/usr/sbin:/sbin"
    managed_codex_executable="${CODEX_HOME}/packages/standalone/current/bin/codex"
    mkdir -p "${HOME}" "${npm_config_prefix}/bin"
    : > "${MOCK_EVENT_LOG}"
}

expect_failure() {
    local expected_message="$1"
    shift
    local actual_status=0

    "$@" > "${case_directory}/stdout" 2> "${case_directory}/stderr" ||
        actual_status=$?
    [[ "${actual_status}" -eq 1 ]] || {
        sed -n '1,160p' "${case_directory}/stderr" >&2
        printf 'Expected exit 1, got %s\n' "${actual_status}" >&2
        exit 1
    }
    grep -Fq "${expected_message}" "${case_directory}/stderr"
}

assert_events() {
    local expected_events="$1"

    [[ "$(cat "${MOCK_EVENT_LOG}")" == "${expected_events}" ]] || {
        printf 'Unexpected event order:\n' >&2
        cat "${MOCK_EVENT_LOG}" >&2
        exit 1
    }
}

prepare_case no_updates
write_version_executable "${npm_config_prefix}/bin/ocx" opencodex 2.55.0
install_fixture_codex "${CODEX_HOME}" 0.154.0
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0
bash "${updater}" "${managed_codex_executable}"
assert_events $'npm-view\ncodex-metadata'
printf 'PASS: current OpenCodex and Codex perform checks without reinstalling\n'

prepare_case updates
write_version_executable "${npm_config_prefix}/bin/ocx" opencodex 2.42.0
install_fixture_codex "${CODEX_HOME}" 0.150.1
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0
bash "${updater}" "${managed_codex_executable}"
assert_events $'npm-view\nnpm-install:2.55.0\ncodex-metadata\ncodex-installer-download\ncodex-install:0.154.0'
[[ "$("${npm_config_prefix}/bin/ocx" --version)" == 'opencodex 2.55.0' ]]
[[ "$("${managed_codex_executable}" --version)" == 'codex-cli 0.154.0' ]]
printf 'PASS: updates run OpenCodex first, then the official standalone Codex installer\n'

prepare_case no_downgrade
write_version_executable "${npm_config_prefix}/bin/ocx" opencodex 2.56.0-preview.1
install_fixture_codex "${CODEX_HOME}" 0.155.0-alpha.1
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0
bash "${updater}" "${managed_codex_executable}"
assert_events $'npm-view\ncodex-metadata'
[[ "$("${npm_config_prefix}/bin/ocx" --version)" == \
    'opencodex 2.56.0-preview.1' ]]
[[ "$("${managed_codex_executable}" --version)" == \
    'codex-cli 0.155.0-alpha.1' ]]
printf 'PASS: registry channels never downgrade a newer installed build\n'

prepare_case ocx_query_failure
install_fixture_codex "${CODEX_HOME}" 0.150.1
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0 MOCK_NPM_VIEW_FAIL=1
expect_failure 'OpenCodex registry query failed' \
    bash "${updater}" "${managed_codex_executable}"
assert_events 'npm-view'
printf 'PASS: a failed OpenCodex query stops startup checks before Codex\n'

prepare_case ocx_install_failure
write_version_executable "${npm_config_prefix}/bin/ocx" opencodex 2.42.0
install_fixture_codex "${CODEX_HOME}" 0.150.1
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0 MOCK_NPM_INSTALL_FAIL=1
expect_failure 'OpenCodex 2.55.0 installation failed' \
    bash "${updater}" "${managed_codex_executable}"
assert_events $'npm-view\nnpm-install:2.55.0'
printf 'PASS: a failed OpenCodex install is explicit and prevents service startup\n'

prepare_case codex_install_failure
install_fixture_codex "${CODEX_HOME}" 0.150.1
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0 MOCK_CODEX_INSTALL_FAIL=1
expect_failure 'Codex 0.154.0 standalone installation failed' \
    bash "${updater}" "${managed_codex_executable}" codex
assert_events $'codex-metadata\ncodex-installer-download\ncodex-install:0.154.0'
printf 'PASS: codex-only mode reports official installer failure\n'

prepare_case ocx_only
write_version_executable "${npm_config_prefix}/bin/ocx" opencodex 2.55.0
export MOCK_OCX_LATEST=2.55.0 MOCK_CODEX_LATEST=0.154.0
bash "${updater}" "${managed_codex_executable}" ocx
assert_events 'npm-view'
printf 'PASS: ocx-only mode does not inspect or alter Codex\n'
