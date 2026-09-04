#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
image_path="${3:?Apptainer image path is required}"
environment_name="${4:-default}"
environment_mode="${5:-immutable}"
requested_session_home="${6:-}"
environment_generation="${7:-base-image}"
vnc_geometry="${8:-2560x1440}"
job_id="${SLURM_JOB_ID:?SLURM_JOB_ID is required}"
current_user="$(id -un)"
host_home="${HOME:?HOME is required}"
host_codex_home="${host_home}/.codex"
state_directory="${user_service_directory}/state"
job_state_directory="${state_directory}/jobs/${job_id}"
session_home="${requested_session_home:-${job_state_directory}/home}"
xfce_terminal_config_directory="${session_home}/.config/xfce4/terminal"
xfce_terminal_config_file="${xfce_terminal_config_directory}/terminalrc"
runtime_directory="${SLURM_TMPDIR:-/tmp}/remote-vnc-${current_user}-${job_id}"
container_home="/home/${current_user}"
connection_file="${state_directory}/connection.env"
plain_password_file="${state_directory}/vnc-password.txt"
vnc_log_file="${job_state_directory}/vncserver.log"
vnc_process_id=""
host_shell_directory="${job_state_directory}/host-shell"
host_shell_log_file="${job_state_directory}/host-shell.log"
host_shell_process_id=""
gpu_log_file="${job_state_directory}/gpu-usage.csv"
gpu_monitor_process_id=""
matlab_executable="/opt/matlab/R2025b/bin/matlab"
matlab_vnc_launcher="${release_directory}/matlab-vnc.sh"
environment_common_helpers="${release_directory}/environment_common.sh"
matlab_warmup_log_file="${job_state_directory}/matlab-warmup.log"
matlab_warmup_status_file="${job_state_directory}/matlab-warmup.status"
matlab_warmup_process_id=""
matlab_warmup_status="NOT_RUN"
opencodex_service_launcher="${release_directory}/start_opencodex.sh"
opencodex_service_directory="${job_state_directory}/opencodex"
opencodex_service_state_file="${opencodex_service_directory}/service.env"
opencodex_service_log_file="${opencodex_service_directory}/service.log"
opencodex_service_process_id=""
opencodex_status="DISABLED_IMMUTABLE"
opencodex_process_id=""
opencodex_port=""
opencodex_log_file=""
opencodex_migration_status="NOT_RUN"
codex_home_directory=""
codex_sqlite_home_directory="${host_codex_home}"
codex_session_store="${host_codex_home}/sessions"
codex_session_sharing="HOST"
codex_app_server_status="NOT_RUN"
codex_app_server_process_id=""
container_instance_name=""
container_instance_process_id=""
opencodex_startup_timeout_seconds=120
slurm_binary_directory=""
host_path_prefix=""
desktop_profile_source="${release_directory}/configure_desktop.sh"
macos_shortcut_source="${release_directory}/macos_shortcut.sh"
desktop_wallpaper_source="${release_directory}/bluehive-aurora.svg"
desktop_profile_launcher="${session_home}/.local/bin/remote-vnc-desktop-profile"
container_desktop_profile_launcher="${container_home}/.local/bin/remote-vnc-desktop-profile"
macos_shortcut_launcher="${session_home}/.local/bin/remote-vnc-macos-shortcut"
desktop_wallpaper_directory="${session_home}/.local/share/backgrounds"
desktop_wallpaper_file="${desktop_wallpaper_directory}/bluehive-aurora.svg"
desktop_profile_autostart_file="${session_home}/.config/autostart/00-remote-vnc-desktop-profile.desktop"
desktop_profile_state_file="${session_home}/.cache/remote-vnc/desktop-profile.env"
desktop_profile_status="NOT_STARTED"
macos_shortcuts_status="NOT_STARTED"

for required_file in \
    "${image_path}" "${matlab_vnc_launcher}" "${environment_common_helpers}" \
    "${opencodex_service_launcher}" "${desktop_profile_source}" \
    "${macos_shortcut_source}" \
    "${desktop_wallpaper_source}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required VNC file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done
for required_executable in \
    "${matlab_vnc_launcher}" "${environment_common_helpers}" \
    "${opencodex_service_launcher}" "${desktop_profile_source}" \
    "${macos_shortcut_source}"; do
    [[ -x "${required_executable}" ]] || {
        printf 'Required VNC helper is not executable: %s\n' \
            "${required_executable}" >&2
        exit 2
    }
