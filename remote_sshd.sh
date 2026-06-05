#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

# Set default value.
CLUSTER=bluehive3
PARTITION=doppelbock
CPUS=16
GPUS=1
MEMORY=256
TIME=24
PORT=30022
ROOT_OVERRIDE=""

usage() {
    echo "Usage: $0 [-a CLUSTER] [-p PARTITION] [-c CPUS] [-g GPUS] [-m MEMORY_GB] [-t HOURS] [-w NODE] [--root PATH]"
    echo "Supported clusters: $(cluster_supported_list)"
}

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

echo "CLUSTER: $CLUSTER"
echo "PARTITION: $PARTITION"
echo "CPUS: $CPUS"
echo "GPUS: $GPUS"
echo "MEMORY: $MEMORY"
echo "TIME: $TIME"
echo "NODE: $NODE"
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1
source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

if [ -n "$ROOT_OVERRIDE" ]; then
    REMOTE_SHARED_ROOT="$ROOT_OVERRIDE"
    export REMOTE_SHARED_ROOT
fi

echo "REMOTE_SHARED_ROOT: $REMOTE_SHARED_ROOT"

source "$current_path/remote_tools.sh"
ensure_remote_dropbear || exit $?
DROPBEAR_DIR="$REMOTE_SHARED_ROOT/dropbear"

ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $USER@$HOSTNAME <<ENDSSH
#!/bin/bash
module load gcc 2>/dev/null || true
mkdir -p /home/$USER/logs
# Your commands go here

if squeue -u $USER -O name:32|grep my_sshd; then
    echo "SSHD is already running."
    job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
    echo "\$job"
else
    rm -rf /home/$USER/logs/dropbear.log
    cat <<'INNEREOF' | sbatch
#!/bin/bash
#SBATCH -p $PARTITION -t $TIME:00:00
#SBATCH -c $CPUS
#SBATCH --mem="${MEMORY}G"
#SBATCH --gres=gpu:$GPUS
#SBATCH -o /home/$USER/logs/dropbear.log
#SBATCH --job-name=my_sshd
#SBATCH --mail-type=BEGIN
#SBATCH --mail-user=guoyang_liao@urmc.rochester.edu

cd "$DROPBEAR_DIR"

# Function to check if a port is available using ss command
function check_port_available() {
    local port=\$1
    # Check if the port is in use
    ss -tuln | grep ":\$port " > /dev/null
    if [ \$? -ne 0 ]; then
        return 0  # Port is available
    else
        return 1  # Port is in use
    fi
}

# Find an available port in range 30000-40000
function find_available_port() {
    local port
    # Try up to 50 times to find an available port
    for attempt in {1..50}; do
        # Generate a random port number between 30000 and 40000
        port=\$((30000 + RANDOM % 10000))
        if check_port_available \$port; then
            echo \$port
            return 0
        fi
    done
    # If no port found after 50 attempts, use default 30022
    echo 30022
    return 1
}

# Get an available port
PORT=\$(find_available_port)
echo "Using port: \$PORT"
echo "Using Node: \$SLURM_JOB_NODELIST"

# Start dropbear with the selected port
./sbin/dropbear -F -E -p \$PORT -r ./.ssh/dropbear_rsa_host_key -r ./.ssh/dropbear_ecdsa_host_key -r ./.ssh/dropbear_ed25519_host_key

INNEREOF
fi
ENDSSH

# SSH into cluster and check for port in a loop
PORT=$(ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $USER@$HOSTNAME <<ENDSSH2
while true; do
    # Get SSH port from the job if it's running
    PORT_INFO=\$(grep 'Using port:' /home/$USER/logs/dropbear.log 2>/dev/null | tail -1)
    PORT=\$(echo \$PORT_INFO | awk '{print \$3}')
    
    # Break the loop if a valid port (greater than 0) is found
    if [ -n "\$PORT" ]; then
        echo \$PORT
        break
    fi
    sleep 1
done
ENDSSH2
)
NODE=$(ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $USER@$HOSTNAME <<ENDSSH2
echo "Waiting for port allocation..." > /home/$USER/logs/dropbear_test.log
while true; do
    # Get SSH port from the job if it's running
    NODE_INFO=\$(grep 'Using Node:' /home/$USER/logs/dropbear.log 2>/dev/null | tail -1)
    NODE=\$(echo \$NODE_INFO | awk '{print \$3}')
    
    # Break the loop if a valid port (greater than 0) is found
    if [ -n "\$NODE" ]; then
        echo \$NODE
        break
    fi
    sleep 1
done
ENDSSH2
)

echo "Detected port: $PORT"
echo "Detected node: $NODE"
$current_path/update_ssh_config.sh -a $CLUSTER -p $PARTITION -o $PORT -w $NODE
