#!/bin/bash
current_path="$(dirname "$0")"
USER_PASSWORD_FILE="$current_path/user_password.txt"
REMOTE_SHARED_ROOT_DEFAULT="/scratch/snormanh_lab/shared"

if [ ! -f "$USER_PASSWORD_FILE" ]; then
    echo "Error: $USER_PASSWORD_FILE not found" >&2
    exit 1
fi

{
    IFS= read -r line1 || true
    IFS= read -r line2 || true
    IFS= read -r line3 || true
} < "$USER_PASSWORD_FILE"

if [[ "$line3" == REMOTE_SHARED_ROOT=* ]]; then
    line3="${line3#REMOTE_SHARED_ROOT=}"
fi

# set environment variables
export USER="$line1"

# Check if password was read successfully, if not prompt for manual input
if [ -z "$line2" ] && [ -z "$PASSWORD" ]; then
    echo "Password not found in file. Please enter password manually:"
    read -s -p "Password: " line2
    echo  # Add newline after password input
fi

export PASSWORD="$line2"
export REMOTE_SHARED_ROOT="${line3:-$REMOTE_SHARED_ROOT_DEFAULT}"

echo "USER: $USER"
echo "REMOTE_SHARED_ROOT: $REMOTE_SHARED_ROOT"
# echo "PASSWORD: $PASSWORD"
