current_path="$(dirname "$0")"
source $current_path/read_user_password.sh
printf "$USER\n$PASSWORD\npush\ny" | /opt/cisco/anyconnect/bin/vpn -s connect vpn.rochester.edu 