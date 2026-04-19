#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


REQUIRED_ROLE_FIELDS = [
    "description",
    "read_roots",
    "write_roots",
    "forbidden_roots",
    "memory_permissions",
    "must_read_docs",
    "default_acceptance_artifacts",
    "parallel_safe_with",
    "parallel_forbidden_with",
]

REQUIRED_TASK_FIELDS = [
    "task_id",
    "role",
    "title",
    "status",
    "owner",
    "allowed_paths",
    "forbidden_paths",
    "parallel_ok",
    "input_refs",
    "output_refs",
    "feedback_path",
    "retrospective_path",
    "accepted_by_main_brain",
]

TASK_STATUSES = {"todo", "ready", "in_progress", "review", "done", "blocked"}

TEMPLATE_SOURCE_REQUIRED_FILES = [
    "scaffold/AGENTS.md.template",
    "scaffold/MEMORY.md.template",
    "scaffold/project/paper/AGENTS.md.template",
    "scaffold/project/spec/runtime_contract.md.template",
    "scaffold/project/spec/multi_agent_workflow_contract.md.template",
    "scaffold/project/spec/agent_roles.yaml.template",
    "scaffold/project/runtime/task_registry.yaml.template",
    "scaffold/project/runtime/work_queue.yaml.template",
    "scaffold/project/paper/spec/paper_runtime_contract.md.template",
    "scaffold/project/paper/runtime/paper.env.template",
    "scripts/setup.sh",
    "scripts/render_templates.sh",
    "scripts/validate_agent_docs.sh",
    "scripts/doctor.sh",
]

FEEDBACK_HEADINGS = [
    "## Task ID",
    "## Role",
    "## Files Changed",
    "## Work Done",
    "## Verified Facts",
    "## Validation Or Acceptance",
    "## Remaining Risks",
    "## Lesson Learned",
    "## What Main Brain Should Have Told Me Earlier",
]

RETRO_HEADINGS = [
    "## Task ID",
    "## Trigger",
    "## Real Phenomenon",
    "## Investigation",
    "## Verified Facts",
    "## Revised Judgement",
    "## Reusable Guardrails",
    "## Next Consumer",
]


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_structured(path: Path) -> Any:
    if not path.is_file():
        fail(f"missing file: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON-compatible YAML in {path}: {exc}")


