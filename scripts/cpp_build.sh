#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_root_env "$ROOT_DIR"

CONTAINER_NAME="${1:-$CONTAINER_NAME}"
CFILE="${2:-main.cpp}"
ARGS="${3:-}"

echo "→ 编译: $CFILE"
if [[ "$CFILE" == "main" ]]; then
    CFILE="main.cpp"
fi

docker exec "$CONTAINER_NAME" bash -c "
    cd '$PROJECT_CONTAINER_DIR/cpp' && \
    g++ -O3 -std=c++17 -o main \"$CFILE\" && \
    echo '编译成功' && \
    ./main $ARGS
"
