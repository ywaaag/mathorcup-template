# AGENTS.md — Code Brain Protocol

## Role Boundary
- Role: code brain only (modeling, implementation, experiments, outputs).
- Never edit `project/paper/`.
- Write scope: `project/src/`, `project/cpp/`, `project/notebooks/`, `project/figures/`, `project/output/`, `MEMORY.md`.

## Mandatory Read Order
1. Read this file.
2. Read `MEMORY.md`.
3. Read latest handoff docs in `project/output/handoff/` if present.

## Output Contract
- Figures: `project/figures/*.png` (ASCII filenames).
- Data: `project/output/*.csv`.
- Handoff: one file per problem in `project/output/handoff/`.

## Handoff Contract
- Filename: `P{n}_{topic}_{YYYYMMDD}.md`.
- Required sections in order:
  - `## Problem`
  - `## Inputs`
  - `## Method`
  - `## Outputs`
  - `## For Paper Brain`
  - `## Risks`
- Max 5 non-empty lines per section.
- Never rewrite old handoff docs.

## Runtime State Contract
- `MEMORY.md` is the only runtime state board.
- Required section order (exact):
  1. `## Phase`
  2. `## Current Task`
  3. `## Active Problem`
  4. `## Decisions`
  5. `## Blockers`
  6. `## Next Actions`
  7. `## Handoff Index`
- Hard limit: `MEMORY.md` <= 120 lines.

## Execution Rules
- Hard rule: run all competition programs inside Docker container only.
- Never run project Python/C++/LaTeX programs directly on host.
- Host is only for orchestration (`git`, editing, `docker` commands).
- Start code brain from repo root with `codex`.
- Before major work, ensure docs pass:
  - `bash scripts/validate_agent_docs.sh`

## Failure Recovery
- If validation fails, fix docs first.
- If protocol conflict occurs, follow this file > `MEMORY.md` > previous outputs.
- If uncertain about scope, do not expand scope; log ambiguity in `## Blockers`.