def save_structured(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def normalize_relpath(path: str) -> str:
    if path in {".", ""}:
        return "."
    return str(Path(path).as_posix()).rstrip("/")


def path_matches(root: str, path: str) -> bool:
    root = normalize_relpath(root)
    path = normalize_relpath(path)
    if root == ".":
        return True
    return path == root or path.startswith(root + "/")


def any_path_matches(roots: Sequence[str], path: str) -> bool:
    return any(path_matches(root, path) for root in roots)


def paths_overlap(a: str, b: str) -> bool:
    a = normalize_relpath(a)
    b = normalize_relpath(b)
    return path_matches(a, b) or path_matches(b, a)


def resolve_config_ref(root: Path, reference: str) -> str:
    if "#" not in reference:
        return reference
    file_ref, key = reference.split("#", 1)
    file_ref = normalize_relpath(file_ref)
    if file_ref.endswith(".env"):
        values = parse_kv_env(root / file_ref)
        return values.get(key, "")
    return reference


def parse_kv_env(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    if not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def detect_root_kind(root: Path) -> str:
    scaffold_dir = root / "scaffold"
    scaffold_roles = root / "scaffold/project/spec/agent_roles.yaml.template"
    scaffold_registry = root / "scaffold/project/runtime/task_registry.yaml.template"
    scaffold_queue = root / "scaffold/project/runtime/work_queue.yaml.template"
    live_roles = root / "project/spec/agent_roles.yaml"
    live_registry = root / "project/runtime/task_registry.yaml"
    live_queue = root / "project/runtime/work_queue.yaml"
    if (
        scaffold_dir.is_dir()
        and scaffold_roles.is_file()
        and scaffold_registry.is_file()
        and scaffold_queue.is_file()
        and not live_roles.is_file()
        and not live_registry.is_file()
        and not live_queue.is_file()
    ):
        return "template_source"
    return "instance"


def validate_template_source(root: Path) -> None:
    if not (root / "scaffold").is_dir():
        fail("missing directory: scaffold")
    for rel in TEMPLATE_SOURCE_REQUIRED_FILES:
        if not (root / rel).exists():
            fail(f"missing template-source file: {rel}")


def load_runtime_state(root: Path) -> Dict[str, Any]:
    roles_path = root / "project/spec/agent_roles.yaml"
    registry_path = root / "project/runtime/task_registry.yaml"
    queue_path = root / "project/runtime/work_queue.yaml"
    roles = load_structured(roles_path)
    registry = load_structured(registry_path)
    queue = load_structured(queue_path)
    return {
        "roles_path": roles_path,
        "registry_path": registry_path,
        "queue_path": queue_path,
        "roles": roles,
        "registry": registry,
        "queue": queue,
    }


def role_map(state: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return state["roles"].get("roles", {})


def task_map(state: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    tasks = state["registry"].get("tasks", [])
    return {task["task_id"]: task for task in tasks}


def queue_items(state: Dict[str, Any]) -> List[Dict[str, Any]]:
    return list(state["queue"].get("active_items", []))


def ensure_fields(mapping: Dict[str, Any], fields: Sequence[str], context: str) -> None:
    missing = [field for field in fields if field not in mapping]
    if missing:
        fail(f"{context} missing fields: {', '.join(missing)}")


def check_required_paths(root: Path, references: Sequence[str], context: str) -> None:
    for ref in references:
        if "#" in ref:
            ref = ref.split("#", 1)[0]
        if ref in {".", ""}:
            continue
        if not (root / ref).exists():
            fail(f"{context} references missing path: {ref}")


def validate_memory(root: Path) -> None:
    file = root / "MEMORY.md"
    if not file.is_file():
        fail("missing file: MEMORY.md")
    lines = file.read_text(encoding="utf-8").splitlines()
    if len(lines) > 120:
        fail(f"MEMORY.md exceeds 120 lines (current: {len(lines)})")
    expected = [
        "## Phase",
        "## Current Task",
        "## Active Problem",
        "## Decisions",
        "## Blockers",
        "## Next Actions",
        "## Handoff Index",
    ]
    headings = [line for line in lines if line.startswith("## ")]
    if headings != expected:
        fail("MEMORY.md must contain the exact 7 level-2 headings in fixed order")


def validate_handoffs(root: Path) -> None:
    handoff_dir = root / "project/output/handoff"
    if not handoff_dir.is_dir():
        fail("missing directory: project/output/handoff")
    template = handoff_dir / "HANDOFF_TEMPLATE.md"
    if not template.is_file():
        fail("missing file: project/output/handoff/HANDOFF_TEMPLATE.md")
    expected = [
        "## Problem",
        "## Inputs",
        "## Method",
        "## Outputs",
        "## For Paper Brain",
        "## Risks",
    ]
    for path in sorted(handoff_dir.glob("*.md")):
        if path.name == "HANDOFF_TEMPLATE.md":
            continue
        if not path.name.endswith(".md") or not path.name.startswith("P"):
            fail(f"invalid handoff filename: {path.name}")
        headings = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("## ")]
        if headings != expected:
            fail(f"{path.name} must contain the exact 6 handoff headings in order")


def validate_contracts(root: Path) -> None:
    required = [
        "AGENTS.md",
        "README.md",
        "project/paper/AGENTS.md",
        "project/spec/runtime_contract.md",
        "project/spec/multi_agent_workflow_contract.md",
        "project/workflow/prompt_template_library.md",
        "project/workflow/TASK_PACKET_TEMPLATE.md",
        "project/workflow/MAIN_BRAIN_ACCEPTANCE_TEMPLATE.md",
        "project/output/review/WORKER_FEEDBACK_TEMPLATE.md",
        "project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md",
        "project/paper/spec/paper_runtime_contract.md",
    ]
    for ref in required:
        if not (root / ref).is_file():
            fail(f"missing file: {ref}")
    runtime_contract = (root / "project/spec/runtime_contract.md").read_text(encoding="utf-8")
    paper_agents = (root / "project/paper/AGENTS.md").read_text(encoding="utf-8")
    root_agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    workflow_contract = (root / "project/spec/multi_agent_workflow_contract.md").read_text(encoding="utf-8")
    if "project/paper/runtime/paper.env" not in runtime_contract:
        fail("runtime_contract.md must reference project/paper/runtime/paper.env")
    if "project/spec/runtime_contract.md" not in root_agents or "project/spec/multi_agent_workflow_contract.md" not in root_agents:
        fail("AGENTS.md must route to runtime/workflow docs")
    if "spec/paper_runtime_contract.md" not in paper_agents:
        fail("project/paper/AGENTS.md must route to paper runtime contract")
    if "project/output/review/WORKER_FEEDBACK_TEMPLATE.md" not in workflow_contract:
        fail("workflow contract must reference worker feedback template")
    if "project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md" not in workflow_contract:
        fail("workflow contract must reference retrospective template")


def validate_paper_config(root: Path) -> None:
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    required = [
        "PAPER_HOST_REL_DIR",
        "PAPER_CONTAINER_DIR",
        "PAPER_ACTIVE_ENTRYPOINT",
        "PAPER_LATEX_ENGINE",
        "PAPER_ACCEPT_PDF",
        "PAPER_ACCEPT_LOG",
        "PAPER_ACCEPT_AUX",
    ]
    missing = [field for field in required if not paper_env.get(field)]
    if missing:
        fail(f"project/paper/runtime/paper.env missing keys: {', '.join(missing)}")
    entrypoint = root / paper_env["PAPER_HOST_REL_DIR"] / paper_env["PAPER_ACTIVE_ENTRYPOINT"]
    if not entrypoint.is_file():
        fail(f"active paper entrypoint does not exist: {entrypoint.relative_to(root)}")


def validate_roles(root: Path, state: Dict[str, Any]) -> None:
    roles_payload = state["roles"]
    if not isinstance(roles_payload, dict) or "roles" not in roles_payload:
        fail("project/spec/agent_roles.yaml must define a top-level 'roles' object")
    roles = role_map(state)
    required_roles = {
        "main_brain",
        "code_brain",
        "paper_brain",
        "layout_worker",
        "review_worker",
        "citation_worker",
        "utility_worker",
    }
    missing_roles = sorted(required_roles - set(roles))
    if missing_roles:
        fail(f"agent_roles.yaml missing roles: {', '.join(missing_roles)}")
    for name, config in roles.items():
        ensure_fields(config, REQUIRED_ROLE_FIELDS, f"role {name}")
        for field in ["read_roots", "write_roots", "forbidden_roots", "must_read_docs", "default_acceptance_artifacts", "parallel_safe_with", "parallel_forbidden_with"]:
            if not isinstance(config[field], list):
                fail(f"role {name} field '{field}' must be a list")
        if not isinstance(config["memory_permissions"], dict):
            fail(f"role {name} field 'memory_permissions' must be an object")
        check_required_paths(root, config["must_read_docs"], f"role {name}")
        for other_role in config["parallel_safe_with"] + config["parallel_forbidden_with"]:
            if other_role not in roles:
                fail(f"role {name} references unknown parallel role: {other_role}")


def validate_tasks(root: Path, state: Dict[str, Any]) -> None:
    tasks_payload = state["registry"]
    tasks = tasks_payload.get("tasks")
    if not isinstance(tasks_payload, dict) or not isinstance(tasks, list):
        fail("project/runtime/task_registry.yaml must define a top-level 'tasks' array")
    roles = role_map(state)
    seen: set[str] = set()
    for task in tasks:
        ensure_fields(task, REQUIRED_TASK_FIELDS, f"task {task.get('task_id', '<unknown>')}")
        task_id = task["task_id"]
        if task_id in seen:
            fail(f"duplicate task_id in task_registry.yaml: {task_id}")
        seen.add(task_id)
        if task["role"] not in roles:
            fail(f"task {task_id} references unknown role: {task['role']}")
        if task["status"] not in TASK_STATUSES:
            fail(f"task {task_id} has invalid status: {task['status']}")
        if not isinstance(task["parallel_ok"], bool):
            fail(f"task {task_id} field 'parallel_ok' must be boolean")
        role = roles[task["role"]]
        for path in task["allowed_paths"]:
            if not any_path_matches(role["write_roots"], path):
                fail(f"task {task_id} allowed path '{path}' is outside role {task['role']} write_roots")
        for path in task["forbidden_paths"]:
            if any_path_matches(role["write_roots"], path) and not any_path_matches(role["forbidden_roots"], path):
                fail(f"task {task_id} forbidden path '{path}' conflicts with role {task['role']} write_roots")
        check_required_paths(root, task["input_refs"], f"task {task_id} input_refs")
        feedback_parent = (root / task["feedback_path"]).parent
        retro_parent = (root / task["retrospective_path"]).parent
        if not feedback_parent.exists():
            fail(f"task {task_id} feedback_path parent does not exist: {feedback_parent.relative_to(root)}")
        if not retro_parent.exists():
            fail(f"task {task_id} retrospective_path parent does not exist: {retro_parent.relative_to(root)}")
        make_task_packet(root, state, task["role"], task_id)


def validate_queue(root: Path, state: Dict[str, Any]) -> None:
    queue_payload = state["queue"]
    if not isinstance(queue_payload, dict) or "active_items" not in queue_payload:
        fail("project/runtime/work_queue.yaml must define top-level 'active_items'")
    if not isinstance(queue_payload["active_items"], list):
        fail("work_queue.yaml field 'active_items' must be a list")
    tasks = task_map(state)
    roles = role_map(state)
    active = queue_items(state)
    task_ids_seen: set[str] = set()
    for item in active:
        for field in ["task_id", "role", "owner", "status", "locked_paths"]:
            if field not in item:
                fail(f"queue item missing field '{field}'")
        task_id = item["task_id"]
        if task_id in task_ids_seen:
            fail(f"duplicate active task in queue: {task_id}")
        task_ids_seen.add(task_id)
        if task_id not in tasks:
            fail(f"queue references unknown task_id: {task_id}")
        task = tasks[task_id]
        if item["role"] != task["role"]:
            fail(f"queue role mismatch for task {task_id}")
        if item["status"] != "in_progress":
            fail(f"queue item {task_id} must use status 'in_progress'")
        if task["status"] != "in_progress":
            fail(f"task {task_id} must also be in_progress in task_registry.yaml")
        if task["owner"] != item["owner"]:
            fail(f"task {task_id} owner mismatch between task_registry and work_queue")
        role = roles[task["role"]]
        for path in item["locked_paths"]:
            if not any_path_matches(task["allowed_paths"], path):
                fail(f"queue item {task_id} locked path '{path}' is outside task allowed_paths")
            if not any_path_matches(role["write_roots"], path):
                fail(f"queue item {task_id} locked path '{path}' is outside role write_roots")
    for idx, left in enumerate(active):
        left_role = roles[left["role"]]
        for right in active[idx + 1 :]:
            right_role = roles[right["role"]]
            role_conflict = (
                right["role"] in left_role["parallel_forbidden_with"]
                or left["role"] in right_role["parallel_forbidden_with"]
            )
            lock_conflict = any(
                paths_overlap(left_lock, right_lock)
                for left_lock in left["locked_paths"]
                for right_lock in right["locked_paths"]
            )
            if role_conflict or lock_conflict:
                fail(
                    f"active task conflict between {left['task_id']} and {right['task_id']}"
                )


def require_headings(path: Path, headings: Sequence[str], context: str) -> List[str]:
    if not path.is_file():
        fail(f"missing file: {path}")
    found = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("## ")]
    if found != list(headings):
        fail(f"{context} must contain exact headings: {' | '.join(headings)}")
    return path.read_text(encoding="utf-8").splitlines()


def task_from_id(state: Dict[str, Any], task_id: str) -> Dict[str, Any]:
    tasks = task_map(state)
    if task_id not in tasks:
        fail(f"unknown task_id: {task_id}")
    return tasks[task_id]


def check_feedback(root: Path, state: Dict[str, Any], *, task_id: Optional[str], file_path: Optional[str], require_exists: bool) -> Path:
    if task_id:
        task = task_from_id(state, task_id)
        path = root / task["feedback_path"]
    elif file_path:
        path = root / file_path if not os.path.isabs(file_path) else Path(file_path)
    else:
        fail("check-feedback requires --task or --file")
    if not path.exists():
        if require_exists:
            fail(f"feedback file does not exist: {path}")
        return path
    lines = require_headings(path, FEEDBACK_HEADINGS, f"feedback file {path.name}")
    task_id_values = [line.strip() for line in lines if line.strip().startswith("- ")]
    if task_id and f"- {task_id}" not in task_id_values:
        fail(f"feedback file {path.name} does not contain task id '{task_id}'")
    return path


def check_retrospective(root: Path, state: Dict[str, Any], *, task_id: Optional[str], file_path: Optional[str], require_exists: bool) -> Path:
    if task_id:
        task = task_from_id(state, task_id)
        path = root / task["retrospective_path"]
    elif file_path:
        path = root / file_path if not os.path.isabs(file_path) else Path(file_path)
    else:
        fail("check-retrospective requires --task or --file")
    if not path.exists():
        if require_exists:
            fail(f"retrospective file does not exist: {path}")
        return path
    lines = require_headings(path, RETRO_HEADINGS, f"retrospective file {path.name}")
    task_id_values = [line.strip() for line in lines if line.strip().startswith("- ")]
    if task_id and f"- {task_id}" not in task_id_values:
        fail(f"retrospective file {path.name} does not contain task id '{task_id}'")
    return path


def validate_feedback(root: Path, state: Dict[str, Any]) -> None:
    for task in state["registry"].get("tasks", []):
        task_id = task["task_id"]
        status = task["status"]
        if status in {"review", "done"}:
            check_feedback(root, state, task_id=task_id, file_path=None, require_exists=True)
        else:
            check_feedback(root, state, task_id=task_id, file_path=None, require_exists=False)


def validate_retrospectives(root: Path, state: Dict[str, Any]) -> None:
    for task in state["registry"].get("tasks", []):
        task_id = task["task_id"]
        status = task["status"]
        accepted = bool(task["accepted_by_main_brain"])
        if status == "done" or accepted:
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=True)
        else:
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=False)


