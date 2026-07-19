from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple

from workflow_kernel.consistency import state_consistency_payload
from workflow_kernel.schema import detect_root_kind, parse_kv_env
from workflow_kernel.validate import (
    validate_codex_bridge,
    validate_feedback,
    validate_handoffs,
    validate_memory,
    validate_paper_config,
    validate_queue,
    validate_retrospectives,
    validate_roles,
    validate_tasks,
    validate_template_source,
)


def generated_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _defaulted_env(root: Path) -> Dict[str, str]:
    values = parse_kv_env(root / ".env")
    competition = values.get("COMPETITION_NAME", "mathorcup")
    instance_id = values.get("INSTANCE_ID", hashlib.sha256(str(root.resolve()).encode("utf-8")).hexdigest()[:8])
    slug = re.sub(r"[^a-z0-9_.-]+", "-", competition.lower()).strip("-_.") or "mathorcup"
    defaults = {
        "HOST_DIR": str(root),
        "IMAGE_NAME": "mathorcup-runtime:latest",
        "COMPETITION_NAME": competition,
        "INSTANCE_ID": instance_id,
        "CONTAINER_NAME": f"{slug[:40]}-{instance_id}-dev",
        "JUPYTER_PORT": "8888",
        "RSTUDIO_PORT": "8787",
        "JUPYTER_PORT_MODE": "fixed",
        "RSTUDIO_PORT_MODE": "fixed",
        "JUPYTER_TOKEN": "mathorcup",
        "CONTAINER_RUNTIME": "nvidia",
        "CONTAINER_GPUS": "all",
        "CONTAINER_PRIVILEGED": "true",
        "CONTAINER_USER": "root",
        "CONTAINER_GRANT_SUDO": "yes",
        "PROJECT_CONTAINER_DIR": "/workspace/mathorcup",
    }
    merged = {**defaults, **values}
    merged.setdefault("HOST_PROJECT_DIR", f"{merged['HOST_DIR']}/project")
    return merged


def _defaulted_paper_env(root: Path, root_env: Dict[str, str]) -> Dict[str, str]:
    values = parse_kv_env(root / "project/paper/runtime/paper.env")
    defaults = {
        "PAPER_HOST_REL_DIR": "project/paper",
        "PAPER_CONTAINER_DIR": f"{root_env.get('PROJECT_CONTAINER_DIR', '/workspace/mathorcup')}/paper",
        "PAPER_ACTIVE_ENTRYPOINT": "main.tex",
        "PAPER_BUILD_DIR": "",
        "PAPER_LATEX_ENGINE": "xelatex",
        "PAPER_RUN_BIBER": "1",
        "PAPER_BUILD_PASSES": "2",
        "PAPER_TEXINPUTS": "",
        "PAPER_ACCEPT_PDF": "project/paper/main.pdf",
        "PAPER_ACCEPT_LOG": "project/paper/main.log",
        "PAPER_ACCEPT_AUX": "project/paper/main.aux",
    }
    return {**defaults, **values}


