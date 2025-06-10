#!/bin/zsh
current_path="$(dirname "$0")"

# Set default value.
CLUSTER=bluehive
PARTITION=doppelbock
CPUS=16
GPUS=0
MEMORY=256
TIME=12
PORT=30022
# Use getopt to handle command line options.
TEMP=$(getopt p:a:c:g:m:t:w: $*)
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Reordered processed command line arguments
eval set -- "$TEMP"

# Iterate options through the case statement.
while true; do
    case "$1" in
        -p)
            PARTITION=$2
            shift 2
            ;;
        -a)
            CLUSTER=$2
            shift 2
            ;;
        -c)
            CPUS=$2
            shift 2
            ;;
        -g)
            GPUS=$2
            shift 2
            ;;
        -m)
            MEMORY=$2
            shift 2
            ;;
        -t)
            TIME=$2
            shift 2
            ;;
        -w)
            NODE=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error!"
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

source $current_path/start_ssh_control.sh -a $CLUSTER

ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $CLUSTER <<ENDSSH
#!/bin/bash
module load gcc
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

cd /scratch/snormanh_lab/shared/dropbear

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
PORT=$(ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $CLUSTER <<ENDSSH2
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
NODE=$(ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no -T $CLUSTER <<ENDSSH2
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
