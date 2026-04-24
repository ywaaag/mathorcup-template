# mathorcup-template 真实任务流测试报告

测试日期：2026-04-24

## 结论

本轮用一个全新的临时实例测试了更接近真实使用的多 Agent 工作流：主脑创建实例并启动容器，然后通过 `run_exec_worker.sh` 把一个简单 `code_brain` 任务交给 `codex exec` worker 执行。worker 成功读取任务包、写入代码侧产物、创建 handoff、更新 `MEMORY.md -> Handoff Index`、填写 feedback，并返回结构化结果。主脑侧随后完成 feedback gate、retrospective gate、close 到 `review`、状态一致性检查和 paper build。

整体结论：当前系统可以完成一次真实的 `main_brain -> codex exec worker -> artifact -> feedback -> review gate` 闭环。

## 测试环境

- 模板源目录：`/home/ywag/mathorcup-template`
- 临时实例目录：`/tmp/mathorcup-template-realflow-20260424_212352.PUj5xc`
- 测试容器：`realflow-20260424_212352`
- 测试容器状态：已清理
- worker backend：`codex exec`
- 任务：`TASK_CODE_MODEL_SLOT`
- owner：`realflow_code`

## 任务目标

派发给 worker 的任务目标是一个最小真实场景：

```text
扮演 code_brain，在允许范围内创建一个最小但完整的代码侧产物。
写入 project/output/realflow_metrics.csv，内容包含三行样例指标。
写入 project/output/handoff/P0_realflow_smoke_20260424.md，严格使用 HANDOFF_TEMPLATE 的 6 个二级标题。
把 handoff 加入 MEMORY.md 的 Handoff Index。
完成后填写 task 对应 feedback 文件。
不要修改 project/paper，不要关闭任务。
```

## 执行链路

执行命令链：

```bash
bash scripts/setup.sh realflow --render-only --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/validate_agent_docs.sh --root /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/bootstrap_container.sh --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/exec_healthcheck.sh --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/run_exec_worker.sh --task TASK_CODE_MODEL_SLOT --owner realflow_code --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc --with-retrospective --goal "<realflow smoke goal>"
bash scripts/validate_agent_docs.sh --root /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/show_task.sh --task TASK_CODE_MODEL_SLOT --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/list_history.sh --task TASK_CODE_MODEL_SLOT --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/check_worker_feedback.sh --task TASK_CODE_MODEL_SLOT --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/check_retrospective.sh --task TASK_CODE_MODEL_SLOT --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/close_task.sh --task TASK_CODE_MODEL_SLOT --to review --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/check_state_consistency.sh --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc
bash scripts/paper.sh --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc build
docker rm -f realflow-20260424_212352
```

全部命令返回码均为 `0`。

## Worker 实际产物

worker 生成了以下关键文件：

- `project/output/realflow_metrics.csv`
- `project/output/handoff/P0_realflow_smoke_20260424.md`
- `project/output/review/TASK_CODE_MODEL_SLOT_feedback.md`
- `project/output/retrospectives/TASK_CODE_MODEL_SLOT_retrospective.md`
- `project/output/review/exec_runs/TASK_CODE_MODEL_SLOT_20260424_212406_exec_packet.md`
- `project/output/review/exec_runs/TASK_CODE_MODEL_SLOT_20260424_212406_exec_last_message.md`

CSV 内容：

```csv
metric,value,unit,notes
sample_flow_rate,12.5,m3_per_s,smoke metric placeholder
sample_travel_time,8.2,min,smoke metric placeholder
sample_capacity_ratio,0.76,ratio,smoke metric placeholder
```

handoff 结果：

- 文件名符合 `P{n}_{topic}_{YYYYMMDD}.md`
- 包含 `Problem / Inputs / Method / Outputs / For Paper Brain / Risks` 六个二级标题
- 明确说明所有数值都是 synthetic smoke placeholders
- 已写入 `MEMORY.md -> ## Handoff Index`

## 状态机结果

关键状态变化：

- `TASK_CODE_MODEL_SLOT` 从 `ready` 被 claim 到 `in_progress`
- `run_exec_worker.sh` 生成 packet 并初始化 feedback / retrospective skeleton
- 事件流记录 `worker.started`
- worker 成功完成后记录 `worker.completed`
- 主脑执行 feedback 与 retrospective gate
- 主脑执行 `close_task.sh --to review`
- 任务最终状态：`review`
- `work_queue.json -> active_items` 清空

`check_state_consistency.sh` 结果：

```text
event log parsed: 11 nonempty event(s)
no state consistency errors detected
Result: PASS
```

## Paper 验证

执行：

```bash
bash scripts/paper.sh --target /tmp/mathorcup-template-realflow-20260424_212352.PUj5xc build
```

结果：

- 编译成功
- host-visible PDF：`/tmp/mathorcup-template-realflow-20260424_212352.PUj5xc/project/paper/main.pdf`
- LaTeX 日志包含：`Output written on main.pdf (1 page).`

## 发现的问题

### 1. retrospective gate 只校验结构，不校验内容完整度

本轮 `--with-retrospective` 创建了 retrospective 文件，`check_retrospective.sh` 返回通过，但文件中的 `Real Phenomenon / Investigation / Verified Facts / Reusable Guardrails` 等主体字段仍为空。

这说明当前 gate 是“标题结构 gate”，不是“内容质量 gate”。如果系统要用于真实多 Agent 复盘，需要增强 `check_retrospective.sh` 或底层 `audit_index.py`，至少检查关键字段是否存在非空内容。

### 2. show_task 日志在 close 前采集，报告了 in_progress

本轮命令顺序里 `show_task_after_worker` 在 `close_task.sh --to review` 之前执行，所以该日志显示 `status: in_progress` 是正常现象。后续 registry 已确认任务最终状态为 `review`。

### 3. worker 可以按任务授权修改 MEMORY.md

本轮 addendum 明确要求 worker 把 handoff 加入 `MEMORY.md -> Handoff Index`，这符合当前 code_brain restricted memory permissions。但这也证明：只要任务包授权，worker 可以触碰 `MEMORY.md` 的部分章节。后续如果要强化主脑单一写入权，需要把“handoff indexing”改成工具接口，而不是让 worker 直接编辑 Markdown。

## 判断

这次测试证明系统当前不是纯文档脚手架，已经具备实际编排能力：

- `codex exec` 后端可用
- 任务包能被 worker 理解
- worker 能按 role/task scope 生成产物
- callback/event log 能记录关键动作
- feedback gate 与 close gate 能推动任务进入 review
- 状态一致性检查能在任务闭环后通过
- paper build 不受代码侧 smoke 任务影响

主要短板不是“跑不起来”，而是 gate 的质量还偏结构化：它能证明文件存在、标题正确、状态一致，但还不能充分证明 feedback / retrospective 的内容质量。

## 建议

下一步优先补两个小改动：

- 增强 `check_retrospective.sh`：要求关键字段非空，避免空复盘通过 gate。
- 增加 `scripts/smoke_realflow.sh`：把本轮真实任务流固化成可重复测试脚本，覆盖 `render -> bootstrap -> exec worker -> gate -> review -> paper build -> cleanup`。
