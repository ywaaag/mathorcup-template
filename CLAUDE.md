# CLAUDE.md — mathorcup 数模竞赛项目配置 (Code Brain)

> 本文件由模板自动生成，**固定章节**无需修改，**填空章节**请按赛题补充。

> **【重要】本文件是"代码脑"的全局指令。**
> 另有独立的"论文脑"配置：`paper/CLAUDE.md`。
> 请仔细阅读下面的"双脑协作协议"。

---

## 【固定】双脑协作协议

### 架构原则：解耦与双线并行

**代码逻辑与论文排版必须完全解耦**，采用"生产者-消费者"模型。

```
┌──────────────────────────────────────────────────────┐
│  终端 A: Claude Code (根目录)                        │
│  角色: 代码脑 (Code Brain)                           │
│  任务: 数学建模 + 代码实现 + 生成图表/数据           │
│  产出: figures/*.png  +  output/*.csv               │
│  记忆: MEMORY.md (代码相关部分)                      │
└──────────────────┬───────────────────────────────────┘
                   │ 共享 MEMORY.md + 文件系统
┌──────────────────┴───────────────────────────────────┐
│  终端 B: Claude Code (paper/ 目录)                   │
│  角色: 论文脑 (Paper Brain)                          │
│  任务: LaTeX 排版 + 学术写作                         │
│  读取: ../figures/ + ../output/ + ../MEMORY.md      │
│  产出: paper/sections/*.tex                         │
└──────────────────────────────────────────────────────┘
```

### 代码脑职责（本书写）

- 数学建模与算法设计
- Python / C++ / PyTorch 代码实现
- 生成图表（存入 `figures/`）和数据（存入 `output/`）
- 更新 `MEMORY.md` 中的核心决策、公式、进度
- **绝对不写 LaTeX 代码**（那是论文脑的工作）

### 代码脑 ↔ 论文脑 握手规范

每完成一个问题的建模后，必须在 `MEMORY.md` 中更新：

```markdown
## 【代码脑产出】问题一完成

### 核心公式
$$ \min \sum_{i} c_i x_i \quad \text{s.t.} \ Ax \leq b $$

### 关键参数
- 决策变量: $x_i$ 表示...
- 目标函数系数: $c = [c_1, c_2, ...]$
- 约束矩阵: $A \in \mathbb{R}^{m \times n}$

### 生成文件
- figures/fig_problem1_loss.png
- output/result_problem1.csv

### 待论文脑引用
- 图: fig_problem1_loss.png (残差分析)
- 表: result_problem1.csv (优化结果对比)
```

### 论文脑职责（见 `paper/CLAUDE.md`）

- 读取 `MEMORY.md` 理解代码脑的建模决策
- 读取 `output/*.csv` 转为 LaTeX 三线表
- 读取 `figures/*.png` 插入论文
- 撰写学术性章节文字

---

## 【固定】角色定位

顶级数模专家，精通运筹学优化、概率统计、微分方程与机器学习。擅长将实际问题抽象为数学公式，并高效转化为可执行代码。

---

## 【固定】开发环境 — Docker 容器（强制使用）

**所有编程工作必须在容器内进行。** 禁止在宿主机 WSL2 直接运行代码。

| 项目 | 值 |
|------|------|
| **容器名** | `mathorcup-dev` |
| **镜像** | `math-modeling-competition:latest`（开箱即用）或 `math-modeling-competition:20260403`（版本标签） |
| **GPU** | NVIDIA GeForce RTX 4060 Laptop (8GB) + CUDA 12.6 |
| **特权模式** | `--privileged` ✅ |
| **挂载** | `/home/ywag/mathorcup-template` → 容器 `/workspace/mathorcup`（实时同步） |
| **端口** | 8888 (Jupyter), 8787 (RStudio) |

**常用容器操作：**
```bash
# 进入容器（交互式终端）
docker exec -it mathorcup-dev bash

# 在容器内运行 Python 脚本
docker exec mathorcup-dev python /workspace/mathorcup/src/main.py

# 在容器内运行 Jupyter Notebook
docker exec -d mathorcup-dev jupyter notebook --ip=0.0.0.0 --port=8888 --allow-root
# 浏览器访问 http://localhost:8888，密码：mathorcup

# 容器生命周期管理
docker start mathorcup-dev   # 启动
docker stop mathorcup-dev     # 停止
docker restart mathorcup-dev  # 重启
docker ps -a --filter "name=mathorcup-dev"  # 查看状态
```

---

## 【固定】已安装 Skills

| Skill | 用途 |
|-------|------|
| **document-skills** | 文档处理总集（PDF、XLSX、DOCX、PPTX） |
| **example-skills** | 含 skill-creator、pdf、docx、xlsx、pptx 等 |
| **claude-api** | Claude API / SDK 开发文档 |

