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
- `dispatch_task.sh` writes a packet artifact under `project/workflow/packets/` by default.
- `submit_feedback.sh` is only for repair or retrospective initialization.
- Prefer stage-level modeling tasks when possible:
  - `TASK_CODE_MODEL_P1`
  - `TASK_CODE_MODEL_P23`
  - `TASK_CODE_MODEL_P4`
- Code/model stages that produce canonical numbers or assumptions should maintain `project/output/model_manifest.json` from `project/output/MODEL_MANIFEST_TEMPLATE.json`.

## Acceptance helpers

```bash
bash scripts/paper_acceptance_check.sh --target <dir> --write-report
bash scripts/artifact_index.sh --target <dir>
```

- Run `paper_acceptance_check.sh` after paper build and before final paper acceptance.
- Use `artifact_index.sh` when packets, feedback, callbacks, exec runs, handoffs, and adjudications are scattered.

## State transition rules

- Use `close_task.sh`, `reopen_task.sh`, and `cancel_task.sh`.
- Do not hand-edit:
  - `project/runtime/task_registry.json`
  - `project/runtime/work_queue.json`
  - `project/runtime/event_log.jsonl`

## Human gate

The main brain still decides acceptance. Native bridge files do not replace repo state or repo scripts.
