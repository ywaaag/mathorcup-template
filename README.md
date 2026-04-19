# MathorCup Template

这是一个面向 `MathorCup` 一类数学建模竞赛项目的模板源仓库。

它不是某一场比赛的实例项目，也不是单纯的 LaTeX 模板或代码模板。它的目标是把一套已经在实战里验证过的协作方式固化下来，让你后续创建的新比赛仓库天然具备这些能力：

- 容器内执行，减少宿主环境漂移
- 代码脑 / 论文脑分工明确
- 多 Agent 协作时有共享共识源，不靠聊天记忆硬猜
- 当前运行事实、论文入口、验收产物、任务边界可以被显式检查
- 即使没有 vendor-specific sub-agent，也能用多会话稳定协作

这份 `README.md` 主要写给人类维护者和使用者看。  
仓库里的大部分协议文档、合同文档、模板文档，默认都是面向 Agent 的。

## 1. 这个仓库到底是什么

建议先建立一个清晰心智模型：

1. `mathorcup-template` 是模板源仓库。
2. `scaffold/` 是模板真正的 source of truth。
3. 你以后真正参赛、真正写代码、真正写论文的目录，是“从这个模板渲染出来的实例仓库”。

换句话说：

- 这里不是 live 比赛项目。
- 这里的职责是“定义以后每个比赛项目该长什么样、怎么跑、怎么协作、怎么校验”。
- 未来实例仓库中的 `AGENTS.md`、`MEMORY.md`、runtime contract、workflow contract、task registry、paper config，都是从这里渲染出来的。

## 2. 适合什么场景

这个模板适合下面这类工作流：

- 你希望代码建模、论文写作、排版编译可以并行推进
- 你希望 Agent 不要频繁猜“当前入口文件是什么”“当前该改哪个目录”
- 你希望把主脑调度、worker 回传、经验复盘固化为机制
- 你希望项目默认运行在 Docker 容器里，而不是把 Python / C++ / LaTeX 依赖散落在 host
- 你希望后续每次新比赛都能快速起一个结构一致的实例仓库

如果你只想要一个轻量单文件比赛模板，这个仓库会显得偏重。  
如果你要的是“多人 / 多会话 / 多 Agent”长期协作脚手架，它就是按这个目标设计的。

## 3. 先理解两层世界

这个仓库里有两套“世界”，不要混淆。

### 3.1 模板源世界

也就是当前这个仓库本身。

关键特点：

- `scaffold/` 才是模板源
- repo root 下的 `project/` 不是某次比赛的真实运行状态
- 根目录不维护 live `MEMORY.md`
- 在这里直接跑 `bash scripts/validate_agent_docs.sh` 时，现在会识别出“template-source mode”，不会再把你误报成实例坏掉了

### 3.2 渲染后的实例世界

也就是你未来真正使用的比赛仓库。

关键特点：

- 会拥有 live `AGENTS.md`
- 会拥有 live `MEMORY.md`
- 会拥有 `project/spec/runtime_contract.md`
- 会拥有 `project/runtime/task_registry.yaml`
- 会拥有 `project/paper/runtime/paper.env`
- 这里才是日常建模、写论文、跑容器、交接 handoff、做 retrospective 的地方

## 4. 仓库结构总览

### 4.1 你最该关心的目录

- `scaffold/`
  - 模板源目录
  - 未来实例里绝大多数关键文件都从这里渲染
- `scripts/`
  - 脚本入口目录
  - 负责 render / bootstrap / deps / reset / validate / doctor / launcher
- `project/`
  - 这里只是模板源仓库里的 placeholder
  - 不要把它当真实实例目录来理解

### 4.2 `scaffold/` 里有什么

- `scaffold/AGENTS.md.template`
  - 实例仓库根协议模板
- `scaffold/MEMORY.md.template`
  - 实例运行状态板模板
- `scaffold/project/spec/`
  - runtime contract、workflow contract、roles matrix 等协议层
- `scaffold/project/runtime/`
  - task registry、work queue 等运行时状态骨架
- `scaffold/project/workflow/`
  - task packet、main-brain acceptance、queue board 等协作骨架
- `scaffold/project/output/review/`
  - worker feedback 模板
- `scaffold/project/output/retrospectives/`
  - retrospective 模板
- `scaffold/project/paper/runtime/paper.env.template`
  - 论文 active entrypoint 单一事实源

### 4.3 `scripts/` 里最重要的入口

- `scripts/setup.sh`
  - 总编排入口
- `scripts/render_templates.sh`
  - 只负责从 `scaffold/` 渲染实例文件
- `scripts/bootstrap_container.sh`
  - 只负责容器创建 / 启动
