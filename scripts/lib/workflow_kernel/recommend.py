from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Sequence

from workflow_kernel.schema import (
    any_path_matches,
    detect_root_kind,
    load_runtime_state,
    paths_overlap,
    queue_items,
    role_map,
    task_map,
)
from workflow_kernel.transitions import parse_task_locks


DISPATCHABLE_STATUSES = {"todo", "ready"}


def owner_for_task(prefix: str, task: Dict[str, Any]) -> str:
    return f"{prefix}_{task['task_id']}"


def shell_quote(value: str) -> str:
    if not value:
        return "''"
    safe = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-=.,:/@%")
    if all(ch in safe for ch in value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def task_title(task: Dict[str, Any]) -> str:
    title = task.get("title", "")
    return f" | {title}" if title else ""


def active_summary(active: Sequence[Dict[str, Any]]) -> List[str]:
    if not active:
        return ["- none"]
    lines = []
    for item in active:
        locks = ", ".join(item.get("locked_paths", [])) or "-"
        lines.append(
            f"- {item.get('task_id', '<unknown>')} | role={item.get('role', '-')} | "
            f"owner={item.get('owner', '-')} | locks={locks}"
        )
    return lines


def lock_paths_for_task(task: Dict[str, Any], lock_overrides: Dict[str, List[str]]) -> List[str]:
    return list(lock_overrides.get(task["task_id"], task.get("allowed_paths", [])))


def role_conflict(candidate_role: Dict[str, Any], candidate_role_name: str, active_role: Dict[str, Any], active_role_name: str) -> bool:
    return (
        active_role_name in candidate_role.get("parallel_forbidden_with", [])
        or candidate_role_name in active_role.get("parallel_forbidden_with", [])
    )


def task_is_pairwise_compatible(
    left: Dict[str, Any],
    left_locks: Sequence[str],
    right: Dict[str, Any],
    right_locks: Sequence[str],
    roles: Dict[str, Dict[str, Any]],
) -> bool:
    if not left.get("parallel_ok", False) or not right.get("parallel_ok", False):
        return False
    left_role_name = left["role"]
    right_role_name = right["role"]
    left_role = roles.get(left_role_name)
    right_role = roles.get(right_role_name)
    if left_role is None or right_role is None:
        return False
    if role_conflict(left_role, left_role_name, right_role, right_role_name):
        return False
    return not any(paths_overlap(left_path, right_path) for left_path in left_locks for right_path in right_locks)


def build_batch_subset(
    safe_tasks: Sequence[Dict[str, Any]],
    effective_locks: Dict[str, List[str]],
    roles: Dict[str, Dict[str, Any]],
) -> List[Dict[str, Any]]:
    selected: List[Dict[str, Any]] = []
    for task in safe_tasks:
        locks = effective_locks[task["task_id"]]
        if not task.get("parallel_ok", False):
            continue
        if all(
            task_is_pairwise_compatible(task, locks, existing, effective_locks[existing["task_id"]], roles)
            for existing in selected
        ):
            selected.append(task)
    return selected


def dispatch_command(task: Dict[str, Any], root: Path, owner_prefix: str, locks: Sequence[str]) -> str:
    parts = [
        "bash",
        "scripts/dispatch_task.sh",
        "--task",
        task["task_id"],
        "--owner",
        owner_for_task(owner_prefix, task),
    ]
    default_locks = list(task.get("allowed_paths", []))
    if list(locks) != default_locks:
        for lock in locks:
            parts.extend(["--lock", lock])
    parts.extend(["--target", str(root)])
    return " ".join(shell_quote(part) for part in parts)


def batch_command(tasks: Sequence[Dict[str, Any]], root: Path, owner_prefix: str, locks_by_task: Dict[str, List[str]]) -> str:
    task_ids = [task["task_id"] for task in tasks]
    owners = [owner_for_task(owner_prefix, task) for task in tasks]
    parts = [
        "bash",
        "scripts/run_exec_batch.sh",
        "--tasks",
        ",".join(task_ids),
        "--owners",
        ",".join(owners),
        "--max-concurrency",
        str(len(task_ids)),
    ]
    for task in tasks:
        default_locks = list(task.get("allowed_paths", []))
        locks = locks_by_task[task["task_id"]]
        if locks != default_locks:
            for lock in locks:
                parts.extend(["--lock", f"{task['task_id']}:{lock}"])
    parts.extend(["--target", str(root)])
    return " ".join(shell_quote(part) for part in parts)


def evaluate_task(
    task: Dict[str, Any],
    *,
    roles: Dict[str, Dict[str, Any]],
    tasks: Dict[str, Dict[str, Any]],
    active: Sequence[Dict[str, Any]],
    active_ids: set[str],
    locks: Sequence[str],
) -> List[str]:
    reasons: List[str] = []
    task_id = task["task_id"]
    role_name = task.get("role", "")
    role = roles.get(role_name)

    if task_id in active_ids:
        owner = next((item.get("owner", "") for item in active if item.get("task_id") == task_id), "")
        suffix = f" by {owner}" if owner else ""
        reasons.append(f"task is already active{suffix}")
    if task.get("status") not in DISPATCHABLE_STATUSES:
        reasons.append(f"status is {task.get('status', '<missing>')}, not todo/ready")
    if task.get("owner"):
        reasons.append(f"owner is already set to {task['owner']}")
    if role is None:
        reasons.append(f"role {role_name or '<missing>'} does not exist in agent_roles.json")
        return reasons

    for path in task.get("allowed_paths", []):
        if not any_path_matches(role.get("write_roots", []), path):
            reasons.append(f"allowed path {path} is outside role {role_name} write_roots")
    for lock in locks:
        if not any_path_matches(task.get("allowed_paths", []), lock):
            reasons.append(f"lock scope {lock} is outside task allowed_paths")
        if not any_path_matches(role.get("write_roots", []), lock):
            reasons.append(f"lock scope {lock} is outside role {role_name} write_roots")

    if active and not task.get("parallel_ok", False):
        active_names = ", ".join(item.get("task_id", "<unknown>") for item in active)
        reasons.append(f"parallel_ok=false while active task exists: {active_names}")

    for item in active:
        active_task_id = item.get("task_id", "")
        active_task = tasks.get(active_task_id)
        active_role_name = item.get("role", "")
        active_role = roles.get(active_role_name)
        if active_task is None:
            reasons.append(f"active queue references unknown task {active_task_id}")
            continue
        if active_role is None:
            reasons.append(f"active task {active_task_id} role {active_role_name} does not exist in agent_roles.json")
            continue
        if role_conflict(role, role_name, active_role, active_role_name):
            reasons.append(f"role {role_name} conflicts with active task {active_task_id} role {active_role_name}")
        if not active_task.get("parallel_ok", False):
            reasons.append(f"active task {active_task_id} has parallel_ok=false")
        overlaps = [
            f"{left} <-> {right}"
            for left in locks
            for right in item.get("locked_paths", [])
            if paths_overlap(left, right)
        ]
        if overlaps:
            reasons.append(f"lock scope overlaps active task {active_task_id}: {', '.join(overlaps)}")

    return reasons


def template_source_notice(root: Path) -> str:
    return "\n".join(
        [
            "Safe-to-dispatch recommendation is advisory-only.",
            "",
            f"Current root is template-source: {root}",
            "Do not run this against the template source as if it were a rendered instance.",
            "",
            "Render a temporary instance first:",
            '  tmpdir="$(mktemp -d)"',
            '  bash scripts/setup.sh demo --render-only --target "$tmpdir"',
            '  bash scripts/recommend_tasks.sh --target "$tmpdir"',
            "",
        ]
    )


def recommend_tasks_report(root: Path, owner_prefix: str, lock_entries: Sequence[str]) -> str:
    if detect_root_kind(root) == "template_source":
        return template_source_notice(root)

    state = load_runtime_state(root)
    roles = role_map(state)
    tasks_by_id = task_map(state)
    active = queue_items(state)
    active_ids = {item.get("task_id", "") for item in active}
    lock_overrides = parse_task_locks(lock_entries)

    safe: List[Dict[str, Any]] = []
    blocked: List[tuple[Dict[str, Any], List[str]]] = []
    effective_locks: Dict[str, List[str]] = {}

    for task in state["registry"].get("tasks", []):
        task_locks = lock_paths_for_task(task, lock_overrides)
        effective_locks[task["task_id"]] = task_locks
        reasons = evaluate_task(
            task,
            roles=roles,
            tasks=tasks_by_id,
            active=active,
            active_ids=active_ids,
            locks=task_locks,
        )
        if reasons:
            blocked.append((task, reasons))
        else:
            safe.append(task)

    lines: List[str] = [
        "Safe-to-dispatch recommendation is advisory-only.",
        "No files are modified by this command.",
        "",
        f"Root: {root}",
        f"Owner prefix: {owner_prefix}",
        "",
        "Active tasks:",
        *active_summary(active),
        "",
        "Safe-to-dispatch list:",
    ]
    if not safe:
        lines.append("- none")
    else:
        for task in safe:
            locks = effective_locks[task["task_id"]]
            lines.append(f"- {task['task_id']} | role={task['role']}{task_title(task)}")
            lines.append(f"  locks: {', '.join(locks) if locks else '-'}")
            lines.append(f"  command: {dispatch_command(task, root, owner_prefix, locks)}")

    lines.extend(["", "Not recommended / blocked list:"])
    if not blocked:
        lines.append("- none")
    else:
        for task, reasons in blocked:
            lines.append(f"- {task.get('task_id', '<unknown>')} | role={task.get('role', '-')}{task_title(task)}")
            for reason in reasons:
                lines.append(f"  reason: {reason}")

    batch_subset = build_batch_subset(safe, effective_locks, roles)
    lines.extend(["", "Optional run_exec_batch.sh suggestion:"])
    if len(batch_subset) >= 2:
        lines.append("- Advisory only; inspect scopes before running.")
        lines.append(f"  command: {batch_command(batch_subset, root, owner_prefix, effective_locks)}")
    else:
        lines.append("- none under current lock scopes")
        if len(safe) >= 2:
            lines.append("- Multiple tasks are individually safe, but their default lock scopes are not mutually parallel.")
            lines.append("- Rerun with --lock <task_id:path> to test a narrower manual batch scope.")

    if lock_overrides:
        lines.extend(["", "Manual lock overrides used:"])
        for task_id, locks in sorted(lock_overrides.items()):
            lines.append(f"- {task_id}: {', '.join(locks)}")

    return "\n".join(lines) + "\n"
