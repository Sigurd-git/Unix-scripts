#!/bin/bash
current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
LOGIN_DEFAULT=bluehive
LOGIN=$LOGIN_DEFAULT  # Set the default value here, it can be bluehive or bhward

# 使用getopt处理命令行选项
TEMP=$(getopt -o a: --long cluster: -n 'ssh_control.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Process the arguments passed to the script
eval set -- "$TEMP"
while true; do
    case "$1" in
        -a|--cluster)
            LOGIN=$2
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

echo "LOGIN: $LOGIN"
running=$(ps aux | grep -c "[s]sh.*$LOGIN")
echo "Running: $[running-2]"
if [ $running -gt 2 ] ; then
  echo "SSH session to $LOGIN is already running. Reuse."
else
  echo "Starting SSH session to $LOGIN."
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -fN $LOGIN
fi
