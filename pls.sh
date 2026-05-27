#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

CLUSTER=bluehive3

usage() {
    echo "Usage: $0 [-a|--cluster CLUSTER]"
    echo "Supported clusters: $(cluster_supported_list)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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

require_cluster "$CLUSTER" || exit 1
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1

echo "CLUSTER: $CLUSTER"
echo "HOSTNAME: $HOSTNAME"

source "$current_path/start_ssh_control.sh" -a "$CLUSTER"
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh_$CLUSTER -o StrictHostKeyChecking=no "$USER@$HOSTNAME"<<ENDSSH
echo
echo "=================================== CLUSTER STATUS ==================================="
echo
echo "📊 DOPPELBOCK PARTITION JOBS:"
squeue -O jobarrayid:12,partition:12,username:10,timeused:12,timelimit:12,numcpus:5,gres:12,minmemory:15,nodelist:10,name:40,reason:30 | awk 'NR == 1 || /doppelbock/' | column -t
echo

echo "📊 DMI PARTITION JOBS:"
squeue -O jobarrayid:12,partition:12,username:10,timeused:12,timelimit:12,numcpus:5,gres:12,minmemory:15,nodelist:10,name:40,reason:30 | awk 'NR == 1 || /dmi/' | column -t
echo

echo "👤 YOUR JOBS IN OTHER PARTITIONS:"
squeue -O jobarrayid:12,partition:12,username:10,timeused:12,timelimit:12,numcpus:5,gres:12,minmemory:15,nodelist:10,name:40,reason:30 -u \$USER | awk 'NR > 1 && !/doppelbock/ && !/dmi/' | column -t
echo

echo "================================================================================"

# Get free CPU count
DMI_FREE_CPU=\$(scontrol show node bhc0208 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 24-\$2}')
DOPPELBOCK_FREE_CPU=\$(scontrol show node bhg0061 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 64-\$2}')

# Get free GPU count with error handling
DMI_FREE_GPU=\$(squeue -w bhc0208 -O gres:15 | awk 'NR>1' | grep -o 'gpu:[0-9]*' | awk -F':' '{sum += \$2} END {print 1-sum+0}')
DOPPELBOCK_FREE_GPU=\$(squeue -w bhg0061 -O gres:15 | awk 'NR>1' | grep -o 'gpu:[0-9]*' | awk -F':' '{sum += \$2} END {print 4-sum+0}')

# Get memory info for DMI node
DMI_TOTAL_MEMORY=\$(scontrol show node bhc0208 | grep -o 'RealMemory=[0-9]*' | cut -d'=' -f2)
DMI_ALLOC_MEMORY=\$(scontrol show node bhc0208 | grep -o 'AllocMem=[0-9]*' | cut -d'=' -f2)
DMI_TOTAL_MEMORY_GB=\$(((\${DMI_TOTAL_MEMORY:-0}+512)/1024))
DMI_FREE_MEMORY_GB=\$(((\${DMI_TOTAL_MEMORY:-0}-\${DMI_ALLOC_MEMORY:-0}+512)/1024))

# Get memory info for DOPPELBOCK node
DOPPELBOCK_TOTAL_MEMORY=\$(scontrol show node bhg0061 | grep -o 'RealMemory=[0-9]*' | cut -d'=' -f2)
DOPPELBOCK_ALLOC_MEMORY=\$(scontrol show node bhg0061 | grep -o 'AllocMem=[0-9]*' | cut -d'=' -f2)
DOPPELBOCK_TOTAL_MEMORY_GB=\$(((\${DOPPELBOCK_TOTAL_MEMORY:-0}+512)/1024))
DOPPELBOCK_FREE_MEMORY_GB=\$(((\${DOPPELBOCK_TOTAL_MEMORY:-0}-\${DOPPELBOCK_ALLOC_MEMORY:-0}+512)/1024))

echo
echo "🖥️  RESOURCE AVAILABILITY:"
echo
printf "%-15s %-15s %-15s %-20s\n" "PARTITION" "CPU:FREE/TOTAL" "GPU:FREE/TOTAL" "MEMORY:FREE/TOTAL"
printf "%-15s %-15s %-15s %-20s\n" "----------" "---------------" "---------------" "--------------------"
printf "%-15s %-15s %-15s %-20s\n" "DMI" "\${DMI_FREE_CPU}c/24c" "\${DMI_FREE_GPU}g/1g" "\${DMI_FREE_MEMORY_GB}GB/\${DMI_TOTAL_MEMORY_GB}GB"
printf "%-15s %-15s %-15s %-20s\n" "DOPPELBOCK" "\${DOPPELBOCK_FREE_CPU}c/64c" "\${DOPPELBOCK_FREE_GPU}g/4g" "\${DOPPELBOCK_FREE_MEMORY_GB}GB/\${DOPPELBOCK_TOTAL_MEMORY_GB}GB"
echo

echo
echo "💾 DISK QUOTA:"
quota snormanh_lab
echo

echo "================================================================================"
ENDSSH
