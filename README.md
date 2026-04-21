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
- 会拥有 `project/spec/callback_hooks.json`
- 会拥有 `project/runtime/task_registry.json`
- 会拥有 `project/runtime/event_log.jsonl`
- 会拥有 `project/paper/runtime/paper.env`
- 这里才是日常建模、写论文、跑容器、交接 handoff、做 retrospective 的地方

## 4. 仓库结构总览

### 4.1 你最该关心的目录

- `scaffold/`
  - 模板源目录
  - 未来实例里绝大多数关键文件都从这里渲染
- `.codex/`
  - 模板源仓库自己的 Codex native front door
  - 只负责 requirements / skills 入口约束，不承担 runtime truth
- `scripts/`
  - 脚本入口目录
  - 负责 render / bootstrap / deps / reset / validate / doctor / launcher
- `project/`
  - 这里只是模板源仓库里的 placeholder
  - 不要把它当真实实例目录来理解

### 4.2 `scaffold/` 里有什么

- `scaffold/AGENTS.md.template`
  - 实例仓库根协议模板
- `scaffold/.codex/`
  - 未来实例仓库的 Codex native front door 模板
- `scaffold/MEMORY.md.template`
  - 实例运行状态板模板
- `scaffold/project/spec/`
  - runtime contract、workflow contract、roles matrix、callback hooks 等协议层
- `scaffold/project/runtime/`
  - task registry、work queue、event log 等运行时状态骨架
- `scaffold/project/workflow/`
  - task packet、main-brain acceptance、queue board 等协作骨架
- `scaffold/project/output/review/`
  - worker feedback 模板，以及 callback/exec harness 的轻量运行产物目录
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
- `scripts/export_reference_image.sh`
  - 检测并导出厚镜像 reference runtime
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
- `scripts/list_open_tasks.sh`
  - 列出当前可直接派发或按条件过滤的任务
- `scripts/dispatch_task.sh`
  - 主脑一键完成 claim + packet 输出
- `scripts/exec_healthcheck.sh`
  - 对 `codex exec` 做一次最小真实探活
- `scripts/run_exec_worker.sh`
  - 用 `codex exec` 串起 claim + packet + feedback init + worker 执行
- `scripts/process_callbacks.sh`
  - 处理 event log 对应的 callback hooks，并生成可审计 callback artifact
- `scripts/run_exec_batch.sh`
  - 并行启动多个 write-scope 不冲突的 exec workers
- `scripts/show_task.sh`
  - 主脑快速查看单个 task 的当前状态、artifact、recent events、next-step hint
- `scripts/list_history.sh`
  - 主脑快速查看单个 task 的 event timeline、queue history、callback artifacts、exec artifacts
- `scripts/adjudicate_task.sh`
  - 主脑生成结构化 adjudication artifact，用来比较多个 worker 结果并形成裁决草案
- `scripts/main_brain_summary.sh`
  - 轻量主脑摘要，快速看 active/failed/check-ready/adjudication-candidate/decision-queue
- `scripts/submit_feedback.sh`
  - 为 worker 初始化 feedback / retrospective skeleton
- `scripts/close_task.sh`
  - 把任务从 `in_progress` 推进到 `review` 或 `done`
- `scripts/reopen_task.sh`
  - 把 `blocked/review/done` 任务按规则重新放回工作流
- `scripts/cancel_task.sh`
  - 中止当前 active task，并释放 path lock
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

### 5.6 默认 reference image 与权限基线

当前模板默认复用的基础镜像是：

- `mathorcup-runtime:latest`

这个 tag 现在来自参考容器 `mathorcup_v1-dev` 的导出镜像，并保留了版本标签：

- `mathorcup-runtime:20260419`

初始化后的默认容器权限基线会写进实例 `.env`，并由 `bootstrap_container.sh` 读取：

- `CONTAINER_RUNTIME=nvidia`
- `CONTAINER_GPUS=all`
- `CONTAINER_PRIVILEGED=true`
- `CONTAINER_USER=root`
- `CONTAINER_GRANT_SUDO=yes`

也就是说，默认行为就是：

- 以 `root` 用户启动
- 以 `--privileged` 模式启动
- 请求全部 GPU
- 容器内保留 `GRANT_SUDO=yes`

基于当前 reference image 的已验证内部环境：

