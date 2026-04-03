# MathorCup 数模竞赛模板

一套开箱即用的数学建模竞赛开发环境，通过 Docker 容器化 + **双脑协作架构** 实现每次比赛快速复用。

## 📜 文档哲学

本项目采用 **AI 优先的文档架构**，所有文档分为两类：

| 文档 | 受众 | 用途 |
|------|------|------|
| **README.md**（本文件） | **人类开发者** | 项目概览、环境搭建、手动操作指南 |
| **CLAUDE.md / MEMORY.md** | **AI 助手（代码脑/论文脑）** | AI 上下文管理、协作协议、任务记忆 |

**核心原则**：
1. **非侵入式开发**：模板本身不包含任何赛题相关代码或数据，`output/` 和 `figures/` 目录仅保留 `.gitkeep` 占位文件。
2. **上下文隔离**：代码脑（建模）与论文脑（写作）拥有独立的 AI 配置，通过 `MEMORY.md` 实现异步协作。
3. **零示例代码**：不提供任何伪数据或样例模型，每次比赛均从空白状态开始，确保思维不受污染。

---

## 🧠 双脑协作架构

### 核心原理

**代码逻辑和论文排版完全解耦**，采用"生产者-消费者"模型：

```text
┌─────────────────────────────────────────────────────┐
│  终端 A: Claude Code (根目录)                       │
│  角色: 代码脑 (Code Brain)                          │
│  目录: ~/mathorcup-template/                        │
│  任务: 数学建模 + 代码实现 + 生成图表/数据          │
│  产出: figures/*.png  +  output/*.csv               │
│  共享: MEMORY.md (代码产出 + 核心公式)              │
└────────────────────────┬────────────────────────────┘
                         │ MEMORY.md + 文件系统
┌────────────────────────┴────────────────────────────┐
│  终端 B: Claude Code (paper/ 目录)                  │
│  角色: 论文脑 (Paper Brain)                         │
│  目录: ~/mathorcup-template/project/paper/          │
│  任务: LaTeX 排版 + 学术写作                        │
│  读取: ../figures/ + ../output/ + ../MEMORY.md      │
│  产出: paper/sections/*.tex                         │
└─────────────────────────────────────────────────────┘
```

### 为什么必须双脑？

| 风险 | 单脑模式 | 双脑模式 |
|------|---------|---------|
| Token 消耗 | 上下文迅速膨胀，AI 性能下降 | 各自独立，上下文互不污染 |
| 精神分裂 | 修 C++ 段错误 ↔ 调 LaTeX 跨页，AI 频繁切换模式 | 专业分工，AI 保持专注 |
| 协作效率 | AI 兼顾建模和写作，两者互相干扰 | 建模完成后直接通知论文脑 |
| 格式风险 | 论文脑不熟悉官方 LaTeX 模板 | 代码脑不管模板，论文脑严格执行 |

---

## 📦 镜像获取

本项目使用预构建的 Docker 镜像 `math-modeling-competition:latest`，包含完整的数学建模开发环境。

### 获取方式

1. **使用预构建镜像**（推荐）：
   ```bash
   docker pull math-modeling-competition:latest
   ```

2. **或使用版本标签**：
   ```bash
   docker pull math-modeling-competition:20260403
   ```

3. **从基础镜像构建**（如无预构建镜像）：
   使用 `gcr.io/kaggle-images/python:latest` 为基础，运行 `scripts/setup.sh` 会自动安装所有依赖。

**镜像特性**：
- PyTorch 2.8.0 + CUDA 12.6（RTX 4060支持）
- 中文LaTeX编译环境（xelatex + xeCJK）
- 数学建模工具链（OR-Tools、PuLP、DEAP、Polars等）
- 国内镜像源配置（清华APT源、PyPI源）

---

## 🚀 快速开始

### 首次使用

```bash
# 1. 克隆仓库
git clone [https://github.com/YOUR_USERNAME/mathorcup-template.git](https://github.com/YOUR_USERNAME/mathorcup-template.git) ~/mathorcup-template
cd ~/mathorcup-template

# 2. 一键初始化（需先获取镜像，见上方"镜像获取"）
bash scripts/setup.sh mathorcup2026

# 3. 同时启动双脑
bash scripts/dual_brain.sh both
#   → 自动打开两个终端窗口：
#     终端 A: 代码脑 (cd ~/mathorcup-template && claude code .)
#     终端 B: 论文脑 (cd ~/mathorcup-template/project/paper && claude code .)

# 4. 赛前准备（手动操作）
#    - 将 MathorCup 官方 LaTeX 模板放入 paper/ 目录
#    - 重命名为 mathorcup_template.tex
#    - 将赛题数据放入 data/ 目录
#    - 【重要】模板项目不包含任何示例代码或数据，保持 output/ 和 figures/ 目录为空
```

