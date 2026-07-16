from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Dict, Sequence

from workflow_kernel.audit_index import check_feedback, check_handoff, check_retrospective
from workflow_kernel.packet import make_task_packet
from workflow_kernel.schema import (
    INSTANCE_CODEX_SKILLS,
    REQUIRED_ROLE_FIELDS,
    REQUIRED_TASK_FIELDS,
    RETROSPECTIVE_POLICIES,
    ROOT_CODEX_SKILLS,
    TASK_STATUSES,
    TASK_CONTRACT_FIELDS,
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
    retrospective_policy,
    retrospective_required,
    task_from_id,
    task_map,
    validate_template_source,
)


PHASE6_CLOSE_GATE_COMMANDS = [
    "bash scripts/check_handoff_intake.sh --target <dir>",
    "bash scripts/check_worker_feedback.sh --task <task_id> --target <dir>",
    "bash scripts/check_retrospective.sh --task <task_id> --target <dir>",
    "bash scripts/close_task.sh --task <task_id> --to review|done --target <dir>",
]

QUERY_SCHEMA_CONTRACT_SURFACES = {
    "doctor.v1": {
        "cli": "bash scripts/doctor.sh --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": [
            "runtime_config",
            "tooling",
            "event_harness",
            "codex_native_bridge",
            "validation",
            "container_state",
            "container_tool_baseline",
            "warnings",
        ],
    },
    "state_consistency.v1": {
        "cli": "bash scripts/check_state_consistency.sh --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": ["findings", "summary"],
    },
    "main_brain_summary.v1": {
        "cli": "bash scripts/main_brain_summary.sh --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": ["sections", "commands"],
    },
    "show_task.v1": {
        "cli": "bash scripts/show_task.sh --task <task_id> --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": [
            "task",
            "role",
            "task_status",
            "owner",
            "allowed_paths",
            "forbidden_paths",
            "queue",
            "feedback",
            "retrospective",
            "acceptance_artifacts",
            "recent_events",
            "recommended_commands",
        ],
    },
    "task_history.v1": {
        "cli": "bash scripts/list_history.sh --task <task_id> --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": [
            "task",
            "filters",
            "events",
            "queue_history",
            "callback_artifacts",
            "exec_artifacts",
            "adjudication_artifacts",
        ],
    },
    "task_adjudication.v1": {
        "cli": "bash scripts/adjudicate_task.sh --task <task_id> --target <dir> --json",
        "read_only": "`read_only`: `false`",
        "keys": [
            "task",
            "mode",
            "decision",
            "note",
            "inputs_considered",
            "agreements",
            "disagreements",
            "missing_evidence",
            "additional_evidence",
            "recommended_next_step",
            "artifact_written",
        ],
    },
    "recommend_tasks.v1": {
        "cli": "bash scripts/recommend_tasks.sh --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": [
            "owner_prefix",
            "safe_to_dispatch",
            "blocked",
            "active_conflicts",
            "suggested_commands",
        ],
    },
    "handoff_intake.v1": {
        "cli": "bash scripts/check_handoff_intake.sh --target <dir> --json",
        "read_only": "`read_only`: `true`",
        "keys": ["indexed_latest", "indexed_files", "warnings"],
    },
}

QUERY_SCHEMA_COMMON_KEYS = ["schema_version", "generated_at", "root", "root_kind", "read_only", "ok", "status"]

QUERY_SCHEMA_GLOBAL_RULES = [
    "Default text output remains the human / Agent compatibility path.",
    "`--json` and `--format json` must print parseable JSON to stdout.",
    "JSON stdout must not include stderr warnings",
    "Container absence in `doctor.v1` is `WARN`, not workflow logic failure",
    "`check_handoff_intake.sh --latest` stdout prints only the latest indexed path.",
    "`check_handoff_intake.sh --files` stdout prints only indexed paths",
    "`check_handoff_intake.sh --latest --json`, `--latest --format json`, `--files --json`, and `--files --format json` must be rejected with exit 2 and empty stdout.",
    "`adjudicate_task.sh --json` and `adjudicate_task.sh --format json` are not read-only.",
    "`artifact_written`",
]