def render_queue_board(root: Path, state: Dict[str, Any]) -> str:
    tasks = task_map(state)
    queue = queue_items(state)
    lines = [
        "# Main-Brain Queue",
        "",
        "- Source of truth: `project/runtime/task_registry.yaml` and `project/runtime/work_queue.yaml`.",
        "- Update task ownership via `scripts/claim_task.sh` and `scripts/close_task.sh`.",
        "",
        "## Active Tasks",
    ]
    if not queue:
        lines.append("- none")
    else:
        for item in queue:
            lines.append(
                f"- `{item['task_id']}` | role=`{item['role']}` | owner=`{item['owner']}` | locked={', '.join(item['locked_paths'])}"
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
    board.write_text(render_queue_board(root, state), encoding="utf-8")


def collect_acceptance_artifacts(root: Path, role_config: Dict[str, Any], task: Optional[Dict[str, Any]]) -> List[str]:
    refs = list(role_config["default_acceptance_artifacts"])
    if task is not None:
        refs.extend(task.get("output_refs", []))
    resolved: List[str] = []
    for ref in refs:
        if isinstance(ref, str) and "#" in ref:
            resolved_value = resolve_config_ref(root, ref)
            if resolved_value:
                resolved.append(resolved_value)
        elif ref:
            resolved.append(ref)
    unique: List[str] = []
    for item in resolved:
        if item not in unique:
            unique.append(item)
    return unique


def choose_cwd(root: Path, role_name: str, task: Optional[Dict[str, Any]]) -> Path:
    if role_name in {"paper_brain", "layout_worker", "citation_worker"}:
        return root / "project/paper"
    if task and any(path_matches("project/paper", path) for path in task.get("allowed_paths", [])):
        return root / "project/paper"
    return root


def make_task_packet(root: Path, state: Dict[str, Any], role_name: str, task_id: Optional[str]) -> str:
    roles = role_map(state)
    if role_name not in roles:
        fail(f"unknown role: {role_name}")
    task: Optional[Dict[str, Any]] = None
    if task_id:
        task = task_from_id(state, task_id)
        if task["role"] != role_name:
            fail(f"task {task_id} is registered for role {task['role']}, not {role_name}")

    role = roles[role_name]
    env = parse_kv_env(root / ".env")
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")
    cwd = choose_cwd(root, role_name, task)
    agent_file = "project/paper/AGENTS.md" if cwd == root / "project/paper" else "AGENTS.md"
    must_read = role["must_read_docs"]
    if task:
        for item in task["input_refs"]:
            if item not in must_read:
                must_read.append(item)
    acceptance = collect_acceptance_artifacts(root, role, task)

    lines = [
        f"你现在在 `{cwd}` 工作。",
        "",
        "角色：",
        f"- {role_name}",
    ]
    if task:
        lines.extend(["", "任务：", f"- `{task['task_id']}`: {task['title']}", f"- status: `{task['status']}`", f"- owner: `{task['owner'] or 'unassigned'}`"])
    lines.extend(
        [
            "",
            "本轮唯一目标：",
            "- [在这里填写唯一任务]",
            "",
            "本轮不是：",
            "- 不要越出 task registry 和 role matrix 规定的 scope",
            "- 不要覆盖其他角色正在占用的文件",
            "- 不要把静态规则写回 `MEMORY.md`",
            "",
            "允许修改的文件范围：",
        ]
    )
    for path in (task["allowed_paths"] if task else role["write_roots"]):
        lines.append(f"- `{path}`")
    lines.extend(["", "禁止修改的路径："])
    for path in (task["forbidden_paths"] if task else role["forbidden_roots"]):
        lines.append(f"- `{path}`")
    lines.extend(["", "必须按顺序读取："])
    for idx, doc in enumerate(must_read, start=1):
        lines.append(f"{idx}. `{doc}`")
    lines.extend(["", "当前容器：", f"- `{env.get('CONTAINER_NAME', '')}`"])
    if role_name == "code_brain":
        lines.extend(
            [
                "",
                "代码侧输出约束：",
                "- 输出图表到 `project/figures/`",
                "- 输出 CSV / 中间结果到 `project/output/`",
                "- handoff 使用 `project/output/handoff/HANDOFF_TEMPLATE.md`",
                "- 只允许后续角色消费已被 `MEMORY.md -> ## Handoff Index` 索引的 handoff",
            ]
        )
    if role_name in {"paper_brain", "layout_worker", "citation_worker", "review_worker"} or (task and any(path_matches("project/paper", path) for path in task["allowed_paths"])):
        lines.extend(
            [
                "",
                "paper 运行事实：",
                "- active paper entrypoint 以 `project/paper/runtime/paper.env` 为准",
                f"- 当前 entrypoint: `{paper_env.get('PAPER_ACTIVE_ENTRYPOINT', '')}`",
                f"- 当前 acceptance PDF: `{paper_env.get('PAPER_ACCEPT_PDF', '')}`",
                f"- 当前 acceptance LOG: `{paper_env.get('PAPER_ACCEPT_LOG', '')}`",
            ]
        )
    lines.extend(["", "验收产物："])
    for item in acceptance:
        lines.append(f"- `{item}`")
    lines.extend(
        [
            "",
            "开始前：",
            "- `bash scripts/validate_agent_docs.sh`",
        ]
    )
    if task:
        lines.extend(
            [
                "",
                "流程 gate：",
                f"- 完成后补 `feedback`: `{task['feedback_path']}`",
                f"- 若要 closed as done，再补 `retrospective`: `{task['retrospective_path']}`",
                f"- 反馈检查：`bash scripts/check_worker_feedback.sh --task {task['task_id']}`",
                f"- 复盘检查：`bash scripts/check_retrospective.sh --task {task['task_id']}`",
            ]
        )
    lines.extend(
        [
            "",
            "最终回复格式：",
            "1. 改了哪些文件",
            "2. 做了什么",
            "3. 哪些结论是已验证的",
            "4. 验证 / 编译 / 验收结果",
            "5. 剩余风险",
            "6. 本轮踩坑点",
            "7. 下次主脑最该提前告诉你的信息",
        ]
    )
    return "\n".join(lines) + "\n"


def find_active_queue_item(state: Dict[str, Any], task_id: str) -> Optional[Dict[str, Any]]:
    for item in queue_items(state):
        if item["task_id"] == task_id:
            return item
    return None


def claim_task(root: Path, state: Dict[str, Any], task_id: str, owner: str, locks: Sequence[str]) -> None:
    task = task_from_id(state, task_id)
    roles = role_map(state)
    role = roles[task["role"]]
    if task["status"] == "done":
        fail(f"task {task_id} is already done")
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
    state["queue"].setdefault("history", []).append(
        {
            "action": "claim",
            "task_id": task_id,
            "owner": owner,
            "locked_paths": locked_paths,
        }
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)


def close_task(root: Path, state: Dict[str, Any], task_id: str, next_status: str, accepted_by: str) -> None:
    if next_status not in {"review", "done"}:
        fail("--to must be review or done")
    task = task_from_id(state, task_id)
    active = find_active_queue_item(state, task_id)
    if not active:
        fail(f"task {task_id} is not currently claimed")
    check_feedback(root, state, task_id=task_id, file_path=None, require_exists=True)
    if next_status == "done":
        check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=True)
        if not accepted_by:
            fail("--accepted-by is required when closing a task as done")
        task["accepted_by_main_brain"] = True
    else:
        task["accepted_by_main_brain"] = False
    task["status"] = next_status
    state["queue"]["active_items"] = [item for item in queue_items(state) if item["task_id"] != task_id]
    state["queue"].setdefault("history", []).append(
        {
            "action": "close",
            "task_id": task_id,
            "status": next_status,
            "accepted_by": accepted_by,
        }
    )
    save_structured(state["registry_path"], state["registry"])
    save_structured(state["queue_path"], state["queue"])
    write_queue_board(root, state)


