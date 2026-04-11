# MathorCup 数模竞赛模板（Codex 版）

一套可复用的数学建模竞赛工程模板，采用 Docker 容器 + 双脑协作（代码脑/论文脑）模式。

## 文档分层

| 文档 | 受众 | 用途 |
|------|------|------|
| `README.md` | 人类开发者 | 项目结构、环境搭建、操作说明 |
| `AGENTS.md` | 代码脑（根目录 Codex） | 建模与代码规则 |
| `project/paper/AGENTS.md` | 论文脑（paper 目录 Codex） | LaTeX 写作与排版规则 |
| `MEMORY.md` | 双脑共享 | 跨会话记忆、交付记录、进度同步 |

## 核心原则

1. 非侵入式开发：模板不内置赛题数据与示例解法。
2. 上下文隔离：代码脑与论文脑分会话协作，通过 `MEMORY.md` 交接。
3. 容器内执行：竞赛代码统一在容器内运行，确保可复现。

## 快速开始

### 1) 初始化

```bash
cd ~/mathorcup-template
bash scripts/setup.sh mathorcup2026
```

### 2) 启动双脑

```bash
# 交互菜单
bash scripts/dual_brain.sh

# 或直接启动代码脑
bash scripts/dual_brain.sh code

# 或直接启动论文脑
bash scripts/dual_brain.sh paper
```

`dual_brain.sh` 会检查：
- Docker 容器已运行
- `codex` 命令可用

### 3) 比赛准备

1. 把赛题原始数据放入 `project/data/`。
2. 把官方 LaTeX 模板放入 `project/paper/`。
3. 在 `AGENTS.md` 的填空区写本场比赛信息（假设、时间节点、模型框架）。

## 常用命令

### 容器管理

```bash
docker start mathorcup-dev
docker exec -it mathorcup-dev bash
```

### 代码脑

```bash
# 运行 Python（参数1是容器名，参数2是脚本路径）
bash scripts/python_run.sh mathorcup-dev src/main.py

# 编译 C++（参数1是容器名，参数2是 cpp 文件名）
bash scripts/cpp_build.sh mathorcup-dev main.cpp

# 启动 Jupyter（容器名 + 端口）
bash scripts/jupyter.sh mathorcup-dev 8888
```

### 论文脑

```bash
# 完整编译（默认 build）
bash scripts/paper.sh mathorcup-dev build

# 仅编译参考文献
bash scripts/paper.sh mathorcup-dev biber

# 清理辅助文件
bash scripts/paper.sh mathorcup-dev clean

# 打开 PDF
bash scripts/paper.sh mathorcup-dev open
```

## 双脑协作协议

### 代码脑产出要求

- 图表输出到：`project/figures/`
- 数据输出到：`project/output/`
- 每完成一个问题，在 `MEMORY.md` 写清：
  - 核心公式
  - 关键参数
  - 生成文件
  - 给论文脑的解释与引用建议

### 论文脑消费流程

1. 读取 `../MEMORY.md`。
2. 读取 `../figures/` 与 `../output/`。
3. 写入 `sections/*.tex`。
4. 更新 `MEMORY.md` 的论文进度区。

## Codex MCP 初始化（用户级）

本模板不再以仓库内 `.mcp.json` 作为主入口。推荐使用用户级命令维护 MCP：

```bash
# 查看已配置 MCP
codex mcp list

# 示例：添加 sequential-thinking
codex mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking

# 示例：添加 math
codex mcp add math -- npx -y math-mcp
```

> 提示：MCP 属于本机用户环境配置，不随仓库自动迁移。

## 项目结构

```text
mathorcup-template/
├── AGENTS.md
├── AGENTS.md.template
├── MEMORY.md
├── MEMORY.md.template
├── README.md
├── docker-compose.yml
├── .env.template
├── scripts/
│   ├── setup.sh
│   ├── dual_brain.sh
│   ├── python_run.sh
│   ├── cpp_build.sh
│   ├── paper.sh
│   ├── jupyter.sh
│   ├── start.sh
│   └── run.sh
├── project/
│   ├── src/
│   ├── cpp/
│   ├── data/
│   ├── notebooks/
│   ├── figures/
│   ├── output/
│   └── paper/
│       ├── AGENTS.md
│       ├── AGENTS.md.template
│       ├── sections/
│       └── references/
└── legacy/
    └── claude/
        └── ...（历史归档，仅供回溯）
```

## 历史归档

旧版工具链相关文件已归档到 `legacy/claude/`，包括历史规则文件与历史配置。当前默认流程仅使用 Codex 入口与 `AGENTS.md` 体系。

## License

MIT
