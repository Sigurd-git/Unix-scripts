#!/bin/zsh
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh

# Set default value.
CLUSTER=bluehive
PARTITION=doppelbock
CPUS=16
GPUS=1
MEMORY=256
TIME=12

# Use getopt to handle command line options.
TEMP=$(getopt p:a:c:g:m:t:w: $*)
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi
# 
# Reordered processed command line arguments
eval set -- "$TEMP"
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

source $current_path/start_ssh_control.sh 

ssh -o StrictHostKeyChecking=no $CLUSTER <<ENDSSH
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
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --name ${CLUSTER}_compute > ~/logs/tunnel.log 2>&1 &
    fi
else
    if squeue -u $USER -O name:32|grep cursor; then
        echo "Tunnel is already running."
        job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
        echo "\$job"
    else
        nohup srun -N 1 --ntasks-per-node=$CPUS -p $PARTITION --mem="$MEMORY"g --gres=gpu:$GPUS -t $TIME:00:00 -w $NODE /scratch/snormanh_lab/shared/cursor tunnel --accept-server-license-terms --name ${CLUSTER}_compute > ~/logs/tunnel.log 2>&1 &
    fi
fi
ENDSSH
# log=$(ssh -o StrictHostKeyChecking=no $CLUSTER "cat ~/logs/tunnel.log")
# echo "Waiting for tunnel to start..."
# token=$(echo $log | grep -o 'use code \S\{9\}' | head -n 1 | cut -d ' ' -f 3)
# if [ -z "$token" ]; then
#     echo "Logs: $log"
# else
#     open "https://github.com/login/device"
#     platform=$(uname -s)

#     echo "Token: $token"
    
# fi
