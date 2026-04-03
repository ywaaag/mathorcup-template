#!/bin/bash
# ============================================================
# 启动 Jupyter Notebook 并输出访问地址
# ============================================================
CONTAINER_NAME="${1:-mathorcup-dev}"
PORT="${2:-8888}"

echo "→ 启动 Jupyter Notebook..."
docker exec -d "$CONTAINER_NAME" jupyter notebook \
    --ip=0.0.0.0 \
    --port=$PORT \
    --allow-root \
    --NotebookApp.token=mathorcup \
    --NotebookApp.password='' \
    --no-browser

sleep 3
echo ""
echo "============================================"
echo "  Jupyter 已启动"
echo "  访问地址: http://localhost:$PORT"
echo "  Token:     mathorcup"
echo "============================================"
