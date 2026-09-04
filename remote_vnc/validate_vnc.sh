#!/usr/bin/env bash

set -Eeuo pipefail

user_service_directory="${1:?usage: validate_vnc.sh USER_SERVICE_DIRECTORY}"
connection_file="${user_service_directory}/state/connection.env"
current_user="$(id -un)"
current_user_id="$(id -u)"

[[ -s "${connection_file}" ]] || {
    printf 'Missing connection file: %s\n' "${connection_file}" >&2
    exit 2
}

read_connection_value() {
    local requested_key="$1"

    awk -F= -v requested_key="${requested_key}" '
        $1 == requested_key {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "${connection_file}"
}

status_value="$(read_connection_value STATUS)"
job_id="$(read_connection_value JOB_ID)"
node_name="$(read_connection_value NODE)"
display_value="$(read_connection_value DISPLAY)"
vnc_port="$(read_connection_value VNC_PORT)"
password_file="$(read_connection_value VNC_PASSWORD_FILE)"
vnc_log_file="$(read_connection_value VNC_LOG)"
host_shell_port="$(read_connection_value HOST_SHELL_PORT)"
host_shell_log_file="$(read_connection_value HOST_SHELL_LOG)"
host_shell_client_key="$(read_connection_value HOST_SHELL_CLIENT_KEY)"
matlab_vnc_launcher="$(read_connection_value MATLAB_VNC_LAUNCHER)"
matlab_warmup_mode="$(read_connection_value MATLAB_WARMUP_MODE)"
matlab_warmup_status_file="$(read_connection_value MATLAB_WARMUP_STATUS_FILE)"
matlab_warmup_log_file="$(read_connection_value MATLAB_WARMUP_LOG)"
gpu_requested="$(read_connection_value GPU_REQUESTED)"
gpu_model_name="$(read_connection_value GPU_MODEL)"
gpu_log_file="$(read_connection_value GPU_LOG)"
cuda_visible_devices="$(read_connection_value CUDA_VISIBLE_DEVICES)"
image_path="$(read_connection_value IMAGE)"
environment_name="$(read_connection_value ENVIRONMENT_NAME)"
environment_mode="$(read_connection_value ENVIRONMENT_MODE)"
environment_generation="$(read_connection_value ENVIRONMENT_GENERATION)"
environment_home="$(read_connection_value ENVIRONMENT_HOME)"
container_instance_name="$(read_connection_value CONTAINER_INSTANCE_NAME)"
container_instance_process_id="$(read_connection_value CONTAINER_INSTANCE_PID)"
opencodex_status="$(read_connection_value OPENCODEX_STATUS)"
opencodex_process_id="$(read_connection_value OPENCODEX_PID)"
opencodex_port="$(read_connection_value OPENCODEX_PORT)"
opencodex_log_file="$(read_connection_value OPENCODEX_LOG)"
opencodex_migration_status="$(read_connection_value OPENCODEX_MIGRATION_STATUS)"
codex_home_directory="$(read_connection_value CODEX_HOME)"
codex_app_server_status="$(read_connection_value CODEX_APP_SERVER_STATUS)"
codex_app_server_process_id="$(read_connection_value CODEX_APP_SERVER_PID)"

[[ "${status_value}" == "READY" ]] || {
    printf 'VNC status is %s, expected READY.\n' "${status_value}" >&2
    exit 3
}
[[ "${job_id}" =~ ^[0-9]+$ ]] || {
    printf 'Invalid job ID: %s\n' "${job_id}" >&2
    exit 3
}
for port_value in "${vnc_port}" "${host_shell_port}"; do
    [[ "${port_value}" =~ ^[0-9]+$ ]] || {
        printf 'Invalid VNC service port: %s\n' "${port_value}" >&2
        exit 3
    }
done
for required_file in \
    "${password_file}" "${vnc_log_file}" "${host_shell_log_file}" \
    "${host_shell_client_key}" "${matlab_warmup_status_file}"; do
    [[ -s "${required_file}" ]] || {
        printf 'Required VNC state file is missing: %s\n' "${required_file}" >&2
        exit 3
    }
done
[[ -e "${image_path}" ]] || {
    printf 'Environment rootfs or image is missing: %s\n' "${image_path}" >&2
    exit 3
}
[[ "${environment_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Invalid environment name: %s\n' "${environment_name}" >&2
    exit 3
}
[[ "${environment_mode}" == "mutable" ||
   "${environment_mode}" == "immutable" ]] || {
    printf 'Invalid environment mode: %s\n' "${environment_mode}" >&2
    exit 3
}
[[ -d "${environment_home}" ]] || {
    printf 'Environment home is missing: %s\n' "${environment_home}" >&2
    exit 3
}
if [[ "${environment_mode}" == "mutable" ]]; then
    [[ "${container_instance_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
       "${container_instance_process_id}" =~ ^[0-9]+$ ]] || {
        printf 'Apptainer service instance state is invalid: name=%s PID=%s\n' \
            "${container_instance_name:-not set}" \
            "${container_instance_process_id:-not set}" >&2
        exit 3
    }
    [[ "${opencodex_status}" == "READY" ]] || {
        printf 'OpenCodex status is %s, expected READY.\n' \
            "${opencodex_status:-not set}" >&2
        exit 3
    }
    [[ "${opencodex_process_id}" =~ ^[0-9]+$ &&
       "${opencodex_port}" =~ ^[0-9]+$ ]] || {
        printf 'OpenCodex process state is invalid: PID=%s port=%s\n' \
            "${opencodex_process_id:-not set}" \
            "${opencodex_port:-not set}" >&2
        exit 3
    }
    [[ "${codex_app_server_status}" == "running" &&
       "${codex_app_server_process_id}" =~ ^[0-9]+$ ]] || {
        printf 'Codex app-server state is invalid: status=%s PID=%s\n' \
            "${codex_app_server_status:-not set}" \
            "${codex_app_server_process_id:-not set}" >&2
        exit 3
    }
    [[ "${codex_home_directory}" == "${environment_home}/.codex" &&
       -d "${codex_home_directory}" ]] || {
        printf 'Container Codex home is invalid: %s\n' \
            "${codex_home_directory:-not set}" >&2
        exit 3
    }
    [[ -e "${opencodex_log_file}" ]] || {
        printf 'OpenCodex log is missing: %s\n' \
            "${opencodex_log_file:-not set}" >&2
        exit 3
    }
else
    [[ "${opencodex_status}" == "DISABLED_IMMUTABLE" ]] || {
        printf 'Immutable OpenCodex status is invalid: %s\n' \
            "${opencodex_status:-not set}" >&2
        exit 3
    }
fi
[[ -x "${matlab_vnc_launcher}" ]] || {
    printf 'Missing MATLAB VNC launcher: %s\n' "${matlab_vnc_launcher}" >&2
    exit 3
}
[[ "${matlab_warmup_mode}" == "BACKGROUND" ]] || {
    printf 'MATLAB warm-up mode is %s, expected BACKGROUND.\n' \
        "${matlab_warmup_mode:-not set}" >&2
    exit 3
}

matlab_warmup_status="$(head -n 1 "${matlab_warmup_status_file}")"
case "${matlab_warmup_status}" in
    RUNNING)
        [[ -e "${matlab_warmup_log_file}" ]] || {
            printf 'Missing running MATLAB warm-up log: %s\n' \
                "${matlab_warmup_log_file}" >&2
            exit 3
        }
        ;;
    PASSED)
        grep -q '^MATLAB_WARMUP_READY$' "${matlab_warmup_log_file}" || {
            printf 'MATLAB warm-up marker is missing from %s.\n' \
                "${matlab_warmup_log_file}" >&2
            exit 3
        }
        ;;
    MISSING|FAILED:*|STOPPED)
        printf 'MATLAB background warm-up status is %s.\n' \
            "${matlab_warmup_status}" >&2
        ;;
    *)
        printf 'Invalid MATLAB background warm-up status: %s.\n' \
            "${matlab_warmup_status:-not set}" >&2
        exit 3
        ;;
