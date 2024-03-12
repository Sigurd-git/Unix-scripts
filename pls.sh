current_path="$(dirname "$0")"
source $current_path/start_ssh_control.sh 
ssh bluehive<<ENDSSH
echo "---------------------------------"
squeue -O jobarrayid:18,partition:13,username:12,starttime:22,timeused:13,timelimit:13,numcpus:10,minmemory:12,nodelist:10,reason:10,name | awk 'NR == 1 || /doppelbock/'
squeue -O jobarrayid:18,partition:13,username:12,starttime:22,timeused:13,timelimit:13,numcpus:10,minmemory:12,nodelist:10,reason:10,name | awk ' /dmi/'
echo "---------------------------------"
scontrol show node bhc0208 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 24-\$2}' | xargs -I {} echo 'Dmi Total Cpu: 24; Free cpu: {}. ' 
scontrol show node bhg0061 | grep 'CPUAlloc' | awk '{print \$1}' | awk -F'=' '{print 64-\$2}' | xargs -I {} echo 'Doppelbock Total Cpu: 64; Free cpu: {}. ' 
ENDSSH
