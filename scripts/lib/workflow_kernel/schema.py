from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence


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

ROOT_CODEX_SKILLS = {
    "template-source-maintenance",
    "render-and-smoke",
}

INSTANCE_CODEX_SKILLS = {
    "main-brain-dispatch",
    "worker-feedback",
    "task-audit-adjudication",
    "instance-runtime-read",
}

TEMPLATE_SOURCE_REQUIRED_FILES = [
    "scaffold/AGENTS.md.template",
    "scaffold/MEMORY.md.template",
    "scaffold/project/paper/AGENTS.md.template",
    "scaffold/project/spec/runtime_contract.md.template",
    "scaffold/project/spec/multi_agent_workflow_contract.md.template",
    "scaffold/project/spec/agent_roles.json.template",
    "scaffold/project/spec/callback_hooks.json.template",
    "scaffold/project/runtime/task_registry.json.template",
    "scaffold/project/runtime/work_queue.json.template",
    "scaffold/project/runtime/event_log.jsonl.template",
    "scaffold/project/paper/spec/paper_runtime_contract.md.template",
    "scaffold/project/paper/runtime/paper.env.template",
    "scripts/setup.sh",
    "scripts/render_templates.sh",
    "scripts/validate_agent_docs.sh",
    "scripts/doctor.sh",
    "scripts/list_open_tasks.sh",
    "scripts/dispatch_task.sh",
    "scripts/submit_feedback.sh",
    "scripts/reopen_task.sh",
    "scripts/cancel_task.sh",
    "scripts/exec_healthcheck.sh",
    "scripts/run_exec_worker.sh",
    "scripts/process_callbacks.sh",
    "scripts/run_exec_batch.sh",
    "scripts/show_task.sh",
    "scripts/list_history.sh",
    "scripts/adjudicate_task.sh",
    "scripts/main_brain_summary.sh",
    "scripts/export_reference_image.sh",
    "scripts/lib/workflow_audit.py",
    ".codex/requirements.toml",
    ".codex/skills/template-source-maintenance/SKILL.md",
    ".codex/skills/template-source-maintenance/agents/openai.yaml",
    ".codex/skills/render-and-smoke/SKILL.md",
    ".codex/skills/render-and-smoke/agents/openai.yaml",
    "scaffold/.codex/requirements.toml.template",
    "scaffold/.codex/skills/main-brain-dispatch/SKILL.md",
    "scaffold/.codex/skills/main-brain-dispatch/agents/openai.yaml",
    "scaffold/.codex/skills/worker-feedback/SKILL.md",
    "scaffold/.codex/skills/worker-feedback/agents/openai.yaml",
    "scaffold/.codex/skills/task-audit-adjudication/SKILL.md",
    "scaffold/.codex/skills/task-audit-adjudication/agents/openai.yaml",
    "scaffold/.codex/skills/instance-runtime-read/SKILL.md",
    "scaffold/.codex/skills/instance-runtime-read/agents/openai.yaml",
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
        fail(f"invalid JSON in {path}: {exc}")


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
    scaffold_roles = root / "scaffold/project/spec/agent_roles.json.template"
    scaffold_registry = root / "scaffold/project/runtime/task_registry.json.template"
    scaffold_queue = root / "scaffold/project/runtime/work_queue.json.template"
    live_roles = root / "project/spec/agent_roles.json"
    live_registry = root / "project/runtime/task_registry.json"
    live_queue = root / "project/runtime/work_queue.json"
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
    roles_path = root / "project/spec/agent_roles.json"
    registry_path = root / "project/runtime/task_registry.json"
    queue_path = root / "project/runtime/work_queue.json"
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


def task_from_id(state: Dict[str, Any], task_id: str) -> Dict[str, Any]:
    tasks = task_map(state)
    if task_id not in tasks:
        fail(f"unknown task_id: {task_id}")
    return tasks[task_id]