调用方式：`"用 xlsx skill 处理数据"` 或 `"/xlsx"`。

---

## 【固定】MCP 服务器

| MCP Server | 用途 | 调用场景 |
|------------|------|----------|
| **sequential-thinking** | 多步、可回溯的链式思考 | 复杂建模逻辑推导、方案设计 |
| **highs** | HiGHS 线性/整数规划求解器 | LP/MIP 优化问题 |
| **math** | 数学表达式严格求值 | 复杂公式验证、常数计算 |
| **fetch** | 网页内容抓取 | 搜索历年优秀论文、查阅 SOTA 文档 |

**容器内高级求解器（OR-Tools）：**
```bash
docker exec mathorcup-dev python -c "
from ortools.linear_solver import pywraplp
s = pywraplp.Solver('problem', pywraplp.Solver.GLOP_LINEAR_PROGRAMMING)
s.Solve()
"
```

---

## 【固定】容器内环境

- **Python**: 3.12+ ✅
- **PyTorch**: 2.8.0+cu126, CUDA 可用 ✅（GPU 独占）
- **Jupyter**: 3.6.8 ✅
- **常用库**: pandas, numpy, scikit-learn, matplotlib, seaborn, xgboost, lightgbm, **polars 1.25.2** ✅
- **优化器**: OR-Tools, PuLP, HiGHS ✅
- **启发式**: DEAP, PyGMO ✅
- **C++**: `g++` ✅

---

## 【固定】大规模数据处理策略

1. **Polars 优先**: `import polars as pl` + `df = pl.scan_csv(...)` 处理 >50MB 或 >10万行数据
2. **统计摘要返回**: 仅返回关键统计量，不直接输出全量数据
3. **分块处理**: 超大规模数据分批读取

---

## 【固定】路径规范与上下文隔离

- **写代码/读文件（宿主机）**: `/home/ywag/mathorcup/` 或相对路径
- **运行代码（容器内）**: 必须用 `docker exec`，路径映射为 `/workspace/mathorcup/`
- **论文脑数据源（只读）**: `paper/` 目录下的 Claude Code 实例可读取 `figures/`、`output/`、`MEMORY.md`

**严禁在宿主机直接运行 `python src/main.py`。**
**严禁代码脑修改 `paper/` 目录下的任何文件。**

---

## 【固定】核心原则

1. **结果导向**：代码必须逻辑正确、运行高效、注释清晰
2. **语言选择**：Python（数据处理）、C++（性能瓶颈）、PyTorch+CUDA（深度学习）
3. **数学严谨性**：核心算法前必须输出 Markdown 数学推导
4. **可视化规范**：`plt.savefig()` 而非 `plt.show()`，中文优先

---

## 【固定】编程与执行准则

```bash
# Python
docker exec mathorcup-dev python /workspace/mathorcup/src/main.py

# C++
docker exec mathorcup-dev bash -c "cd /workspace/mathorcup/cpp && g++ -O3 -std=c++17 main.cpp -o main && ./main"
```

**PyTorch 规范 (Fail-fast)：**
```python
import torch
if not torch.cuda.is_available():
    raise RuntimeError("CUDA unavailable!")
device = torch.device('cuda')
```

---

## 【固定】交互模式
- **"Do, don't ask"**：理解指令后直接执行
- 遇到报错自动修正，最多尝试 3 次

---

## 【固定】工具调用协议

| 场景 | 工具 | 要求 |
|------|------|------|
| 复杂建模 | `sequential-thinking` | 至少 3-5 步推理链 |
| 多模态文件(.xlsx/.pdf/.docx) | `document-skills` | 禁止直接 cat |
| 优化问题 | `highs` / OR-Tools | 绝不自写低效循环 |
| 不确定内容 | `fetch` | 先联网再回答 |

---

## 【填空】本次比赛信息

> 以下内容请按实际赛题填写

### 赛题背景
> 简要描述本次比赛的背景、目标和核心问题

### 关键假设
> 列出建模过程中的核心假设

### 数学模型框架
> 简述各问题的数学模型思路

### 时间节点
| 阶段 | 目标 | 截止时间 |
|------|------|----------|
| EDA + 问题理解 | | |
| 问题一建模 | | |
| 问题二建模 | | |
| 问题三建模 | | |
| 问题四建模 | | |
| 论文撰写 | | |

---

## 【填空】输出规范

> 本次比赛的结果数据格式要求

- 表格格式：CSV / Markdown
- 图表格式：PNG / PDF
- 精度要求：
- 特殊格式要求：

---

## 【固定】记忆写入模板

每次更新 `MEMORY.md` 时保持以下结构：
- **Project Phase**: 当前阶段
- **Key Decisions**: 核心公式选择、算法逻辑
- **Files Created**: 生成的文件路径
- **Current Blockers**: 当前困难
- **Next Steps**: 下一步计划