- `Python 3.12.12`
- `pip 24.1.2`
- `latexmk 4.83`
- `XeTeX (TeX Live 2023/Debian)`
- `R 4.5.1`
- `sudo` 免密可用
- `nvidia-smi` 可用（前提是宿主 Docker GPU runtime 可用）
- `biber`
- `fd`
- `tree`
- `yq`

如果你用的不是这份已导出的 reference image，或者容器内部 baseline 有漂移，再执行：

```bash
bash scripts/install_deps.sh --target <实例目录>
```

如果后续你想用新的 reference container 刷新这套厚镜像，优先使用：

```bash
bash scripts/export_reference_image.sh \
  --container mathorcup_v1-dev \
  --image mathorcup-runtime:20260419 \
  --tag-latest
```

这个脚本会：

- 检测厚镜像 baseline
- 如果 reference container 的 Ubuntu 主仓 codename 与容器真实 OS 不一致，先自动归一化
- 自动补装 `biber / fd-find / tree / yq`
- 在只有 `fdfind` 时补出 `fd` 命令
- 再执行 `docker commit` 导出 reference image

## 6. 实例仓库创建后，你会得到什么

渲染后的实例仓库里，最重要的几个文件是：

- `AGENTS.md`
  - 根协议入口
- `MEMORY.md`
  - 运行状态板
- `.codex/requirements.toml`
  - Codex native front door summary
- `.codex/skills/`
  - Codex native working-method skills
- `.env`
  - container / image / host-path 的 machine truth
- `project/spec/runtime_contract.md`
  - 当前项目运行事实的 rendered mirror
- `project/spec/multi_agent_workflow_contract.md`
  - 多 Agent 协作协议
- `project/spec/agent_roles.json`
  - machine-readable 角色权限矩阵
- `project/runtime/task_registry.json`
  - machine-readable 任务注册表
- `project/runtime/work_queue.json`
  - 当前任务占用与并发状态
- `project/workflow/MAIN_BRAIN_QUEUE.md`
  - 给主脑和人类都更易读的队列表
- `project/paper/runtime/paper.env`
  - paper active entrypoint / acceptance artifacts 的 machine truth

可以把它们理解为四层：

1. `AGENTS.md`
   - 规定读哪些文档、按什么顺序工作
2. `runtime_contract.md`
   - 给人和 Agent 看的一份 rendered mirror；如果和 `.env` / `project/paper/runtime/paper.env` 冲突，config wins
3. `agent_roles.json` / `task_registry.json` / `work_queue.json`
   - 规定谁能改什么、谁正在改什么、能不能并行；其中 `owner` 只表示当前 active owner
4. `MEMORY.md` / feedback / retrospective
   - 记录当前状态、已验证事实、经验教训

另外还有一层 native bridge：

- `.codex/requirements.toml` / `.codex/skills/`
  - 负责把 Codex 引导到正确的 repo truth 和正确的工作法
  - 不和 `.env / paper.env / MEMORY.md / task_registry.json / work_queue.json / event_log.jsonl` 争夺 truth
  - 本轮默认不启用 `hooks.json`；repo harness 仍然是唯一必需的 workflow engine

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
- 看 `task_registry.json` 和 `MAIN_BRAIN_QUEUE.md`
- 让 Agent 先 claim task，再开始改文件
- 验收 feedback 和 retrospective

这套系统当前不是全自动 pipeline orchestration。  
它的定位是：

- 人工 / 主脑驱动
- machine-readable state 托底
- 用脚本把多步手工操作串成半自动 workflow
- 用 append-only event log 和受控 callback hooks 提供可回放的 orchestration harness

也就是说，它不会后台自动派发任务、不会轮询队列、不会自动把任务发到别的会话；但主脑可以用现成脚本把“派工、回填、打回、撤销”这些动作标准化。

### 7.3 没有 sub-agent 也能工作

如果你的环境没有 vendor-specific delegation，也暂时不想用 `codex exec`：

- 仍然可以先看 dispatch pool
- 再 dispatch task
- 然后把生成的任务包贴给另一个终端 / 另一个会话里的 Agent

典型顺序通常是：

