#!/bin/bash
current_path="$(dirname "$0")"
# read first 2 rows
while IFS= read -r line1; do
    IFS= read -r line2
    # set environment variables
    export USER="$line1"
    export PASSWORD="$line2"
    break
done < $current_path/user_password.txt

echo "USER: $USER"
echo "PASSWORD: $PASSWORD"
