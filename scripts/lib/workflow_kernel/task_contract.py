from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Dict

from workflow_kernel.audit_index import inspect_handoff_intake
from workflow_kernel.schema import TASK_CONTRACT_FIELDS, ensure_fields, fail, save_structured, task_from_id


DOMAIN_ROLES = {"code_brain", "paper_brain", "layout_worker", "review_worker", "citation_worker"}
DEPENDENCY_MODES = {"final", "provisional"}
MANIFEST_GATES = {"none", "producer", "consumer_integrated", "consumer_verified"}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_task_contract(root: Path, state: Dict[str, Any], task_id: str, *, for_dispatch: bool) -> Dict[str, Any]:
    task = task_from_id(state, task_id)
    contract = task.get("task_contract")
    if not isinstance(contract, dict):
        if state["registry"].get("schema_version", 1) < 2:
            return {"legacy": True, "prepared": True, "dependency_mode": "final"}
        fail(f"task {task_id} has no task_contract")
    ensure_fields(contract, TASK_CONTRACT_FIELDS, f"task {task_id} task_contract")
    if not isinstance(contract["prepared"], bool):
        fail(f"task {task_id} task_contract.prepared must be boolean")
    if contract["dependency_mode"] not in DEPENDENCY_MODES:
        fail(f"task {task_id} task_contract.dependency_mode must be final or provisional")
    if contract["manifest_gate"] not in MANIFEST_GATES:
        fail(f"task {task_id} task_contract.manifest_gate is invalid")
    list_fields = [field for field in TASK_CONTRACT_FIELDS if field not in {"prepared", "objective", "dependency_mode", "manifest_gate"}]
    for field in list_fields:
        if not isinstance(contract[field], list):
            fail(f"task {task_id} task_contract.{field} must be a list")
    if not for_dispatch:
        return contract
    if task["role"] in DOMAIN_ROLES:
        if not contract["prepared"]:
            fail(f"task {task_id} domain contract is not prepared; configure it before dispatch")
        for field in ["objective", "problem_inputs", "required_artifacts", "validation_commands"]:
            if not contract[field]:
                fail(f"task {task_id} task_contract.{field} must be non-empty before dispatch")

    tasks = {item["task_id"]: item for item in state["registry"].get("tasks", [])}
    for dependency in contract["dependencies"]:
        if dependency not in tasks:
            fail(f"task {task_id} references unknown dependency: {dependency}")
        if contract["dependency_mode"] == "final" and tasks[dependency]["status"] != "done":
            fail(f"task {task_id} dependency {dependency} is not done")

    indexed = set(inspect_handoff_intake(root).get("files", []))
    for ref in contract["canonical_inputs"]:
        if isinstance(ref, str):
            rel = ref
            expected_hash = ""
        elif isinstance(ref, dict):
            rel = str(ref.get("path", ""))
            expected_hash = str(ref.get("sha256", ""))
        else:
            fail(f"task {task_id} canonical_inputs entries must be strings or objects")
        if not rel:
            fail(f"task {task_id} canonical input path is empty")
        path = root / rel
        if not path.is_file():
            fail(f"task {task_id} canonical input does not exist: {rel}")
        if rel.startswith("project/output/handoff/") and contract["dependency_mode"] == "final" and rel not in indexed:
            fail(f"task {task_id} canonical handoff is not indexed: {rel}")
        if expected_hash and _sha256(path) != expected_hash:
            fail(f"task {task_id} canonical input hash mismatch: {rel}")
    return contract


def configure_task_contract(root: Path, state: Dict[str, Any], task_id: str, file_path: str) -> None:
    task = task_from_id(state, task_id)
    source = Path(file_path)
    if not source.is_absolute():
        source = root / source
    if not source.is_file():
        fail(f"task contract file does not exist: {source}")
    try:
        contract = json.loads(source.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"invalid task contract JSON: {exc}")
    task["task_contract"] = contract
    validate_task_contract(root, state, task_id, for_dispatch=False)
    save_structured(state["registry_path"], state["registry"])
