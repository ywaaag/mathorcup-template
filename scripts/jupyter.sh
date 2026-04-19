#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_root_env "$ROOT_DIR"

CONTAINER_NAME="${1:-$CONTAINER_NAME}"
PORT="${2:-$JUPYTER_PORT}"

echo "→ 启动 Jupyter Notebook..."
docker exec -d "$CONTAINER_NAME" jupyter notebook \
    --ip=0.0.0.0 \
    --port="$PORT" \
    --allow-root \
    --NotebookApp.token="$JUPYTER_TOKEN" \
    --NotebookApp.password='' \
    --no-browser

sleep 3
echo ""
echo "============================================"
echo "  Jupyter 已启动"
echo "  访问地址: http://localhost:$PORT"
echo "  Token:     $JUPYTER_TOKEN"
echo "============================================"
