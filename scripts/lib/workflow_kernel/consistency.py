from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from workflow_kernel.schema import (
    any_path_matches,
    detect_root_kind,
    load_runtime_state,
    paths_overlap,
    queue_items,
    role_map,
    task_map,
)


REQUIRED_EVENT_FIELDS = [
    "timestamp",
    "event_id",
    "event_type",
    "task_id",
    "role",
    "actor",
    "owner",
    "from_status",
    "to_status",
    "artifacts",
    "note",
    "metadata",
]


@dataclass(frozen=True)
class Finding:
    level: str
    message: str
    task_id: str = "-"
    path: str = "-"

    def render(self) -> str:
        return f"- task_id={self.task_id} | path={self.path} | {self.message}"


class ConsistencyReport:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.ok: List[Finding] = []
        self.warn: List[Finding] = []
        self.error: List[Finding] = []

    def add(self, level: str, message: str, *, task_id: str = "-", path: str = "-") -> None:
        finding = Finding(level=level, message=message, task_id=task_id, path=path)
        if level == "ERROR":
            self.error.append(finding)
        elif level == "WARN":
            self.warn.append(finding)
        else:
            self.ok.append(finding)

    @property
    def has_errors(self) -> bool:
        return bool(self.error)

    def render(self) -> str:
        lines = [
            "State Consistency Check",
            "Advisory-only. No files are modified by this command.",
            f"Root: {self.root}",
            "",
            "OK:",
        ]
        lines.extend(item.render() for item in self.ok or [Finding("OK", "no OK entries recorded")])
        lines.extend(["", "WARN:"])
        lines.extend(item.render() for item in self.warn or [Finding("WARN", "none")])
        lines.extend(["", "ERROR:"])
        lines.extend(item.render() for item in self.error or [Finding("ERROR", "none")])
        lines.append("")
        if self.has_errors:
            lines.append("Result: FAIL")
        else:
            lines.append("Result: PASS")
        return "\n".join(lines) + "\n"


def template_source_notice(root: Path) -> str:
    return "\n".join(
        [
            "State consistency check is advisory-only and read-only.",
            "",
            f"Current root is template-source: {root}",
            "Do not run this against the template source as if it were a rendered instance.",
            "",
            "Render a temporary instance first:",
            '  tmpdir="$(mktemp -d)"',
            '  bash scripts/setup.sh demo --render-only --target "$tmpdir"',
            '  bash scripts/check_state_consistency.sh --target "$tmpdir"',
            "",
            "Equivalent validator mode:",
            '  bash scripts/validate_agent_docs.sh --state-consistency-only --root "$tmpdir"',
            "",
        ]
    )


def state_consistency_report(root: Path) -> Tuple[str, int]:
    if detect_root_kind(root) == "template_source":
        return template_source_notice(root), 0

    state = load_runtime_state(root)
    report = ConsistencyReport(root)
    tasks = task_map(state)
    roles = role_map(state)
    active = queue_items(state)

    check_registry_owner_semantics(report, state)
    check_active_items(report, state, tasks, roles, active)
    check_active_parallelism(report, state, tasks, roles, active)
    check_gate_artifacts(report, root, state)
    check_event_log(report, root, tasks)

    if not report.error:
        report.add("OK", "no state consistency errors detected", path="project/runtime")
    return report.render(), 1 if report.has_errors else 0


def check_registry_owner_semantics(report: ConsistencyReport, state: Dict[str, Any]) -> None:
    path = "project/runtime/task_registry.json"
    for task in state["registry"].get("tasks", []):
        task_id = str(task.get("task_id", "<unknown>"))
        status = task.get("status", "")
        owner = task.get("owner", "")
        if status == "in_progress" and not owner:
            report.add("ERROR", "in_progress task owner must be nonempty", task_id=task_id, path=path)
        if status != "in_progress" and owner:
            report.add("ERROR", f"non-in_progress task owner must be empty; owner={owner}", task_id=task_id, path=path)
        if status == "done" and not bool(task.get("accepted_by_main_brain", False)):
            report.add("WARN", "done task has accepted_by_main_brain=false", task_id=task_id, path=path)


