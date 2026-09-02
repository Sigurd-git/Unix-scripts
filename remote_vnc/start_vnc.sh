#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

release_directory="${1:?release directory is required}"
user_service_directory="${2:?user service directory is required}"
image_path="${3:?Apptainer image path is required}"
job_id="${SLURM_JOB_ID:?SLURM_JOB_ID is required}"
current_user="$(id -un)"
host_home="${HOME:?HOME is required}"
state_directory="${user_service_directory}/state"
job_state_directory="${state_directory}/jobs/${job_id}"
session_home="${job_state_directory}/home"
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
matlab_executable="/gpfs/fs1/sfw3/rhel9-x86_64/matlab/r2024b/bin/matlab"
matlab_vnc_launcher="${release_directory}/matlab-vnc.sh"
matlab_warmup_log_file="${job_state_directory}/matlab-warmup.log"
matlab_warmup_status_file="${job_state_directory}/matlab-warmup.status"
matlab_warmup_process_id=""
matlab_warmup_status="NOT_RUN"

for required_file in "${image_path}" "${matlab_vnc_launcher}"; do
    [[ -r "${required_file}" ]] || {
        printf 'Required VNC file is missing: %s\n' "${required_file}" >&2
        exit 2
    }
done
[[ -x "${matlab_vnc_launcher}" ]] || {
    printf 'MATLAB VNC launcher is not executable: %s\n' \
        "${matlab_vnc_launcher}" >&2
    exit 2
}

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

source /etc/profile.d/modules.sh
module purge
module load apptainer/1.4.1
apptainer_executable="$(command -v apptainer)"

mkdir -p \
    "${job_state_directory}" \
    "${host_shell_directory}" \
    "${session_home}/.config/tigervnc" \
    "${session_home}/.config/autostart" \
    "${session_home}/.config/xfce4" \
    "${session_home}/.local/bin" \
    "${session_home}/.local/share/applications" \
    "${session_home}/.local/share/xfce4/helpers" \
    "${session_home}/.ssh" \
    "${session_home}/Desktop" \
    "${runtime_directory}/runtime"
chmod 700 "${state_directory}" "${job_state_directory}" "${host_shell_directory}" \
    "${session_home}" \
    "${session_home}/.config" "${session_home}/.config/tigervnc" \
    "${session_home}/.config/autostart" "${session_home}/.config/xfce4" \
    "${session_home}/.local" "${session_home}/.local/bin" \
    "${session_home}/.local/share" "${session_home}/.local/share/applications" \
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

