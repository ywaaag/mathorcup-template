#!/bin/bash
# ============================================================
# 在容器内编译并运行 C++ 代码
#
# 用法:
#   bash scripts/cpp_build.sh                    # 运行默认 cpp/main.cpp
#   bash scripts/cpp_build.sh my_solver.cpp      # 运行指定文件
#   bash scripts/cpp_build.sh main 1000          # 运行并传参 1000
# ============================================================
CONTAINER_NAME="${1:-mathorcup-dev}"
CFILE="${2:-main.cpp}"
ARGS="${3:-}"

echo "→ 编译: $CFILE"
if [[ "$CFILE" == "main" ]]; then
    CFILE="main.cpp"
fi

docker exec "$CONTAINER_NAME" bash -c "
    cd /workspace/mathorcup/cpp && \
    g++ -O3 -std=c++17 -o main main.cpp && \
    echo '编译成功' && \
    ./main $ARGS
"
