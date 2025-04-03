#!/bin/bash
current_path="$(dirname "$0")"
# read first row of user.txt as user 
# Read the first line from user.txt as USER
if [ -f "$current_path/user.txt" ]; then
    USER=$(head -n 1 "$current_path/user.txt" | tr -d '\r\n')
else
    echo "Error: user.txt not found in $current_path" >&2
    exit 1
fi

echo "USER: $USER"
