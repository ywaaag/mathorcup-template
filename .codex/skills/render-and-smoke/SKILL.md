---
name: render-and-smoke
description: "Use when a template-source change needs a safe, low-risk smoke test. Render scaffold into a temporary instance, then run validate_agent_docs.sh and doctor.sh on the rendered target without touching backend runtime execution."
---

# Render And Smoke

Use this skill after template-source edits when you need to prove the scaffold still renders and validates.

## Standard flow

```bash
tmpdir="$(mktemp -d)"
bash scripts/setup.sh demo --render-only --target "$tmpdir"
bash scripts/validate_agent_docs.sh --root "$tmpdir"
bash scripts/doctor.sh --root "$tmpdir"
```

## What this verifies

- `scaffold/` can still render into a valid instance.
- The rendered instance still contains expected contracts, runtime files, and native bridge files.
- Validator and doctor still agree on repo mode and runtime routing.

## What this does not verify

- `bootstrap_container.sh`
- `install_deps.sh`
- `paper.sh build`
- `run_exec_worker.sh`
- `run_exec_batch.sh`

## Working rules

- Keep this as a low-risk smoke path.
- Prefer temp directories over mutating a live instance.
- If render-only fails, fix scaffold or validator assumptions before touching backend scripts.