done
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
if [[ "${vnc_geometry}" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    vnc_width="${BASH_REMATCH[1]}"
    vnc_height="${BASH_REMATCH[2]}"
else
    printf 'Invalid VNC geometry: %s\n' "${vnc_geometry}" >&2
    exit 2
fi
((vnc_width >= 1024 && vnc_width <= 7680 &&
  vnc_height >= 768 && vnc_height <= 4320)) || {
    printf 'VNC geometry must be between 1024x768 and 7680x4320: %s\n' \
        "${vnc_geometry}" >&2
    exit 2
}
slurm_sbatch_executable="$(bh_env_find_slurm_executable sbatch)" || {
    printf 'Slurm commands are unavailable in the VNC allocation.\n' >&2
    exit 2
}
slurm_binary_directory="$(dirname "${slurm_sbatch_executable}")"
host_path_prefix="${session_home}/.local/bin:${slurm_binary_directory}"

write_status() {
    local status_value="$1"
    local status_file="${job_state_directory}/status"
    local temporary_status_file="${status_file}.tmp.$$"

    printf '%s\n' "${status_value}" > "${temporary_status_file}"
    mv "${temporary_status_file}" "${status_file}"
}

write_matlab_warmup_status() {
    local status_value="$1"
    local temporary_status_file="${matlab_warmup_status_file}.tmp.$$"

    printf '%s\n' "${status_value}" > "${temporary_status_file}"
    mv "${temporary_status_file}" "${matlab_warmup_status_file}"
}

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM

    if [[ -n "${opencodex_service_process_id}" ]] &&
       kill -0 "${opencodex_service_process_id}" 2>/dev/null; then
        kill -TERM "${opencodex_service_process_id}" 2>/dev/null || true
        wait "${opencodex_service_process_id}" 2>/dev/null || true
    fi

    if [[ -n "${gpu_monitor_process_id}" ]] &&
       kill -0 "${gpu_monitor_process_id}" 2>/dev/null; then
        kill -TERM "${gpu_monitor_process_id}" 2>/dev/null || true
        wait "${gpu_monitor_process_id}" 2>/dev/null || true
    fi

    if [[ -n "${matlab_warmup_process_id}" ]] &&
       kill -0 "${matlab_warmup_process_id}" 2>/dev/null; then
        kill -TERM "${matlab_warmup_process_id}" 2>/dev/null || true
        wait "${matlab_warmup_process_id}" 2>/dev/null || true
        write_matlab_warmup_status "STOPPED"
    fi

    if [[ -n "${host_shell_process_id}" ]] &&
       kill -0 "${host_shell_process_id}" 2>/dev/null; then
        kill -TERM "${host_shell_process_id}" 2>/dev/null || true
        wait "${host_shell_process_id}" 2>/dev/null || true
    fi

    if [[ -n "${vnc_process_id}" ]] && kill -0 "${vnc_process_id}" 2>/dev/null; then
        kill -TERM "${vnc_process_id}" 2>/dev/null || true
        wait "${vnc_process_id}" 2>/dev/null || true
    fi

    if [[ -d "${job_state_directory}" ]]; then
        if [[ ${exit_status} -eq 0 ]]; then
            write_status "STOPPED"
        else
            write_status "FAILED:${exit_status}"
        fi
    fi

    exit "${exit_status}"
}

port_is_listening() {
    local requested_port="$1"

    ss -H -ltn | awk -v requested_port="${requested_port}" '
        {
            address = $4
            sub(/^.*:/, "", address)
            if (address == requested_port) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
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

choose_display_number() {
    local display_number
    local candidate_port

    for ((display_number = 41; display_number <= 99; display_number++)); do
        candidate_port=$((5900 + display_number))

        if [[ -e "/tmp/.X${display_number}-lock" ]] ||
           [[ -S "/tmp/.X11-unix/X${display_number}" ]] ||
           port_is_listening "${candidate_port}"; then
            continue
        fi

        printf '%s\n' "${display_number}"
        return 0
    done

    return 1
}

choose_host_shell_port() {
    local candidate_port

    for ((candidate_port = 43000; candidate_port <= 43999; candidate_port++)); do
        if ! port_is_listening "${candidate_port}"; then
            printf '%s\n' "${candidate_port}"
            return 0
        fi
    done

    return 1
}

trap cleanup EXIT INT TERM

bh_env_load_apptainer || {
    printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
    exit 2
}
apptainer_executable="$(command -v apptainer)"

mkdir -p \
    "${job_state_directory}" \
    "${host_shell_directory}" \
    "${session_home}/.config/tigervnc" \
    "${session_home}/.config/autostart" \
    "${session_home}/.config/xfce4" \
    "${xfce_terminal_config_directory}" \
    "${session_home}/.local/bin" \
    "${session_home}/.local/share/applications" \
    "${desktop_wallpaper_directory}" \
    "${session_home}/.local/share/xfce4/helpers" \
    "${session_home}/.ssh" \
    "${session_home}/Desktop" \
    "${runtime_directory}/runtime"
chmod 700 "${state_directory}" "${job_state_directory}" "${host_shell_directory}" \
    "${session_home}" \
    "${session_home}/.config" "${session_home}/.config/tigervnc" \
    "${session_home}/.config/autostart" "${session_home}/.config/xfce4" \
    "${xfce_terminal_config_directory}" \
    "${session_home}/.local" "${session_home}/.local/bin" \
    "${session_home}/.local/share" "${session_home}/.local/share/applications" \
    "${desktop_wallpaper_directory}" \
    "${session_home}/.local/share/xfce4" "${session_home}/.local/share/xfce4/helpers" \
    "${session_home}/.ssh" "${session_home}/Desktop" \
    "${runtime_directory}" "${runtime_directory}/runtime"

if [[ ! -s "${plain_password_file}" ]]; then
    openssl rand -hex 4 > "${plain_password_file}"
fi
chmod 600 "${plain_password_file}"

display_number="$(choose_display_number)" || {
    printf 'No free VNC display found in the range :41-:99\n' >&2
    exit 3
}
vnc_port=$((5900 + display_number))
display_value=":${display_number}"
host_shell_port="$(choose_host_shell_port)" || {
    printf 'No free host-shell port found in the range 43000-43999\n' >&2
    exit 3
}
vnc_config_directory="${session_home}/.config/tigervnc"
vnc_config_file="${vnc_config_directory}/config"
vnc_password_file="${vnc_config_directory}/passwd"
host_shell_server_key="${host_shell_directory}/server-key"
host_shell_client_key="${session_home}/.ssh/bluehive-host-shell"
host_shell_known_hosts="${session_home}/.ssh/known_hosts"
host_shell_entry_script="${host_shell_directory}/entry.sh"
host_shell_rc_file="${host_shell_directory}/bashrc"
bluehive_shell_client="${session_home}/.local/bin/bluehive-host-shell"
bluehive_terminal_launcher="${session_home}/.local/bin/bluehive-terminal"
environment_shell_launcher="${session_home}/.local/bin/bh-env-shell-terminal"
container_environment_shell_launcher="${container_home}/.local/bin/bh-env-shell-terminal"
environment_admin_launcher="${session_home}/.local/bin/bh-env-admin-terminal"
environment_matlab_launcher="${session_home}/.local/bin/bh-env-matlab"
container_environment_matlab_launcher="${container_home}/.local/bin/bh-env-matlab"

desktop_profile_temporary_file="${desktop_profile_launcher}.tmp.$$"
cp "${desktop_profile_source}" "${desktop_profile_temporary_file}"
chmod 700 "${desktop_profile_temporary_file}"
mv "${desktop_profile_temporary_file}" "${desktop_profile_launcher}"
macos_shortcut_temporary_file="${macos_shortcut_launcher}.tmp.$$"
cp "${macos_shortcut_source}" "${macos_shortcut_temporary_file}"
chmod 700 "${macos_shortcut_temporary_file}"
mv "${macos_shortcut_temporary_file}" "${macos_shortcut_launcher}"
desktop_wallpaper_temporary_file="${desktop_wallpaper_file}.tmp.$$"
cp "${desktop_wallpaper_source}" "${desktop_wallpaper_temporary_file}"
chmod 600 "${desktop_wallpaper_temporary_file}"
mv "${desktop_wallpaper_temporary_file}" "${desktop_wallpaper_file}"
{
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\n'
    printf 'Type=Application\n'
    printf 'Name=Remote VNC Desktop Profile\n'
    printf 'Comment=Apply the persistent macOS-inspired XFCE profile\n'
    printf 'Exec=%s apply\n' "${container_desktop_profile_launcher}"
    printf 'OnlyShowIn=XFCE;\n'
    printf 'NoDisplay=true\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
} > "${desktop_profile_autostart_file}"
chmod 600 "${desktop_profile_autostart_file}"
rm -f "${desktop_profile_state_file}"

if [[ "${environment_mode}" == "mutable" ]]; then
    matlab_vnc_target="${environment_name}"
else
    matlab_vnc_target="--host"
fi

gpu_requested="false"
gpu_model_name=""
allocated_gpu_identifier=""
if [[ -n "${SLURM_JOB_GPUS:-}" ]] ||
   [[ -n "${CUDA_VISIBLE_DEVICES:-}" && "${CUDA_VISIBLE_DEVICES}" != "NoDevFiles" ]]; then
    gpu_requested="true"
    allocated_gpu_identifier="${CUDA_VISIBLE_DEVICES:-${SLURM_JOB_GPUS}}"
    allocated_gpu_identifier="${allocated_gpu_identifier%%,*}"
    gpu_model_name="$(
        nvidia-smi \
            --id="${allocated_gpu_identifier}" \
            --query-gpu=name \
            --format=csv,noheader |
            head -n 1
    )"
    [[ "${gpu_model_name}" == "NVIDIA A40" ]] || {
        printf 'Expected NVIDIA A40, found %s on GPU %s.\n' \
            "${gpu_model_name:-unknown}" "${allocated_gpu_identifier}" >&2
        exit 4
    }

    printf 'timestamp,index,name,uuid,utilization_gpu_percent,memory_used_mib,memory_total_mib\n' \
        > "${gpu_log_file}"
    (
        while true; do
            nvidia-smi \
                --id="${allocated_gpu_identifier}" \
                --query-gpu=timestamp,index,name,uuid,utilization.gpu,memory.used,memory.total \
                --format=csv,noheader,nounits \
                >> "${gpu_log_file}" 2>/dev/null || true
            sleep 60
        done
    ) &
    gpu_monitor_process_id=$!
    printf '%s\n' "${gpu_monitor_process_id}" \
        > "${job_state_directory}/gpu-monitor-process-id"
fi

container_options=()
bh_env_append_runtime_options \
    container_options "${session_home}" "${runtime_directory}/runtime" \
    "${display_value}" normal
container_options+=(
    --env "BH_ENV_NAME=${environment_name}"
    --env "BH_ENV_GENERATION=${environment_generation}"
    --env "XAUTHORITY=${container_home}/.Xauthority"
)

if ! "${apptainer_executable}" "${container_options[@]}" "${image_path}" \
    "${container_desktop_profile_launcher}" prepare; then
    printf 'WhiteSur theme preparation failed; continuing with the XFCE fallback theme.\n' \
        >&2
fi

matlab_warmup_available=false
matlab_warmup_command=(ionice -c 3 nice -n 10)
if [[ "${environment_mode}" == "mutable" ]] &&
   "${apptainer_executable}" "${container_options[@]}" "${image_path}" \
       test -x "${matlab_executable}"; then
    matlab_warmup_available=true
    matlab_warmup_command+=(
        "${apptainer_executable}" "${container_options[@]}" "${image_path}"
    )
elif [[ "${environment_mode}" == "immutable" ]]; then
    matlab_executable="/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2025b/bin/matlab"
    [[ -x "${matlab_executable}" ]] && matlab_warmup_available=true
fi

if [[ "${matlab_warmup_available}" == "true" ]]; then
    matlab_warmup_status="RUNNING"
    write_matlab_warmup_status "${matlab_warmup_status}"
    (
        set +e
        warmup_start_nanoseconds="$(date +%s%N)"
        printf 'MATLAB_WARMUP_BEGIN %s\n' "$(date --iso-8601=seconds)"
        timeout 180 "${matlab_warmup_command[@]}" \
            env -u DISPLAY -u XAUTHORITY \
            "${matlab_executable}" -batch 'disp("MATLAB_WARMUP_READY")'
        warmup_exit_status=$?
        warmup_end_nanoseconds="$(date +%s%N)"
        awk \
            -v start="${warmup_start_nanoseconds}" \
            -v end="${warmup_end_nanoseconds}" \
            -v status="${warmup_exit_status}" \
            'BEGIN {printf "MATLAB_WARMUP_WALL=%.3f STATUS=%d\n", (end-start)/1000000000, status}'
        if [[ ${warmup_exit_status} -eq 0 ]]; then
            write_matlab_warmup_status "PASSED"
        else
            write_matlab_warmup_status "FAILED:${warmup_exit_status}"
        fi
        exit 0
    ) > "${matlab_warmup_log_file}" 2>&1 &
    matlab_warmup_process_id=$!
else
    printf 'MATLAB executable is missing in %s: %s\n' \
        "${environment_name}" "${matlab_executable}" \
        > "${matlab_warmup_log_file}"
    matlab_warmup_status="MISSING"
    write_matlab_warmup_status "${matlab_warmup_status}"
fi

"${apptainer_executable}" "${container_options[@]}" "${image_path}" \
    /usr/bin/vncpasswd -f < "${plain_password_file}" > "${vnc_password_file}"
chmod 600 "${vnc_password_file}"

{
    printf 'geometry=%s\n' "${vnc_geometry}"
    printf 'depth=24\n'
    printf 'rfbport=%s\n' "${vnc_port}"
    printf 'interface=127.0.0.1\n'
    printf 'securitytypes=VncAuth\n'
    printf 'session=xfce\n'
    printf 'localhost\n'
    printf 'alwaysshared\n'
    printf 'acceptcuttext=1\n'
    printf 'sendcuttext=1\n'
    printf 'sendprimary=1\n'
    printf 'setprimary=1\n'
    printf 'maxcuttext=1048576\n'
    printf 'acceptsetdesktopsize=1\n'
    # TigerVNC intentionally sends the Mac left Command key as Alt_L and the
    # right Command key as Super_L. Normalize both to Super_L before X11 sees
    # them so application shortcuts behave identically and Alt+V cannot open
    # the terminal's View menu.
    printf 'remapkeys=0xffe9->0xffeb\n'
    printf 'useblacklist=1\n'
} > "${vnc_config_file}"
chmod 600 "${vnc_config_file}"

if [[ ! -s "${host_shell_server_key}" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "${host_shell_server_key}"
fi
if [[ ! -s "${host_shell_client_key}" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "${host_shell_client_key}"
fi
chmod 600 "${host_shell_server_key}" "${host_shell_client_key}"
chmod 644 "${host_shell_server_key}.pub" "${host_shell_client_key}.pub"

host_shell_public_key="$(ssh-keygen -y -f "${host_shell_server_key}")"
printf '[127.0.0.1]:%s %s\n' \
    "${host_shell_port}" "${host_shell_public_key}" > "${host_shell_known_hosts}"
chmod 600 "${host_shell_known_hosts}"

{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'export DISPLAY=%q\n' "${display_value}"
    printf 'export XAUTHORITY=%q\n' "${session_home}/.Xauthority"
    printf 'export BH_ENV_NAME=%q\n' "${environment_name}"
    printf 'export CODEX_HOME=%q\n' "${host_codex_home}"
    printf 'export CODEX_SQLITE_HOME=%q\n' "${host_codex_home}"
    printf 'export PATH=%q:"${HOME}/.local/bin:${PATH}"\n' \
        "${host_path_prefix}"
    printf 'matlab-vnc() { %q %q "$@"; }\n' \
        "${matlab_vnc_launcher}" "${matlab_vnc_target}"
    printf 'export -f matlab-vnc\n'
    for slurm_variable_name in \
        CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES \
        SLURM_CLUSTER_NAME SLURM_CPUS_PER_TASK SLURM_JOB_ACCOUNT SLURM_JOB_ID \
        SLURM_JOB_GPUS SLURM_JOB_NAME SLURM_JOB_NODELIST SLURM_JOB_PARTITION \
        SLURM_GPUS SLURM_GPUS_ON_NODE SLURM_MEM_PER_NODE SLURM_STEP_GPUS \
        SLURM_SUBMIT_DIR SLURM_TMPDIR; do
        if [[ -n "${!slurm_variable_name:-}" ]]; then
            printf 'export %s=%q\n' \
                "${slurm_variable_name}" "${!slurm_variable_name}"
        fi
    done
    printf 'if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then\n'
    printf '    exec /bin/bash -c %q -- "${SSH_ORIGINAL_COMMAND}" %q %q %q\n' \
        'source /etc/profile 2>/dev/null || true; export PATH="$2:${HOME}/.local/bin:${PATH}"; export CODEX_HOME="$3"; export CODEX_SQLITE_HOME="$4"; eval "$1"' \
        "${host_path_prefix}" "${host_codex_home}" "${host_codex_home}"
    printf 'fi\n'
    printf 'exec /bin/bash --rcfile %q -i\n' "${host_shell_rc_file}"
} > "${host_shell_entry_script}"
chmod 700 "${host_shell_entry_script}"

{
    printf '[[ -r /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh 2>/dev/null || true\n'
    printf '[[ -r /etc/bashrc ]] && source /etc/bashrc\n'
    printf '[[ -r "${HOME}/.bashrc" ]] && source "${HOME}/.bashrc"\n'
    printf 'export DISPLAY=%q\n' "${display_value}"
    printf 'export XAUTHORITY=%q\n' "${session_home}/.Xauthority"
    printf 'export BH_ENV_NAME=%q\n' "${environment_name}"
    printf 'export CODEX_HOME=%q\n' "${host_codex_home}"
    printf 'export CODEX_SQLITE_HOME=%q\n' "${host_codex_home}"
    printf 'export PATH=%q:"${HOME}/.local/bin:${PATH}"\n' \
        "${host_path_prefix}"
    printf 'matlab-vnc() { %q %q "$@"; }\n' \
        "${matlab_vnc_launcher}" "${matlab_vnc_target}"
    for slurm_variable_name in \
        CUDA_VISIBLE_DEVICES NVIDIA_VISIBLE_DEVICES \
        SLURM_CLUSTER_NAME SLURM_CPUS_PER_TASK SLURM_JOB_ACCOUNT SLURM_JOB_ID \
        SLURM_JOB_GPUS SLURM_JOB_NAME SLURM_JOB_NODELIST SLURM_JOB_PARTITION \
        SLURM_GPUS SLURM_GPUS_ON_NODE SLURM_MEM_PER_NODE SLURM_STEP_GPUS \
        SLURM_SUBMIT_DIR SLURM_TMPDIR; do
        if [[ -n "${!slurm_variable_name:-}" ]]; then
            printf 'export %s=%q\n' \
                "${slurm_variable_name}" "${!slurm_variable_name}"
        fi
    done
    printf 'cd "${HOME}"\n'
} > "${host_shell_rc_file}"
chmod 600 "${host_shell_rc_file}"

{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'ssh_tty_option=-T\n'
    printf 'if [[ -t 0 && -t 1 ]]; then\n'
    printf '    ssh_tty_option=-tt\n'
    printf 'fi\n'
    printf 'exec /host/lib64/ld-linux-x86-64.so.2 \\\n'
    printf '    --library-path /host/lib64:/host/usr/lib64 \\\n'
    printf '    /host/usr/bin/ssh "${ssh_tty_option}" \\\n'
    printf '    -i %q \\\n' "${container_home}/.ssh/bluehive-host-shell"
    printf '    -p %q \\\n' "${host_shell_port}"
    printf '    -o BatchMode=yes \\\n'
    printf '    -o IdentitiesOnly=yes \\\n'
    printf '    -o StrictHostKeyChecking=yes \\\n'
    printf '    -o UserKnownHostsFile=%q \\\n' "${container_home}/.ssh/known_hosts"
    printf '    -o GlobalKnownHostsFile=/dev/null \\\n'
    printf '    -o LogLevel=ERROR \\\n'
    printf '    %q "$@"\n' "${current_user}@127.0.0.1"
} > "${bluehive_shell_client}"
chmod 700 "${bluehive_shell_client}"

{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'exec /usr/bin/xfce4-terminal --disable-server '
    printf '%q ' "--title=Bluehive Host Terminal"
    printf '%q\n' "--command=${container_home}/.local/bin/bluehive-host-shell"
} > "${bluehive_terminal_launcher}"
chmod 700 "${bluehive_terminal_launcher}"

{
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'exec %q %q --env %q admin\n' \
        "${container_home}/.local/bin/bluehive-host-shell" \
        "${host_home}/.local/bin/bh-env" "${environment_name}"
} > "${environment_admin_launcher}"
chmod 700 "${environment_admin_launcher}"

if [[ "${environment_mode}" == "mutable" ]]; then
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'exec %q %q --env %q shell\n' \
            "${container_home}/.local/bin/bluehive-host-shell" \
            "${host_home}/.local/bin/bh-env" "${environment_name}"
    } > "${environment_shell_launcher}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'exec %q %q --env %q exec -- matlab -desktop\n' \
            "${container_home}/.local/bin/bluehive-host-shell" \
            "${host_home}/.local/bin/bh-env" "${environment_name}"
    } > "${environment_matlab_launcher}"
    chmod 700 "${environment_shell_launcher}" \
        "${environment_matlab_launcher}"

    if [[ ! -e "${xfce_terminal_config_file}" &&
          ! -L "${xfce_terminal_config_file}" ]]; then
        {
            printf '[Configuration]\n'
            printf 'RunCustomCommand=TRUE\n'
            printf 'CustomCommand=%s\n' \
                "${container_environment_shell_launcher}"
        } > "${xfce_terminal_config_file}"
        chmod 600 "${xfce_terminal_config_file}"
    elif [[ -f "${xfce_terminal_config_file}" &&
            ! -L "${xfce_terminal_config_file}" ]] &&
         grep -Fxq 'CustomCommand=/usr/bin/fish -l' \
            "${xfce_terminal_config_file}"; then
        temporary_terminal_config="${xfce_terminal_config_file}.tmp.$$"
        awk -v terminal_command="${container_environment_shell_launcher}" '
            $0 == "CustomCommand=/usr/bin/fish -l" {
                print "CustomCommand=" terminal_command
                next
            }
            { print }
        ' "${xfce_terminal_config_file}" > "${temporary_terminal_config}"
        chmod 600 "${temporary_terminal_config}"
        mv "${temporary_terminal_config}" "${xfce_terminal_config_file}"
    fi
fi

{
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\n'
    printf 'Type=X-XFCE-Helper\n'
    printf 'Name=Bluehive Host Terminal\n'
    printf 'Icon=utilities-terminal\n'
    printf 'X-XFCE-Binaries=bluehive-terminal;\n'
    printf 'X-XFCE-Category=TerminalEmulator\n'
    printf 'X-XFCE-Commands=%%B;\n'
    printf 'X-XFCE-CommandsWithParameter=%%B;\n'
} > "${session_home}/.local/share/xfce4/helpers/bluehive-host-terminal.desktop"

{
    printf 'WebBrowser=debian-sensible-browser\n'
    printf 'MailReader=thunderbird\n'
    printf 'TerminalEmulator=xfce4-terminal\n'
    printf 'FileManager=thunar\n'
} > "${session_home}/.config/xfce4/helpers.rc"

{
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\n'
    printf 'Type=Application\n'
    printf 'Name=Bluehive Host Terminal\n'
    printf 'Comment=Run commands on the Bluehive host\n'
    printf 'Icon=utilities-terminal\n'
    printf 'Exec=%s/.local/bin/bluehive-terminal\n' "${container_home}"
    printf 'Terminal=false\n'
    printf 'Categories=System;TerminalEmulator;\n'
} > "${session_home}/.local/share/applications/bluehive-host-terminal.desktop"
cp "${session_home}/.local/share/applications/bluehive-host-terminal.desktop" \
    "${session_home}/Desktop/Bluehive Host Terminal.desktop"
chmod 700 "${session_home}/Desktop/Bluehive Host Terminal.desktop"

{
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\n'
    printf 'Type=Application\n'
    printf 'Name=Environment Terminal (%s)\n' "${environment_name}"
    printf 'Comment=Open a shell in the persistent Apptainer environment\n'
    printf 'Icon=utilities-terminal\n'
    if [[ "${environment_mode}" == "mutable" ]]; then
        printf 'Exec=/usr/bin/xfce4-terminal --disable-server '
        printf '%s %s\n' "--title=bh-env:${environment_name}" \
            "--command=${container_environment_shell_launcher}"
    else
        printf 'Exec=/usr/bin/xfce4-terminal --disable-server --title=bh-env:%s\n' \
            "${environment_name}"
    fi
    printf 'Terminal=false\n'
    printf 'Categories=System;TerminalEmulator;\n'
} > "${session_home}/.local/share/applications/bh-env-terminal.desktop"
cp "${session_home}/.local/share/applications/bh-env-terminal.desktop" \
    "${session_home}/Desktop/Environment Terminal.desktop"
chmod 700 "${session_home}/Desktop/Environment Terminal.desktop"

if [[ "${environment_mode}" == "mutable" ]]; then
    rm -f \
        "${session_home}/Desktop/MATLAB R2024b.desktop" \
        "${session_home}/Desktop/MATLAB R2026a.desktop"
    {
        printf '[Desktop Entry]\n'
        printf 'Version=1.0\n'
        printf 'Type=Application\n'
        printf 'Name=Environment Admin Terminal\n'
        printf 'Comment=Open a writable fakeroot shell for apt installs\n'
        printf 'Icon=utilities-terminal\n'
        printf 'Exec=%s/.local/bin/bh-env-admin-terminal\n' "${container_home}"
        printf 'Terminal=true\n'
        printf 'Categories=System;TerminalEmulator;\n'
    } > "${session_home}/.local/share/applications/bh-env-admin.desktop"
    cp "${session_home}/.local/share/applications/bh-env-admin.desktop" \
        "${session_home}/Desktop/Environment Admin Terminal.desktop"

    {
        printf '[Desktop Entry]\n'
        printf 'Version=1.0\n'
        printf 'Type=Application\n'
        printf 'Name=Google Chrome\n'
        printf 'Icon=google-chrome\n'
        printf 'Exec=/usr/bin/google-chrome-stable %%U\n'
        printf 'Terminal=false\n'
        printf 'Categories=Network;WebBrowser;\n'
    } > "${session_home}/Desktop/Google Chrome.desktop"

    {
        printf '[Desktop Entry]\n'
        printf 'Version=1.0\n'
        printf 'Type=Application\n'
        printf 'Name=ChatGPT\n'
        printf 'Icon=chatgpt\n'
        printf 'Exec=/usr/bin/chatgpt %%U\n'
        printf 'Terminal=false\n'
        printf 'Categories=Network;Utility;\n'
    } > "${session_home}/Desktop/ChatGPT.desktop"

    {
        printf '[Desktop Entry]\n'
        printf 'Version=1.0\n'
        printf 'Type=Application\n'
        printf 'Name=MATLAB R2025b\n'
        printf 'Icon=matlab\n'
        printf 'Exec=%s\n' "${container_environment_matlab_launcher}"
        printf 'Terminal=false\n'
        printf 'Categories=Development;Science;\n'
    } > "${session_home}/Desktop/MATLAB R2025b.desktop"
    chmod 700 \
        "${session_home}/Desktop/Environment Admin Terminal.desktop" \
        "${session_home}/Desktop/Google Chrome.desktop" \
        "${session_home}/Desktop/ChatGPT.desktop" \
        "${session_home}/Desktop/MATLAB R2025b.desktop"
fi

{
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Name=Bluehive Host Terminal\n'
    printf 'Exec=%s/.local/bin/bluehive-terminal\n' "${container_home}"
    printf 'OnlyShowIn=XFCE;\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
} > "${session_home}/.config/autostart/bluehive-host-terminal.desktop"

ln -sfn /bluehive-home "${session_home}/Desktop/Bluehive Home"
ln -sfn /gpfs/fs1 "${session_home}/Desktop/GPFS fs1"
ln -sfn /gpfs/fs2 "${session_home}/Desktop/GPFS fs2"
ln -sfn /scratch "${session_home}/Desktop/Scratch"

/sbin/sshd -D -e -f /dev/null \
    -o "Port=${host_shell_port}" \
    -o ListenAddress=127.0.0.1 \
    -o "HostKey=${host_shell_server_key}" \
    -o "AuthorizedKeysFile=${host_shell_client_key}.pub" \
    -o "AllowUsers=${current_user}" \
    -o "ForceCommand=${host_shell_entry_script}" \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ChallengeResponseAuthentication=no \
    -o UsePAM=no \
    -o StrictModes=no \
    -o X11Forwarding=no \
    -o AllowTcpForwarding=no \
    -o PermitTunnel=no \
    -o GatewayPorts=no \
    -o PermitUserEnvironment=no \
    -o "PidFile=${host_shell_directory}/sshd.pid" \
    > "${host_shell_log_file}" 2>&1 &
host_shell_process_id=$!
printf '%s\n' "${host_shell_process_id}" \
    > "${host_shell_directory}/sshd-process-id"

host_shell_ready=false
for ((attempt_number = 1; attempt_number <= 30; attempt_number++)); do
    if ! kill -0 "${host_shell_process_id}" 2>/dev/null; then
        printf 'Host-shell SSH process exited before opening port %s.\n' \
            "${host_shell_port}" >&2
        sed -n '1,200p' "${host_shell_log_file}" >&2 || true
        exit 4
    fi

    if port_is_listening "${host_shell_port}"; then
        host_shell_ready=true
        break
    fi
    sleep 1
done

if [[ "${host_shell_ready}" != "true" ]]; then
    printf 'Host-shell SSH process did not open port %s within 30 seconds.\n' \
        "${host_shell_port}" >&2
    sed -n '1,200p' "${host_shell_log_file}" >&2 || true
    exit 5
fi

write_status "STARTING"
printf '%s\n' "${display_number}" > "${job_state_directory}/display-number"
printf '%s\n' "${vnc_port}" > "${job_state_directory}/vnc-port"
printf '%s\n' "${host_shell_port}" > "${job_state_directory}/host-shell-port"

"${apptainer_executable}" "${container_options[@]}" "${image_path}" \
    /usr/bin/vncserver "${display_value}" > "${vnc_log_file}" 2>&1 &
vnc_process_id=$!
printf '%s\n' "${vnc_process_id}" > "${job_state_directory}/vnc-process-id"

listener_ready=false
for ((attempt_number = 1; attempt_number <= 60; attempt_number++)); do
    if ! kill -0 "${vnc_process_id}" 2>/dev/null; then
        printf 'VNC process exited before opening port %s.\n' "${vnc_port}" >&2
        sed -n '1,240p' "${vnc_log_file}" >&2 || true
        exit 4
    fi

    if port_is_listening "${vnc_port}"; then
        listener_ready=true
        break
    fi
    sleep 1
done

if [[ "${listener_ready}" != "true" ]]; then
    printf 'VNC process did not open port %s within 60 seconds.\n' \
        "${vnc_port}" >&2
    sed -n '1,240p' "${vnc_log_file}" >&2 || true
    exit 5
fi

listener_addresses="$(
    ss -H -ltn | awk -v requested_port="${vnc_port}" '
        {
            address = $4
            port = address
            sub(/^.*:/, "", port)
            if (port == requested_port) {
                print address
            }
        }
    '
)"

if grep -Evq '^(127\.0\.0\.1|\[::1\]):' <<< "${listener_addresses}"; then
    printf 'VNC listener is not restricted to loopback: %s\n' \
        "${listener_addresses}" >&2
    exit 6
fi

read_vnc_parameter() {
    local parameter_name="$1"

    "${apptainer_executable}" "${container_options[@]}" "${image_path}" \
        /usr/bin/vncconfig -display "${display_value}" \
        -get "${parameter_name}" 2>/dev/null |
        awk '
            NF {
                parameter_value = $0
                sub(/^[^=:]*[=:][[:space:]]*/, "", parameter_value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", parameter_value)
                parameter_value = tolower(parameter_value)
                if (parameter_value == "on" || parameter_value == "true" ||
                    parameter_value == "yes") {
                    parameter_value = "1"
                } else if (parameter_value == "off" ||
                           parameter_value == "false" ||
                           parameter_value == "no") {
                    parameter_value = "0"
                }
                print parameter_value
                exit
            }
        '
}

for vnc_parameter_expectation in \
    AcceptCutText=1 \
    SendCutText=1 \
    SendPrimary=1 \
    SetPrimary=1 \
    MaxCutText=1048576 \
    AcceptSetDesktopSize=1 \
    'RemapKeys=0xffe9->0xffeb' \
    UseBlacklist=1; do
    vnc_parameter_name="${vnc_parameter_expectation%%=*}"
    expected_vnc_parameter_value="${vnc_parameter_expectation#*=}"
    actual_vnc_parameter_value="$(
        read_vnc_parameter "${vnc_parameter_name}" || true
    )"
    [[ "${actual_vnc_parameter_value}" == \
       "${expected_vnc_parameter_value}" ]] || {
        printf 'VNC parameter %s is %s; expected %s.\n' \
            "${vnc_parameter_name}" \
            "${actual_vnc_parameter_value:-unavailable}" \
            "${expected_vnc_parameter_value}" >&2
        exit 6
    }
done

for ((attempt_number = 1; attempt_number <= 45; attempt_number++)); do
    desktop_profile_status="$(
        read_state_value "${desktop_profile_state_file}" STATUS || true
    )"
    desktop_profile_job_id="$(
        read_state_value "${desktop_profile_state_file}" JOB_ID || true
    )"
    macos_shortcuts_status="$(
        read_state_value "${desktop_profile_state_file}" \
            MACOS_SHORTCUTS || true
    )"
    if [[ "${desktop_profile_job_id}" == "${job_id}" ]] &&
       [[ "${desktop_profile_status}" == "READY" ||
          "${desktop_profile_status}" == "READY_REUSED" ]]; then
        break
    fi
    if [[ "${desktop_profile_job_id}" == "${job_id}" &&
          "${desktop_profile_status}" == FAILED_* ]]; then
        break
    fi
    sleep 1
