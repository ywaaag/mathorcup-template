# MathorCup Template (Agent-First)

这是一个可复用的数模模板，默认面向 Agent 协议，不面向人类教程。

## 核心文件
- `AGENTS.md`: 代码脑硬约束
- `project/paper/AGENTS.md`: 论文脑硬约束
- `MEMORY.md`: 运行时状态板（固定 7 段，<=120 行）
- `project/output/handoff/`: 题目交接文档目录（每题一个文件）

## 快速使用
```bash
# 1) 新克隆后初始化
bash scripts/setup.sh <competition_name>

# 2) 启动代码脑或论文脑（启动前会自动校验协议）
bash scripts/dual_brain.sh code
bash scripts/dual_brain.sh paper
```

## 文档校验
```bash
# 全量校验
bash scripts/validate_agent_docs.sh

# 仅校验 MEMORY.md
bash scripts/validate_agent_docs.sh --memory-only

# 仅校验 handoff 文档
bash scripts/validate_agent_docs.sh --handoff-only
```

## 协议摘要
- `MEMORY.md` 固定标题顺序：
  - `## Phase`
  - `## Current Task`
  - `## Active Problem`
  - `## Decisions`
  - `## Blockers`
  - `## Next Actions`
  - `## Handoff Index`
- handoff 命名必须是：`P{n}_{topic}_{YYYYMMDD}.md`
- handoff 固定字段：`Problem` / `Inputs` / `Method` / `Outputs` / `For Paper Brain` / `Risks`
- handoff 每个字段最多 5 行非空内容

## 目录（精简）
```text
.
├── AGENTS.md
├── MEMORY.md
├── scripts/
│   ├── setup.sh
│   ├── dual_brain.sh
│   └── validate_agent_docs.sh
└── project/
    ├── output/handoff/
    └── paper/AGENTS.md
```

## 说明
- 每场比赛建议从 GitHub 拉取新模板并重新初始化。
- `legacy/claude/` 仅用于历史回溯，不参与当前流程。
