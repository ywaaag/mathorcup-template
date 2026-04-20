from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from workflow_kernel.audit_index import check_feedback, check_retrospective
from workflow_kernel.packet import choose_cwd, collect_acceptance_artifacts
from workflow_kernel.render import write_queue_board
from workflow_kernel.schema import (
    any_path_matches,
    fail,
    parse_kv_env,
    paths_overlap,
    queue_items,
    role_map,
    save_structured,
    task_from_id,
)


def current_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def append_history(
    state: Dict[str, Any],
    *,
    task_id: str,
    action: str,
    from_status: str,
    to_status: str,
    owner: str,
    actor: str,
    reason: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> None:
    entry: Dict[str, Any] = {
        "timestamp": current_timestamp(),
        "task_id": task_id,
        "action": action,
        "from_status": from_status,
        "to_status": to_status,
        "owner": owner,
        "actor": actor,
        "reason": reason,
    }
    if extra:
        for key, value in extra.items():
            if value not in ("", None, [], {}):
                entry[key] = value
    state["queue"].setdefault("history", []).append(entry)


def active_task_ids(state: Dict[str, Any]) -> set[str]:
    return {item["task_id"] for item in queue_items(state)}


def find_active_queue_item(state: Dict[str, Any], task_id: str) -> Optional[Dict[str, Any]]:
    for item in queue_items(state):
        if item["task_id"] == task_id:
            return item
    return None


def claim_task_impl(
    root: Path,
    state: Dict[str, Any],
    task_id: str,
    owner: str,
    locks: Sequence[str],
    *,
    actor: str,
    allowed_from_statuses: Sequence[str],
    history_action: str,
    reason: str = "",
) -> None:
    task = task_from_id(state, task_id)
    roles = role_map(state)
    role = roles[task["role"]]
    from_status = task["status"]
    if from_status not in allowed_from_statuses:
        fail(
            f"task {task_id} cannot be claimed from status '{from_status}'; "
            f"allowed: {', '.join(allowed_from_statuses)}"
        )
    existing = find_active_queue_item(state, task_id)
    if existing:
        fail(f"task {task_id} is already in progress by {existing['owner']}")
    locked_paths = list(locks) if locks else list(task["allowed_paths"])
    for locked in locked_paths:
        if not any_path_matches(task["allowed_paths"], locked):
            fail(f"locked path '{locked}' is outside task allowed_paths")
        if not any_path_matches(role["write_roots"], locked):
            fail(f"locked path '{locked}' is outside role write_roots")
    for other in queue_items(state):
        other_task = task_from_id(state, other["task_id"])
        other_role = roles[other["role"]]
        role_conflict = (
            other["role"] in role["parallel_forbidden_with"]
            or task["role"] in other_role["parallel_forbidden_with"]
        )
        if role_conflict:
            fail(f"task {task_id} conflicts with active task {other['task_id']} by role matrix")
        if (not task["parallel_ok"]) or (not other_task["parallel_ok"]):
            fail(f"task {task_id} cannot run in parallel with active task {other['task_id']}")
        if any(paths_overlap(left, right) for left in locked_paths for right in other["locked_paths"]):
            fail(f"task {task_id} locked paths conflict with active task {other['task_id']}")
    task["status"] = "in_progress"
    task["owner"] = owner
    task["accepted_by_main_brain"] = False
    state["queue"].setdefault("active_items", []).append(
        {
            "task_id": task_id,
            "role": task["role"],
            "owner": owner,
            "status": "in_progress",
            "locked_paths": locked_paths,
        }
    )
    append_history(
        state,
        task_id=task_id,
        action=history_action,
        from_status=from_status,
        to_status="in_progress",
        owner=owner,
        actor=actor or owner,
        reason=reason,
        extra={"locked_paths": locked_paths},
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)


def task_field_value(root: Path, state: Dict[str, Any], task_id: str, field: str) -> str:
    task = task_from_id(state, task_id)
    role = role_map(state)[task["role"]]
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    values: Dict[str, Any] = {
        "task_id": task["task_id"],
        "role": task["role"],
        "title": task["title"],
        "status": task["status"],
        "owner": task["owner"],
        "allowed_paths": task["allowed_paths"],
        "parallel_ok": task["parallel_ok"],
        "feedback_path": task["feedback_path"],
        "retrospective_path": task["retrospective_path"],
        "cwd": str(choose_cwd(root, task["role"], task).relative_to(root) or "."),
        "acceptance_artifacts": collect_acceptance_artifacts(root, role, task),
        "paper_entrypoint": paper_env.get("PAPER_ACTIVE_ENTRYPOINT", ""),
        "paper_accept_pdf": paper_env.get("PAPER_ACCEPT_PDF", ""),
        "paper_accept_log": paper_env.get("PAPER_ACCEPT_LOG", ""),
    }
    if field not in values:
        fail(f"unknown task field: {field}")
    value = values[field]
    if isinstance(value, list):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, bool):
        return json.dumps(value)
    return str(value)


