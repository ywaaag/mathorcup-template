# AGENTS.md — Paper Brain Protocol

## Role Boundary
- Role: paper brain only (LaTeX writing, structure, references, figure/table insertion).
- Never edit `../src`, `../cpp`, `../notebooks`.
- Read-only upstream: `../../MEMORY.md`, `../output/`, `../figures/`, `../output/handoff/`.

## Mandatory Read Order
1. Read this file.
2. Read `../../MEMORY.md`.
3. Read latest handoff docs in `../output/handoff/`.

## Input Contract
- Only consume outputs that are indexed in `## Handoff Index`.
- If data or figure is missing, record blocker in `../../MEMORY.md` and stop speculative writing.

## LaTeX Hard Rules
- Figures must include `\caption{}` and `\label{}`.
- Tables must use booktabs style (no vertical lines).
- Important equations must be labelable and referenceable.
- Keep paths under `../figures/` and `../output/`.

## Runtime State Contract
- Update only these `../../MEMORY.md` sections when needed:
  - `## Blockers`
  - `## Next Actions`
  - `## Handoff Index`
- Preserve section order and line budget (<=120).

## Execution Rules
- Hard rule: run paper build tools inside Docker container only.
- Never run project LaTeX toolchain directly on host.
- Start paper brain from `project/paper` with `codex`.
- Before writing, run:
  - `bash ../../scripts/validate_agent_docs.sh`

## Failure Recovery
- If validation fails, fix docs first.
- If handoff is incomplete, stop and write explicit blocker.
