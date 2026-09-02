#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

# Default values
CLUSTER="bluehive3"
NODE=""
PARTITION="doppelbock"
PORT="22"  # 默认SSH端口

# Parse command line arguments
while getopts "a:w:p:o:" opt; do
    case $opt in
        a) CLUSTER="$OPTARG" ;;
        w) NODE="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        o) PORT="$OPTARG" ;;
        ?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
done

# SSH config file path
SSH_CONFIG="$HOME/.ssh/config"

COMPUTE_HOST="$(cluster_compute_host "$CLUSTER")" || exit 1

if ! awk -v target="$COMPUTE_HOST" '
    /^Host[[:space:]]/ {
        n = split($0, parts, /[[:space:]]+/)
        for (i = 2; i <= n; i++) {
            if (parts[i] == target) {
                found = 1
            }
        }
    }
    END { exit(found ? 0 : 1) }
' "$SSH_CONFIG"; then
    echo "Error: Host $COMPUTE_HOST not found in $SSH_CONFIG" >&2
    exit 1
fi

update_host_value() {
    local host_alias="$1"
    local key="$2"
    local value="$3"
    local tmp_file
    tmp_file="$(mktemp "${SSH_CONFIG}.XXXXXX")"

    awk -v target="$host_alias" -v key="$key" -v value="$value" '
        function host_line_matches(    i, n, parts) {
            n = split($0, parts, /[[:space:]]+/)
            for (i = 2; i <= n; i++) {
                if (parts[i] == target) {
                    return 1
                }
            }
            return 0
        }
        function add_key_if_missing() {
            if (in_block && !updated) {
                print "\t" key " " value
                updated = 1
            }
        }
        /^Host[[:space:]]/ {
            add_key_if_missing()
            in_block = host_line_matches()
            updated = 0
            print
            next
        }
        in_block && $1 == key {
            print "\t" key " " value
            updated = 1
            next
        }
        { print }
        END {
            add_key_if_missing()
        }
    ' "$SSH_CONFIG" > "$tmp_file" && mv "$tmp_file" "$SSH_CONFIG"
}

# If node is specified, use it directly
if [ -n "$NODE" ]; then
    TARGET_NODE="$NODE"
# Otherwise use default logic based on partition
else
    if [ "$PARTITION" = "doppelbock" ]; then
        TARGET_NODE="bhg0061"
    elif [ "$PARTITION" = "dmi" ]; then
        TARGET_NODE="bhc0208"
    elif [ "$PARTITION" = "preempt" ]; then
        echo "Error: preempt partition requires a specific allocated node" >&2
        exit 1
    else
        echo "Error: Unknown partition $PARTITION" >&2
        exit 1
    fi
fi

read_effective_ssh_value() {
    local key="$1"

    ssh -G "$COMPUTE_HOST" 2>/dev/null |
        awk -v key="$key" '$1 == key { print $2; exit }'
}

current_hostname="$(read_effective_ssh_value hostname)"
current_port="$(read_effective_ssh_value port)"
control_path="$(read_effective_ssh_value controlpath)"

if { [ "$current_hostname" != "$TARGET_NODE" ] || [ "$current_port" != "$PORT" ]; } &&
   [[ "$control_path" == /* && "$control_path" != *%* && -S "$control_path" ]]; then
    control_status="$(
        ssh -S "$control_path" -O check "$COMPUTE_HOST" 2>&1 || true
    )"
    if [[ "$control_status" == *"Master running"* ]]; then
        echo "Closing the previous SSH master for $COMPUTE_HOST."
        ssh -S "$control_path" -O exit "$COMPUTE_HOST" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            [[ ! -S "$control_path" ]] && break
            sleep 1
        done
        if [[ -S "$control_path" ]]; then
            echo "Error: SSH master did not close: $control_path" >&2
            exit 1
        fi
    else
        unlink "$control_path"
    fi
fi

update_host_value "$COMPUTE_HOST" "Hostname" "$TARGET_NODE"
update_host_value "$COMPUTE_HOST" "Port" "$PORT"

echo "Updated SSH config for $COMPUTE_HOST ($CLUSTER) with node: $TARGET_NODE and port: $PORT"
