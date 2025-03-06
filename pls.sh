current_path="$(dirname "$0")"

CLUSTER=bluehive
# Use getopt to handle command line options.
TEMP=$(getopt -o a: --long cluster: -n 'pls.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi
# 
# Reordered processed command line arguments
eval set -- "$TEMP"

while true; do
    case "$1" in
        -a|--cluster)
            CLUSTER=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
    esac
done

source $current_path/start_ssh_control.sh -a $CLUSTER
ssh $CLUSTER<<ENDSSH
echo "---------------------------------"
# Get all jobs info with header and doppelbock partition jobs
squeue -O jobarrayid:18,partition:13,username:12,timeused:13,timelimit:13,numcpus:5,gres:15,minmemory:12,nodelist:9,name:40,reason | awk 'NR == 1 || /doppelbock/'

# Get dmi partition jobs without header
squeue -O jobarrayid:18,partition:13,username:12,timeused:13,timelimit:13,numcpus:5,gres:15,minmemory:12,nodelist:9,name:40,reason | awk 'NR > 1 && /dmi/'

# Get current user's jobs that are not in doppelbock or dmi partitions
squeue -O jobarrayid:18,partition:13,username:12,timeused:13,timelimit:13,numcpus:5,gres:15,minmemory:12,nodelist:9,name:40,reason -u $USER | awk 'NR > 1 && !/doppelbock/ && !/dmi/'
echo "---------------------------------"
# Get free CPU count
DMI_FREE_CPU=\$(scontrol show node bhc0208 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 24-\$2}')
DOPPELBOCK_FREE_CPU=\$(scontrol show node bhg0061 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 64-\$2}')

# Get free GPU count with error handling
DMI_FREE_GPU=\$(squeue -w bhc0208 -O gres:15 | awk 'NR>1' | grep -o 'gpu:[0-9]*' | awk -F':' '{sum += \$2} END {print 1-sum+0}')
DOPPELBOCK_FREE_GPU=\$(squeue -w bhg0061 -O gres:15 | awk 'NR>1' | grep -o 'gpu:[0-9]*' | awk -F':' '{sum += \$2} END {print 4-sum+0}')

echo "Dmi Total Cpu: 24; Free cpu: \$DMI_FREE_CPU. Dmi Total GPU: 1; Free GPU: \$DMI_FREE_GPU."
echo "Doppelbock Total Cpu: 64; Free cpu: \$DOPPELBOCK_FREE_CPU. Doppelbock Total GPU: 4; Free GPU: \$DOPPELBOCK_FREE_GPU."
ENDSSH
