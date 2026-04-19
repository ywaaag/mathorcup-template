# Migration To Agent-First Workflow

## 为什么要迁移

旧版模板的问题主要有三类：

1. `.template` 与 live 文件混放，Agent 很容易误判哪个才是 source of truth。
2. `scripts/setup.sh` 同时负责 render、container、deps、reset，rerun 风险太大。
3. 缺少 runtime contract、多 Agent workflow contract、prompt-template library、retrospective 机制，导致实例仓库里的 Agent 只能靠聊天猜上下文。

## 这轮做了什么结构改造

### 1. Source Of Truth 收拢到 `scaffold/`

- 未来实例文件的模板源统一迁到 `scaffold/`。
- 根目录不再保留实例级 live `MEMORY.md`。
- `AGENTS.md.template` / `MEMORY.md.template` / `project/paper/AGENTS.md.template` 等旧根目录模板入口，迁入 `scaffold/` 后由渲染脚本生成实例文件。

### 2. setup 退化为编排入口

新职责边界：

- `scripts/render_templates.sh`
  - render / instantiate
- `scripts/bootstrap_container.sh`
  - container bootstrap
- `scripts/install_deps.sh`
  - deps install
- `scripts/reset_state.sh`
  - runtime state reset
- `scripts/doctor.sh`
  - environment/config doctor
- `scripts/validate_agent_docs.sh`
  - contract validation
- `scripts/setup.sh`
  - orchestration only

### 3. 补齐三层新合同

- runtime contract
- multi-agent workflow contract
- prompt-template library

同时新增：

- review feedback template
- retrospective template
- paper active entrypoint config

## 以后实例仓库该怎么用

1. 克隆模板。
2. 运行 `bash scripts/setup.sh <比赛名>`。
3. 在实例仓库中使用渲染出的：
   - `AGENTS.md`
   - `project/paper/AGENTS.md`
   - `MEMORY.md`
   - runtime/workflow/prompt contracts
4. 若 paper 入口改变，只改：
   - `project/paper/runtime/paper.env`
5. 若只想重置运行状态，执行：
   - `bash scripts/reset_state.sh`

## 哪些旧做法被废弃

### 废弃 1：把 live `MEMORY.md` 长期留在模板源仓库根目录

原因：
- 这是实例运行时状态，不是模板源。
- 长期保留会让 Agent 误把模板仓库当成某次比赛的 live 项目。

### 废弃 2：把 reset 行为绑进 `setup.sh`

原因：
- 容器修复和状态重置不是一回事。
- rerun setup 不应该带来“协议被重置、handoff 被清空”的副作用。

### 废弃 3：把 runtime facts 塞进 AGENTS / MEMORY

原因：
- 会让静态协议和动态事实互相污染。
- 漂移之后最难发现。

## 迁移后谁该先读什么

- 模板维护者：
  - `AGENTS.md`
  - `README.md`
  - `scaffold/`
  - `scripts/`
- 实例仓库主脑：
  - `AGENTS.md`
  - `MEMORY.md`
  - `project/spec/runtime_contract.md`
  - `project/spec/multi_agent_workflow_contract.md`
- 实例仓库论文脑：
  - `project/paper/AGENTS.md`
  - `../../MEMORY.md`
  - `project/paper/spec/paper_runtime_contract.md`
  - indexed handoffs
