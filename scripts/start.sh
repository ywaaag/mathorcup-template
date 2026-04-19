#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_root_env "$ROOT_DIR"
CONTAINER_NAME="${1:-$CONTAINER_NAME}"
docker start "$CONTAINER_NAME" >/dev/null
echo "容器 $CONTAINER_NAME 已启动"
docker ps --filter "name=$CONTAINER_NAME"
