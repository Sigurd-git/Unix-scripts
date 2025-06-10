#!/bin/zsh
current_path="$(dirname "$0")"

# Set default value.
CLUSTER=bluehive
PARTITION=doppelbock
CPUS=16
GPUS=1
MEMORY=256
TIME=12
NO_LOG=false

# Use getopt to handle command line options.
TEMP=$(getopt p:a:c:g:m:t:w:n $*)
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi
# 
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
        -n)
            NO_LOG=true
            shift
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
echo "NO_LOG: $NO_LOG"

# Set HOSTNAME based on CLUSTER
if [ "$CLUSTER" = "bluehive" ]; then
    HOSTNAME="bluehive.circ.rochester.edu"
elif [ "$CLUSTER" = "bhward" ]; then
    HOSTNAME="bhward.circ.rochester.edu"
else
    echo "Error: Unknown cluster '$CLUSTER'. Supported clusters: bluehive, bhward"
    exit 1
fi

echo "HOSTNAME: $HOSTNAME"

source $current_path/start_ssh_control.sh 

ssh -o StrictHostKeyChecking=no $USER@$HOSTNAME <<ENDSSH
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
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --name ${CLUSTER}_compute > ~/logs/tunnel.log 2>&1 &
    fi
else
    if squeue -u $USER -O name:32|grep cursor; then
        echo "Tunnel is already running."
        job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
        echo "\$job"
    else
        echo "Starting tunnel..." > ~/logs/tunnel.log
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 -w $NODE /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --name ${CLUSTER}_compute > ~/logs/tunnel.log 2>&1 &
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