- `scripts/install_deps.sh`
  - 只负责容器内依赖安装
- `scripts/reset_state.sh`
  - 只负责重置运行状态
- `scripts/validate_agent_docs.sh`
  - 校验协议、roles、tasks、queue、paper config 等
- `scripts/doctor.sh`
  - 轻量诊断入口
- `scripts/dual_brain.sh`
  - 多脑 launcher
- `scripts/make_task_packet.sh`
  - 从角色 / task registry 生成任务包
- `scripts/claim_task.sh`
  - 认领任务并锁定路径
- `scripts/close_task.sh`
  - 把任务从 `in_progress` 推进到 `review` 或 `done`
- `scripts/check_worker_feedback.sh`
  - 检查 worker feedback 是否达标
- `scripts/check_retrospective.sh`
  - 检查 retrospective 是否达标

## 5. 最常见的人类使用路径

### 5.1 创建一个新比赛实例

最常用流程：

```bash
git clone <this-template-repo> mathorcup-<比赛名>
cd mathorcup-<比赛名>
bash scripts/setup.sh <比赛名>
```

默认会做这些事：

1. 从 `scaffold/` 渲染实例文件
2. 生成 `.env` 和 paper runtime config
3. 创建 / 启动容器
4. 安装依赖
5. 执行 doctor 和 validator

默认不会做这些事：

- 不会强制清空 `MEMORY.md`
- 不会删除历史 handoff
- 不会无提示覆盖已有 runtime config
- 不会把 rerun `setup.sh` 等同于“重置项目状态”

### 5.2 只想先渲染，不想启动容器

```bash
bash scripts/setup.sh demo --render-only --target /tmp/demo
```

适合：

- 想 smoke-test 模板是否自洽
- 想看渲染后的实例结构
- 想在临时目录里验证协议和脚本联动

### 5.3 只想检查当前实例是否健康

```bash
bash scripts/validate_agent_docs.sh --root <实例目录>
bash scripts/doctor.sh --root <实例目录>
```

两者区别：

- `validate_agent_docs.sh`
  - 更偏“协议 / 文档 / 运行配置 / workflow 一致性检查”
- `doctor.sh`
  - 更偏“给人看的一页诊断摘要”，包括 repo mode、runtime config、tooling、validation、container state

### 5.4 只想重置运行状态，不碰容器

```bash
bash scripts/reset_state.sh --target <实例目录>
```

这个动作和 `setup.sh` 是分离的。  
这是本模板的刻意设计：`setup` 不是 reset bomb。

### 5.5 只想修复容器或重装依赖

```bash
bash scripts/setup.sh --bootstrap-only --target <实例目录>
bash scripts/setup.sh --deps-only --target <实例目录>
```

这样做的好处是：

- 容器修复不等于状态重置
- 依赖修复不等于模板重渲染
- Agent 和人都更敢重复执行

## 6. 实例仓库创建后，你会得到什么

渲染后的实例仓库里，最重要的几个文件是：

- `AGENTS.md`
  - 根协议入口
- `MEMORY.md`
  - 运行状态板
- `project/spec/runtime_contract.md`
  - 当前项目运行事实总入口
- `project/spec/multi_agent_workflow_contract.md`
  - 多 Agent 协作协议
- `project/spec/agent_roles.yaml`
  - machine-readable 角色权限矩阵
- `project/runtime/task_registry.yaml`
  - machine-readable 任务注册表
- `project/runtime/work_queue.yaml`
  - 当前任务占用与并发状态
- `project/workflow/MAIN_BRAIN_QUEUE.md`
  - 给主脑和人类都更易读的队列表
- `project/paper/runtime/paper.env`
  - paper active entrypoint 单一事实源

可以把它们理解为四层：

1. `AGENTS.md`
   - 规定读哪些文档、按什么顺序工作
2. `runtime_contract.md`
   - 规定当前项目怎么跑、看什么算验收
3. `agent_roles.yaml` / `task_registry.yaml` / `work_queue.yaml`
   - 规定谁能改什么、谁正在改什么、能不能并行
4. `MEMORY.md` / feedback / retrospective
   - 记录当前状态、已验证事实、经验教训

## 7. 这个模板如何支持“人类 + Agent”协作

这个项目的核心思路不是“让 Agent 自己随便发挥”，而是：

- 把高频误判点写成合同
- 把高频冲突点写成 machine-readable 状态
- 把交接和复盘写成固定模板

### 7.1 角色划分

实例仓库默认支持这些角色：

- `main_brain`
  - 负责任务拆解、状态同步、验收、共识维护
- `code_brain`
  - 负责建模、代码、实验、图表、handoff
- `paper_brain`
  - 负责 LaTeX 写作和整合
