# Main-Brain Acceptance Template

Use this checklist before accepting a worker result:

1. Scope
- Did the worker stay inside the allowed file set?
- Did the worker stay inside the claimed `locked_paths` / task `allowed_paths`?

2. Consensus
- Did the worker change any project-wide fact that now belongs in `MEMORY.md`, runtime contract, or paper config?

3. Verification
- Which claims are actually verified by live files, logs, or outputs?

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