done
if [[ "${desktop_profile_job_id:-}" != "${job_id}" ]] ||
   [[ "${desktop_profile_status}" != "READY" &&
      "${desktop_profile_status}" != "READY_REUSED" ]]; then
    printf 'Desktop profile did not report ready for Job %s (status=%s).\n' \
        "${job_id}" "${desktop_profile_status:-unavailable}" >&2
fi

if [[ "${environment_mode}" == "mutable" ]]; then
    write_status "STARTING_OPENCODEX"
    mkdir -p "${opencodex_service_directory}"
    chmod 700 "${opencodex_service_directory}"
    "${opencodex_service_launcher}" \
        "${release_directory}" \
        "${user_service_directory}" \
        "${image_path}" \
        "${session_home}" \
        "${environment_name}" \
        "${opencodex_startup_timeout_seconds}" &
    opencodex_service_process_id=$!
    printf '%s\n' "${opencodex_service_process_id}" \
        > "${opencodex_service_directory}/launcher-process-id"

    opencodex_ready=false
    for ((attempt_number = 1;
          attempt_number <= opencodex_startup_timeout_seconds + 120;
          attempt_number++)); do
        if ! kill -0 "${opencodex_service_process_id}" 2>/dev/null; then
            opencodex_exit_status=0
            wait "${opencodex_service_process_id}" || opencodex_exit_status=$?
            opencodex_service_process_id=""
            printf 'OpenCodex service exited before becoming ready with status %s.\n' \
                "${opencodex_exit_status}" >&2
            sed -n '1,240p' "${opencodex_service_log_file}" >&2 || true
            exit 7
        fi

        if [[ "$(read_state_value "${opencodex_service_state_file}" STATUS || true)" == \
              "READY" ]] &&
           [[ "$(read_state_value "${opencodex_service_state_file}" JOB_ID || true)" == \
              "${job_id}" ]]; then
            opencodex_ready=true
            break
        fi
        sleep 1
    done
    [[ "${opencodex_ready}" == "true" ]] || {
        printf 'OpenCodex did not become ready within %s seconds.\n' \
            "$((opencodex_startup_timeout_seconds + 120))" >&2
        sed -n '1,240p' "${opencodex_service_log_file}" >&2 || true
        exit 7
    }

    opencodex_status="READY"
    opencodex_process_id="$(
        read_state_value "${opencodex_service_state_file}" OPENCODEX_PID
    )"
    opencodex_port="$(
        read_state_value "${opencodex_service_state_file}" OPENCODEX_PORT
    )"
    opencodex_log_file="$(
        read_state_value "${opencodex_service_state_file}" OPENCODEX_LOG
    )"
    opencodex_migration_status="$(
        read_state_value "${opencodex_service_state_file}" MIGRATION_STATUS
    )"
    codex_home_directory="$(
        read_state_value "${opencodex_service_state_file}" CODEX_HOME
    )"
    codex_sqlite_home_directory="$(
        read_state_value "${opencodex_service_state_file}" CODEX_SQLITE_HOME
    )"
    codex_session_store="$(
        read_state_value "${opencodex_service_state_file}" CODEX_SESSION_STORE
    )"
    codex_session_sharing="$(
        read_state_value "${opencodex_service_state_file}" CODEX_SESSION_SHARING
    )"
    codex_app_server_status="$(
        read_state_value \
            "${opencodex_service_state_file}" CODEX_APP_SERVER_STATUS
    )"
    codex_app_server_process_id="$(
        read_state_value \
            "${opencodex_service_state_file}" CODEX_APP_SERVER_PID
    )"
    container_instance_name="$(
        read_state_value \
            "${opencodex_service_state_file}" CONTAINER_INSTANCE_NAME
    )"
    container_instance_process_id="$(
        read_state_value \
            "${opencodex_service_state_file}" CONTAINER_INSTANCE_PID
    )"
    [[ "${opencodex_process_id}" =~ ^[0-9]+$ &&
       "${opencodex_port}" =~ ^[0-9]+$ &&
       "${codex_app_server_status}" == "running" &&
       "${codex_app_server_process_id}" =~ ^[0-9]+$ &&
       "${container_instance_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
       "${container_instance_process_id}" =~ ^[0-9]+$ ]] || {
        printf 'OpenCodex returned incomplete service state.\n' >&2
        exit 7
    }