- `layout_worker`
  - 负责编译、版式、验收产物
- `review_worker`
  - 负责一致性审查、验收审查、复盘沉淀
- `citation_worker`
  - 负责引用和术语审校
- `utility_worker`
  - 负责有限范围的脏活和辅助自动化

### 7.2 人类在这套体系里的位置

通常人类扮演的是“项目拥有者 / 主脑监督者”：

- 决定这轮任务目标
- 判断哪些任务可以并行
- 看 `task_registry.yaml` 和 `MAIN_BRAIN_QUEUE.md`
- 让 Agent 先 claim task，再开始改文件
- 验收 feedback 和 retrospective

### 7.3 没有 sub-agent 也能工作

如果你的环境没有 vendor-specific delegation：

- 仍然可以先 `claim_task`
- 再 `make_task_packet`
- 然后把生成的任务包贴给另一个终端 / 另一个会话里的 Agent

典型顺序通常是：

1. `bash scripts/claim_task.sh --task <task_id> --owner <owner> --target <dir>`
2. `bash scripts/make_task_packet.sh --task <task_id> --target <dir>`
3. 把任务包发给某个 Agent 会话
4. Agent 完成后补 feedback / retrospective
5. `bash scripts/check_worker_feedback.sh --task <task_id> --target <dir>`
6. `bash scripts/check_retrospective.sh --task <task_id> --target <dir>`
7. `bash scripts/close_task.sh --task <task_id> --to review|done --target <dir>`

这套模板依赖的是“文件化机制”，不是某个产品按钮：

- role matrix
- task registry
- work queue
- feedback gate
- retrospective gate

## 8. paper 工作流的关键设计

论文侧最容易出错的点，是“大家以为入口文件是 A，实际在编 B”。

这个模板用 `project/paper/runtime/paper.env` 作为 paper side 的单一事实源，里面会定义：

- `PAPER_ACTIVE_ENTRYPOINT`
- `PAPER_ACCEPT_PDF`
- `PAPER_ACCEPT_LOG`
- `PAPER_ACCEPT_AUX`
- 以及构建相关参数

这意味着：

- `paper.sh`
- `dual_brain.sh`
- validator
- runtime contract
- task packet

都能共享同一份事实，而不是各自猜一套。

如果你在实例仓库里切换论文入口，应该优先修改这个文件，而不是四处改脚本和文档。

## 9. 为什么保留“代码脑 / 论文脑”而不是只讲通用 Agent

因为在数模实战里，这两个角色的读写边界天然不同：

- `code_brain` 主要关心 `project/src`、`project/output`、`project/figures`
- `paper_brain` 主要关心 `project/paper`

把这个边界显式保留下来，有几个实际好处：

- 降低误改目录的概率
- 降低上下文污染
- 让主脑更容易拆任务
- 让“编译型脏活”和“建模型脏活”能独立下放

所以虽然模板已经扩展到多角色，但 `dual_brain` 仍然保留，是为了保持低成本心智模型。

## 10. 模板源仓库和实例仓库的常用命令区别

### 10.1 在模板源仓库里

你通常做的是：

```bash
bash scripts/validate_agent_docs.sh
bash scripts/validate_agent_docs.sh --template-source-only

tmpdir="$(mktemp -d)"
bash scripts/setup.sh demo --render-only --target "$tmpdir"
bash scripts/validate_agent_docs.sh --root "$tmpdir"
bash scripts/doctor.sh --root "$tmpdir"
```

注意：

- 模板源仓库根目录不是实例目录
- 这里跑 validator 时会识别 `template-source mode`
- 真正的实例校验要对渲染后的目录执行

### 10.2 在实例仓库里

你通常做的是：

```bash
bash scripts/setup.sh <比赛名>
bash scripts/validate_agent_docs.sh
bash scripts/doctor.sh
bash scripts/dual_brain.sh both
```

## 11. 常用脚本速查

### 11.1 `scripts/setup.sh`

用途：总入口。

常见模式：

```bash
bash scripts/setup.sh demo
bash scripts/setup.sh demo --render-only --target /tmp/demo
bash scripts/setup.sh --bootstrap-only --target <dir>
bash scripts/setup.sh --deps-only --target <dir>
bash scripts/setup.sh --doctor-only --target <dir>
bash scripts/setup.sh --reset-state --target <dir>
```

### 11.2 `scripts/validate_agent_docs.sh`

用途：做结构和一致性校验。

常见模式：

