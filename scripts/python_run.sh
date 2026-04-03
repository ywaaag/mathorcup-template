#!/bin/bash
# ============================================================
# 在容器内运行 Python 脚本
# ============================================================
CONTAINER_NAME="${1:-mathorcup-dev}"
SCRIPT="${2:-src/main.py}"
shift 2

docker exec "$CONTAINER_NAME" python "/workspace/mathorcup/$SCRIPT" "$@"
