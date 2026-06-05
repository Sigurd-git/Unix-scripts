#!/bin/bash
current_path="$(dirname "$0")"
source "$current_path/cluster_helpers.sh"

CLUSTER="bluehive3"
ROOT_OVERRIDE=""
DEPLOY_CODE=false
DEPLOY_CURSOR=false
DEPLOY_DROPBEAR=false

usage() {
    echo "Usage: $0 [-a CLUSTER] [--root PATH] [--code] [--cursor] [--dropbear] [--all]"
    echo "Supported clusters: $(cluster_supported_list)"
    echo "If no tool is specified, --all is used."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--cluster)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a cluster name" >&2
                exit 1
            fi
            CLUSTER="$2"
            shift 2
            ;;
        --cluster=*)
            CLUSTER="${1#*=}"
            shift
            ;;
        -r|--root)
            if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: $1 requires a remote path" >&2
                exit 1
            fi
            ROOT_OVERRIDE="$2"
            shift 2
            ;;
        --root=*)
            ROOT_OVERRIDE="${1#*=}"
            shift
            ;;
        --code|--vscode)
            DEPLOY_CODE=true
            shift
            ;;
        --cursor)
            DEPLOY_CURSOR=true
            shift
            ;;
        --dropbear)
            DEPLOY_DROPBEAR=true
            shift
            ;;
        --all)
            DEPLOY_CODE=true
            DEPLOY_CURSOR=true
            DEPLOY_DROPBEAR=true
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

if [ "$DEPLOY_CODE" = false ] && [ "$DEPLOY_CURSOR" = false ] && [ "$DEPLOY_DROPBEAR" = false ]; then
    DEPLOY_CODE=true
    DEPLOY_CURSOR=true
    DEPLOY_DROPBEAR=true
fi

require_cluster "$CLUSTER" || exit 1
HOSTNAME="$(cluster_hostname "$CLUSTER")" || exit 1

source "$current_path/start_ssh_control.sh" -a "$CLUSTER"

if [ -n "$ROOT_OVERRIDE" ]; then
    REMOTE_SHARED_ROOT="$ROOT_OVERRIDE"
    export REMOTE_SHARED_ROOT
fi

echo "CLUSTER: $CLUSTER"
echo "HOSTNAME: $HOSTNAME"
echo "REMOTE_SHARED_ROOT: $REMOTE_SHARED_ROOT"

source "$current_path/remote_tools.sh"

if [ "$DEPLOY_CODE" = true ]; then
    ensure_remote_vscode_cli || exit $?
fi

if [ "$DEPLOY_CURSOR" = true ]; then
    ensure_remote_cursor_cli || exit $?
fi

if [ "$DEPLOY_DROPBEAR" = true ]; then
    ensure_remote_dropbear || exit $?
fi

echo "Remote tool deployment completed."
