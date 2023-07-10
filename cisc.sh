source ./read_user_password.sh
printf "$USER\n$PASSWORD\npush\ny" | /opt/cisco/anyconnect/bin/vpn -s connect vpn.rochester.edu 