from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from workflow_kernel.schema import TASK_STATUSES, atomic_write_text, queue_items, task_map


def list_tasks(
    state: Dict[str, Any],
    *,
    role: str = "",
    status: str = "",
    open_only: bool = False,
) -> str:
    tasks = state["registry"].get("tasks", [])
    active_ids = {item["task_id"] for item in queue_items(state)}
    rows: List[Tuple[str, str, str, str, str, str, str]] = []
    for task in tasks:
        claimed = "yes" if task["task_id"] in active_ids else "no"
        if role and task["role"] != role:
            continue
        if status and task["status"] != status:
            continue
        if open_only and not (task["owner"] == "" and task["status"] in {"todo", "ready"}):
            continue
        rows.append(
            (
                task["task_id"],
                task["role"],
                task["status"],
                task["owner"] or "-",
                "yes" if task["parallel_ok"] else "no",
                claimed,
                ",".join(task["allowed_paths"]),
            )
        )
    headers = ("TASK_ID", "ROLE", "STATUS", "OWNER", "PAR", "CLAIMED", "ALLOWED_PATHS")
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, value in enumerate(row):
            widths[idx] = max(widths[idx], len(value))
    line_fmt = "  ".join(f"{{:{width}}}" for width in widths)
    lines = [line_fmt.format(*headers), line_fmt.format(*["-" * width for width in widths])]
    if not rows:
        lines.append("(no matching tasks)")
    else:
        for row in rows:
            lines.append(line_fmt.format(*row))
    return "\n".join(lines) + "\n"


def render_queue_board(root: Path, state: Dict[str, Any]) -> str:
    tasks = task_map(state)
    queue = queue_items(state)
    lines = [
        "# Main-Brain Queue",
        "",
        "- Source of truth: `project/runtime/task_registry.json` and `project/runtime/work_queue.json`.",
        "- Inspect ready pool via `bash scripts/list_open_tasks.sh --open-only`.",
        "- Dispatch a task via `bash scripts/dispatch_task.sh --task <task_id> --owner <owner>`.",
        "- Run a non-interactive exec worker via `bash scripts/run_exec_worker.sh --task <task_id> --owner <owner> --target <dir>`.",
        "- Update task ownership or status via `scripts/claim_task.sh`, `scripts/close_task.sh`, `scripts/reopen_task.sh`, and `scripts/cancel_task.sh`.",
        "- `owner` only means current active owner; inspect event/history views for the last actor after a task leaves `in_progress`.",
        "- `--open-only` only includes `todo/ready`; inspect blocked tasks explicitly with `bash scripts/list_open_tasks.sh --status blocked`.",
        "",
        "## Active Tasks",
    ]
    if not queue:
        lines.append("- none")
    else:
        for item in queue:
            lines.append(
                f"- `{item['task_id']}` | role=`{item['role']}` | active_owner=`{item['owner']}` | locked={', '.join(item['locked_paths'])}"
            )
    lines.extend(["", "## Task Summary"])
    by_status: Dict[str, List[str]] = {status: [] for status in sorted(TASK_STATUSES)}
    for task in tasks.values():
        by_status.setdefault(task["status"], []).append(task["task_id"])
    for status in sorted(by_status):
        values = by_status[status]
        if values:
            lines.append(f"- {status}: {', '.join(sorted(values))}")
    lines.extend(["", "## Review Gate"])
    lines.append("- `review` or `done` tasks must have valid feedback.")
    lines.append("- `done` tasks must also have a valid retrospective and `accepted_by_main_brain = true`.")
    return "\n".join(lines) + "\n"


def write_queue_board(root: Path, state: Dict[str, Any]) -> None:
    board = root / "project/workflow/MAIN_BRAIN_QUEUE.md"
    atomic_write_text(board, render_queue_board(root, state))
