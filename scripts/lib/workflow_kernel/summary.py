from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from workflow_kernel.recommend import shell_quote
from workflow_kernel.schema import (
    TASK_STATUSES,
    detect_root_kind,
    load_runtime_state,
    parse_kv_env,
    queue_items,
    task_map,
)
from workflow_kernel.transitions import current_timestamp


STATUS_ORDER = ["todo", "ready", "in_progress", "blocked", "review", "done"]


def command(parts: Sequence[str]) -> str:
    return " ".join(shell_quote(part) for part in parts)


def value_or_missing(value: str, *, source: str = "") -> str:
    if value:
        return value
    return f"<missing {source}>" if source else "-"


def template_source_notice(root: Path) -> str:
    return "\n".join(
        [
            "Main-brain summary is advisory-only and read-only.",
            "",
            f"Current root is template-source: {root}",
            "Do not run this against the template source as if it were a rendered instance.",
            "",
            "Render a temporary instance first:",
            '  tmpdir="$(mktemp -d)"',
            '  bash scripts/setup.sh demo --render-only --target "$tmpdir"',
            '  bash scripts/main_brain_summary.sh --target "$tmpdir"',
            "",
        ]
    )


def exists_flag(root: Path, relpath: str) -> str:
    if not relpath:
        return "no"
    return "yes" if (root / relpath).is_file() else "no"


def read_recent_events(root: Path, limit: int = 5) -> Tuple[List[Dict[str, str]], str]:
    path = root / "project/runtime/event_log.jsonl"
    if not path.is_file():
        return [], "event log missing"
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    nonempty = [(idx, line.strip()) for idx, line in enumerate(raw_lines, start=1) if line.strip()]
    if not nonempty:
        return [], "event log empty"

    events: List[Dict[str, str]] = []
    for lineno, line in nonempty[-limit:]:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            events.append(
                {
                    "timestamp": "-",
                    "event_type": f"invalid-json line {lineno}",
                    "task_id": "-",
                    "actor": "-",
                    "owner": "-",
                }
            )
            continue
        if not isinstance(payload, dict):
            events.append(
                {
                    "timestamp": "-",
                    "event_type": f"invalid-event line {lineno}",
                    "task_id": "-",
                    "actor": "-",
                    "owner": "-",
                }
            )
            continue
        events.append(
            {
                "timestamp": str(payload.get("timestamp") or "-"),
                "event_type": str(payload.get("event_type") or "-"),
                "task_id": str(payload.get("task_id") or "-"),
                "actor": str(payload.get("actor") or "-"),
                "owner": str(payload.get("owner") or "-"),
            }
        )
    return events, ""


def status_counts(tasks: Sequence[Dict[str, Any]]) -> Dict[str, int]:
    counts = {status: 0 for status in sorted(TASK_STATUSES)}
    for task in tasks:
        status = str(task.get("status") or "")
        counts[status] = counts.get(status, 0) + 1
    return counts


