#!/usr/bin/env bash
set -Eeuo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "${fixture_directory}"' EXIT
# Load the actual remote payload functions without connecting or submitting jobs.
awk '/^read_state_value\(\)/ {copy=1} /^opencodex_connection_is_ready\(\)/ {exit} copy {print}' \
    "${repository_directory}/remote_vnc.sh" > "${fixture_directory}/functions.sh"
source "${fixture_directory}/functions.sh"
user_service_directory="${fixture_directory}"
environment_name=default
environment_mode=mutable
requested_remote_ssh_port=44422
vnc_geometry=2560x1440
managed_launcher_comment=remote-vnc-managed-v17:default:mutable:44422:2560x1440
scontrol_executable="${fixture_directory}/scontrol"
cat > "${scontrol_executable}" <<'MOCK'
#!/usr/bin/env bash
printf 'Comment=%s\n' "${TEST_JOB_COMMENT}"
MOCK
chmod +x "${scontrol_executable}"
mkdir -p "${fixture_directory}/state/jobs/123"
launcher_state_file="$(managed_launcher_state_file 123)"
expect_rejection() {
    if "$@"; then
        printf "Expected rejection: %s\n" "$*" >&2
        exit 1
    fi
}
for launcher_version in 17 18; do
    export TEST_JOB_COMMENT="remote-vnc-managed-v${launcher_version}:default:mutable:44422:2560x1440"
    job_uses_managed_launcher 123
    job_matches_requested_configuration 123
    cat > "${launcher_state_file}" <<STATE
STATUS=READY
LAUNCHER_VERSION=${launcher_version}
JOB_ID=123
ENVIRONMENT_NAME=default
ENVIRONMENT_MODE=mutable
REMOTE_SSH_PORT=44422
VNC_GEOMETRY=2560x1440
STATE
    job_uses_managed_launcher 123
    managed_launcher_is_ready 123
    job_matches_requested_configuration 123
    sed "s/JOB_ID=123/JOB_ID=456/" "${launcher_state_file}" > "${fixture_directory}/wrong-job.env"
    cp "${launcher_state_file}" "${fixture_directory}/original.env"
    cp "${fixture_directory}/wrong-job.env" "${launcher_state_file}"
    expect_rejection job_uses_managed_launcher 123
    expect_rejection managed_launcher_is_ready 123
    cp "${fixture_directory}/original.env" "${launcher_state_file}"
    vnc_geometry=1920x1080
    managed_launcher_comment=remote-vnc-managed-v17:default:mutable:44422:1920x1080
    expect_rejection managed_launcher_is_ready 123
    expect_rejection job_matches_requested_configuration 123
    vnc_geometry=2560x1440
    managed_launcher_comment=remote-vnc-managed-v17:default:mutable:44422:2560x1440
    # A compatible comment must not override an incompatible state file.
    for incompatible_version in 16 19 invalid; do
        sed "s/LAUNCHER_VERSION=${launcher_version}/LAUNCHER_VERSION=${incompatible_version}/" \
            "${launcher_state_file}" > "${fixture_directory}/incompatible.env"
        cp "${launcher_state_file}" "${fixture_directory}/original.env"
        cp "${fixture_directory}/incompatible.env" "${launcher_state_file}"
        expect_rejection job_uses_managed_launcher 123
        expect_rejection managed_launcher_is_ready 123
        cp "${fixture_directory}/original.env" "${launcher_state_file}"
    done
    rm "${launcher_state_file}"
done
for incompatible_version in 16 19 invalid; do
    export TEST_JOB_COMMENT="remote-vnc-managed-v${incompatible_version}:default:mutable:44422:2560x1440"
    expect_rejection job_uses_managed_launcher 123
    expect_rejection job_matches_requested_configuration 123
done
printf 'PASS: v17/v18 state and comment compatibility; incompatible versions and configuration rejected\n'