```bash
bash scripts/validate_agent_docs.sh --root <dir>
bash scripts/validate_agent_docs.sh --root <dir> --roles-only
bash scripts/validate_agent_docs.sh --root <dir> --tasks-only
bash scripts/validate_agent_docs.sh --root <dir> --queue-only
bash scripts/validate_agent_docs.sh --root <dir> --feedback-only
bash scripts/validate_agent_docs.sh --root <dir> --retrospective-only
```

模板源仓库还支持：

```bash
bash scripts/validate_agent_docs.sh --template-source-only
```

### 11.3 `scripts/doctor.sh`

用途：给人类一个比较容易读的诊断摘要。

常见模式：

```bash
bash scripts/doctor.sh
bash scripts/doctor.sh --root <dir>
```

### 11.4 `scripts/dual_brain.sh`

用途：启动代码脑 / 论文脑工作入口。

常见模式：

```bash
bash scripts/dual_brain.sh code
bash scripts/dual_brain.sh paper
bash scripts/dual_brain.sh both
```

### 11.5 `scripts/make_task_packet.sh`

用途：根据 role 或 task 自动生成 prompt/task packet。

常见模式：

```bash
bash scripts/make_task_packet.sh --role code_brain --target <dir>
bash scripts/make_task_packet.sh --task TASK_PAPER_DRAFT_SLOT --target <dir>
```

### 11.6 `scripts/claim_task.sh` / `scripts/close_task.sh`

用途：管理任务占用、状态推进和并发约束。

常见模式：

```bash
bash scripts/claim_task.sh --task TASK_CODE_MODEL_SLOT --owner alice --target <dir>
bash scripts/claim_task.sh --task TASK_PAPER_DRAFT_SLOT --owner bob --lock project/paper/sections --target <dir>
bash scripts/close_task.sh --task TASK_CODE_MODEL_SLOT --to review --target <dir>
bash scripts/close_task.sh --task TASK_REVIEW_CONSISTENCY --to done --accepted-by main_brain --target <dir>
```

### 11.7 `scripts/check_worker_feedback.sh` / `scripts/check_retrospective.sh`

用途：在主脑验收前检查 worker 回传是否满足最小结构要求。

常见模式：

```bash
bash scripts/check_worker_feedback.sh --task TASK_CODE_MODEL_SLOT --target <dir>
bash scripts/check_retrospective.sh --task TASK_REVIEW_CONSISTENCY --target <dir>
```

## 12. 人类最容易踩的坑

### 12.1 把模板源仓库误当成实例仓库

这是最常见的误区。

症状：

- 直接在模板源仓库根目录里找 live `MEMORY.md`
- 直接把 repo root 下的 `project/` 当成比赛项目
- 直接对模板源仓库根目录跑实例级 validator，再疑惑为什么缺 live 文件

正确做法：

- 模板维护改 `scaffold/`
- 实例验证对渲染目录执行

### 12.2 把 rerun `setup.sh` 当成 reset

现在不是这个语义。

正确理解：

- `setup.sh` 默认是安全重跑的 orchestration
- `reset_state.sh` 才是显式 destructive path

### 12.3 让 Agent 直接凭感觉改文件

正确做法是：

- 先看 runtime contract
- 再看 role matrix
- 再看 task registry / work queue
- 再生成 task packet

### 12.4 论文入口漂移后只改脚本不改 `paper.env`

正确做法：

- 优先改 `project/paper/runtime/paper.env`
- 再让脚本和文档自动消费这份共享事实

## 13. 如果你要维护这个模板本身

维护模板时，建议遵守这条顺序：

1. 先改 `scaffold/` 中对应模板源
2. 如果改到脚本行为，再看 `scripts/setup.sh` / `scripts/render_templates.sh` / `scripts/validate_agent_docs.sh`
3. 用临时目录做渲染验证
4. 确认模板源仓库模式和实例模式都没有被破坏

推荐最小验证：

```bash
tmpdir="$(mktemp -d)"
bash scripts/setup.sh demo --render-only --target "$tmpdir"
bash scripts/validate_agent_docs.sh --root "$tmpdir"
bash scripts/doctor.sh --root "$tmpdir"
```

如果你改的是模板源仓库自身的行为，也建议补一次：

```bash
bash scripts/validate_agent_docs.sh
bash scripts/doctor.sh
```

## 14. 相关文档

- [MIGRATION_TO_AGENT_FIRST_WORKFLOW.md](MIGRATION_TO_AGENT_FIRST_WORKFLOW.md)
  - 解释为什么模板从旧结构迁移到现在的 scaffold-first / agent-first 结构
- [AGENTS.md](AGENTS.md)
  - 模板仓库维护协议

## 15. 一句话总结

如果只用一句话概括这个项目：

它不是“给人手工搭比赛目录”的模板，而是“给人和 Agent 共同维护比赛项目”的可执行脚手架。