1. `bash scripts/list_open_tasks.sh --open-only --target <dir>`
2. `bash scripts/dispatch_task.sh --task <task_id> --owner <owner> --target <dir>`
3. 把任务包发给某个 Agent 会话
4. dispatch 的 `task.dispatched` callback 会在缺失时自动补建 feedback skeleton
5. Agent 完成后填写 feedback / retrospective
6. 如果 feedback 缺失，或你要手工初始化 retrospective，再执行：
   - `bash scripts/submit_feedback.sh --task <task_id> --with-retrospective --target <dir>`
7. 如需重放最新 callback，可执行：
   - `bash scripts/process_callbacks.sh --latest --target <dir>`
8. `bash scripts/check_worker_feedback.sh --task <task_id> --target <dir>`
9. 视情况执行：
   - `bash scripts/close_task.sh --task <task_id> --to review|done --target <dir>`
   - `bash scripts/reopen_task.sh --task <task_id> --to ready|review|in_progress --reason <reason> --target <dir>`
   - `bash scripts/cancel_task.sh --task <task_id> --reason <reason> --target <dir>`

这套模板依赖的是“文件化机制”，不是某个产品按钮：

- role matrix
- task registry
- work queue
- feedback gate
- retrospective gate

### 7.4 `codex exec` worker 模式

如果你的环境里 `codex exec` 比 sub-agent 更稳，那么它可以作为这套系统的一等公民执行后端。

推荐顺序：

1. `bash scripts/exec_healthcheck.sh --target <dir>`
2. `bash scripts/run_exec_worker.sh --task <task_id> --owner <owner> --target <dir>`
3. 如需显式重放最新 callback，可执行：
   - `bash scripts/process_callbacks.sh --latest --target <dir>`
4. 主脑检查：
   - `bash scripts/check_worker_feedback.sh --task <task_id> --target <dir>`
   - 如本轮创建了 retrospective，再执行 `bash scripts/check_retrospective.sh --task <task_id> --target <dir>`
5. 主脑再决定：
   - `bash scripts/close_task.sh --task <task_id> --to review|done --target <dir>`
   - 或 `bash scripts/reopen_task.sh ...`
   - 或 `bash scripts/cancel_task.sh ...`

这条路径的边界要理解清楚：

- `run_exec_worker.sh` 不是后台调度器
- 它不会自动 close task
- 它不会替主脑判定 feedback 是否合格
- 它只是把“生成 packet、初始化回传骨架、调用 `codex exec`、保存最后一条消息”串成一条显式命令
- 关键动作会写入 `project/runtime/event_log.jsonl`，并触发受控 `callback_hooks`

### 7.5 callback / event-log / harness 是怎么工作的

这轮之后，实例仓库里不只有 packet + gate，还多了一个轻量 orchestration harness：

- `project/runtime/event_log.jsonl`
  - append-only event stream
- `project/spec/callback_hooks.json`
  - machine-readable event -> action 路由表
- `bash scripts/process_callbacks.sh`
  - 前台 callback processor
- `project/output/review/callback_runs/`
  - callback 派生出的可审计 artifact

这层机制的作用不是“替你自动做决定”，而是：

- 记录关键状态变化
- 在事件发生后执行受控 built-in action
- 帮主脑生成 next-step hint 和 run summary
- 让主脑可以重放、排查、复盘

你可以把它理解为：

- 不是后台守护进程
- 不是自动工作流引擎
- 而是文件化、可重放、由主脑显式触发的事件驱动 harness

### 7.6 有 sub-agent 时怎么用

如果环境支持 sub-agent delegation，也不要再维护一套独立状态系统。

推荐做法仍然是：

1. 主脑看 `task_registry.json` / `MAIN_BRAIN_QUEUE.md`
2. 主脑用 `dispatch_task.sh` 领取并生成 packet
3. 把 packet 发给 sub-agent
4. sub-agent 按同一套 feedback / retrospective / close / reopen / cancel 机制回传

也就是说：

- sub-agent 只是执行媒介
- 不是另一套 workflow contract
- 如果 `codex exec` 也可用，它和 sub-agent 只是两个不同的 worker backend
- 不建议 worker 自己继续任意分裂新总任务，除非主脑任务包显式允许

### 7.7 主脑怎么做审计与裁决

这轮之后，主脑侧不需要再手翻多个 json/jsonl/md 去猜一个 task 到底发生了什么。

主脑默认入口链是：

1. `bash scripts/doctor.sh --target <dir>`
2. `bash scripts/main_brain_summary.sh --target <dir>`
3. `bash scripts/show_task.sh --task <task_id> --target <dir>`
4. 如需看完整时间线，再执行：
   - `bash scripts/list_history.sh --task <task_id> --target <dir>`
