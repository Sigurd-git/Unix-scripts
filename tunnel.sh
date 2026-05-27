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

usage() {
    echo "Usage: $0 [-a CLUSTER] [-p PARTITION] [-c CPUS] [-g GPUS] [-m MEMORY_GB] [-t HOURS] [-w NODE] [-n]"
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

echo "CLUSTER: $CLUSTER"
echo "PARTITION: $PARTITION"
echo "CPUS: $CPUS"
echo "GPUS: $GPUS"
echo "MEMORY: $MEMORY"
echo "TIME: $TIME"
echo "NODE: $NODE"
echo "NO_LOG: $NO_LOG"

require_cluster "$CLUSTER" || exit 1
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1

echo "HOSTNAME: $HOSTNAME"

source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no "$USER@$HOSTNAME" <<ENDSSH
#!/bin/bash
module load gcc
mkdir -p /home/$USER/logs
# Your commands go here
if [ -z "$NODE" ]; then
    if squeue -u $USER -O name:32|grep cursor; then
        echo "Tunnel is already running."
        job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
        echo "\$job"
    else
        echo "Starting tunnel..." > ~/logs/tunnel.log
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --verbose --name ${CLUSTER}C > ~/logs/tunnel.log 2>&1 &
    fi
else
    if squeue -u $USER -O name:32|grep cursor; then
        echo "Tunnel is already running."
        job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
        echo "\$job"
    else
        echo "Starting tunnel..." > ~/logs/tunnel.log
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 -w $NODE /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --verbose --name ${CLUSTER}C > ~/logs/tunnel.log 2>&1 &
    fi
fi
if [ "$NO_LOG" = "false" ]; then
    echo "Continuously monitoring tunnel log... Ctrl+C to exit."
    while true; do
        cat ~/logs/tunnel.log
        sleep 5
    done
fi
ENDSSH
