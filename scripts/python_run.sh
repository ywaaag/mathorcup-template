#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_root_env "$ROOT_DIR"

CONTAINER_NAME="${1:-$CONTAINER_NAME}"
SCRIPT="${2:-src/main.py}"
shift $(( $# >= 2 ? 2 : $# ))

docker exec "$CONTAINER_NAME" python "$PROJECT_CONTAINER_DIR/$SCRIPT" "$@"
