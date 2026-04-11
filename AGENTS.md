# AGENTS.md — mathorcup 数模竞赛项目配置（代码脑）

> 本文件是根目录代码脑的全局规则。论文脑规则在 `project/paper/AGENTS.md`。

## 1. 角色与边界

- 代码脑职责：数学建模、算法实现、实验、图表与结果数据产出。
- 产出目录：`project/figures/`、`project/output/`、`project/src/`、`project/cpp/`、`project/notebooks/`。
- 禁止修改：`project/paper/` 内论文章节与排版文件（论文脑负责）。
- 协作要求：每个问题完成后必须更新 `MEMORY.md`，供论文脑消费。

## 2. 双脑协作协议

- 共享状态文件：`MEMORY.md`。
- 代码脑向论文脑交付：
  - 图：`project/figures/*.png`（优先 300 dpi，文件名使用 ASCII）
  - 数据：`project/output/*.csv`
  - 说明：在 `MEMORY.md` 写明公式、参数、结论、文件名。

推荐写入格式：

```markdown
## 【代码脑产出】问题X完成

### 核心公式
$$ ... $$

### 关键参数
- 参数A: ...
- 参数B: ...

### 生成文件
- figures/fig_problemX_xxx.png
- output/result_problemX_xxx.csv

### 给论文脑备注
- 图表含义、变量解释、如何引用
```

## 3. 运行环境（容器内执行）

- 容器名：`mathorcup-dev`
- 镜像：`math-modeling-competition:latest`（或版本标签）
- 挂载：`/home/ywag/mathorcup-template/project` ↔ `/workspace/mathorcup`
- Jupyter 端口：`8888`
- RStudio 端口：`8787`

常用命令：

```bash
# 进入容器
docker exec -it mathorcup-dev bash

# Python
docker exec mathorcup-dev python /workspace/mathorcup/src/main.py

# C++
docker exec mathorcup-dev bash -c "cd /workspace/mathorcup/cpp && g++ -O3 -std=c++17 main.cpp -o main && ./main"
```

## 4. 开发约束

- 宿主机不直接跑竞赛代码，统一通过容器执行。
- 大数据优先 Polars（`scan_csv` + 惰性执行）。
- 生成图必须 `savefig` 到 `project/figures/`，避免仅 `show()`。
- 输出结论需可复现：代码、参数、输入和结果路径都要可追踪。

## 5. Codex 入口与 MCP

- 代码脑启动：在仓库根目录执行 `codex`。
- 论文脑启动：在 `project/paper/` 目录执行 `codex`。
- MCP 采用用户级配置，不以仓库 `.mcp.json` 为主入口：

```bash
codex mcp list
codex mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking
```

## 6. 赛题填空

### 赛题背景

> 填写本次赛题背景与目标。

### 关键假设

- 假设1：
- 假设2：

### 模型框架

- 问题一：
- 问题二：
- 问题三：
- 问题四：

### 时间节点

| 阶段 | 目标 | 截止时间 |
|------|------|----------|
| EDA | | |
| 问题一 | | |
| 问题二 | | |
| 问题三 | | |
| 问题四 | | |
| 论文收口 | | |
