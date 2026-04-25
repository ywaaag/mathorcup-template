from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Dict, Sequence

from workflow_kernel.audit_index import check_feedback, check_retrospective
from workflow_kernel.packet import make_task_packet
from workflow_kernel.schema import (
    INSTANCE_CODEX_SKILLS,
    REQUIRED_ROLE_FIELDS,
    REQUIRED_TASK_FIELDS,
    ROOT_CODEX_SKILLS,
    TASK_STATUSES,
    any_path_matches,
    check_required_paths,
    detect_root_kind,
    ensure_fields,
    fail,
    load_runtime_state,
    parse_kv_env,
    path_matches,
    paths_overlap,
    queue_items,
    role_map,
    task_from_id,
    task_map,
    validate_template_source,
)


def validate_requirements_toml(path: Path, *, context: str) -> None:
    if not path.is_file():
        fail(f"missing file: {path}")
    try:
        payload = parse_simple_toml(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        fail(f"{context} is not valid TOML: {exc}")
    if not isinstance(payload, dict):
        fail(f"{context} must parse to a TOML table")
    for key in ["schema_version", "bridge_mode", "bridge_kind", "non_authoritative"]:
        if key not in payload:
            fail(f"{context} missing top-level key: {key}")


def parse_simple_toml(text: str) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    current = result
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        raw = lines[index]
        line = raw.strip()
        index += 1
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            if not section:
                raise ValueError("empty table header")
            result.setdefault(section, {})
            current = result[section]
            continue
        if "=" not in line:
            raise ValueError(f"invalid assignment line: {raw}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"missing key in line: {raw}")
        if value == "[" or (value.startswith("[") and not value.endswith("]")):
            collected = [value]
            while index < len(lines):
                fragment_raw = lines[index]
                fragment = fragment_raw.strip()
                index += 1
                if not fragment or fragment.startswith("#"):
                    continue
                collected.append(fragment)
                if fragment.endswith("]"):
                    break
            value = " ".join(collected)
        current[key] = parse_simple_toml_value(value)
    return result


def parse_simple_toml_value(raw: str) -> Any:
    value = raw.strip()
    if value in {"true", "false"}:
        return value == "true"
    if re.fullmatch(r"[0-9]+", value):
        return int(value)
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        items = re.findall(r'"([^"]*)"', inner)
        if not items and inner:
            raise ValueError(f"unsupported array value: {raw}")
        return items
    raise ValueError(f"unsupported TOML value: {raw}")


def validate_skill_dir(path: Path, *, context: str) -> None:
    skill_md = path / "SKILL.md"
    openai_yaml = path / "agents/openai.yaml"
    if not skill_md.is_file():
        fail(f"{context} missing SKILL.md")
    if not openai_yaml.is_file():
        fail(f"{context} missing agents/openai.yaml")
    content = skill_md.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    if not match:
        fail(f"{context} has invalid SKILL.md frontmatter")
    frontmatter = match.group(1)
    if "name:" not in frontmatter or "description:" not in frontmatter:
        fail(f"{context} SKILL.md frontmatter must include name and description")


def validate_skill_collection(skills_root: Path, *, context: str, required_names: set[str]) -> None:
    if not skills_root.is_dir():
        fail(f"missing directory: {skills_root}")
    seen = {item.name for item in skills_root.iterdir() if item.is_dir()}
    missing = sorted(required_names - seen)
    if missing:
        fail(f"{context} missing skill directories: {', '.join(missing)}")
    for name in sorted(required_names):
        validate_skill_dir(skills_root / name, context=f"{context}/{name}")


def validate_optional_hooks_json(path: Path, *, context: str) -> None:
    if not path.exists():
        return
    payload = load_structured(path)
    if not isinstance(payload, dict):
        fail(f"{context} must contain a JSON object")


def validate_codex_bridge(root: Path, *, template_source: bool) -> None:
    if template_source:
        validate_requirements_toml(root / ".codex/requirements.toml", context=".codex/requirements.toml")
        validate_skill_collection(root / ".codex/skills", context=".codex/skills", required_names=ROOT_CODEX_SKILLS)
        validate_optional_hooks_json(root / ".codex/hooks.json", context=".codex/hooks.json")
        validate_requirements_toml(root / "scaffold/.codex/requirements.toml.template", context="scaffold/.codex/requirements.toml.template")
        validate_skill_collection(root / "scaffold/.codex/skills", context="scaffold/.codex/skills", required_names=INSTANCE_CODEX_SKILLS)
        validate_optional_hooks_json(root / "scaffold/.codex/hooks.json.template", context="scaffold/.codex/hooks.json.template")
        return

    validate_requirements_toml(root / ".codex/requirements.toml", context=".codex/requirements.toml")
    validate_skill_collection(root / ".codex/skills", context=".codex/skills", required_names=INSTANCE_CODEX_SKILLS)
    validate_optional_hooks_json(root / ".codex/hooks.json", context=".codex/hooks.json")


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
        "project/spec/callback_hooks.json",
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
    prompt_library = (root / "project/workflow/prompt_template_library.md").read_text(encoding="utf-8")
    task_packet_template = (root / "project/workflow/TASK_PACKET_TEMPLATE.md").read_text(encoding="utf-8")
    if "project/paper/runtime/paper.env" not in runtime_contract or ".env" not in runtime_contract:
        fail("runtime_contract.md must reference .env and project/paper/runtime/paper.env as config truth sources")
    if "project/spec/runtime_contract.md" not in root_agents or "project/spec/multi_agent_workflow_contract.md" not in root_agents:
        fail("AGENTS.md must route to runtime/workflow docs")
    if "spec/paper_runtime_contract.md" not in paper_agents:
        fail("project/paper/AGENTS.md must route to paper runtime contract")
    if "project/output/review/WORKER_FEEDBACK_TEMPLATE.md" not in workflow_contract:
        fail("workflow contract must reference worker feedback template")
    if "project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md" not in workflow_contract:
        fail("workflow contract must reference retrospective template")
    if "project/runtime/event_log.jsonl" not in workflow_contract or "project/spec/callback_hooks.json" not in workflow_contract:
        fail("workflow contract must reference event_log.jsonl and callback_hooks.json")
    if "scripts/process_callbacks.sh" not in workflow_contract or "scripts/run_exec_batch.sh" not in workflow_contract:
        fail("workflow contract must reference process_callbacks.sh and run_exec_batch.sh")
    if "adjudicate_task.sh" not in workflow_contract or "show_task.sh" not in workflow_contract:
        fail("workflow contract must reference adjudicate_task.sh and show_task.sh")
    if "codex exec" not in workflow_contract or "scripts/run_exec_worker.sh" not in workflow_contract:
        fail("workflow contract must describe codex exec worker mode via scripts/run_exec_worker.sh")
    if "codex exec" not in prompt_library or "scripts/run_exec_worker.sh" not in prompt_library:
        fail("prompt_template_library.md must reference codex exec and scripts/run_exec_worker.sh")
    if "process_callbacks.sh" not in prompt_library or "event_log.jsonl" not in prompt_library:
        fail("prompt_template_library.md must reference process_callbacks.sh and event_log.jsonl")
    if "adjudicate_task.sh" not in prompt_library or "main_brain_summary.sh" not in prompt_library:
        fail("prompt_template_library.md must reference adjudicate_task.sh and main_brain_summary.sh")
    if "feedback path" not in task_packet_template or "close_task.sh" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must describe feedback path and close_task.sh gate")
    if "event_log.jsonl" not in task_packet_template or "callback_hooks.json" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must reference event_log.jsonl and callback_hooks.json")


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
        fail("project/spec/agent_roles.json must define a top-level 'roles' object")
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
        fail(f"agent_roles.json missing roles: {', '.join(missing_roles)}")
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
        fail("project/runtime/task_registry.json must define a top-level 'tasks' array")
    roles = role_map(state)
    seen: set[str] = set()
    for task in tasks:
        ensure_fields(task, REQUIRED_TASK_FIELDS, f"task {task.get('task_id', '<unknown>')}")
        task_id = task["task_id"]
        if task_id in seen:
            fail(f"duplicate task_id in task_registry.json: {task_id}")
        seen.add(task_id)
        if task["role"] not in roles:
            fail(f"task {task_id} references unknown role: {task['role']}")
        if task["status"] not in TASK_STATUSES:
            fail(f"task {task_id} has invalid status: {task['status']}")
        if task["status"] == "in_progress":
            if not task["owner"]:
                fail(f"task {task_id} must keep owner set while status is in_progress")
        elif task["owner"]:
            fail(f"task {task_id} must clear owner when status is not in_progress")
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
        fail("project/runtime/work_queue.json must define top-level 'active_items'")
    if not isinstance(queue_payload["active_items"], list):
        fail("work_queue.json field 'active_items' must be a list")
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
            fail(f"task {task_id} must also be in_progress in task_registry.json")
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
                fail(f"active task conflict between {left['task_id']} and {right['task_id']}")


def validate_feedback(root: Path, state: Dict[str, Any]) -> None:
    for task in state["registry"].get("tasks", []):
        task_id = task["task_id"]
        status = task["status"]
        if status in {"review", "done"}:
            check_feedback(root, state, task_id=task_id, file_path=None, require_exists=True, require_content=True)
        else:
            check_feedback(root, state, task_id=task_id, file_path=None, require_exists=False, require_content=False)


def validate_retrospectives(root: Path, state: Dict[str, Any]) -> None:
    for task in state["registry"].get("tasks", []):
        task_id = task["task_id"]
        status = task["status"]
        accepted = bool(task["accepted_by_main_brain"])
        if status == "done" or accepted:
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=True, require_content=True)
        else:
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=False, require_content=False)
