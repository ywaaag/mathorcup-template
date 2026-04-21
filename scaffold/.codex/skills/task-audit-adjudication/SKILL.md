---
name: task-audit-adjudication
description: "Use when main_brain needs to inspect one task in depth, reconstruct its event and queue history, or compare multiple worker artifacts through adjudicate_task.sh before any human-gated close, reopen, or cancel decision."
---

# Task Audit Adjudication

Use this skill for structured audit, not free-chat arbitration.

## Inspection chain

```bash
bash scripts/show_task.sh --task <task_id> --target <dir>
bash scripts/list_history.sh --task <task_id> --target <dir>
bash scripts/adjudicate_task.sh --task <task_id> --target <dir>
```

## Core rules

- `show_task.sh` is the current-state view.
- `list_history.sh` is the timeline and audit trace view.
- `adjudicate_task.sh` is the structured comparison draft.
- Final state change still belongs to main brain through repo scripts.

## Evidence handling

- Default adjudication compares worker-produced evidence first.
- Callback or event-derived artifacts are supporting evidence, not primary truth.
- If evidence is incomplete, say so explicitly instead of forcing a verdict.

## Do not do

- Do not auto-close a task from adjudication output.
- Do not use free chat as the primary comparison mechanism.
- Do not treat `.codex` as a second state machine.
