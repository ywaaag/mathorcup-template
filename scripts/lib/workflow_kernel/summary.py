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
        lines.append(f"  check_handoff_intake: {command(['bash', 'scripts/check_handoff_intake.sh', '--target', str(root)])}")
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


def done_tasks(tasks: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [task for task in tasks if task.get("status") == "done"]


def append_close_gate(lines: List[str], root: Path, tasks: Sequence[Dict[str, Any]], active: Sequence[Dict[str, Any]]) -> None:
    lines.append("## Review / Done Close Gate")
    lines.append(f"- Handoff intake first: {command(['bash', 'scripts/check_handoff_intake.sh', '--target', str(root)])}")
    if active:
        lines.append("- Active tasks can move to review only after main-brain gate checks:")
        for item in active:
            task_id = item.get("task_id", "<task_id>")
            lines.append(f"  - {command(['bash', 'scripts/check_worker_feedback.sh', '--task', task_id, '--target', str(root)])}")
            lines.append(f"  - {command(['bash', 'scripts/close_task.sh', '--task', task_id, '--to', 'review', '--target', str(root)])}")
    else:
        lines.append("- Active tasks can move to review after feedback passes; no active tasks are currently claimed.")
        lines.append(f"  - {command(['bash', 'scripts/check_worker_feedback.sh', '--task', '<task_id>', '--target', str(root)])}")
        lines.append(f"  - {command(['bash', 'scripts/close_task.sh', '--task', '<task_id>', '--to', 'review', '--target', str(root)])}")

    reviews = review_tasks(tasks)
    if reviews:
        lines.append("- Review tasks can move to done only after feedback, retrospective, and main-brain acceptance:")
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
    else:
        lines.append("- Review tasks can move to done after feedback and retrospective pass; no review tasks are waiting.")
        lines.append(f"  - {command(['bash', 'scripts/check_worker_feedback.sh', '--task', '<task_id>', '--target', str(root)])}")
        lines.append(f"  - {command(['bash', 'scripts/check_retrospective.sh', '--task', '<task_id>', '--target', str(root)])}")
        lines.append(
            "  - "
            + command(
                [
                    "bash",
                    "scripts/close_task.sh",
                    "--task",
                    "<task_id>",
                    "--to",
                    "done",
                    "--accepted-by",
                    "main_brain",
                    "--target",
                    str(root),
                ]
            )
        )

    done = done_tasks(tasks)
    if done:
        lines.append("- Done tasks already accepted by main brain:")
        for task in done:
            accepted = "yes" if task.get("accepted_by_main_brain") else "no"
            lines.append(f"  - {task.get('task_id', '<unknown>')} | accepted_by_main_brain={accepted}")


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
            lines.append(f"  - {command(['bash', 'scripts/check_handoff_intake.sh', '--target', str(root)])}")
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


def close_gate_commands(root: Path, task_id: str = "<task_id>") -> Dict[str, str]:
    return {
        "check_handoff_intake": command(["bash", "scripts/check_handoff_intake.sh", "--target", str(root)]),
        "check_worker_feedback": command(["bash", "scripts/check_worker_feedback.sh", "--task", task_id, "--target", str(root)]),
        "check_retrospective": command(["bash", "scripts/check_retrospective.sh", "--task", task_id, "--target", str(root)]),
        "close_review": command(["bash", "scripts/close_task.sh", "--task", task_id, "--to", "review", "--target", str(root)]),
        "close_done": command(
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
        ),
    }


def main_summary_payload(root: Path) -> Dict[str, Any]:
    root_kind = detect_root_kind(root)
    generated_at = current_timestamp()
    if root_kind == "template_source":
        return {
            "schema_version": "main_brain_summary.v1",
            "generated_at": generated_at,
            "root": str(root),
            "root_kind": root_kind,
            "ok": True,
            "status": "TEMPLATE_SOURCE",
            "read_only": True,
            "sections": {
                "repo_runtime_quick_facts": {
                    "root_path": str(root),
                    "root_kind": root_kind,
                },
                "template_source_notice": [
                    "Do not run this against the template source as if it were a rendered instance.",
                    "Render a temporary instance before reading live main-brain state.",
                ],
            },
            "commands": [
                'tmpdir="$(mktemp -d)"',
                'bash scripts/setup.sh demo --render-only --target "$tmpdir"',
                'bash scripts/main_brain_summary.sh --target "$tmpdir"',
            ],
        }

    state = load_runtime_state(root)
    tasks = list(task_map(state).values())
    active = queue_items(state)
    root_env = parse_kv_env(root / ".env")
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    counts = status_counts(tasks)
    recent_events, recent_event_note = read_recent_events(root, limit=5)
    gate_issues = missing_gates(root, tasks)

    active_section = [
        {
            "task_id": str(item.get("task_id", "")),
            "role": str(item.get("role", "")),
            "owner": str(item.get("owner", "")),
            "locked_paths": list(item.get("locked_paths", [])) if isinstance(item.get("locked_paths", []), list) else [],
        }
        for item in active
    ]
    review_section = []
    for task in review_tasks(tasks):
        task_id = task["task_id"]
        feedback_path = task.get("feedback_path", "")
        retrospective_path = task.get("retrospective_path", "")
        review_section.append(
            {
                "task_id": task_id,
                "role": task.get("role", ""),
                "title": task.get("title", ""),
                "feedback_path": feedback_path,
                "feedback_exists": exists_flag(root, feedback_path) == "yes",
                "retrospective_path": retrospective_path,
                "retrospective_exists": exists_flag(root, retrospective_path) == "yes",
                "accepted_by_main_brain": bool(task.get("accepted_by_main_brain")),
                "commands": close_gate_commands(root, task_id),
            }
        )

    dispatchable = ready_or_todo_tasks(tasks)
    blocked = blocked_tasks(tasks)
    recommended_commands: List[Dict[str, str]] = [
        {
            "name": "recommend_tasks",
            "command": command(["bash", "scripts/recommend_tasks.sh", "--target", str(root)]),
        }
    ]
    if dispatchable:
        recommended_commands.append(
            {
                "name": "dispatch_shape",
                "command": command(["bash", "scripts/dispatch_task.sh", "--task", "<task_id>", "--owner", "<owner>", "--target", str(root)]),
            }
        )
    for item in active:
        task_id = str(item.get("task_id", "<task_id>"))
        recommended_commands.append({"name": "show_task", "task_id": task_id, "command": command(["bash", "scripts/show_task.sh", "--task", task_id, "--target", str(root)])})
        recommended_commands.append({"name": "list_history", "task_id": task_id, "command": command(["bash", "scripts/list_history.sh", "--task", task_id, "--target", str(root)])})
    for task in review_tasks(tasks):
        task_id = task["task_id"]
        for name, cmd in close_gate_commands(root, task_id).items():
            recommended_commands.append({"name": name, "task_id": task_id, "command": cmd})
    for task in blocked:
        task_id = task["task_id"]
        recommended_commands.append({"name": "show_task", "task_id": task_id, "command": command(["bash", "scripts/show_task.sh", "--task", task_id, "--target", str(root)])})
        recommended_commands.append({"name": "list_history", "task_id": task_id, "command": command(["bash", "scripts/list_history.sh", "--task", task_id, "--target", str(root)])})
        recommended_commands.append(
            {
                "name": "reopen_ready",
                "task_id": task_id,
                "command": command(["bash", "scripts/reopen_task.sh", "--task", task_id, "--to", "ready", "--reason", "main brain re-queued blocked task", "--target", str(root)]),
            }
        )
        recommended_commands.append(
            {
                "name": "cancel_blocked",
                "task_id": task_id,
                "command": command(["bash", "scripts/cancel_task.sh", "--task", task_id, "--reason", "main brain cancelled blocked task", "--target", str(root)]),
            }
        )

    return {
        "schema_version": "main_brain_summary.v1",
        "generated_at": generated_at,
        "root": str(root),
        "root_kind": root_kind,
        "ok": not gate_issues,
        "status": "WARN" if gate_issues else "OK",
        "read_only": True,
        "sections": {
            "repo_runtime_quick_facts": {
                "root_path": str(root),
                "root_kind": root_kind,
                "competition": value_or_missing(root_env.get("COMPETITION_NAME", ""), source=".env#COMPETITION_NAME"),
                "container": value_or_missing(root_env.get("CONTAINER_NAME", ""), source=".env#CONTAINER_NAME"),
                "image": value_or_missing(root_env.get("IMAGE_NAME", ""), source=".env#IMAGE_NAME"),
                "paper_active_entrypoint": value_or_missing(paper_env.get("PAPER_ACTIVE_ENTRYPOINT", ""), source="paper.env#PAPER_ACTIVE_ENTRYPOINT"),
                "paper_accept_pdf": value_or_missing(paper_env.get("PAPER_ACCEPT_PDF", ""), source="paper.env#PAPER_ACCEPT_PDF"),
            },
            "queue_overview": {status: counts.get(status, 0) for status in STATUS_ORDER},
            "active_tasks": active_section,
            "review_decision_needed_tasks": review_section,
            "review_done_close_gate": {
                "default_commands": close_gate_commands(root),
                "active_task_ids": [item["task_id"] for item in active_section],
                "review_task_ids": [item["task_id"] for item in review_section],
                "done_task_ids": [str(task.get("task_id", "")) for task in done_tasks(tasks)],
            },
            "missing_gates": [
                {
                    "message": issue,
                }
                for issue in gate_issues
            ],
            "recent_events": {
                "note": recent_event_note,
                "items": recent_events,
            },
            "recommended_next_commands": recommended_commands,
            "recommendation_preview": {
                "command": command(["bash", "scripts/recommend_tasks.sh", "--target", str(root)]),
            },
        },
        "commands": recommended_commands,
    }


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
    lines.append("")
    append_close_gate(lines, root, tasks, active)

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