### 每次比赛复用

```bash
cd ~/mathorcup-template

# 新比赛：一条命令搞定所有初始化
bash scripts/setup.sh 华为杯2026

# 启动双脑
bash scripts/dual_brain.sh both
```

### 常用操作

```bash
# ── 容器管理 ───────────────────────────────────────
docker start mathorcup-dev           # 启动
docker exec -it mathorcup-dev bash   # 进入容器

# ── 代码脑操作 ────────────────────────────────────
bash scripts/python_run.sh           # 运行 src/main.py
bash scripts/cpp_build.sh            # 编译运行 C++

# ── 论文脑操作 ────────────────────────────────────
bash scripts/paper.sh build          # 编译论文（xelatex x3）
bash scripts/paper.sh open           # 打开 PDF
bash scripts/paper.sh clean          # 清理辅助文件

# ── Jupyter ───────────────────────────────────────
bash scripts/jupyter.sh              # 启动 Jupyter
# 访问: http://localhost:8888  (密码: mathorcup)
```

**setup.sh 高级选项**：
```bash
# 跳过依赖安装（假定镜像已预装所有依赖）
bash scripts/setup.sh mathorcup2026 --skip-deps

# 安装完整版 LaTeX（约 4GB）
bash scripts/setup.sh mathorcup2026 --full-latex

# 组合使用
bash scripts/setup.sh mathorcup2026 --skip-deps --full-latex
```

---

## 📁 项目结构

```text
mathorcup-template/
│
├── CLAUDE.md.template       # 【代码脑】全局配置（AI 读）
├── MEMORY.md.template       # 【共享】双脑记忆库（AI 读）
│
├── .mcp.json               # MCP 服务器配置
├── .claude/settings.json   # Claude Code Skills
├── docker-compose.yml      # Docker Compose
├── .env.template           # 环境变量模板
│
├── scripts/
│   ├── setup.sh            # ⭐ 一键初始化
│   ├── start.sh            # 启动容器
│   ├── run.sh              # 进入容器终端
│   ├── jupyter.sh          # 启动 Jupyter
│   ├── python_run.sh       # 运行 Python
│   ├── cpp_build.sh        # 编译运行 C++
│   ├── paper.sh            # LaTeX 编译
│   └── dual_brain.sh       # ⭐ 双脑协作启动器
│
└── project/                # 比赛项目目录（初始为空）
    ├── src/                # Python / PyTorch 源代码（空）
    ├── cpp/                # C++ 源代码（空）
    ├── data/               # 赛题数据（空）
    ├── figures/            # 生成的高清图表 ← 代码脑产出（仅 .gitkeep）
    ├── output/             # CSV 结果数据 ← 代码脑产出（仅 .gitkeep）
    ├── notebooks/          # Jupyter Notebooks（空）
    │
    └── paper/              # 【论文脑工作区】
        ├── CLAUDE.md       # ⭐【论文脑】全局配置（AI 读）
        ├── main.tex        # 主文档（从模板填充）
        ├── mathorcup_template.tex  # 官方模板（禁止修改导言区！）
        ├── references.bib  # 参考文献（空）
        └── sections/       # 各章节 .tex 分块（仅占位文件）
            ├── 00_abstract.tex
            ├── 01_intro.tex
            ├── 02_symbols.tex
            ├── 03_model_1.tex
            ├── 04_model_2.tex
            ├── 05_model_3.tex
            ├── 06_model_4.tex
            ├── 07_validation.tex
            ├── 08_conclusion.tex
            └── 09_appendix.tex
```

---

## 🔄 双脑协作工作流

### 代码脑 → 论文脑：信息传递规范

每完成一个问题的建模，代码脑在 `MEMORY.md` 中记录：