esac

slurm_binary_directory="/sfw/rhel9-x86_64/slurm/24.05.0.b1/bin"
squeue_executable="${slurm_binary_directory}/squeue"
[[ -x "${squeue_executable}" ]] || {
    printf 'Missing Slurm client: %s\n' "${squeue_executable}" >&2
    exit 4
}
job_state="$("${squeue_executable}" -h -j "${job_id}" -o '%T')"
[[ "${job_state}" == "RUNNING" ]] || {
    printf 'Slurm Job %s is %s, expected RUNNING.\n' \
        "${job_id}" "${job_state:-not active}" >&2
    exit 4
}

listener_address="not checked from $(hostname -s)"
host_shell_listener_address="not checked from $(hostname -s)"
host_shell_check="not checked from $(hostname -s)"
host_shell_gpu_check="not checked from $(hostname -s)"
opencodex_runtime_check="not checked from $(hostname -s)"

if [[ "$(hostname -s)" == "${node_name}" ]]; then
    listener_address="$(
        ss -H -ltn | awk -v requested_port="${vnc_port}" '
            {
                address = $4
                port = address
                sub(/^.*:/, "", port)
                if (port == requested_port) { print address; exit }
            }
        '
    )"
    [[ "${listener_address}" == "127.0.0.1:${vnc_port}" ]] || {
        printf 'Unexpected VNC listener address: %s\n' \
            "${listener_address:-not listening}" >&2
        exit 5
    }

    host_shell_listener_address="$(
        ss -H -ltn | awk -v requested_port="${host_shell_port}" '
            {
                address = $4
                port = address
                sub(/^.*:/, "", port)
                if (port == requested_port) { print address; exit }
            }
        '
    )"
    [[ "${host_shell_listener_address}" == "127.0.0.1:${host_shell_port}" ]] || {
        printf 'Unexpected host-shell listener address: %s\n' \
            "${host_shell_listener_address:-not listening}" >&2
        exit 5
    }

    rfb_banner="$(
        timeout 3 bash -c "head -c 12 < /dev/tcp/127.0.0.1/${vnc_port}" \
            2>/dev/null || true
    )"
    [[ "${rfb_banner}" == RFB\ * ]] || {
        printf 'Port %s did not return an RFB banner.\n' "${vnc_port}" >&2
        exit 6
    }

    host_shell_known_hosts="$(dirname "${host_shell_client_key}")/known_hosts"
    host_shell_check="$(
        timeout 10 /usr/bin/ssh \
            -q \
            -i "${host_shell_client_key}" \
            -p "${host_shell_port}" \
            -o BatchMode=yes \
            -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes \
            -o "UserKnownHostsFile=${host_shell_known_hosts}" \
            -o GlobalKnownHostsFile=/dev/null \
            "${current_user}@127.0.0.1" \
            'source /etc/profile.d/modules.sh >/dev/null 2>&1; printf "HOST_SHELL_OK job=%s node=%s display=%s module=%s data=%s matlab_vnc=%s\n" "${SLURM_JOB_ID:-missing}" "$(hostname -s)" "${DISPLAY:-missing}" "$(type -t module || true)" "$(test -d /gpfs/fs2 && printf yes || printf no)" "$(type -t matlab-vnc || true)"' \
            2>/dev/null || true
    )"
    expected_host_shell_check="HOST_SHELL_OK job=${job_id} node=${node_name} display=${display_value} module=function data=yes matlab_vnc=function"
    [[ "${host_shell_check}" == "${expected_host_shell_check}" ]] || {
        printf 'Host-shell validation failed: %s\n' \
            "${host_shell_check:-no response}" >&2
        exit 7
    }

    if [[ "${gpu_requested}" == "true" ]]; then
        [[ -n "${cuda_visible_devices}" && "${gpu_model_name}" == "NVIDIA A40" ]] || {
            printf 'GPU allocation validation failed: visible=%s model=%s\n' \
                "${cuda_visible_devices:-missing}" "${gpu_model_name:-missing}" >&2
            exit 8
        }
        [[ -s "${gpu_log_file}" ]] || {
            printf 'Missing GPU usage log: %s\n' "${gpu_log_file:-missing}" >&2
            exit 8
        }
        host_shell_gpu_check="$(
            timeout 10 /usr/bin/ssh \
                -q \
                -i "${host_shell_client_key}" \
                -p "${host_shell_port}" \
                -o BatchMode=yes \
                -o IdentitiesOnly=yes \
                -o StrictHostKeyChecking=yes \
                -o "UserKnownHostsFile=${host_shell_known_hosts}" \
                -o GlobalKnownHostsFile=/dev/null \
                "${current_user}@127.0.0.1" \
                'gpu_identifier="${CUDA_VISIBLE_DEVICES%%,*}"; gpu_name="$(nvidia-smi --id="${gpu_identifier}" --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1)"; printf "GPU_OK visible=%s allocated=%s name=%s\n" "${CUDA_VISIBLE_DEVICES:-missing}" "${SLURM_JOB_GPUS:-missing}" "${gpu_name:-missing}"' \
                2>/dev/null || true
        )"
        [[ "${host_shell_gpu_check}" == GPU_OK\ visible=*\ allocated=*\ name=NVIDIA\ A40 ]] || {
            printf 'Host-shell GPU validation failed: %s\n' \
                "${host_shell_gpu_check:-no response}" >&2
            exit 8
        }
    fi

    if [[ "${environment_mode}" == "mutable" ]]; then
        [[ -r "/proc/${container_instance_process_id}/cgroup" ]] || {
            printf 'Apptainer service instance PID is unavailable: %s\n' \
                "${container_instance_process_id}" >&2
            exit 9
        }
        container_instance_user_id="$(
            stat -c '%u' "/proc/${container_instance_process_id}" 2>/dev/null || true
        )"
        [[ "${container_instance_user_id}" == "${current_user_id}" ]] || {
            printf 'Apptainer service instance PID %s belongs to UID %s.\n' \
                "${container_instance_process_id}" \
                "${container_instance_user_id:-unknown}" >&2
            exit 9
        }
        container_instance_cgroup="$(
            tr '\n' ';' < "/proc/${container_instance_process_id}/cgroup"
        )"
        [[ "${container_instance_cgroup}" == \
           *"/job_${job_id}/step_batch/"* ]] || {
            printf 'Apptainer service instance is outside Job %s: %s\n' \
                "${job_id}" "${container_instance_cgroup}" >&2
            exit 9
        }

        # shellcheck disable=SC1090
        source "$(dirname "${matlab_vnc_launcher}")/environment_common.sh"
        bh_env_load_apptainer || {
            printf 'Apptainer 1.4.1 could not be loaded.\n' >&2
            exit 9
        }
        for service_process_id in \
            "${opencodex_process_id}" "${codex_app_server_process_id}"; do
            service_process_cgroup="$(
                apptainer exec --cleanenv \
                    "instance://${container_instance_name}" \
                    /bin/bash -c '
                        process_id="$1"
                        [[ -r "/proc/${process_id}/cgroup" ]] || exit 1
                        tr "\n" ";" < "/proc/${process_id}/cgroup"
                    ' -- "${service_process_id}" 2>/dev/null || true
            )"
            [[ -n "${service_process_cgroup}" ]] || {
                printf 'Managed service PID is unavailable in instance %s: %s\n' \
                    "${container_instance_name}" "${service_process_id}" >&2
                exit 9
            }
            [[ "${service_process_cgroup}" == \
               *"/job_${job_id}/step_batch/"* ]] || {
                printf 'Managed service PID %s is outside Job %s: %s\n' \
                    "${service_process_id}" "${job_id}" \
                    "${service_process_cgroup}" >&2
                exit 9
            }
        done

        opencodex_runtime_check="$(
            timeout 20 /usr/bin/ssh \
                -q \
                -i "${host_shell_client_key}" \
                -p "${host_shell_port}" \
                -o BatchMode=yes \
                -o IdentitiesOnly=yes \
                -o StrictHostKeyChecking=yes \
                -o "UserKnownHostsFile=${host_shell_known_hosts}" \
                -o GlobalKnownHostsFile=/dev/null \
                "${current_user}@127.0.0.1" \
                'ocx ready --json | grep -Eq "\"ready\"[[:space:]]*:[[:space:]]*true"; codex app-server daemon version | grep -Eq "\"status\"[[:space:]]*:[[:space:]]*\"running\""; printf OPENCODEX_RUNTIME_OK' \
                2>/dev/null || true
        )"
        [[ "${opencodex_runtime_check}" == "OPENCODEX_RUNTIME_OK" ]] || {
            printf 'OpenCodex container wrapper validation failed: %s\n' \
                "${opencodex_runtime_check:-no response}" >&2
            exit 9
        }

        environment_command_check="$(
            apptainer exec --cleanenv "${image_path}" /bin/bash -c '
                set -eu
                export PATH="/usr/local/cuda/bin:/opt/matlab/R2024b/bin:${PATH}"
                for command_name in gcc g++ node npm ocx codex uv pixi nvcc \
                    google-chrome-stable \
                    chatgpt matlab mpm vncserver; do
                    command -v "${command_name}" >/dev/null
                done
                printf ENVIRONMENT_COMMANDS_OK
            '
        )"
        [[ "${environment_command_check}" == "ENVIRONMENT_COMMANDS_OK" ]] || {
            printf 'Mutable environment command validation failed.\n' >&2
            exit 9
        }
    fi
