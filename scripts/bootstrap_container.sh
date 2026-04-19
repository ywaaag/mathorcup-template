#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
RECREATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --recreate)
            RECREATE=true
            shift
            ;;
        -h|--help)
            echo "Usage: bash scripts/bootstrap_container.sh [--target <dir>] [--recreate]"
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

require_cmd docker
load_root_env "$TARGET_DIR"

status_info "container: $CONTAINER_NAME"
status_info "host project dir: $HOST_PROJECT_DIR"

docker image inspect "$IMAGE_NAME" >/dev/null 2>&1 || die "image not found: $IMAGE_NAME"

if container_exists && [[ "$RECREATE" == true ]]; then
    status_info "removing existing container $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
fi

if ! container_exists; then
    status_info "creating container $CONTAINER_NAME"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --gpus all \
        --runtime=nvidia \
        --privileged \
        -p "$JUPYTER_PORT:8888" \
        -p "$RSTUDIO_PORT:8787" \
        -v "$HOST_PROJECT_DIR:$PROJECT_CONTAINER_DIR" \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e JUPYTER_TOKEN="$JUPYTER_TOKEN" \
        --restart unless-stopped \
        "$IMAGE_NAME" \
        /usr/bin/env bash -lc "while true; do sleep 86400; done" >/dev/null
    status_ok "container created"
else
    status_skip "container already exists"
fi

docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
status_ok "container running"