fi

connection_temporary_file="${connection_file}.tmp.${job_id}"
{
    printf 'STATUS=READY\n'
    printf 'JOB_ID=%s\n' "${job_id}"
    printf 'NODE=%s\n' "$(hostname -s)"
    printf 'DISPLAY=%s\n' "${display_value}"
    printf 'VNC_PORT=%s\n' "${vnc_port}"
    printf 'VNC_GEOMETRY=%s\n' "${vnc_geometry}"
    printf 'VNC_CLIPBOARD=ENABLED\n'
    printf 'VNC_MACOS_COMMAND_REMAP=ALT_L_TO_SUPER_L\n'
    printf 'VNC_SCREEN_SHARING_COMPATIBILITY=RFB_3_8_VNC_AUTH\n'
    printf 'VNC_PASSWORD_FILE=%s\n' "${plain_password_file}"
    printf 'VNC_LOG=%s\n' "${vnc_log_file}"
    printf 'DESKTOP_PROFILE_STATUS=%s\n' "${desktop_profile_status}"
    printf 'MACOS_SHORTCUTS_STATUS=%s\n' "${macos_shortcuts_status:-UNAVAILABLE}"
    printf 'DESKTOP_PROFILE_STATE=%s\n' "${desktop_profile_state_file}"
    printf 'HOST_SHELL_PORT=%s\n' "${host_shell_port}"
    printf 'HOST_SHELL_LOG=%s\n' "${host_shell_log_file}"
    printf 'HOST_SHELL_CLIENT_KEY=%s\n' "${host_shell_client_key}"
    printf 'MATLAB_VNC_LAUNCHER=%s\n' "${matlab_vnc_launcher}"
    printf 'MATLAB_WARMUP_MODE=BACKGROUND\n'
    printf 'MATLAB_WARMUP_STATUS=%s\n' "${matlab_warmup_status}"
    printf 'MATLAB_WARMUP_STATUS_FILE=%s\n' "${matlab_warmup_status_file}"
    printf 'MATLAB_WARMUP_LOG=%s\n' "${matlab_warmup_log_file}"
    printf 'GPU_REQUESTED=%s\n' "${gpu_requested}"
    printf 'GPU_MODEL=%s\n' "${gpu_model_name}"
    printf 'GPU_LOG=%s\n' "${gpu_log_file}"
    printf 'CUDA_VISIBLE_DEVICES=%s\n' "${CUDA_VISIBLE_DEVICES:-}"
    printf 'SLURM_JOB_GPUS=%s\n' "${SLURM_JOB_GPUS:-}"
    printf 'IMAGE=%s\n' "${image_path}"
    printf 'ENVIRONMENT_NAME=%s\n' "${environment_name}"
    printf 'ENVIRONMENT_MODE=%s\n' "${environment_mode}"
    printf 'ENVIRONMENT_GENERATION=%s\n' "${environment_generation}"
    printf 'ENVIRONMENT_HOME=%s\n' "${session_home}"
    printf 'CONTAINER_INSTANCE_NAME=%s\n' "${container_instance_name}"
    printf 'CONTAINER_INSTANCE_PID=%s\n' \
        "${container_instance_process_id}"
    printf 'OPENCODEX_STATUS=%s\n' "${opencodex_status}"
    printf 'OPENCODEX_PID=%s\n' "${opencodex_process_id}"
    printf 'OPENCODEX_PORT=%s\n' "${opencodex_port}"
    printf 'OPENCODEX_LOG=%s\n' "${opencodex_log_file}"
    printf 'OPENCODEX_MIGRATION_STATUS=%s\n' \
        "${opencodex_migration_status}"
    printf 'CODEX_HOME=%s\n' "${codex_home_directory}"
    printf 'CODEX_SQLITE_HOME=%s\n' "${codex_sqlite_home_directory}"
    printf 'CODEX_SESSION_STORE=%s\n' "${codex_session_store}"
    printf 'CODEX_SESSION_SHARING=%s\n' "${codex_session_sharing}"
    printf 'CODEX_APP_SERVER_STATUS=%s\n' "${codex_app_server_status}"
    printf 'CODEX_APP_SERVER_PID=%s\n' \
        "${codex_app_server_process_id}"
    printf 'STARTED_AT=%s\n' "$(date --iso-8601=seconds)"
} > "${connection_temporary_file}"
mv "${connection_temporary_file}" "${connection_file}"