def parse_task_locks(entries: Sequence[str]) -> Dict[str, List[str]]:
    mapping: Dict[str, List[str]] = {}
    for entry in entries:
        if ":" not in entry:
            fail(f"invalid --lock entry for batch-check: {entry}")
        task_id, path = entry.split(":", 1)
        task_id = task_id.strip()
        path = path.strip()
        if not task_id or not path:
            fail(f"invalid --lock entry for batch-check: {entry}")
        mapping.setdefault(task_id, []).append(path)
    return mapping


def batch_check(root: Path, state: Dict[str, Any], task_ids: Sequence[str], lock_overrides: Dict[str, List[str]]) -> Dict[str, Any]:
    if not task_ids:
        fail("batch-check requires at least one --task")
    if len(set(task_ids)) != len(task_ids):
        fail("batch-check received duplicate task ids")

    tasks = [task_from_id(state, task_id) for task_id in task_ids]
    roles = role_map(state)
    active_items = queue_items(state)
    conflicts: List[Dict[str, Any]] = []
    effective_locks: Dict[str, List[str]] = {}

    for task in tasks:
        active = find_active_queue_item(state, task["task_id"])
        if active:
            conflicts.append(
                {
                    "type": "already_claimed",
                    "task_id": task["task_id"],
                    "owner": active["owner"],
                }
            )
        if task["status"] not in {"todo", "ready"}:
            conflicts.append(
                {
                    "type": "status_not_dispatchable",
                    "task_id": task["task_id"],
                    "status": task["status"],
                }
            )
        effective_locks[task["task_id"]] = list(lock_overrides.get(task["task_id"], task["allowed_paths"]))
        for path in effective_locks[task["task_id"]]:
            if not any_path_matches(task["allowed_paths"], path):
                conflicts.append(
                    {
                        "type": "lock_outside_allowed_paths",
                        "task_id": task["task_id"],
                        "path": path,
                    }
                )

    for idx, left in enumerate(tasks):
        left_role = roles[left["role"]]
        for right in tasks[idx + 1 :]:
            right_role = roles[right["role"]]
            reasons: List[str] = []
            if (not left["parallel_ok"]) or (not right["parallel_ok"]):
                reasons.append("parallel_ok=false")
            if right["role"] in left_role["parallel_forbidden_with"] or left["role"] in right_role["parallel_forbidden_with"]:
                reasons.append("role_matrix_forbidden")
            if any(
                paths_overlap(left_path, right_path)
                for left_path in effective_locks[left["task_id"]]
                for right_path in effective_locks[right["task_id"]]
            ):
                reasons.append("locked_paths_overlap")
            if reasons:
                conflicts.append(
                    {
                        "type": "batch_conflict",
                        "left": left["task_id"],
                        "right": right["task_id"],
                        "reasons": reasons,
                    }
                )

    for task in tasks:
        task_role = roles[task["role"]]
        for active in active_items:
            active_task = task_from_id(state, active["task_id"])
            active_role = roles[active["role"]]
            reasons: List[str] = []
            if (not task["parallel_ok"]) or (not active_task["parallel_ok"]):
                reasons.append("parallel_ok=false_against_active")
            if active["role"] in task_role["parallel_forbidden_with"] or task["role"] in active_role["parallel_forbidden_with"]:
                reasons.append("role_matrix_forbidden_against_active")
            if any(paths_overlap(left_path, right_path) for left_path in effective_locks[task["task_id"]] for right_path in active["locked_paths"]):
                reasons.append("locked_paths_overlap_against_active")
            if reasons:
                conflicts.append(
                    {
                        "type": "active_conflict",
                        "task_id": task["task_id"],
                        "active_task_id": active["task_id"],
                        "reasons": reasons,
                    }
                )

    summary = {
        "ok": not conflicts,
        "tasks": [
            {
                "task_id": task["task_id"],
                "role": task["role"],
                "status": task["status"],
                "locked_paths": effective_locks[task["task_id"]],
            }
            for task in tasks
        ],
        "conflicts": conflicts,
    }
    if conflicts:
        fail(json.dumps(summary, ensure_ascii=True, indent=2))
    return summary


