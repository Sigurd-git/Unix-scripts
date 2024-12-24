#!/bin/zsh
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh

# Set default value.
CLUSTER=bluehive
PARTITION=doppelbock
CPUS=16
GPUS=0
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

# Add SSH config modification based on PARTITION
SSH_CONFIG="$HOME/.ssh/config"
if [ "$PARTITION" = "doppelbock" ]; then
    sed -i '' '/^Host bluehive_compute/,/Hostname/{s/Hostname.*/Hostname bhg0061/;}' "$SSH_CONFIG"
elif [ "$PARTITION" = "dmi" ]; then
    sed -i '' '/^Host bluehive_compute/,/Hostname/{s/Hostname.*/Hostname bhc0208/;}' "$SSH_CONFIG"
fi

source $current_path/start_ssh_control.sh 



ssh -o StrictHostKeyChecking=no $CLUSTER <<ENDSSH
#!/bin/bash
module load gcc
mkdir -p /home/$USER/logs
# Your commands go here

if squeue -u $USER -O name:32|grep my_sshd; then
    echo "SSHD is already running."
    job=\$(squeue -u $USER -O jobarrayid:18,partition:13,username:12,submittime:22,starttime:22,timeused:13,timelimit:13,numcpus:10,gres:15,minmemory:12,nodelist:10,priorityLong:9,reason:9,name:4)
    echo "\$job"
else
    cat <<'INNEREOF' | sbatch
#!/bin/bash
#SBATCH -p $PARTITION -t $TIME:00:00
#SBATCH -c $CPUS
#SBATCH --mem="${MEMORY}G"
#SBATCH --gres=gpu:$GPUS -x bhg0044,bhg0046,bhg0047,bhg0048
#SBATCH -o /home/$USER/logs/dropbear.log
#SBATCH --job-name=my_sshd

cd /scratch/snormanh_lab/shared/dropbear
# Start dropbear with the randomly selected port
./sbin/dropbear -F -E -p 30022 -r ./.ssh/dropbear_rsa_host_key -r ./.ssh/dropbear_ecdsa_host_key -r ./.ssh/dropbear_ed25519_host_key

INNEREOF

fi
ENDSSH