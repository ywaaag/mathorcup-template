---
name: worker-feedback
description: "Use when acting as a bounded worker inside a rendered MathorCup instance. Read the task packet, stay inside allowed paths, and return structured feedback or retrospective artifacts through the repo gate files without closing or mutating runtime state directly."
---

# Worker Feedback

Use this skill after a main-brain dispatch when you are executing a bounded task.

## Required inputs

1. `.codex/requirements.toml`
2. `AGENTS.md` or `project/paper/AGENTS.md`
3. The task packet
4. `MEMORY.md`
5. Relevant runtime/workflow contracts

## Working rules

- Stay inside the packet's allowed paths.
- Respect `task_registry.json` and `work_queue.json`.
- Read `.env` and `project/paper/runtime/paper.env` when runtime facts matter.
- Do not treat Markdown mirrors as machine truth.

## Feedback path

- Canonical path: feedback skeleton is normally created by `dispatch_task.sh`.
- Task packets are normally persisted under `project/workflow/packets/`.
- Use `bash scripts/submit_feedback.sh --task <task_id> --with-retrospective --target <dir>` only when feedback is missing or retrospective needs manual initialization.

## Model and paper evidence

- If you are a code/model worker and you produce assumptions, canonical numbers, algorithm boundaries, enumeration caps, or paper-facing outputs, update `project/output/model_manifest.json` from `project/output/MODEL_MANIFEST_TEMPLATE.json`.
- If you are a paper/layout/final-fix worker, run `bash scripts/paper_acceptance_check.sh --target <dir>` after build and report the result. The script checks host-visible artifacts; it does not compile or close the task.

## Hard boundaries

- Do not run `close_task.sh`, `reopen_task.sh`, or `cancel_task.sh` as a worker.
- Do not create new top-level tasks unless the packet explicitly allows it.
- Do not rewrite repo truth by hand when a repo script already owns that transition.

## Minimum return

- Files changed
- What was done
- Verified facts
- Validation or acceptance result
- Remaining risks
- Lesson learned