def review_tasks(tasks: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [task for task in tasks if task.get("status") == "review"]


def blocked_tasks(tasks: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [task for task in tasks if task.get("status") == "blocked"]


def ready_or_todo_tasks(tasks: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [task for task in tasks if task.get("status") in {"todo", "ready"}]


def missing_gates(root: Path, tasks: Sequence[Dict[str, Any]]) -> List[str]:
    issues: List[str] = []
    for task in tasks:
        task_id = task.get("task_id", "<unknown>")
        status = task.get("status", "")
        feedback_path = task.get("feedback_path", "")
        retrospective_path = task.get("retrospective_path", "")

        if status == "in_progress" and feedback_path and not (root / feedback_path).is_file():
            issues.append(f"{task_id}: in_progress but feedback_path is missing: {feedback_path}")
        if status in {"review", "done"} and feedback_path and not (root / feedback_path).is_file():
            issues.append(f"{task_id}: {status} but feedback_path is missing: {feedback_path}")
        if status == "done" and retrospective_path and not (root / retrospective_path).is_file():
            issues.append(f"{task_id}: done but retrospective_path is missing: {retrospective_path}")
    return issues


def append_active_tasks(lines: List[str], active: Sequence[Dict[str, Any]]) -> None:
    lines.append("## Active Tasks")
    if not active:
        lines.append("- none")
        return
    for item in active:
        locks = ", ".join(item.get("locked_paths", [])) or "-"
        lines.append(
            f"- {item.get('task_id', '<unknown>')} | role={item.get('role', '-')} | "
            f"owner={item.get('owner', '-')} | locked_paths={locks}"
        )


def append_review_tasks(lines: List[str], root: Path, tasks: Sequence[Dict[str, Any]]) -> None:
    lines.append("## Review / Decision-Needed Tasks")
    reviews = review_tasks(tasks)
    if not reviews:
        lines.append("- none")
        return
    for task in reviews:
        task_id = task["task_id"]
        feedback_path = task.get("feedback_path", "")
        retrospective_path = task.get("retrospective_path", "")
        accepted = "yes" if task.get("accepted_by_main_brain") else "no"
        lines.append(f"- {task_id} | role={task.get('role', '-')} | title={task.get('title', '-')}")
        lines.append(f"  feedback_path: {feedback_path or '-'} | exists={exists_flag(root, feedback_path)}")
        lines.append(f"  retrospective_path: {retrospective_path or '-'} | exists={exists_flag(root, retrospective_path)}")
        lines.append(f"  accepted_by_main_brain: {accepted}")
        lines.append(f"  check_feedback: {command(['bash', 'scripts/check_worker_feedback.sh', '--task', task_id, '--target', str(root)])}")
        lines.append(f"  check_retrospective: {command(['bash', 'scripts/check_retrospective.sh', '--task', task_id, '--target', str(root)])}")
        lines.append(
            "  close_done: "
            + command(
                [
                    "bash",
                    "scripts/close_task.sh",
                    "--task",
                    task_id,
                    "--to",
                    "done",
                    "--accepted-by",
                    "main_brain",
                    "--target",
                    str(root),
                ]
            )
        )


def append_recent_events(lines: List[str], root: Path) -> None:
    lines.append("## Recent Events")
    events, note = read_recent_events(root, limit=5)
    if note:
        lines.append(f"- {note}")
        return
    for event in events:
        lines.append(
            f"- {event['timestamp']} | {event['event_type']} | task={event['task_id']} | "
            f"actor={event['actor']} | owner={event['owner']}"
        )


def append_recommended_commands(
    lines: List[str],
    root: Path,
    tasks: Sequence[Dict[str, Any]],
    active: Sequence[Dict[str, Any]],
) -> None:
    reviews = review_tasks(tasks)
    blocked = blocked_tasks(tasks)
    dispatchable = ready_or_todo_tasks(tasks)

    lines.append("## Recommended Next Commands")
    lines.append(f"- Inspect safe dispatch recommendations: {command(['bash', 'scripts/recommend_tasks.sh', '--target', str(root)])}")
    if dispatchable:
        lines.append("- Ready/todo tasks exist; inspect recommend_tasks before dispatching.")
        lines.append(
            "- Dispatch shape: "
            + command(["bash", "scripts/dispatch_task.sh", "--task", "<task_id>", "--owner", "<owner>", "--target", str(root)])
        )
    if active:
        lines.append("- Active task drill-down:")
        for item in active:
            task_id = item.get("task_id", "<task_id>")
            lines.append(f"  - {command(['bash', 'scripts/show_task.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(f"  - {command(['bash', 'scripts/list_history.sh', '--task', task_id, '--target', str(root)])}")
    if reviews:
        lines.append("- Review gate drill-down:")
        for task in reviews:
            task_id = task["task_id"]
            lines.append(f"  - {command(['bash', 'scripts/check_worker_feedback.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(f"  - {command(['bash', 'scripts/check_retrospective.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(
                "  - "
                + command(
                    [
                        "bash",
                        "scripts/close_task.sh",
                        "--task",
                        task_id,
                        "--to",
                        "done",
                        "--accepted-by",
                        "main_brain",
                        "--target",
                        str(root),
                    ]
                )
            )
    if blocked:
        lines.append("- Blocked task decisions:")
        for task in blocked:
            task_id = task["task_id"]
            lines.append(f"  - {command(['bash', 'scripts/show_task.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(f"  - {command(['bash', 'scripts/list_history.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(
                f"  - {command(['bash', 'scripts/reopen_task.sh', '--task', task_id, '--to', 'ready', '--reason', 'main brain re-queued blocked task', '--target', str(root)])}"
            )
            lines.append(
                f"  - {command(['bash', 'scripts/cancel_task.sh', '--task', task_id, '--reason', 'main brain cancelled blocked task', '--target', str(root)])}"
            )
    if not active and not reviews and not blocked:
        lines.append("- No active/review/blocked tasks; the dispatch pool is the primary next decision surface.")


def append_recommendation_preview(lines: List[str], root: Path) -> None:
    lines.append("## Recommendation Preview")
    scripts_dir = Path(__file__).resolve().parents[2]
    if (scripts_dir / "recommend_tasks.sh").is_file():
        lines.append("- Full safe-to-dispatch reasoning is available via:")
        lines.append(f"  {command(['bash', 'scripts/recommend_tasks.sh', '--target', str(root)])}")
        lines.append("- This summary does not depend on recommend_tasks succeeding; use that script for detailed safe/blocked reasons.")
    else:
        lines.append("- scripts/recommend_tasks.sh was not found; basic summary sections above were still generated.")


def main_summary_report(root: Path) -> str:
    root_kind = detect_root_kind(root)
    if root_kind == "template_source":
        return template_source_notice(root)

    state = load_runtime_state(root)
    tasks = list(task_map(state).values())
    active = queue_items(state)
    root_env = parse_kv_env(root / ".env")
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    counts = status_counts(tasks)

    lines: List[str] = [
        "# Main-Brain Decision Panel",
        "",
        "Advisory-only. No files are modified by this command.",
        "",
        "## Repo / Runtime Quick Facts",
        f"- generated_at: {current_timestamp()}",
        f"- root path: {root}",
        f"- root kind: {root_kind}",
        f"- competition: {value_or_missing(root_env.get('COMPETITION_NAME', ''), source='.env#COMPETITION_NAME')}",
        f"- container: {value_or_missing(root_env.get('CONTAINER_NAME', ''), source='.env#CONTAINER_NAME')}",
        f"- image: {value_or_missing(root_env.get('IMAGE_NAME', ''), source='.env#IMAGE_NAME')}",
        f"- paper active entrypoint: {value_or_missing(paper_env.get('PAPER_ACTIVE_ENTRYPOINT', ''), source='paper.env#PAPER_ACTIVE_ENTRYPOINT')}",
        f"- paper accept pdf: {value_or_missing(paper_env.get('PAPER_ACCEPT_PDF', ''), source='paper.env#PAPER_ACCEPT_PDF')}",
        "",
        "## Queue Overview",
    ]
    for status in STATUS_ORDER:
        lines.append(f"- {status}: {counts.get(status, 0)}")
    extra_statuses = sorted(status for status in counts if status not in STATUS_ORDER and counts[status])
    for status in extra_statuses:
        lines.append(f"- {status}: {counts[status]}")

    lines.append("")
    append_active_tasks(lines, active)
    lines.append("")
    append_review_tasks(lines, root, tasks)

    lines.extend(["", "## Missing Gates"])
    gate_issues = missing_gates(root, tasks)
    if gate_issues:
        lines.extend(f"- {issue}" for issue in gate_issues)
    else:
        lines.append("- no missing gates detected")

    lines.append("")
    append_recent_events(lines, root)
    lines.append("")
    append_recommended_commands(lines, root, tasks, active)
    lines.append("")
    append_recommendation_preview(lines, root)
    return "\n".join(lines) + "\n"
