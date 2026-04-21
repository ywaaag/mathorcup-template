---
name: main-brain-dispatch
description: "Use when acting as main_brain inside a rendered MathorCup instance and you need to inspect the ready pool, dispatch a bounded task, observe its status, or decide close, reopen, or cancel through repo scripts instead of hand-editing runtime truth."
---

# Main Brain Dispatch

Use this skill for task orchestration in a rendered instance.

## Read order

1. `.codex/requirements.toml`
2. `AGENTS.md`
3. `MEMORY.md`
4. `project/spec/runtime_contract.md`
5. `project/spec/multi_agent_workflow_contract.md`

## Default entry chain

```bash
bash scripts/doctor.sh --target <dir>
bash scripts/main_brain_summary.sh --target <dir>
bash scripts/show_task.sh --task <task_id> --target <dir>
```

## Dispatch path

```bash
bash scripts/list_open_tasks.sh --open-only --target <dir>
bash scripts/dispatch_task.sh --task <task_id> --owner <owner> --target <dir>
```

- `dispatch_task.sh` is the canonical path for feedback skeleton creation.
- `submit_feedback.sh` is only for repair or retrospective initialization.

## State transition rules

- Use `close_task.sh`, `reopen_task.sh`, and `cancel_task.sh`.
- Do not hand-edit:
  - `project/runtime/task_registry.json`
  - `project/runtime/work_queue.json`
  - `project/runtime/event_log.jsonl`

## Human gate

The main brain still decides acceptance. Native bridge files do not replace repo state or repo scripts.
