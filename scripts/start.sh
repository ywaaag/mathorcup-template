#!/bin/bash
# ============================================================
# 启动 / 重启容器
# ============================================================
CONTAINER_NAME="${1:-mathorcup-dev}"
docker start "$CONTAINER_NAME"
echo "容器 $CONTAINER_NAME 已启动"
docker ps --filter "name=$CONTAINER_NAME"
