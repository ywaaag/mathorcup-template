# Main-Brain Acceptance Template

Use this checklist before accepting a worker result:

1. Scope
- Did the worker stay inside the allowed file set?
- Did the worker stay inside the claimed `locked_paths` / task `allowed_paths`?

2. Consensus
- Did the worker change any project-wide fact that now belongs in `MEMORY.md`, runtime contract, or paper config?

3. Verification
- Which claims are actually verified by live files, logs, or outputs?
- Indexed handoff intake checked first:
  - `bash scripts/check_handoff_intake.sh --target <dir>`
- Optional structured read-only checks for machine-assisted review:
  - `bash scripts/doctor.sh --target <dir> --json`
  - `bash scripts/check_state_consistency.sh --target <dir> --json`
  - `bash scripts/main_brain_summary.sh --target <dir> --json`
  - `bash scripts/list_history.sh --task <task_id> --target <dir> --json`
  - `bash scripts/adjudicate_task.sh --task <task_id> --target <dir> --json`

4. Acceptance Artifacts
- If the task touched paper/build, were the host-visible acceptance artifacts refreshed?

5. Risks
- What remains unresolved?
- Is another narrow-scope worker needed?

6. Reuse
- Should any lesson be copied into `project/output/retrospectives/`?

7. Workflow State
- Should `project/runtime/task_registry.json` move from `review` to `done`?
- Is `accepted_by_main_brain` ready to become `true`?
- Review gate:
  - `bash scripts/check_worker_feedback.sh --task <task_id> --target <dir>`
  - `bash scripts/close_task.sh --task <task_id> --to review|done --target <dir>`
- Done gate:
  - `bash scripts/check_retrospective.sh --task <task_id> --target <dir>`
  - `bash scripts/close_task.sh --task <task_id> --to done --accepted-by main_brain --target <dir>`
- Workers submit evidence only; worker must not run close_task.sh.