def claim_task(root: Path, state: Dict[str, Any], task_id: str, owner: str, locks: Sequence[str], actor: str) -> None:
    claim_task_impl(
        root,
        state,
        task_id,
        owner,
        locks,
        actor=actor or owner,
        allowed_from_statuses=("todo", "ready"),
        history_action="claim",
    )


def close_task(root: Path, state: Dict[str, Any], task_id: str, next_status: str, accepted_by: str, actor: str) -> None:
    if next_status not in {"review", "done"}:
        fail("--to must be review or done")
    task = task_from_id(state, task_id)
    active = find_active_queue_item(state, task_id)
    if not active:
        fail(f"task {task_id} is not currently claimed")
    from_status = task["status"]
    owner = task["owner"]
    check_feedback(root, state, task_id=task_id, file_path=None, require_exists=True)
    if next_status == "done":
        check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=True)
        if not accepted_by:
            fail("--accepted-by is required when closing a task as done")
        task["accepted_by_main_brain"] = True
    else:
        task["accepted_by_main_brain"] = False
    task["status"] = next_status
    task["owner"] = ""
    state["queue"]["active_items"] = [item for item in queue_items(state) if item["task_id"] != task_id]
    append_history(
        state,
        task_id=task_id,
        action="close",
        from_status=from_status,
        to_status=next_status,
        owner=owner,
        actor=actor or accepted_by or owner,
        extra={"accepted_by": accepted_by},
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)


def cancel_task(root: Path, state: Dict[str, Any], task_id: str, to_status: str, reason: str, actor: str) -> None:
    if to_status not in {"blocked", "ready"}:
        fail("--to must be blocked or ready")
    task = task_from_id(state, task_id)
    active = find_active_queue_item(state, task_id)
    if not active:
        fail(f"task {task_id} is not currently claimed")
    from_status = task["status"]
    if from_status != "in_progress":
        fail(f"task {task_id} cannot be cancelled from status '{from_status}'")
    owner = task["owner"]
    task["status"] = to_status
    task["owner"] = ""
    task["accepted_by_main_brain"] = False
    state["queue"]["active_items"] = [item for item in queue_items(state) if item["task_id"] != task_id]
    append_history(
        state,
        task_id=task_id,
        action="cancel",
        from_status=from_status,
        to_status=to_status,
        owner=owner,
        actor=actor,
        reason=reason,
        extra={"locked_paths": active.get("locked_paths", [])},
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)


def reopen_task(
    root: Path,
    state: Dict[str, Any],
    task_id: str,
    to_status: str,
    reason: str,
    actor: str,
    owner: str,
    locks: Sequence[str],
) -> None:
    task = task_from_id(state, task_id)
    from_status = task["status"]
    allowed_transitions = {
        ("blocked", "ready"),
        ("blocked", "in_progress"),
        ("review", "ready"),
        ("review", "in_progress"),
        ("done", "review"),
    }
    if (from_status, to_status) not in allowed_transitions:
        fail(f"task {task_id} cannot transition from '{from_status}' to '{to_status}' via reopen")
    if to_status == "in_progress":
        if not owner:
            fail("--owner is required when reopening a task to in_progress")
        claim_task_impl(
            root,
            state,
            task_id,
            owner,
            locks,
            actor=actor,
            allowed_from_statuses=(from_status,),
            history_action="reopen",
            reason=reason,
        )
        return
    active = find_active_queue_item(state, task_id)
    if active:
        fail(f"task {task_id} is still claimed by {active['owner']}; cancel or close it first")
    current_owner = task["owner"]
    task["status"] = to_status
    task["owner"] = ""
    if from_status == "done":
        task["accepted_by_main_brain"] = False
    append_history(
        state,
        task_id=task_id,
        action="reopen",
        from_status=from_status,
        to_status=to_status,
        owner=current_owner,
        actor=actor,
        reason=reason,
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)