write_status "READY"
printf 'READY\n' > "${job_state_directory}/READY"

printf 'VNC_READY job=%s node=%s display=%s port=%s geometry=%s desktop=%s shortcuts=%s\n' \
    "${job_id}" "$(hostname -s)" "${display_value}" "${vnc_port}" \
    "${vnc_geometry}" "${desktop_profile_status}" \
    "${macos_shortcuts_status:-UNAVAILABLE}"
printf 'Password file: %s\n' "${plain_password_file}"
printf 'VNC log: %s\n' "${vnc_log_file}"
printf 'Host-shell port: %s\n' "${host_shell_port}"
printf 'Host-shell log: %s\n' "${host_shell_log_file}"
printf 'Environment: %s (%s, %s)\n' \
    "${environment_name}" "${environment_mode}" "${environment_generation}"
if [[ "${environment_mode}" == "mutable" ]]; then
    printf 'Container service instance: %s (host PID %s)\n' \
        "${container_instance_name}" "${container_instance_process_id}"
    printf 'OpenCodex: ready on port %s (PID %s)\n' \
        "${opencodex_port}" "${opencodex_process_id}"
    printf 'Codex app server: %s (PID %s)\n' \
        "${codex_app_server_status}" "${codex_app_server_process_id}"
fi

while kill -0 "${vnc_process_id}" 2>/dev/null; do
    if [[ "${environment_mode}" == "mutable" ]] &&
       ! kill -0 "${opencodex_service_process_id}" 2>/dev/null; then
        opencodex_exit_status=0
        wait "${opencodex_service_process_id}" || opencodex_exit_status=$?
        opencodex_service_process_id=""
        printf 'OpenCodex service stopped with status %s.\n' \
            "${opencodex_exit_status}" >&2
        if [[ ${opencodex_exit_status} -eq 0 ]]; then
            exit 7
        fi
        exit "${opencodex_exit_status}"
    fi
    sleep 5
done

wait "${vnc_process_id}"