def require_text_contains(text: str, needles: Sequence[str], context: str) -> None:
    missing = [needle for needle in needles if needle not in text]
    if missing:
        fail(f"{context} missing required Phase 6 close/review gate text: {', '.join(missing)}")


def require_payload_keys(payload: Dict[str, Any], keys: Sequence[str], context: str) -> None:
    missing = [key for key in keys if key not in payload]
    if missing:
        fail(f"{context} missing structured output keys: {', '.join(missing)}")


def require_payload_value(payload: Dict[str, Any], key: str, expected: Any, context: str) -> None:
    if payload.get(key) != expected:
        fail(f"{context} expected {key}={expected!r}, got {payload.get(key)!r}")


def validate_query_schema_contract(path: Path) -> None:
    if not path.is_file():
        fail(f"missing file: {path.relative_to(path.parents[2]) if len(path.parents) > 2 else path}")
    text = path.read_text(encoding="utf-8")
    require_text_contains(text, QUERY_SCHEMA_GLOBAL_RULES, "query_schema_contract.md")
    for schema_version, contract in QUERY_SCHEMA_CONTRACT_SURFACES.items():
        required = [
            f"### {schema_version}",
            contract["cli"],
            contract["read_only"],
            f"`schema_version`: `{schema_version}`",
            "Required top-level keys:",
            "Status / ok semantics:",
            "Side effects / writes:",
        ]
        required.extend(f"`{key}`" for key in QUERY_SCHEMA_COMMON_KEYS)
        required.extend(f"`{key}`" for key in contract["keys"])
        require_text_contains(text, required, f"query_schema_contract.md surface {schema_version}")


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
        validate_query_schema_contract(root / "scaffold/project/spec/query_schema_contract.md.template")
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
    for path in sorted(handoff_dir.glob("*.md")):
        if path.name == "HANDOFF_TEMPLATE.md":
            continue
        check_handoff(root, path.as_posix(), require_content=False)