def run_validate(root: Path, mode: str) -> None:
    root_kind = detect_root_kind(root)
    if root_kind == "template_source":
        if mode != "template_source":
            fail(
                "template-source repo detected; instance validation modes expect rendered files under project/. "
                "Run `bash scripts/validate_agent_docs.sh --template-source-only`, or render a target via "
                "`bash scripts/setup.sh demo --render-only --target <dir>` and validate that directory."
            )
        validate_template_source(root)
        print("[validate_agent_docs] OK (template-source)")
        return

    state = load_runtime_state(root)
    if mode in {"all", "memory"}:
        validate_memory(root)
    if mode in {"all", "handoff"}:
        validate_handoffs(root)
    if mode in {"all", "contracts"}:
        validate_contracts(root)
    if mode in {"all", "paper"}:
        validate_paper_config(root)
    if mode in {"all", "roles"}:
        validate_roles(root, state)
    if mode in {"all", "tasks"}:
        validate_tasks(root, state)
    if mode in {"all", "queue"}:
        validate_queue(root, state)
    if mode in {"all", "feedback"}:
        validate_feedback(root, state)
    if mode in {"all", "retrospective"}:
        validate_retrospectives(root, state)
    print("[validate_agent_docs] OK")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--root", required=True)
    validate.add_argument(
        "--mode",
        default="all",
        choices=[
            "all",
            "memory",
            "handoff",
            "contracts",
            "paper",
            "roles",
            "tasks",
            "queue",
            "feedback",
            "retrospective",
            "template_source",
        ],
    )

    root_kind = subparsers.add_parser("root-kind")
    root_kind.add_argument("--root", required=True)

    packet = subparsers.add_parser("task-packet")
    packet.add_argument("--root", required=True)
    packet.add_argument("--role")
    packet.add_argument("--task")

    claim = subparsers.add_parser("claim-task")
    claim.add_argument("--root", required=True)
    claim.add_argument("--task", required=True)
    claim.add_argument("--owner", required=True)
    claim.add_argument("--lock", action="append", default=[])

    close = subparsers.add_parser("close-task")
    close.add_argument("--root", required=True)
    close.add_argument("--task", required=True)
    close.add_argument("--to", required=True)
    close.add_argument("--accepted-by", default="")

    check_feedback_parser = subparsers.add_parser("check-feedback")
    check_feedback_parser.add_argument("--root", required=True)
    check_feedback_parser.add_argument("--task")
    check_feedback_parser.add_argument("--file")

    check_retro_parser = subparsers.add_parser("check-retrospective")
    check_retro_parser.add_argument("--root", required=True)
    check_retro_parser.add_argument("--task")
    check_retro_parser.add_argument("--file")

    render_queue = subparsers.add_parser("render-queue")
    render_queue.add_argument("--root", required=True)
    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve() if hasattr(args, "root") else None

    if args.command == "validate":
        run_validate(root, args.mode)
        return 0

    if args.command == "root-kind":
        print(detect_root_kind(root))
        return 0

    state = load_runtime_state(root)

    if args.command == "task-packet":
        role_name = args.role
        if args.task:
            task = task_from_id(state, args.task)
            if role_name and role_name != task["role"]:
                fail(f"task {args.task} belongs to role {task['role']}, not {role_name}")
            role_name = task["role"]
        if not role_name:
            fail("task-packet requires --role or --task")
        sys.stdout.write(make_task_packet(root, state, role_name, args.task))
        return 0

    if args.command == "claim-task":
        claim_task(root, state, args.task, args.owner, args.lock)
        print(f"[workflow] claimed task {args.task}")
        return 0

    if args.command == "close-task":
        close_task(root, state, args.task, args.to, args.accepted_by)
        print(f"[workflow] closed task {args.task} -> {args.to}")
        return 0

    if args.command == "check-feedback":
        check_feedback(root, state, task_id=args.task, file_path=args.file, require_exists=True)
        print("[workflow] worker feedback OK")
        return 0

    if args.command == "check-retrospective":
        check_retrospective(root, state, task_id=args.task, file_path=args.file, require_exists=True)
        print("[workflow] retrospective OK")
        return 0

    if args.command == "render-queue":
        write_queue_board(root, state)
        print("[workflow] queue board refreshed")
        return 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
