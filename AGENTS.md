# AGENTS.md — Template Repo Maintenance Protocol

## Scope

- This root `AGENTS.md` governs the template repository itself.
- Source of truth for future instance files now lives under `scaffold/`.
- The live `project/` tree at repo root is a render target placeholder, not the primary template source.

## Mandatory Read Order

1. Read this file.
2. If present, read `.codex/requirements.toml` as a Codex-native front door summary. It does not replace repo truth.
3. Read `scaffold/`.
4. Read `scripts/setup.sh`, `scripts/render_templates.sh`, `scripts/validate_agent_docs.sh`.
5. If changing workflow design, read the scaffold contracts under:
   - `scaffold/project/spec/`
   - `scaffold/project/workflow/`
   - `scaffold/project/paper/spec/`

## Editing Rules

- If a future instance file should change, edit the `scaffold/` source, not only a rendered target.
- Keep the boundary clear:
  - `scaffold/` = template source of truth
  - rendered files in an instance = runtime/live artifacts
  - `MEMORY.md` is instance runtime state and should not be committed as a live root file in this template repo
- Preserve stable entrypoint names unless there is a strong reason not to:
  - `scripts/setup.sh`
  - `scripts/dual_brain.sh`
  - `scripts/validate_agent_docs.sh`

## Verification Rules

- Before finishing, run at least:
  - `bash scripts/setup.sh --render-only --target <temp_dir>`
  - `bash scripts/validate_agent_docs.sh --root <temp_dir>`
- Use `git diff` and `git status` checkpoints while refactoring.

## Failure Recovery

- If a change only updates rendered outputs but not `scaffold/`, treat it as incomplete.
- If a script starts mixing render/bootstrap/reset concerns again, split the responsibility instead of adding flags indefinitely.