def validate_contracts(root: Path) -> None:
    required = [
        "AGENTS.md",
        "README.md",
        "project/paper/AGENTS.md",
        "project/paper/cumcmthesis.cls",
        "project/paper/metadata.tex",
        "project/paper/main.tex",
        "project/spec/runtime_contract.md",
        "project/spec/multi_agent_workflow_contract.md",
        "project/spec/query_schema_contract.md",
        "project/spec/callback_hooks.json",
        "project/workflow/prompt_template_library.md",
        "project/workflow/TASK_PACKET_TEMPLATE.md",
        "project/workflow/MAIN_BRAIN_ACCEPTANCE_TEMPLATE.md",
        "project/output/MODEL_MANIFEST_TEMPLATE.json",
        "project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md",
        "project/output/review/WORKER_FEEDBACK_TEMPLATE.md",
        "project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md",
        "project/paper/spec/paper_runtime_contract.md",
    ]
    for ref in required:
        if not (root / ref).is_file():
            fail(f"missing file: {ref}")
    runtime_env = parse_kv_env(root / ".env")
    if runtime_env:
        for key in ("JUPYTER_PORT", "RSTUDIO_PORT"):
            try:
                port = int(runtime_env.get(key, ""))
            except ValueError:
                fail(f".env#{key} must be an integer TCP port")
            if not 1 <= port <= 65535:
                fail(f".env#{key} must be between 1 and 65535")
        if runtime_env["JUPYTER_PORT"] == runtime_env["RSTUDIO_PORT"]:
            fail(".env JUPYTER_PORT and RSTUDIO_PORT must be different")
        for key in ("JUPYTER_PORT_MODE", "RSTUDIO_PORT_MODE"):
            if key in runtime_env and runtime_env[key] not in {"auto", "fixed"}:
                fail(f".env#{key} must be auto or fixed")
        if "INSTANCE_ID" in runtime_env and not re.fullmatch(r"[0-9a-f]{8}", runtime_env["INSTANCE_ID"]):
            fail(".env#INSTANCE_ID must be an 8-character lowercase hexadecimal ID")
    runtime_contract = (root / "project/spec/runtime_contract.md").read_text(encoding="utf-8")
    paper_agents = (root / "project/paper/AGENTS.md").read_text(encoding="utf-8")
    root_agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    workflow_contract = (root / "project/spec/multi_agent_workflow_contract.md").read_text(encoding="utf-8")
    query_schema_contract_path = root / "project/spec/query_schema_contract.md"
    prompt_library = (root / "project/workflow/prompt_template_library.md").read_text(encoding="utf-8")
    task_packet_template = (root / "project/workflow/TASK_PACKET_TEMPLATE.md").read_text(encoding="utf-8")
    acceptance_template = (root / "project/workflow/MAIN_BRAIN_ACCEPTANCE_TEMPLATE.md").read_text(encoding="utf-8")
    paper_runtime_contract = (root / "project/paper/spec/paper_runtime_contract.md").read_text(encoding="utf-8")
    paper_main = (root / "project/paper/main.tex").read_text(encoding="utf-8")
    validate_query_schema_contract(query_schema_contract_path)
    if "cumcmthesis" not in paper_main or "metadata.tex" not in paper_main:
        fail("project/paper/main.tex must use cumcmthesis and load metadata.tex")
    if "project/paper/runtime/paper.env" not in runtime_contract or ".env" not in runtime_contract:
        fail("runtime_contract.md must reference .env and project/paper/runtime/paper.env as config truth sources")
    if "project/spec/runtime_contract.md" not in root_agents or "project/spec/multi_agent_workflow_contract.md" not in root_agents:
        fail("AGENTS.md must route to runtime/workflow docs")
    if "check_handoff_intake.sh" not in root_agents:
        fail("AGENTS.md must mention scripts/check_handoff_intake.sh for indexed handoff intake")
    if "spec/paper_runtime_contract.md" not in paper_agents:
        fail("project/paper/AGENTS.md must route to paper runtime contract")
    if "check_handoff_intake.sh" not in paper_agents:
        fail("project/paper/AGENTS.md must mention scripts/check_handoff_intake.sh for indexed handoff intake")
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
    if "check_handoff_intake.sh" not in workflow_contract:
        fail("workflow contract must reference scripts/check_handoff_intake.sh")
    if "paper_acceptance_check.sh" not in workflow_contract:
        fail("workflow contract must reference scripts/paper_acceptance_check.sh")
    if "artifact_index.sh" not in workflow_contract:
        fail("workflow contract must reference scripts/artifact_index.sh")
    if "model_manifest.json" not in workflow_contract:
        fail("workflow contract must reference project/output/model_manifest.json")
    if "codex exec" not in prompt_library or "scripts/run_exec_worker.sh" not in prompt_library:
        fail("prompt_template_library.md must reference codex exec and scripts/run_exec_worker.sh")
    if "paper_acceptance_check.sh" not in prompt_library:
        fail("prompt_template_library.md must reference scripts/paper_acceptance_check.sh")
    if "model_manifest.json" not in prompt_library:
        fail("prompt_template_library.md must reference project/output/model_manifest.json")
    if "check_handoff_intake.sh" not in prompt_library:
        fail("prompt_template_library.md must reference scripts/check_handoff_intake.sh")
    if "process_callbacks.sh" not in prompt_library or "event_log.jsonl" not in prompt_library:
        fail("prompt_template_library.md must reference process_callbacks.sh and event_log.jsonl")
    if "adjudicate_task.sh" not in prompt_library or "main_brain_summary.sh" not in prompt_library:
        fail("prompt_template_library.md must reference adjudicate_task.sh and main_brain_summary.sh")
    if "feedback path" not in task_packet_template or "close_task.sh" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must describe feedback path and close_task.sh gate")
    if "model_manifest.json" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must reference project/output/model_manifest.json")
    if "paper_acceptance_check.sh" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must reference scripts/paper_acceptance_check.sh")
    if "check_handoff_intake.sh" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must reference scripts/check_handoff_intake.sh")
    if "event_log.jsonl" not in task_packet_template or "callback_hooks.json" not in task_packet_template:
        fail("TASK_PACKET_TEMPLATE.md must reference event_log.jsonl and callback_hooks.json")
    if "check_handoff_intake.sh" not in runtime_contract:
        fail("runtime_contract.md must reference scripts/check_handoff_intake.sh")
    if "project/spec/query_schema_contract.md" not in runtime_contract:
        fail("runtime_contract.md must reference project/spec/query_schema_contract.md")
    if "project/spec/query_schema_contract.md" not in workflow_contract:
        fail("multi_agent_workflow_contract.md must reference project/spec/query_schema_contract.md")
    if "project/spec/query_schema_contract.md" not in prompt_library:
        fail("prompt_template_library.md must reference project/spec/query_schema_contract.md")
    if "project/spec/query_schema_contract.md" not in acceptance_template:
        fail("MAIN_BRAIN_ACCEPTANCE_TEMPLATE.md must reference project/spec/query_schema_contract.md")
    if "check_handoff_intake.sh" not in paper_runtime_contract:
        fail("paper_runtime_contract.md must reference scripts/check_handoff_intake.sh")
    if "cumcmthesis.cls" not in paper_runtime_contract or "metadata.tex" not in paper_runtime_contract:
        fail("paper_runtime_contract.md must reference cumcmthesis.cls and metadata.tex")
    require_text_contains(
        workflow_contract,
        [
            "check_state_consistency.sh --target <dir> --json",
            "main_brain_summary.sh --target <dir> --json",
            "doctor.sh --target <dir> --json",
            "show_task.sh --task <task_id> --target <dir> --json",
            "list_history.sh --task <task_id> --target <dir> --json",
            "adjudicate_task.sh --task <task_id> --target <dir> --json",
            "recommend_tasks.sh --target <dir> --json",
            "check_handoff_intake.sh --target <dir> --json",
            "schema_version",
            "generated_at",
        ],
        "multi_agent_workflow_contract.md",
    )
    require_text_contains(
        runtime_contract,
        [
            "check_state_consistency.sh --target <dir> --json",
            "main_brain_summary.sh --target <dir> --json",
            "doctor.sh --target <dir> --json",
            "show_task.sh --task <task_id> --target <dir> --json",
            "list_history.sh --task <task_id> --target <dir> --json",
            "adjudicate_task.sh --task <task_id> --target <dir> --json",
            "recommend_tasks.sh --target <dir> --json",
            "check_handoff_intake.sh --target <dir> --json",
        ],
        "runtime_contract.md",
    )
    require_text_contains(
        prompt_library,
        [
            "check_state_consistency.sh --target <dir> --json",
            "main_brain_summary.sh --target <dir> --json",
            "doctor.sh --target <dir> --json",
            "show_task.sh --task <task_id> --target <dir> --json",
            "list_history.sh --task <task_id> --target <dir> --json",
            "adjudicate_task.sh --task <task_id> --target <dir> --json",
            "recommend_tasks.sh --target <dir> --json",
            "check_handoff_intake.sh --target <dir> --json",
        ],
        "prompt_template_library.md",
    )
    require_text_contains(
        acceptance_template,
        PHASE6_CLOSE_GATE_COMMANDS,
        "MAIN_BRAIN_ACCEPTANCE_TEMPLATE.md",
    )
    require_text_contains(
        workflow_contract,
        [
            "check_handoff_intake.sh --target <dir>",
            "check_worker_feedback.sh --task <task_id> --target <dir>",
            "check_retrospective.sh --task <task_id> --target <dir>",
            "close_task.sh --task <task_id> --to review|done --target <dir>",
            "worker must not run close_task.sh",
        ],
        "multi_agent_workflow_contract.md",
    )
    require_text_contains(
        task_packet_template,
        [
            "check_handoff_intake.sh --target <dir>",
            "check_worker_feedback.sh --task <task_id> --target <dir>",
            "check_retrospective.sh --task <task_id> --target <dir>",
            "close_task.sh --task <task_id> --to review --target <dir>",
            "close_task.sh --task <task_id> --to done --accepted-by main_brain --target <dir>",
            "worker must not run close_task.sh",
        ],
        "TASK_PACKET_TEMPLATE.md",
    )
    require_text_contains(
        prompt_library,
        [
            "check_handoff_intake.sh --target <dir>",
            "check_worker_feedback.sh --task <task_id> --target <dir>",
            "check_retrospective.sh --task <task_id> --target <dir>",
            "close_task.sh --task <task_id> --to review|done --target <dir>",
            "不要自行执行 `close_task.sh`",
        ],
        "prompt_template_library.md",
    )
    from workflow_kernel.consistency import state_consistency_payload
    from workflow_kernel.doctor import doctor_payload
    from workflow_kernel.audit_index import handoff_intake_payload
    from workflow_kernel.recommend import recommend_tasks_payload
    from workflow_kernel.summary import main_summary_payload, main_summary_report
    from workflow_audit import adjudication_payload, list_history_payload, show_task_payload

    summary = main_summary_report(root)
    require_text_contains(
        summary,
        [
            "## Review / Done Close Gate",
            "scripts/check_handoff_intake.sh",
            "scripts/check_worker_feedback.sh",
            "scripts/check_retrospective.sh",
            "scripts/close_task.sh",
        ],
        "main_brain_summary.sh output",
    )
    state_payload, _state_status = state_consistency_payload(root)
    require_payload_keys(
        state_payload,
        ["schema_version", "generated_at", "root", "root_kind", "ok", "status", "findings"],
        "check_state_consistency.sh --json output",
    )
    require_payload_value(state_payload, "schema_version", "state_consistency.v1", "check_state_consistency.sh --json output")
    require_payload_value(state_payload, "read_only", True, "check_state_consistency.sh --json output")
    summary_payload = main_summary_payload(root)
    require_payload_keys(
        summary_payload,
        ["schema_version", "generated_at", "root", "root_kind", "ok", "status", "sections", "commands"],
        "main_brain_summary.sh --json output",
    )
    require_payload_value(summary_payload, "schema_version", "main_brain_summary.v1", "main_brain_summary.sh --json output")
    require_payload_value(summary_payload, "read_only", True, "main_brain_summary.sh --json output")
    scripts_dir = root / "scripts"
    doctor = doctor_payload(root, scripts_dir)
    require_payload_keys(
        doctor,
        [
            "schema_version",
            "generated_at",
            "root",
            "root_kind",
            "read_only",
            "runtime_config",
            "tooling",
            "event_harness",
            "codex_native_bridge",
            "validation",
            "container_state",
            "container_tool_baseline",
            "status",
        ],
        "doctor.sh --json output",
    )
    require_payload_value(doctor, "schema_version", "doctor.v1", "doctor.sh --json output")
    require_payload_value(doctor, "read_only", True, "doctor.sh --json output")
    task_from_id(load_runtime_state(root), "TASK_MAIN_SYNC")
    history_payload = list_history_payload(root, "TASK_MAIN_SYNC", latest=20, event_type="", actor="")
    require_payload_keys(
        history_payload,
        [
            "schema_version",
            "generated_at",
            "root",
            "task",
            "filters",
            "events",
            "queue_history",
            "callback_artifacts",
            "exec_artifacts",
            "adjudication_artifacts",
            "read_only",
        ],
        "list_history.sh --json output",
    )
    require_payload_value(history_payload, "schema_version", "task_history.v1", "list_history.sh --json output")
    require_payload_value(history_payload, "read_only", True, "list_history.sh --json output")
    adjudication = adjudication_payload(root, "TASK_MAIN_SYNC", inputs=[], mode="compare", output="", decision="manual", note="")
    require_payload_keys(
        adjudication,
        [
            "schema_version",
            "generated_at",
            "root",
            "task",
            "mode",
            "decision",
            "inputs_considered",
            "agreements",
            "disagreements",
            "missing_evidence",
            "additional_evidence",
            "recommended_next_step",
            "artifact_written",
            "read_only",
        ],
        "adjudicate_task.sh --json output",
    )
    require_payload_value(adjudication, "schema_version", "task_adjudication.v1", "adjudicate_task.sh --json output")
    require_payload_value(adjudication, "read_only", False, "adjudicate_task.sh --json output")
    show_task = show_task_payload(root, "TASK_MAIN_SYNC")
    require_payload_keys(
        show_task,
        [
            "schema_version",
            "generated_at",
            "root",
            "root_kind",
            "task",
            "role",
            "task_status",
            "owner",
            "allowed_paths",
            "forbidden_paths",
            "feedback",
            "retrospective",
            "acceptance_artifacts",
            "recommended_commands",
            "read_only",
            "ok",
            "status",
        ],
        "show_task.sh --json output",
    )
    require_payload_value(show_task, "schema_version", "show_task.v1", "show_task.sh --json output")
    require_payload_value(show_task, "read_only", True, "show_task.sh --json output")
    recommendations = recommend_tasks_payload(root, "recommended", [])
    require_payload_keys(
        recommendations,
        [
            "schema_version",
            "generated_at",
            "root",
            "root_kind",
            "read_only",
            "owner_prefix",
            "safe_to_dispatch",
            "blocked",
            "active_conflicts",
            "suggested_commands",
            "ok",
            "status",
        ],
        "recommend_tasks.sh --json output",
    )
    require_payload_value(recommendations, "schema_version", "recommend_tasks.v1", "recommend_tasks.sh --json output")
    require_payload_value(recommendations, "read_only", True, "recommend_tasks.sh --json output")
    handoff_intake = handoff_intake_payload(root)
    require_payload_keys(
        handoff_intake,
        [
            "schema_version",
            "generated_at",
            "root",
            "root_kind",
            "read_only",
            "indexed_latest",
            "indexed_files",
            "warnings",
            "ok",
            "status",
        ],
        "check_handoff_intake.sh --json output",
    )
    require_payload_value(handoff_intake, "schema_version", "handoff_intake.v1", "check_handoff_intake.sh --json output")
    require_payload_value(handoff_intake, "read_only", True, "check_handoff_intake.sh --json output")


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
        if roles_payload.get("schema_version", 1) >= 2 and "workflow_artifact_roots" not in config:
            fail(f"role {name} missing field 'workflow_artifact_roots' in schema v2")
        for field in ["read_roots", "write_roots", "forbidden_roots", "must_read_docs", "default_acceptance_artifacts", "parallel_safe_with", "parallel_forbidden_with"]:
            if not isinstance(config[field], list):
                fail(f"role {name} field '{field}' must be a list")
        if "workflow_artifact_roots" in config and not isinstance(config["workflow_artifact_roots"], list):
            fail(f"role {name} field 'workflow_artifact_roots' must be a list")
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
        policy = retrospective_policy(task)
        if policy not in RETROSPECTIVE_POLICIES:
            fail(f"task {task_id} has invalid retrospective_policy: {policy}")
        contract = task.get("task_contract")
        if state["registry"].get("schema_version", 1) >= 2:
            if not isinstance(contract, dict):
                fail(f"task {task_id} must define task_contract in schema v2")
            ensure_fields(contract, TASK_CONTRACT_FIELDS, f"task {task_id} task_contract")
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
        for artifact_path in [task["feedback_path"], task["retrospective_path"]]:
            if state["roles"].get("schema_version", 1) >= 2 and not any_path_matches(role["workflow_artifact_roots"], artifact_path):
                fail(f"task {task_id} workflow artifact '{artifact_path}' is outside role workflow_artifact_roots")
        packet = make_task_packet(root, state, task["role"], task_id)
        require_text_contains(
            packet,
            [
                "bash scripts/check_handoff_intake.sh --target",
                f"bash scripts/check_worker_feedback.sh --task {task_id} --target",
                f"bash scripts/check_retrospective.sh --task {task_id} --target",
                f"bash scripts/close_task.sh --task {task_id} --to review --target",
                f"bash scripts/close_task.sh --task {task_id} --to done --accepted-by main_brain --target",
                "worker 只提交结果，不自行验收结案",
            ],
            f"generated task packet for {task_id}",
        )


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
        if (status == "done" or accepted) and retrospective_required(root, state, task):
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=True, require_content=True)
        else:
            check_retrospective(root, state, task_id=task_id, file_path=None, require_exists=False, require_content=False)