def check_active_items(
    report: ConsistencyReport,
    state: Dict[str, Any],
    tasks: Dict[str, Dict[str, Any]],
    roles: Dict[str, Dict[str, Any]],
    active: Sequence[Dict[str, Any]],
) -> None:
    queue_path = "project/runtime/work_queue.json"
    registry_path = "project/runtime/task_registry.json"

    for item in active:
        task_id = str(item.get("task_id", "<unknown>"))
        if task_id not in tasks:
            report.add("ERROR", "active item references unknown registry task", task_id=task_id, path=queue_path)
            continue

        task = tasks[task_id]
        role_name = task.get("role", "")
        role = roles.get(role_name)
        if item.get("status") != "in_progress":
            report.add("ERROR", "active item status must be in_progress", task_id=task_id, path=queue_path)
        if task.get("status") != "in_progress":
            report.add("ERROR", "registry task for active item must be in_progress", task_id=task_id, path=registry_path)
        if item.get("owner", "") != task.get("owner", ""):
            report.add("ERROR", "active item owner differs from registry owner", task_id=task_id, path=queue_path)
        if item.get("role", "") != role_name:
            report.add("ERROR", "active item role differs from registry role", task_id=task_id, path=queue_path)

        locked_paths = item.get("locked_paths")
        if not isinstance(locked_paths, list):
            report.add("ERROR", "active item locked_paths must be a list", task_id=task_id, path=queue_path)
            continue
        if not locked_paths:
            report.add("ERROR", "active item locked_paths must be nonempty", task_id=task_id, path=queue_path)
        if role is None:
            report.add("ERROR", f"task role does not exist in agent_roles.json: {role_name}", task_id=task_id, path="project/spec/agent_roles.json")
            continue
        for locked in locked_paths:
            if not any_path_matches(task.get("allowed_paths", []), str(locked)):
                report.add("ERROR", f"locked path outside task allowed_paths: {locked}", task_id=task_id, path=queue_path)
            if not any_path_matches(role.get("write_roots", []), str(locked)):
                report.add("ERROR", f"locked path outside role.write_roots: {locked}", task_id=task_id, path="project/spec/agent_roles.json")


def check_active_parallelism(
    report: ConsistencyReport,
    state: Dict[str, Any],
    tasks: Dict[str, Dict[str, Any]],
    roles: Dict[str, Dict[str, Any]],
    active: Sequence[Dict[str, Any]],
) -> None:
    queue_path = "project/runtime/work_queue.json"
    for idx, left in enumerate(active):
        left_task_id = str(left.get("task_id", "<unknown>"))
        left_task = tasks.get(left_task_id)
        if left_task is None:
            continue
        left_role_name = str(left.get("role", ""))
        left_role = roles.get(left_role_name)
        for right in active[idx + 1 :]:
            right_task_id = str(right.get("task_id", "<unknown>"))
            right_task = tasks.get(right_task_id)
            if right_task is None:
                continue
            right_role_name = str(right.get("role", ""))
            right_role = roles.get(right_role_name)

            pair_task_id = f"{left_task_id},{right_task_id}"
            if not bool(left_task.get("parallel_ok", False)) or not bool(right_task.get("parallel_ok", False)):
                report.add("ERROR", "parallel_ok=false task is active with another task", task_id=pair_task_id, path=queue_path)
            if left_role is not None and right_role is not None:
                forbidden = (
                    right_role_name in left_role.get("parallel_forbidden_with", [])
                    or left_role_name in right_role.get("parallel_forbidden_with", [])
                )
                if forbidden:
                    report.add("ERROR", "active task roles are mutually forbidden by role matrix", task_id=pair_task_id, path="project/spec/agent_roles.json")
            left_locks = left.get("locked_paths", [])
            right_locks = right.get("locked_paths", [])
            if isinstance(left_locks, list) and isinstance(right_locks, list):
                overlaps = [
                    f"{left_lock} <-> {right_lock}"
                    for left_lock in left_locks
                    for right_lock in right_locks
                    if paths_overlap(str(left_lock), str(right_lock))
                ]
                if overlaps:
                    report.add("ERROR", f"active locked_paths overlap: {', '.join(overlaps)}", task_id=pair_task_id, path=queue_path)


