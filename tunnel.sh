#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

# Set default value.
CLUSTER=bluehive3
PARTITION=doppelbock
CPUS=16
GPUS=1
MEMORY=256
TIME=12
NO_LOG=false
TUNNEL_TOOL=code
ROOT_OVERRIDE=""

usage() {
    echo "Usage: $0 [-a CLUSTER] [-p PARTITION] [-c CPUS] [-g GPUS] [-m MEMORY_GB] [-t HOURS] [-w NODE] [-n] [--tool code|cursor] [--root PATH]"
    echo "Supported clusters: $(cluster_supported_list)"
}

# Iterate options through the case statement.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--partition)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a partition" >&2
                exit 1
            fi
            PARTITION=$2
            shift 2
            ;;
        -a|--cluster)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            fi
            CLUSTER=$2
            shift 2
            ;;
        --cluster=*)
            CLUSTER="${1#*=}"
            shift
            ;;
        -c|--cpus)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a CPU count" >&2
                exit 1
            fi
            CPUS=$2
            shift 2
            ;;
        -g|--gpus)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a GPU count" >&2
                exit 1
            fi
            GPUS=$2
            shift 2
            ;;
        -m|--memory)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a memory value" >&2
                exit 1
            fi
            MEMORY=$2
            shift 2
            ;;
        -t|--time)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a runtime in hours" >&2
                exit 1
            fi
            TIME=$2
            shift 2
            ;;
        -w|--node)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a node name" >&2
                exit 1
            fi
            NODE=$2
            shift 2
            ;;
        -n|--no-log)
            NO_LOG=true
            shift
            ;;
        --tool)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires code or cursor" >&2
                exit 1
            fi
            TUNNEL_TOOL="$2"
            shift 2
            ;;
        --tool=*)
            TUNNEL_TOOL="${1#*=}"
            shift
            ;;
        --code|--vscode)
            TUNNEL_TOOL=code
            shift
            ;;
        --cursor)
            TUNNEL_TOOL=cursor
            shift
            ;;
        -r|--root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a remote path" >&2
                exit 1
            fi
            ROOT_OVERRIDE="$2"
            shift 2
            ;;
        --root=*)
            ROOT_OVERRIDE="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: Unexpected argument '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$TUNNEL_TOOL" in
    code|vscode)
        TUNNEL_TOOL=code
        ;;
    cursor)
        ;;
    *)
        echo "Error: --tool must be code or cursor" >&2
        exit 1
        ;;
esac

echo "CLUSTER: $CLUSTER"
echo "PARTITION: $PARTITION"
echo "CPUS: $CPUS"
echo "GPUS: $GPUS"
echo "MEMORY: $MEMORY"
echo "TIME: $TIME"
echo "NODE: $NODE"
echo "NO_LOG: $NO_LOG"
echo "TUNNEL_TOOL: $TUNNEL_TOOL"

require_cluster "$CLUSTER" || exit 1
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1

echo "HOSTNAME: $HOSTNAME"

source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

if [ -n "$ROOT_OVERRIDE" ]; then
    REMOTE_SHARED_ROOT="$ROOT_OVERRIDE"
    export REMOTE_SHARED_ROOT
fi

echo "REMOTE_SHARED_ROOT: $REMOTE_SHARED_ROOT"

source "$current_path/remote_tools.sh"

if [ "$TUNNEL_TOOL" = "code" ]; then
    ensure_remote_vscode_cli || exit $?
    TUNNEL_BIN="$REMOTE_SHARED_ROOT/code"
    TUNNEL_ENV="VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT=1"
    TUNNEL_NAME="${CLUSTER}V"
else
    ensure_remote_cursor_cli || exit $?
    TUNNEL_BIN="$REMOTE_SHARED_ROOT/cursor"
    TUNNEL_ENV="CURSOR_CLI_DISABLE_KEYCHAIN_ENCRYPT=1"
    TUNNEL_NAME="${CLUSTER}C"
fi

TUNNEL_JOB_NAME="${TUNNEL_TOOL}_tunnel"

ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no "$USER@$HOSTNAME" \
    "REMOTE_USER=$(printf "%q" "$USER") CLUSTER=$(printf "%q" "$CLUSTER") PARTITION=$(printf "%q" "$PARTITION") CPUS=$(printf "%q" "$CPUS") GPUS=$(printf "%q" "$GPUS") MEMORY=$(printf "%q" "$MEMORY") TIME=$(printf "%q" "$TIME") NODE=$(printf "%q" "$NODE") NO_LOG=$(printf "%q" "$NO_LOG") TUNNEL_TOOL=$(printf "%q" "$TUNNEL_TOOL") TUNNEL_BIN=$(printf "%q" "$TUNNEL_BIN") TUNNEL_ENV=$(printf "%q" "$TUNNEL_ENV") TUNNEL_NAME=$(printf "%q" "$TUNNEL_NAME") TUNNEL_JOB_NAME=$(printf "%q" "$TUNNEL_JOB_NAME") bash -s" <<'ENDSSH'
#!/bin/bash
module load gcc 2>/dev/null || true
mkdir -p /home/$USER/logs

if squeue -u "$REMOTE_USER" -O name:32 | grep -q "$TUNNEL_JOB_NAME"; then
    echo "$TUNNEL_TOOL tunnel is already running."
    job=$(squeue -u "$REMOTE_USER" -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
    echo "$job"
else
    echo "Starting $TUNNEL_TOOL tunnel..." > ~/logs/tunnel.log
    srun_args=(-N 1 --ntasks-per-node="$CPUS" -p "$PARTITION" --mem="${MEMORY}g" --gres="gpu:$GPUS" -t "$TIME:00:00" --job-name="$TUNNEL_JOB_NAME")
    if [ -n "$NODE" ]; then
        srun_args+=(-w "$NODE")
    fi
    nohup srun "${srun_args[@]}" env "$TUNNEL_ENV" "$TUNNEL_BIN" tunnel --accept-server-license-terms --verbose --name "$TUNNEL_NAME" > ~/logs/tunnel.log 2>&1 &
fi

if [ "$NO_LOG" = "false" ]; then
    echo "Continuously monitoring tunnel log... Ctrl+C to exit."
    while true; do
        cat ~/logs/tunnel.log
        sleep 5
    done
fi
ENDSSH
