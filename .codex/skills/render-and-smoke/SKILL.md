---
name: render-and-smoke
description: "Use when a template-source change needs a safe, low-risk smoke test. Render scaffold into a temporary instance, then run validate_agent_docs.sh and doctor.sh on the rendered target without touching backend runtime execution."
---

# Render And Smoke

Use this skill after template-source edits when you need to prove the scaffold still renders and validates.

Prefer the packaged smoke entrypoint first:

```bash
bash scripts/smoke_instance.sh --keep-temp
```

It writes a timestamped Markdown report under `reports/`, renders a temporary instance, runs low-risk advisory checks, fills minimum valid feedback content for the Phase 1 gate, and does not start Docker or run `codex exec`.

The smoke path exercises the state-changing workflow entrypoints through their instance-local write lock and post-change consistency check.

## Standard flow

Use this manual flow only when you need to isolate a failing smoke step:

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

For the optional realflow harness, use:

```bash
bash scripts/smoke_realflow.sh --keep-temp
```

By default it is dry/lightweight and skips Docker plus `codex exec`. Heavy checks require explicit flags:

```bash
bash scripts/smoke_realflow.sh --with-docker --with-exec --keep-temp
```

`--with-exec` requires `--with-docker`.

## Working rules

- Keep this as a low-risk smoke path.
- Prefer temp directories over mutating a live instance.
- If render-only fails, fix scaffold or validator assumptions before touching backend scripts.
