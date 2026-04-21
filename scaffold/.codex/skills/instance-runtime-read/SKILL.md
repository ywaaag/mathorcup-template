---
name: instance-runtime-read
description: "Use when you need current runtime facts inside a rendered MathorCup instance. Read .env and project/paper/runtime/paper.env as machine truth, then use runtime contracts as rendered mirrors and never confuse the native bridge with runtime state truth."
---

# Instance Runtime Read

Use this skill whenever current runtime facts matter.

## Read order

1. `.codex/requirements.toml`
2. `.env`
3. `project/paper/runtime/paper.env`
4. `project/spec/runtime_contract.md`
5. `project/paper/spec/paper_runtime_contract.md`

## Truth model

- Machine truth:
  - `.env`
  - `project/paper/runtime/paper.env`
  - `MEMORY.md`
  - `project/runtime/task_registry.json`
  - `project/runtime/work_queue.json`
  - `project/runtime/event_log.jsonl`
- Rendered mirrors:
  - `project/spec/runtime_contract.md`
  - `project/paper/spec/paper_runtime_contract.md`
- Native bridge:
  - `.codex/requirements.toml`
  - `.codex/skills/`

## Consequences

- If `.env` and a Markdown contract disagree, `.env` wins.
- If `paper.env` and a script default disagree, `paper.env` wins.
- If `task_registry.json` and memory or chat disagree, `task_registry.json` wins for task state.
- `.codex` may guide reading order, but it does not own runtime truth.