def _tool_status(root: Path) -> Dict[str, Any]:
    tools: List[Dict[str, Any]] = []
    warnings: List[str] = []
    for name in ["python3", "docker", "codex"]:
        path = shutil.which(name)
        item: Dict[str, Any] = {
            "name": name,
            "available": path is not None,
            "path": path or "",
        }
        if path is None:
            warnings.append(f"{name} not found")
        tools.append(item)

    exec_worker = {
        "codex_exec_available": False,
        "wrapper": "bash scripts/run_exec_worker.sh",
        "healthcheck": f"bash scripts/exec_healthcheck.sh --target {root}",
    }
    if shutil.which("codex"):
        result = subprocess.run(["codex", "exec", "--help"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        exec_worker["codex_exec_available"] = result.returncode == 0
        if result.returncode != 0:
            warnings.append("codex exec subcommand unavailable")
    else:
        warnings.append("codex not found; exec worker mode unavailable")
    return {"tools": tools, "exec_worker_mode": exec_worker, "warnings": warnings}


def _event_harness(root: Path, root_kind: str, scripts_dir: Path) -> Dict[str, Any]:
    if root_kind == "template_source":
        event_log_path = root / "scaffold/project/runtime/event_log.jsonl.template"
        callback_hooks_path = root / "scaffold/project/spec/callback_hooks.json.template"
        return {
            "event_log": {"path": "scaffold/project/runtime/event_log.jsonl.template", "exists": event_log_path.is_file()},
            "callback_hooks": {"path": "scaffold/project/spec/callback_hooks.json.template", "exists": callback_hooks_path.is_file()},
            "process_callbacks_available": (scripts_dir / "process_callbacks.sh").is_file(),
            "batch_supervisor_available": (scripts_dir / "run_exec_batch.sh").is_file(),
        }

    event_log_path = root / "project/runtime/event_log.jsonl"
    event_count = 0
    if event_log_path.is_file():
        event_count = sum(1 for line in event_log_path.read_text(encoding="utf-8").splitlines() if line.strip())
    return {
        "event_log": {
            "path": "project/runtime/event_log.jsonl",
            "exists": event_log_path.is_file(),
            "event_count": event_count,
        },
        "callback_hooks": {
            "path": "project/spec/callback_hooks.json",
            "exists": (root / "project/spec/callback_hooks.json").is_file(),
        },
        "process_callbacks_available": (scripts_dir / "process_callbacks.sh").is_file(),
        "batch_supervisor_available": (scripts_dir / "run_exec_batch.sh").is_file(),
    }


def _codex_native_bridge(root: Path, root_kind: str) -> Dict[str, Any]:
    if root_kind == "template_source":
        root_skills = list((root / ".codex/skills").glob("*")) if (root / ".codex/skills").is_dir() else []
        scaffold_skills = list((root / "scaffold/.codex/skills").glob("*")) if (root / "scaffold/.codex/skills").is_dir() else []
        root_agents = list((root / ".codex/agents").glob("*.toml")) if (root / ".codex/agents").is_dir() else []
        scaffold_agents = list((root / "scaffold/.codex/agents").glob("*.toml")) if (root / "scaffold/.codex/agents").is_dir() else []
        return {
            "requirements": {"path": ".codex/requirements.toml", "exists": (root / ".codex/requirements.toml").is_file()},
            "skills_count": len([item for item in root_skills if item.is_dir()]),
            "instance_requirements_template": {
                "path": "scaffold/.codex/requirements.toml.template",
                "exists": (root / "scaffold/.codex/requirements.toml.template").is_file(),
            },
            "instance_skills_count": len([item for item in scaffold_skills if item.is_dir()]),
            "agent_definitions_count": len(root_agents),
            "instance_agent_definitions_count": len(scaffold_agents),
            "hooks_present": (root / ".codex/hooks.json").is_file() or (root / "scaffold/.codex/hooks.json.template").is_file(),
        }

    skills = list((root / ".codex/skills").glob("*")) if (root / ".codex/skills").is_dir() else []
    agents = list((root / ".codex/agents").glob("*.toml")) if (root / ".codex/agents").is_dir() else []
    worker_pool_path = root / "project/runtime/worker_pool.json"
    worker_pool: Dict[str, Any] = {"path": "project/runtime/worker_pool.json", "exists": worker_pool_path.is_file()}
    if worker_pool_path.is_file():
        try:
            pool = json.loads(worker_pool_path.read_text(encoding="utf-8"))
            workers = pool.get("workers", {})
            worker_pool.update(
                {
                    "generation": pool.get("pool_generation", ""),
                    "max_open_threads": pool.get("max_open_threads", 0),
                    "registered_count": len(workers),
                    "busy_count": sum(item.get("status") == "busy" for item in workers.values()),
                    "idle_count": sum(item.get("status") == "idle" for item in workers.values()),
                }
            )
        except (OSError, json.JSONDecodeError):
            worker_pool["parse_error"] = True
    return {
        "requirements": {"path": ".codex/requirements.toml", "exists": (root / ".codex/requirements.toml").is_file()},
        "skills_count": len([item for item in skills if item.is_dir()]),
        "agent_definitions_count": len(agents),
        "worker_pool": worker_pool,
        "hooks_present": (root / ".codex/hooks.json").is_file(),
    }


def _acceptance_helpers(root: Path, root_kind: str, scripts_dir: Path) -> Dict[str, Any]:
    if root_kind == "template_source":
        model_manifest = root / "scaffold/project/output/MODEL_MANIFEST_TEMPLATE.json"
        paper_checklist = root / "scaffold/project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md"
        return {
            "paper_acceptance_check": {
                "available": (scripts_dir / "paper_acceptance_check.sh").is_file(),
                "command": "bash scripts/paper_acceptance_check.sh --target <rendered-instance>",
            },
            "artifact_index": {
                "available": (scripts_dir / "artifact_index.sh").is_file(),
                "command": "bash scripts/artifact_index.sh --target <rendered-instance>",
            },
            "model_manifest_template": {
                "path": "scaffold/project/output/MODEL_MANIFEST_TEMPLATE.json",
                "exists": model_manifest.is_file(),
            },
            "paper_acceptance_checklist": {
                "path": "scaffold/project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md",
                "exists": paper_checklist.is_file(),
            },
        }

    model_manifest = root / "project/output/MODEL_MANIFEST_TEMPLATE.json"
    paper_checklist = root / "project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md"
    return {
        "paper_acceptance_check": {
            "available": (scripts_dir / "paper_acceptance_check.sh").is_file(),
            "command": f"bash scripts/paper_acceptance_check.sh --target {root}",
        },
        "artifact_index": {
            "available": (scripts_dir / "artifact_index.sh").is_file(),
            "command": f"bash scripts/artifact_index.sh --target {root}",
        },
        "model_manifest_template": {
            "path": "project/output/MODEL_MANIFEST_TEMPLATE.json",
            "exists": model_manifest.is_file(),
        },
        "paper_acceptance_checklist": {
            "path": "project/output/review/PAPER_ACCEPTANCE_CHECKLIST.md",
            "exists": paper_checklist.is_file(),
        },
    }


def _validation(root: Path, root_kind: str) -> Dict[str, Any]:
    checks: List[Dict[str, str]] = []

    def run(name: str, callback: Any) -> None:
        try:
            callback()
            checks.append({"name": name, "status": "OK", "message": ""})
        except SystemExit as exc:
            checks.append({"name": name, "status": "FAIL", "message": str(exc)})

    if root_kind == "template_source":
        run("template_source", lambda: validate_template_source(root))
        run("codex_bridge", lambda: validate_codex_bridge(root, template_source=True))
    else:
        from workflow_kernel.schema import load_runtime_state

        state = load_runtime_state(root)
        run("memory", lambda: validate_memory(root))
        run("handoff", lambda: validate_handoffs(root))
        run("codex_bridge", lambda: validate_codex_bridge(root, template_source=False))
        run("paper", lambda: validate_paper_config(root))
        run("roles", lambda: validate_roles(root, state))
        run("tasks", lambda: validate_tasks(root, state))
        run("queue", lambda: validate_queue(root, state))
        run("feedback", lambda: validate_feedback(root, state))
        run("retrospective", lambda: validate_retrospectives(root, state))
        consistency_payload, consistency_status = state_consistency_payload(root)
        checks.append(
            {
                "name": "state_consistency",
                "status": "OK" if consistency_status == 0 else "FAIL",
                "message": consistency_payload.get("status", ""),
            }
        )
    ok = all(item["status"] == "OK" for item in checks)
    return {"ok": ok, "status": "OK" if ok else "FAIL", "checks": checks}


def _docker_names(args: List[str]) -> List[str]:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def _container_state(container_name: str, root_env: Dict[str, str]) -> Dict[str, Any]:
    if shutil.which("docker") is None:
        return {"docker_available": False, "exists": False, "running": False, "warnings": ["docker not found"]}
    running = container_name in _docker_names(["docker", "ps", "--filter", f"name=^/{container_name}$", "--format", "{{.Names}}"])
    exists = running or container_name in _docker_names(["docker", "ps", "-a", "--filter", f"name=^/{container_name}$", "--format", "{{.Names}}"])
    warnings: List[str] = []
    identity: Dict[str, Any] = {"checked": False, "matches": False}
    if exists:
        result = subprocess.run(["docker", "inspect", container_name], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if result.returncode == 0:
            import json

            details = json.loads(result.stdout)[0]
            labels = details.get("Config", {}).get("Labels") or {}
            bindings = details.get("HostConfig", {}).get("PortBindings") or {}
            destination = root_env.get("PROJECT_CONTAINER_DIR", "/workspace/mathorcup")
            mount_source = next((item.get("Source", "") for item in details.get("Mounts", []) if item.get("Destination") == destination), "")
            expected_root = str(Path(root_env["HOST_DIR"]).resolve())
            expected_project = str(Path(root_env["HOST_PROJECT_DIR"]).resolve())
            label_instance = labels.get("io.mathorcup.instance.id", "")
            label_root = labels.get("io.mathorcup.instance.root", "")
            legacy = not label_instance and not label_root
            matches = (legacy and mount_source == expected_project) or (
                label_instance == root_env["INSTANCE_ID"] and label_root == expected_root and mount_source == expected_project
            )
            actual_jupyter = ((bindings.get("8888/tcp") or [{}])[0]).get("HostPort", "")
            actual_rstudio = ((bindings.get("8787/tcp") or [{}])[0]).get("HostPort", "")
            ports_match = actual_jupyter == root_env["JUPYTER_PORT"] and actual_rstudio == root_env["RSTUDIO_PORT"]
            identity = {
                "checked": True,
                "matches": matches,
                "legacy": legacy,
                "instance_id": label_instance,
                "instance_root": label_root,
                "mount_source": mount_source,
                "mount_destination": destination,
                "expected_root": expected_root,
                "expected_project": expected_project,
                "ports_match": ports_match,
                "actual_jupyter_port": actual_jupyter,
                "actual_rstudio_port": actual_rstudio,
            }
            if not matches:
                warnings.append("container identity or project mount does not match this instance")
            if not ports_match:
                warnings.append("container port bindings do not match .env")
    if not exists:
        warnings.append("container does not exist")
    elif not running:
        warnings.append("container exists but is stopped")
    return {"docker_available": True, "exists": exists, "running": running, "identity": identity, "warnings": warnings}


def _container_tool_baseline(container_name: str, running: bool) -> Dict[str, Any]:
    if shutil.which("docker") is None:
        return {"checked": False, "tools": [], "warnings": ["docker not found"]}
    if not running:
        return {"checked": False, "tools": [], "warnings": ["container baseline skipped"]}
    script = r'''
check() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "OK %s %s\n" "$cmd" "$(command -v "$cmd")"
    else
        printf "MISS %s\n" "$cmd"
    fi
}
check biber
check tree
check yq
if command -v fd >/dev/null 2>&1; then
    printf "OK fd %s\n" "$(command -v fd)"
elif command -v fdfind >/dev/null 2>&1; then
    printf "WARN fd %s\n" "$(command -v fdfind)"
else
    printf "MISS fd\n"
fi
python3 - <<'PY'
modules = [
    "numpy",
    "pandas",
    "polars",
    "scipy",
    "sklearn",
    "matplotlib",
    "seaborn",
    "plotly",
    "ortools",
    "pulp",
    "deap",
    "pygmo",
    "sympy",
    "statsmodels",
    "openpyxl",
    "docx",
    "pptx",
    "rich",
    "tqdm",
]
for module in modules:
    try:
        __import__(module)
        print(f"OK py:{module}")
    except Exception:
        print(f"MISS py:{module}")

try:
    from matplotlib import font_manager
    font_manager._load_fontmanager(try_read_cache=False)
    candidates = ("WenQuanYi", "Noto Sans CJK", "AR PL UMing", "Droid Sans Fallback")
    matches = [
        font.name
        for font in font_manager.fontManager.ttflist
        if any(candidate in font.name for candidate in candidates)
    ]
    if matches:
        print(f"OK matplotlib-cjk-font {matches[0]}")
    else:
        print("MISS matplotlib-cjk-font")
except Exception:
    print("MISS matplotlib-cjk-font")
PY
'''
    result = subprocess.run(["docker", "exec", "-w", "/", container_name, "bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    tools: List[Dict[str, Any]] = []
    warnings: List[str] = []
    for line in result.stdout.splitlines():
        parts = line.split(maxsplit=2)
        if len(parts) < 2:
            continue
        state, name = parts[0], parts[1]
        path = parts[2] if len(parts) > 2 else ""
        tools.append({"name": name, "status": state, "path": path})
        if state != "OK":
            warnings.append(f"{name} missing" if state == "MISS" else f"{name} uses fallback {path}")
    return {"checked": True, "tools": tools, "warnings": warnings}


def doctor_payload(root: Path, scripts_dir: Path) -> Dict[str, Any]:
    root = root.resolve()
    root_kind = detect_root_kind(root)
    root_env = _defaulted_env(root)
    paper_env = _defaulted_paper_env(root, root_env)
    tooling = _tool_status(root)
    validation = _validation(root, root_kind)
    container = _container_state(root_env["CONTAINER_NAME"], root_env)
    baseline = _container_tool_baseline(root_env["CONTAINER_NAME"], bool(container["running"]))
    warnings = (
        tooling["warnings"]
        + container["warnings"]
        + baseline["warnings"]
    )
    status = "FAIL" if not validation["ok"] else ("WARN" if warnings else "OK")
    return {
        "schema_version": "doctor.v1",
        "generated_at": generated_timestamp(),
        "root": str(root),
        "root_kind": root_kind,
        "read_only": True,
        "runtime_config": {
            "competition": root_env["COMPETITION_NAME"],
            "instance_id": root_env["INSTANCE_ID"],
            "image": root_env["IMAGE_NAME"],
            "container": root_env["CONTAINER_NAME"],
            "host_project": root_env["HOST_PROJECT_DIR"],
            "jupyter_port": root_env["JUPYTER_PORT"],
            "jupyter_port_mode": root_env["JUPYTER_PORT_MODE"],
            "rstudio_port": root_env["RSTUDIO_PORT"],
            "rstudio_port_mode": root_env["RSTUDIO_PORT_MODE"],
            "runtime": root_env["CONTAINER_RUNTIME"],
            "gpus": root_env["CONTAINER_GPUS"],
            "privileged": root_env["CONTAINER_PRIVILEGED"],
            "container_user": root_env["CONTAINER_USER"],
            "grant_sudo": root_env["CONTAINER_GRANT_SUDO"],
            "paper_entry": paper_env["PAPER_ACTIVE_ENTRYPOINT"],
            "paper_build_dir": paper_env["PAPER_BUILD_DIR"] or "<same as paper dir>",
            "accept_pdf": paper_env["PAPER_ACCEPT_PDF"],
            "truth_source": ".env + project/paper/runtime/paper.env",
            "rendered_mirror": "project/spec/runtime_contract.md + project/paper/spec/paper_runtime_contract.md",
        },
        "tooling": tooling,
        "event_harness": _event_harness(root, root_kind, scripts_dir),
        "acceptance_helpers": _acceptance_helpers(root, root_kind, scripts_dir),
        "codex_native_bridge": _codex_native_bridge(root, root_kind),
        "validation": validation,
        "container_state": container,
        "container_tool_baseline": baseline,
        "ok": validation["ok"],
        "status": status,
        "warnings": warnings,
    }