fi

printf 'VNC validation passed.\n'
printf 'Job: %s (%s)\n' "${job_id}" "${job_state}"
printf 'Node: %s\n' "${node_name}"
printf 'Display: %s\n' "${display_value}"
printf 'Port: %s\n' "${vnc_port}"
printf 'Listener: %s\n' "${listener_address}"
printf 'Host-shell port: %s\n' "${host_shell_port}"
printf 'Host-shell listener: %s\n' "${host_shell_listener_address}"
printf 'Host-shell check: %s\n' "${host_shell_check}"
printf 'GPU requested: %s\n' "${gpu_requested:-false}"
printf 'GPU model: %s\n' "${gpu_model_name:-not set}"
printf 'Host-shell GPU check: %s\n' "${host_shell_gpu_check}"
printf 'Image: %s\n' "${image_path}"
printf 'Environment: %s (%s)\n' "${environment_name}" "${environment_mode}"
printf 'Environment generation: %s\n' "${environment_generation}"
printf 'Environment home: %s\n' "${environment_home}"
printf 'Container service instance: %s (host PID %s)\n' \
    "${container_instance_name:-not set}" \
    "${container_instance_process_id:-not set}"
printf 'OpenCodex: %s (PID %s, port %s)\n' \
    "${opencodex_status}" "${opencodex_process_id:-not set}" \
    "${opencodex_port:-not set}"
printf 'OpenCodex settings migration: %s\n' \
    "${opencodex_migration_status:-not set}"
printf 'Codex app server: %s (PID %s)\n' \
    "${codex_app_server_status:-not set}" \
    "${codex_app_server_process_id:-not set}"
printf 'OpenCodex runtime check: %s\n' "${opencodex_runtime_check}"
printf 'Password file: %s\n' "${password_file}"