5. 如果多个 worker 或多个 artifact 对同一 task 给出不同结论，再执行：
   - `bash scripts/adjudicate_task.sh --task <task_id> --target <dir>`
6. 然后由主脑显式决定：
   - `bash scripts/close_task.sh ...`
   - 或 `bash scripts/reopen_task.sh ...`
   - 或 `bash scripts/cancel_task.sh ...`

这条链的分工是：

- `doctor.sh`
  - 先确认 repo mode、tooling、runtime config truth 入口是否正常
- `main_brain_summary.sh`
  - 先看全局，再判断该 drill down 哪个 task
- `show_task.sh`
  - 看单任务当前状态、active owner、last actor、反馈/复盘是否齐全
- `list_history.sh`
  - 看事件链、queue history、callback / exec artifact
- `adjudicate_task.sh`
  - 只在需要结构化比较多个 worker 证据时再进入

这里要强调一条边界：

- 不推荐把“多个 Agent 彼此讨论”实现成自由聊天 relay
- 推荐方式是：
  - packet
  - feedback
  - retrospective
  - event log
  - callback artifacts
  - adjudication artifact
  - main-brain decision

也就是说，adjudication 是结构化比较与裁决草案，不是自动决定 `done`。

### 7.8 主脑摘要命令

如果你想先看全局，再决定要不要 drill down 到某个 task：

```bash
bash scripts/main_brain_summary.sh --target <dir>
```

它会优先回答这些问题：

- 哪些 task 正在跑
- 哪些 task 最近失败或被 block
- 哪些 feedback / retrospective 已经写好但还没 check
- 哪些 task 适合先做 adjudicate
- 哪些 task 已经进入主脑 decision queue

注意：

- `show_task.sh` 和 `main_brain_summary.sh` 里出现的 `owner` 现在只表示当前 active owner
- task 一旦离开 `in_progress`，registry 里的 `owner` 会被清空
- 如果你想看最近执行者，应该看 `last_actor`、`event_log.jsonl` 或 `work_queue.json -> history`

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

同时要注意：

- `project/paper/runtime/paper.env` 是 machine truth
- `project/paper/spec/paper_runtime_contract.md` 是 rendered mirror
- 如果二者有冲突，以 `paper.env` 为准

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

### 11.1.1 `scripts/export_reference_image.sh`

用途：以参考容器为母体，补齐厚镜像 baseline 后导出 reference image。

常见模式：