```markdown
## 【代码脑产出】问题一完成

### 核心公式
$$\min \sum_{i=1}^{n} c_i x_i \quad \text{s.t.} \ Ax \leq b$$

### 关键参数
- 决策变量: $x_i$ 表示第 i 种资源的使用量
- 目标函数系数: $c = [10, 15, 20, ...]$
- 约束矩阵: $A \in \mathbb{R}^{4 \times 6}$

### 生成文件
- figures/fig_problem1_loss.png      ← 残差分析图
- figures/fig_problem1_convergence.png ← 收敛曲线
- output/result_problem1.csv         ← 优化结果

### 给论文脑的备注
- 图中横轴为迭代次数，纵轴为目标函数值
- 最优解 x* = [1.2, 0.8, 2.1, ...]，最优值 f* = 156.3
- 与启发式算法对比见 output/comparison.csv
```

### 论文脑接到指令后

```text
你：帮我写问题一的求解章节

论文脑工作流程：
1. 读取 MEMORY.md → 理解代码脑的核心公式和参数
2. 读取 figures/fig_problem1_loss.png → 准备插入图表
3. 读取 output/result_problem1.csv → 转三线表
4. 提炼学术语言，写入 sections/03_model_1.tex
5. 更新 MEMORY.md 的【论文脑进度】
```

---

## 🛠️ Claude Code 工具链

### MCP 服务器

| MCP | 用途 | 场景 |
|-----|------|------|
| `sequential-thinking` | 链式推理 | 复杂建模设计 |
| `highs` | LP/MIP 求解 | 优化问题 |
| `math` | 公式求值 | 公式验证 |
| `fetch` | 联网检索 | 查 SOTA / 历年论文 |

### 容器内工具

| 工具 | 命令 |
|------|------|
| OR-Tools LP/MIP | `from ortools.linear_solver import pywraplp` |
| Polars 大数据 | `docker exec ... python -c "import polars as pl; ..."` |
| LaTeX 编译 | `bash scripts/paper.sh build` |
| 清理 LaTeX 辅助文件 | `bash scripts/paper.sh clean` |

---

## 📝 LaTeX 论文写作指南

### 论文脑排版规范

1. **绝对禁止修改模板导言区** — `mathorcup_template.tex` 的 `\documentclass` 到 `\begin{document}` 之间禁止改动
2. **图表引用必须完整**：
   ```latex
   \begin{figure}[htbp]
       \centering
       \includegraphics[width=0.8\textwidth]{../figures/xxx.png}
       \caption{详尽图注：横轴...纵轴...关键发现...}
       \label{fig:xxx}
   \end{figure}
   ```
3. **CSV 转三线表**（用 `booktabs`）：
   ```latex
   \begin{table}[htbp]
       \centering
       \caption{结果对比表}
       \begin{tabular}{lccc}
           \toprule
           指标 & 方法A & 方法B & 方法C \\
           \midrule
           准确率 & 0.95 & 0.97 & \textbf{0.98} \\
           \bottomrule
       \end{tabular}
   \end{table}
   ```

### Overleaf 协作（备选方案）

如果不想在本地编译，可采用：
1. 代码脑将结果上传到 Overleaf（手动或 Git）
2. 论文脑在 Overleaf 实时协作
3. 模板中标注 `%% OVERLEAF_SYNC` 提醒

---

## 🏆 多比赛并行

```bash
# 同时运行 3 个比赛的容器（共享同一镜像）
bash scripts/setup.sh mathorcup2026   # mathorcup2026-dev :8888
bash scripts/setup.sh 华为杯2026      # 华为杯2026-dev :8889
bash scripts/setup.sh 电工杯2026      # 电工杯2026-dev :8890

# 查看所有容器
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## ❓ 常见问题

**Q: TeX Live 安装太慢/太大？**
```bash
# 使用精简版（~500MB，默认选项）
bash scripts/setup.sh 比赛名称

# 使用完整版（约 4GB）
bash scripts/setup.sh 比赛名称 --full-latex
```

**Q: GPU 不可用？**
```bash
nvidia-smi  # 先检查宿主机驱动
docker run --rm --gpus all nvidia/cuda:12.6.0-base nvidia-smi  # 测试 Docker GPU
```

**Q: 端口冲突？**
```bash
# 修改 .env
JUPYTER_PORT=8889
```

**Q: 论文脑无法读取中文路径的图片？**
```bash
# 确保图片使用 ASCII 文件名
# 或者在 paper/CLAUDE.md 中配置 \usepackage{graphicx}
```

---

## 📄 License

MIT — 供个人和团队免费使用，可按需修改。