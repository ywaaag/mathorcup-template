---
name: template-source-maintenance
description: "Use when maintaining the mathorcup-template repository itself rather than a rendered instance. Read scaffold as the source of truth, edit scaffold-first artifacts, preserve stable script entrypoints, and validate changes with template-source checks plus render-only smoke."
---

# Template Source Maintenance

Use this skill when the current workspace is the template-source repo.

## Required stance

- Treat `scaffold/` as template truth.
- Treat repo-root `project/` as a placeholder, not a live instance.
- Treat `.codex/requirements.toml` as a native front door only, never as runtime truth.

## Read order

1. `AGENTS.md`
2. `.codex/requirements.toml`
3. `README.md`
4. `scaffold/`
5. `scripts/setup.sh`, `scripts/render_templates.sh`, `scripts/validate_agent_docs.sh`

## Working rules

- If a future instance file should change, update `scaffold/`, not only a rendered target.
- Preserve stable shell facades unless there is a strong reason not to:
  - `scripts/setup.sh`
  - `scripts/dual_brain.sh`
  - `scripts/validate_agent_docs.sh`
- Do not create live runtime state in the template root.
- Do not move runtime truth into `.codex`.

## Validation path

Run both layers:

```bash
bash scripts/validate_agent_docs.sh
bash scripts/validate_agent_docs.sh --template-source-only
tmpdir="$(mktemp -d)"
bash scripts/setup.sh demo --render-only --target "$tmpdir"
bash scripts/validate_agent_docs.sh --root "$tmpdir"
bash scripts/doctor.sh --root "$tmpdir"
```

## When to stop

Stop and re-check scope if you catch yourself treating this repo like a live instance checkout.