if [[ -x "${matlab_executable}" ]]; then
    matlab_warmup_status="RUNNING"
    write_matlab_warmup_status "${matlab_warmup_status}"
    (
        set +e
        warmup_start_nanoseconds="$(date +%s%N)"
        printf 'MATLAB_WARMUP_BEGIN %s\n' "$(date --iso-8601=seconds)"
        timeout 180 ionice -c 3 nice -n 10 env -u DISPLAY -u XAUTHORITY \
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
    printf 'MATLAB executable is missing: %s\n' "${matlab_executable}" \
        > "${matlab_warmup_log_file}"
    matlab_warmup_status="MISSING"
    write_matlab_warmup_status "${matlab_warmup_status}"
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

container_options=(exec)
if [[ "${gpu_requested}" == "true" ]]; then
    container_options+=(--nv)
fi
container_options+=(
    --cleanenv
    --home "${session_home}:${container_home}"
    --bind "/:/host:ro"
    --bind "${host_home}:/bluehive-home"
    --bind "/gpfs/fs1:/gpfs/fs1"
    --bind "/gpfs/fs2:/gpfs/fs2"
    --bind "/scratch:/scratch"
    --env "USER=${current_user}"
    --env "LOGNAME=${current_user}"
    --env "XDG_CONFIG_HOME=${container_home}/.config"
    --env "XDG_RUNTIME_DIR=${runtime_directory}/runtime"
    --env "DISPLAY=${display_value}"
    --env "LANG=C.UTF-8"
)

"${apptainer_executable}" "${container_options[@]}" "${image_path}" \
    /usr/bin/vncpasswd -f < "${plain_password_file}" > "${vnc_password_file}"
chmod 600 "${vnc_password_file}"

{
    printf 'geometry=1920x1080\n'
    printf 'depth=24\n'
    printf 'rfbport=%s\n' "${vnc_port}"
    printf 'interface=127.0.0.1\n'
    printf 'securitytypes=VncAuth\n'
    printf 'session=xfce\n'
    printf 'localhost\n'
    printf 'alwaysshared\n'
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
    printf 'matlab-vnc() { %q "$@"; }\n' "${matlab_vnc_launcher}"
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
    printf '    exec /bin/bash -lc "${SSH_ORIGINAL_COMMAND}"\n'
    printf 'fi\n'
    printf 'exec /bin/bash --rcfile %q -i\n' "${host_shell_rc_file}"
} > "${host_shell_entry_script}"
chmod 700 "${host_shell_entry_script}"

{
    printf '[[ -r /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh\n'
    printf '[[ -r /etc/bashrc ]] && source /etc/bashrc\n'
    printf '[[ -r "${HOME}/.bashrc" ]] && source "${HOME}/.bashrc"\n'
    printf 'export DISPLAY=%q\n' "${display_value}"
    printf 'export XAUTHORITY=%q\n' "${session_home}/.Xauthority"
    printf 'matlab-vnc() { %q "$@"; }\n' "${matlab_vnc_launcher}"
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
    printf 'exec /host/lib64/ld-linux-x86-64.so.2 \\\n'
    printf '    --library-path /host/lib64:/host/usr/lib64 \\\n'
    printf '    /host/usr/bin/ssh -tt \\\n'
    printf '    -i %q \\\n' "${container_home}/.ssh/bluehive-host-shell"
    printf '    -p %q \\\n' "${host_shell_port}"
    printf '    -o BatchMode=yes \\\n'
    printf '    -o IdentitiesOnly=yes \\\n'
    printf '    -o StrictHostKeyChecking=yes \\\n'
    printf '    -o UserKnownHostsFile=%q \\\n' "${container_home}/.ssh/known_hosts"
    printf '    -o GlobalKnownHostsFile=/dev/null \\\n'
    printf '    -o LogLevel=ERROR \\\n'
    printf '    %q\n' "${current_user}@127.0.0.1"
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
    printf 'TerminalEmulator=bluehive-host-terminal\n'
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

connection_temporary_file="${connection_file}.tmp.${job_id}"
{
    printf 'STATUS=READY\n'
    printf 'JOB_ID=%s\n' "${job_id}"
    printf 'NODE=%s\n' "$(hostname -s)"
    printf 'DISPLAY=%s\n' "${display_value}"
    printf 'VNC_PORT=%s\n' "${vnc_port}"
    printf 'VNC_PASSWORD_FILE=%s\n' "${plain_password_file}"
    printf 'VNC_LOG=%s\n' "${vnc_log_file}"
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
    printf 'STARTED_AT=%s\n' "$(date --iso-8601=seconds)"
} > "${connection_temporary_file}"
mv "${connection_temporary_file}" "${connection_file}"

write_status "READY"
printf 'READY\n' > "${job_state_directory}/READY"

printf 'VNC_READY job=%s node=%s display=%s port=%s\n' \
    "${job_id}" "$(hostname -s)" "${display_value}" "${vnc_port}"
printf 'Password file: %s\n' "${plain_password_file}"
printf 'VNC log: %s\n' "${vnc_log_file}"
printf 'Host-shell port: %s\n' "${host_shell_port}"
printf 'Host-shell log: %s\n' "${host_shell_log_file}"

wait "${vnc_process_id}"