def check_gate_artifacts(report: ConsistencyReport, root: Path, state: Dict[str, Any]) -> None:
    registry_path = "project/runtime/task_registry.json"
    for task in state["registry"].get("tasks", []):
        task_id = str(task.get("task_id", "<unknown>"))
        status = task.get("status", "")
        feedback_path = task.get("feedback_path")
        retrospective_path = task.get("retrospective_path")
        if not isinstance(feedback_path, str) or not feedback_path:
            report.add("ERROR", "task missing feedback_path", task_id=task_id, path=registry_path)
        if not isinstance(retrospective_path, str) or not retrospective_path:
            report.add("ERROR", "task missing retrospective_path", task_id=task_id, path=registry_path)
        if status in {"review", "done"} and isinstance(feedback_path, str) and feedback_path:
            if not (root / feedback_path).is_file():
                report.add("ERROR", "review/done task feedback_path artifact is missing", task_id=task_id, path=feedback_path)
        if status == "done" and isinstance(retrospective_path, str) and retrospective_path:
            if not (root / retrospective_path).is_file():
                report.add("ERROR", "done task retrospective_path artifact is missing", task_id=task_id, path=retrospective_path)


def check_event_log(report: ConsistencyReport, root: Path, tasks: Dict[str, Dict[str, Any]]) -> None:
    event_path = root / "project/runtime/event_log.jsonl"
    rel_event_path = "project/runtime/event_log.jsonl"
    if not event_path.is_file():
        report.add("WARN", "event log missing; fresh or manually prepared instance may not have audit trace yet", path=rel_event_path)
        return
    nonempty_lines = [(idx, line.strip()) for idx, line in enumerate(event_path.read_text(encoding="utf-8").splitlines(), start=1) if line.strip()]
    if not nonempty_lines:
        report.add("OK", "event log exists and is empty", path=rel_event_path)
        return

    seen_event_ids: Dict[str, int] = {}
    for lineno, line in nonempty_lines:
        context_path = f"{rel_event_path}:{lineno}"
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            report.add("ERROR", f"event line is not valid JSON: {exc}", path=context_path)
            continue
        if not isinstance(event, dict):
            report.add("ERROR", "event line must be a JSON object", path=context_path)
            continue

        task_id = str(event.get("task_id", "<missing>"))
        missing = [field for field in REQUIRED_EVENT_FIELDS if field not in event]
        if missing:
            report.add("ERROR", f"event missing required fields: {', '.join(missing)}", task_id=task_id, path=context_path)
        if "artifacts" in event and not isinstance(event["artifacts"], list):
            report.add("ERROR", "event artifacts must be a list", task_id=task_id, path=context_path)
        if "metadata" in event and not isinstance(event["metadata"], dict):
            report.add("ERROR", "event metadata must be an object", task_id=task_id, path=context_path)

        event_id = event.get("event_id", "")
        if isinstance(event_id, str) and event_id:
            if event_id in seen_event_ids:
                report.add("ERROR", f"duplicate event_id also seen at line {seen_event_ids[event_id]}: {event_id}", task_id=task_id, path=context_path)
            else:
                seen_event_ids[event_id] = lineno
        else:
            report.add("ERROR", "event event_id must be nonempty", task_id=task_id, path=context_path)

        if task_id not in tasks:
            report.add("ERROR", "event task_id does not exist in registry", task_id=task_id, path=context_path)
            continue
        expected_role = tasks[task_id].get("role", "")
        if event.get("role", "") != expected_role:
            report.add("ERROR", f"event role does not match registry role; expected={expected_role} actual={event.get('role', '')}", task_id=task_id, path=context_path)

    report.add("OK", f"event log parsed: {len(nonempty_lines)} nonempty event(s)", path=rel_event_path)
