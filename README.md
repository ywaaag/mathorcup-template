# MathorCup 数模模板（Human Guide）

这是一个用于数学建模比赛的可复用工程模板。

设计目标：
- 用 Docker 固定运行环境，减少机器差异问题。
- 用双脑工作流并行推进：代码脑（建模/实验）+ 论文脑（写作/排版）。
- 用 Agent 协议文件约束协作，减少上下文漂移。

## 1. 你会用到哪些文件

- `AGENTS.md`：代码脑协议（根目录）。
- `project/paper/AGENTS.md`：论文脑协议（paper 目录）。
- `MEMORY.md`：双脑共享状态板（固定结构，给 Agent 读写）。
- `project/output/handoff/`：每道题的交接文档目录。
- `scripts/validate_agent_docs.sh`：协议校验脚本。

说明：项目里的 `AGENTS/MEMORY/handoff` 主要面向 Agent；本 README 主要给人类快速操作。

## 2. 前置条件

你本机需要：
- Docker 可用（含 GPU 时建议 NVIDIA Container Toolkit 已配置）。
- `codex` 命令可用（用于启动两路 Agent 会话）。
- 已拉取镜像 `math-modeling-competition:latest`（或你自己的同等镜像）。

建议先检查：

```bash
docker --version
codex --version
docker images | grep math-modeling-competition
```

若镜像不存在：

```bash
docker pull math-modeling-competition:latest
```

## 3. 快速开始（首次）

### 步骤 1：初始化项目

```bash
bash scripts/setup.sh <competition_name>
```

示例：

```bash
bash scripts/setup.sh mathorcup2026
```

可选参数：

```bash
# 跳过依赖安装（镜像已预装时）
bash scripts/setup.sh mathorcup2026 --skip-deps

# 安装完整版 LaTeX（体积较大）
bash scripts/setup.sh mathorcup2026 --full-latex
```

`setup.sh` 会做这些事：
- 检查镜像、创建/启动容器。
- 安装依赖（可选跳过）。
- 冷启动重置 `AGENTS.md / MEMORY.md / handoff` 模板内容。
- 运行 `scripts/validate_agent_docs.sh` 做协议校验。

### 步骤 2：启动双脑

```bash
# 交互菜单
bash scripts/dual_brain.sh

# 或只启动代码脑
bash scripts/dual_brain.sh code

# 或只启动论文脑
bash scripts/dual_brain.sh paper
```

`dual_brain.sh` 启动前会先校验：
- Agent 协议格式是否正确。
- Docker 容器是否在运行。
- `codex` 命令是否存在。

## 4. 日常操作命令

### 容器管理

```bash
docker start <competition_name>-dev
docker exec -it <competition_name>-dev bash
```

### Python 运行

```bash
bash scripts/python_run.sh <container_name> src/main.py
```

### C++ 编译运行

```bash
bash scripts/cpp_build.sh <container_name> main.cpp
```

### 论文编译

```bash
bash scripts/paper.sh <container_name> build
bash scripts/paper.sh <container_name> biber
bash scripts/paper.sh <container_name> clean
bash scripts/paper.sh <container_name> open
```

### Jupyter

```bash
bash scripts/jupyter.sh <container_name> 8888
```

## 5. 双脑协作建议流程（人类视角）

1. 代码脑先完成某题建模并产出 `figures/*.png` 与 `output/*.csv`。  
2. 代码脑写一份 handoff：`project/output/handoff/P{n}_{topic}_{YYYYMMDD}.md`。  
3. 更新 `MEMORY.md` 的状态与 `Handoff Index`。  
4. 论文脑只消费已索引的 handoff 与产出文件，写入 `paper/sections/*.tex`。  
5. 编译论文并修正引用/排版问题。

## 6. 协议与校验（你需要知道的最低限度）

### MEMORY 约束
- `MEMORY.md` 必须保持固定 7 个二级标题，顺序不可变。
- `MEMORY.md` 总行数硬上限 120 行。

### handoff 约束
- 文件命名：`P{n}_{topic}_{YYYYMMDD}.md`
- 必须包含固定字段：
  - `Problem`
  - `Inputs`
  - `Method`
  - `Outputs`
  - `For Paper Brain`
  - `Risks`
- 每个字段最多 5 行非空内容。

### 校验命令

```bash
# 全量校验
bash scripts/validate_agent_docs.sh

# 只校验 MEMORY
bash scripts/validate_agent_docs.sh --memory-only

# 只校验 handoff
bash scripts/validate_agent_docs.sh --handoff-only
```

## 7. 每场新比赛怎么复用

推荐做法：
1. 从 GitHub 拉新副本（或新目录克隆）。
2. 运行 `setup.sh` 初始化。
3. 放入新赛题数据和官方 LaTeX 模板。
4. 启动双脑开始本场比赛。

不建议在同一工作目录长期叠加多场比赛状态。

## 8. 常见问题

### Q1: `dual_brain.sh` 报协议校验失败
先执行：

```bash
bash scripts/validate_agent_docs.sh
```

按报错行号修复 `MEMORY.md` 或 handoff 文档后再启动。

### Q2: 报容器未运行

```bash
docker start <container_name>
```

### Q3: 报找不到 `codex`
确认 CLI 已安装并在 PATH：

```bash
codex --version
```

### Q4: 论文编译失败
先看 `paper.sh build` 输出末尾日志，再根据缺包/路径/引用问题逐项修复。

## 9. 目录结构（当前）

```text
.
├── AGENTS.md
├── MEMORY.md
├── README.md
├── scripts/
│   ├── setup.sh
│   ├── dual_brain.sh
│   ├── validate_agent_docs.sh
│   ├── python_run.sh
│   ├── cpp_build.sh
│   ├── paper.sh
│   └── jupyter.sh
└── project/
    ├── data/
    ├── src/
    ├── cpp/
    ├── figures/
    ├── output/
    │   └── handoff/
    └── paper/
        ├── AGENTS.md
        └── sections/
```

## 10. 历史说明

`legacy/claude/` 是旧版本归档，仅用于回溯，不参与当前流程。
