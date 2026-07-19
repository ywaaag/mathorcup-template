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
bash scripts/worker_pool.sh status --target <dir>
```

## Persistent native worker pool

When native sub-agents are available, keep one warm thread for each core role:

- `code_brain:primary`
- `paper_brain:primary`
- `layout_worker:primary`
- `utility_worker:primary`

At main-brain startup:

1. Read `bash scripts/worker_pool.sh status --target <dir>`.
2. Spawn only missing or stale core workers with the matching `.codex/agents/<role>.toml` definition.
3. Register every returned `agent_id` with `worker_pool.sh register --backend native_subagent`.
4. A completed native agent is idle, not disposable. Do not call `close_agent` after each task.
5. Send related follow-up work to the same `agent_id` with `send_input`.

The default Codex limit is six open agent threads. Four core workers stay warm;
the remaining two slots are burst capacity for citation, review, or a disjoint
parallel code branch. Close the least-recently-used idle burst worker before
exceeding the cap. Never close a running worker.

## Dispatch path

```bash
bash scripts/list_open_tasks.sh --open-only --target <dir>
bash scripts/dispatch_task.sh --task <task_id> --owner <owner> --target <dir>
```

For a registered native worker, bind routing into the packet and pool state:

```bash
bash scripts/dispatch_task.sh \
  --task <task_id> \
  --owner <owner> \
  --backend subagent \
  --pool-worker <role:primary> \
  --session-id <agent_id> \
  --target <dir>
```

Send the generated packet to that exact `agent_id`. Record `worker.started`,
then record the terminal result with `record_worker_result.sh`; the latter marks
the pool worker idle without closing its native thread.

For a small follow-up while the task remains `in_progress`, write a short delta
file and reuse the same session:

```bash
bash scripts/dispatch_task.sh \
  --task <task_id> \
  --no-claim \
  --backend subagent \
  --pool-worker <role:primary> \
  --session-id <agent_id> \
  --delta-file <delta.md> \
  --delta-from <previous-cycle-or-result> \
  --target <dir>
```

Delta dispatch is forbidden for canonical-number, algorithm-boundary, or
top-level contract changes. Upgrade those changes to a full dispatch.

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

## Recovery

- Native `agent_id` values are reliable only while the owning main-brain session can still address them.
- After a main-brain restart, probe/resume the recorded ID. On `not_found` or `shutdown`, mark it stale and spawn a replacement.
- Rehydrate replacements from the current task packet, indexed handoffs, feedback, event history, and `MEMORY.md`; do not replay the whole chat transcript.
- Persistent `codex exec` sessions are the non-interactive fallback. Always resume an explicit thread ID, never `--last`.
- Close the four core workers only at competition shutdown, or when a session is confirmed unhealthy.