```bash
bash scripts/export_reference_image.sh --check-only
bash scripts/export_reference_image.sh --container mathorcup_v1-dev --image mathorcup-runtime:20260419 --tag-latest
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

### 11.6 `scripts/list_open_tasks.sh` / `scripts/dispatch_task.sh`

用途：让主脑先看 dispatch pool，再一键派单。

常见模式：

```bash
bash scripts/list_open_tasks.sh --target <dir>
bash scripts/list_open_tasks.sh --open-only --target <dir>
bash scripts/list_open_tasks.sh --status blocked --target <dir>
bash scripts/dispatch_task.sh --task TASK_PAPER_DRAFT_SLOT --owner alice --target <dir>
bash scripts/dispatch_task.sh --task TASK_REVIEW_CONSISTENCY --owner bob --packet-out /tmp/review_packet.md --target <dir>
```

注意：

- `--open-only` 只看 `todo/ready` 且 `owner=""` 的任务
- `blocked` 不在直接派发池里，想看它必须显式 `--status blocked`

### 11.7 `scripts/exec_healthcheck.sh` / `scripts/run_exec_worker.sh` / `scripts/run_exec_batch.sh`

用途：把 `codex exec` 接成一个可选但正式的 worker backend。

常见模式：

```bash
bash scripts/exec_healthcheck.sh --target <dir>
bash scripts/exec_healthcheck.sh --target <dir> --model gpt-5.4
bash scripts/run_exec_worker.sh --task TASK_REVIEW_CONSISTENCY --owner exec_review --target <dir>
bash scripts/run_exec_worker.sh --task TASK_REVIEW_CONSISTENCY --owner exec_review --with-retrospective --goal "只做 review output，不改源码" --target <dir>
bash scripts/run_exec_batch.sh --tasks TASK_CODE_MODEL_SLOT,TASK_UTILITY_SUPPORT --owner-prefix exec --lock TASK_CODE_MODEL_SLOT:project/src --lock TASK_CODE_MODEL_SLOT:project/output/review/TASK_CODE_MODEL_SLOT_feedback.md --lock TASK_UTILITY_SUPPORT:project/runtime --lock TASK_UTILITY_SUPPORT:project/output/review/TASK_UTILITY_SUPPORT_feedback.md --max-concurrency 2 --target <dir>
```

注意：

- `exec_healthcheck.sh` 只做一次最小真实探活，不是后台 health monitor
- `run_exec_worker.sh` 会串起 dispatch、feedback skeleton、`codex exec`、last-message 落盘
- `run_exec_batch.sh` 只负责并行 supervisor，不会自动判定任务 done
- 如果 task slot 的默认 allowed_paths 太宽，可以用 `--lock task_id:path` 给 batch 指定更窄的 claim scope
- 它不会自动 `close_task.sh`
- 如果 exec 失败，任务不会被自动取消，仍由主脑决定是 retry、cancel 还是 reopen
- 默认运行产物会落到 `project/output/review/exec_runs/`

### 11.8 `scripts/process_callbacks.sh`

用途：重放或显式处理 `event_log.jsonl` 对应的 callback hooks。

常见模式：

```bash
bash scripts/process_callbacks.sh --latest --target <dir>
bash scripts/process_callbacks.sh --event-id <event_id> --target <dir>
bash scripts/process_callbacks.sh --replay-from <event_id> --target <dir>
```

注意：

- 它只执行受控 built-in actions，不执行任意 shell callback
- 它不是后台 listener
- callback 派生 artifact 默认写到 `project/output/review/callback_runs/`
### 11.9 `scripts/claim_task.sh` / `scripts/close_task.sh`

用途：管理任务占用、状态推进和并发约束。

常见模式：

```bash
bash scripts/claim_task.sh --task TASK_CODE_MODEL_SLOT --owner alice --target <dir>
bash scripts/claim_task.sh --task TASK_PAPER_DRAFT_SLOT --owner bob --lock project/paper/sections --target <dir>
bash scripts/close_task.sh --task TASK_CODE_MODEL_SLOT --to review --target <dir>
bash scripts/close_task.sh --task TASK_REVIEW_CONSISTENCY --to done --accepted-by main_brain --target <dir>
```

### 11.10 `scripts/submit_feedback.sh`

用途：repair missing feedback skeleton、初始化 retrospective、或手工补建回传文件。

常见模式：

```bash
bash scripts/submit_feedback.sh --task TASK_CODE_MODEL_SLOT --target <dir>
bash scripts/submit_feedback.sh --task TASK_REVIEW_CONSISTENCY --with-retrospective --target <dir>
```

注意：

- canonical path 是 `dispatch_task.sh` 触发 `task.dispatched` callback 自动补 feedback skeleton
- `submit_feedback.sh` 不是和 dispatch 并列的主路径
- 它更适合 repair missing feedback、补 retrospective、或者手工补录

### 11.11 `scripts/reopen_task.sh` / `scripts/cancel_task.sh`

用途：标准化处理“任务打回重做”“任务中止撤销”。

常见模式：

```bash
bash scripts/cancel_task.sh --task TASK_PAPER_DRAFT_SLOT --reason "manual stop" --target <dir>
bash scripts/reopen_task.sh --task TASK_PAPER_DRAFT_SLOT --to ready --reason "retry later" --target <dir>
bash scripts/reopen_task.sh --task TASK_PAPER_DRAFT_SLOT --to in_progress --owner alice --reason "resume now" --target <dir>
bash scripts/reopen_task.sh --task TASK_LAYOUT_ACCEPTANCE --to review --reason "acceptance needs recheck" --target <dir>
```

状态机上要注意：

- `done` 不能直接跳回 `ready` 或 `in_progress`
- 如果要重开已验收任务，应先 `done -> review`
- 然后再由主脑决定是否 `review -> ready` 或 `review -> in_progress`
- task 一旦离开 `in_progress`，`owner` 会被清空；最近执行者应从 `event_log.jsonl` 或 `work_queue.json -> history` 读取

### 11.12 `scripts/check_worker_feedback.sh` / `scripts/check_retrospective.sh`

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
