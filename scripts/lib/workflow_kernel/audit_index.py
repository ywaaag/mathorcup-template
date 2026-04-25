from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from workflow_kernel.schema import (
    FEEDBACK_HEADINGS,
    FEEDBACK_REQUIRED_CONTENT_HEADINGS,
    HANDOFF_HEADINGS,
    RETRO_HEADINGS,
    RETRO_REQUIRED_CONTENT_HEADINGS,
    atomic_write_text,
    detect_root_kind,
    fail,
    normalize_relpath,
    task_from_id,
)


LOW_SIGNAL_VALUES = {"none", "n/a", "no", "empty", "no meaningful change"}
LOW_SIGNAL_PLACEHOLDERS = {
    "command:",
    "result:",
    "old judgement -> new conclusion:",
    "if the main brain had told me this earlier:",
    "future task packets should include:",
    "who should read this next:",
    "canonical inputs:",
    "supporting files:",
    "model / script:",
    "what was actually validated:",
    "figures:",
    "tables:",
    "csv:",
    "key claims:",
    "variable definitions:",
    "wording boundaries / caveats:",
    "assumption risk:",
    "sensitivity risk:",
}
LOW_SIGNAL_PREFIXES = (
    "these fields below are candidate policy hints only",
)


def prefill_template(template_text: str, replacements: Dict[str, str]) -> str:
    lines = template_text.splitlines()
    for index, line in enumerate(lines[:-1]):
        if line in replacements and lines[index + 1].lstrip().startswith("-"):
            lines[index + 1] = replacements[line]
    return "\n".join(lines) + "\n"


def init_feedback_files(
    root: Path,
    state: Dict[str, Any],
    task_id: str,
    *,
    create_feedback: bool,
    create_retrospective: bool,
) -> List[str]:
    task = task_from_id(state, task_id)
    created: List[str] = []
    items: List[Tuple[bool, str, str, Dict[str, str]]] = []
    if create_feedback:
        items.append(
            (
                True,
                "project/output/review/WORKER_FEEDBACK_TEMPLATE.md",
                task["feedback_path"],
                {
                    "## Task ID": f"- {task_id}",
                    "## Role": f"- {task['role']}",
                },
            )
        )
    if create_retrospective:
        items.append(
            (
                False,
                "project/output/retrospectives/RETROSPECTIVE_TEMPLATE.md",
                task["retrospective_path"],
                {
                    "## Task ID": f"- {task_id}",
                    "## Trigger": f"- task `{task_id}`: {task['title']}",
                    "## Next Consumer": "- main_brain",
                },
            )
        )
    for is_feedback, template_ref, output_ref, replacements in items:
        output_path = root / output_ref
        if output_path.exists():
            created.append(f"exists:{output_ref}")
            continue
        template_path = root / template_ref
        template_text = template_path.read_text(encoding="utf-8")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(prefill_template(template_text, replacements), encoding="utf-8")
        kind = "feedback" if is_feedback else "retrospective"
        created.append(f"created:{kind}:{output_ref}")
    return created


def require_headings(path: Path, headings: Sequence[str], context: str) -> List[str]:
    if not path.is_file():
        fail(f"missing file: {path}")
    found = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.startswith("## ")]
    if found != list(headings):
        fail(f"{context} must contain exact headings: {' | '.join(headings)}")
    return path.read_text(encoding="utf-8").splitlines()


def sections_by_heading(lines: Sequence[str]) -> Dict[str, List[str]]:
    sections: Dict[str, List[str]] = {}
    current: str | None = None
    for raw_line in lines:
        line = raw_line.rstrip()
        if line.startswith("## "):
            current = line.strip()
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    return sections


def normalized_section_values(lines: Sequence[str]) -> List[str]:
    values: List[str] = []
    for raw_line in lines:
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("- "):
            stripped = stripped[2:].strip()
        elif stripped == "-":
            stripped = ""
        if stripped:
            values.append(stripped)
    return values


def has_effective_content(lines: Sequence[str]) -> bool:
    values = normalized_section_values(lines)
    if not values:
        return False
    return any(not is_low_signal_value(value) for value in values)


def is_low_signal_value(value: str) -> bool:
    normalized = value.strip().casefold()
    if not normalized:
        return True
    if normalized in LOW_SIGNAL_VALUES or normalized in LOW_SIGNAL_PLACEHOLDERS:
        return True
    if any(normalized.startswith(prefix) for prefix in LOW_SIGNAL_PREFIXES):
        return True
    if normalized.endswith(":"):
        return True
    return False


def require_effective_sections(
    path: Path,
    lines: Sequence[str],
    required_headings: Sequence[str],
    artifact_type: str,
) -> None:
    sections = sections_by_heading(lines)
    missing_or_low_signal = [
        heading[3:]
        for heading in required_headings
        if not has_effective_content(sections.get(heading, []))
    ]
    if missing_or_low_signal:
        details = "\n".join(
            f"- {artifact_type} file {path.name} missing or low-signal section: {section_name}"
            for section_name in missing_or_low_signal
        )
        fail(details)


def check_feedback(
    root: Path,
    state: Dict[str, Any],
    *,
    task_id: Optional[str],
    file_path: Optional[str],
    require_exists: bool,
    require_content: bool = True,
) -> Path:
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
    if require_content:
        require_effective_sections(path, lines, FEEDBACK_REQUIRED_CONTENT_HEADINGS, "feedback")
        task_id_values = [line.strip() for line in lines if line.strip().startswith("- ")]
        if task_id and f"- {task_id}" not in task_id_values:
            fail(f"feedback file {path.name} does not contain task id '{task_id}'")
    return path


def check_retrospective(
    root: Path,
    state: Dict[str, Any],
    *,
    task_id: Optional[str],
    file_path: Optional[str],
    require_exists: bool,
    require_content: bool = True,
) -> Path:
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
    if require_content:
        require_effective_sections(path, lines, RETRO_REQUIRED_CONTENT_HEADINGS, "retrospective")
        task_id_values = [line.strip() for line in lines if line.strip().startswith("- ")]
        if task_id and f"- {task_id}" not in task_id_values:
            fail(f"retrospective file {path.name} does not contain task id '{task_id}'")
    return path


def resolve_handoff_path(root: Path, file_path: str) -> Path:
    if not file_path:
        fail("submit-handoff requires --handoff")
    path = Path(file_path)
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def handoff_relpath(root: Path, path: Path) -> str:
    try:
        return normalize_relpath(path.resolve().relative_to(root.resolve()).as_posix())
    except ValueError:
        fail(f"handoff file {path.name} must be inside rendered instance root: {root}")


def check_handoff(root: Path, file_path: str, *, require_content: bool = True) -> Path:
    path = resolve_handoff_path(root, file_path)
    handoff_dir = (root / "project/output/handoff").resolve()
    issue = handoff_contract_issue(path, handoff_dir, require_content=require_content)
    if issue:
        fail(issue)
    return path


def handoff_contract_issue(path: Path, handoff_dir: Path, *, require_content: bool) -> Optional[str]:
    if not path.is_file():
        return f"missing file: {path}"
    if path.parent != handoff_dir:
        return f"handoff file {path.name} must be in project/output/handoff/"
    if path.name == "HANDOFF_TEMPLATE.md" or not path.name.startswith("P") or path.suffix != ".md":
        return f"invalid handoff filename: {path.name}"

    lines = path.read_text(encoding="utf-8").splitlines()
    found = [line.strip() for line in lines if line.startswith("## ")]
    if found != list(HANDOFF_HEADINGS):
        return f"handoff file {path.name} must contain exact headings: {' | '.join(HANDOFF_HEADINGS)}"

    if require_content:
        sections = sections_by_heading(lines)
        missing_or_low_signal = [
            heading[3:]
            for heading in HANDOFF_HEADINGS
            if not has_effective_content(sections.get(heading, []))
        ]
        if missing_or_low_signal:
            return "\n".join(
                f"- handoff file {path.name} missing or low-signal section: {section_name}"
                for section_name in missing_or_low_signal
            )
    return None


def load_handoff_index(root: Path) -> Dict[str, Any]:
    memory_path = root / "MEMORY.md"
    if not memory_path.is_file():
        fail("missing file: MEMORY.md")

    lines = memory_path.read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("## Handoff Index")
    except ValueError:
        fail("MEMORY.md missing section: ## Handoff Index")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break

    latest: Optional[str] = None
    latest_seen = False
    files_seen = False
    files: List[str] = []

    for raw_line in lines[start + 1 : end]:
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("- latest:"):
            latest_seen = True
            value = stripped.split(":", 1)[1].strip()
            if value and value != "none":
                latest = _normalize_indexed_handoff_ref(value)
            continue
        if stripped == "- files:":
            files_seen = True
            continue
        if stripped.startswith("- "):
            if not files_seen:
                fail("MEMORY.md -> ## Handoff Index must declare '- files:' before file entries")
            files.append(_normalize_indexed_handoff_ref(stripped[2:].strip()))
            continue
        fail(f"MEMORY.md -> ## Handoff Index contains unsupported line: {raw_line}")

    if not latest_seen:
        fail("MEMORY.md -> ## Handoff Index missing '- latest:' entry")
    if not files_seen:
        fail("MEMORY.md -> ## Handoff Index missing '- files:' entry")

    deduped_files: List[str] = []
    seen: set[str] = set()
    for item in files:
        if item in seen:
            continue
        seen.add(item)
        deduped_files.append(item)

    if latest is None and deduped_files:
        fail("MEMORY.md -> ## Handoff Index cannot use 'latest: none' when indexed files are present")
    if latest is not None and latest not in seen:
        fail(f"MEMORY.md -> ## Handoff Index latest entry is not present in files: {latest}")

    return {
        "latest": latest,
        "files": deduped_files,
    }


def _normalize_indexed_handoff_ref(value: str) -> str:
    normalized = value.strip().strip("`").strip()
    if not normalized:
        fail("MEMORY.md -> ## Handoff Index contains an empty handoff path")
    normalized = normalize_relpath(normalized)
    if not normalized.startswith("project/output/handoff/"):
        fail(f"indexed handoff must stay under project/output/handoff/: {normalized}")
    if normalized.endswith("/HANDOFF_TEMPLATE.md") or normalized == "project/output/handoff/HANDOFF_TEMPLATE.md":
        fail("HANDOFF_TEMPLATE.md cannot appear in MEMORY.md -> ## Handoff Index")
    if not normalized.endswith(".md"):
        fail(f"indexed handoff must be a Markdown file: {normalized}")
    return normalized


def inspect_handoff_intake(root: Path) -> Dict[str, Any]:
    if detect_root_kind(root) != "instance":
        fail("handoff-intake requires a rendered instance root")

    handoff_dir = (root / "project/output/handoff").resolve()
    if not handoff_dir.is_dir():
        fail("missing directory: project/output/handoff")

    index = load_handoff_index(root)
    indexed_files = index["files"]
    for rel in indexed_files:
        check_handoff(root, rel, require_content=True)

    warnings: List[str] = []
    indexed_set = set(indexed_files)
    for path in sorted(handoff_dir.glob("P*.md")):
        rel = normalize_relpath(path.relative_to(root).as_posix())
        if rel in indexed_set:
            continue
        issue = handoff_contract_issue(path.resolve(), handoff_dir, require_content=True)
        if issue:
            warnings.append(f"unindexed handoff ignored by default intake: {rel} (contract issue: {issue})")
            continue
        warnings.append(f"unindexed handoff ignored by default intake: {rel}")

    return {
        "latest": index["latest"],
        "files": indexed_files,
        "warnings": warnings,
    }


def render_handoff_intake_report(report: Dict[str, Any]) -> str:
    lines = [
        "[workflow] indexed latest: " + (report["latest"] or "none"),
        "[workflow] indexed files:",
    ]
    if report["files"]:
        lines.extend(f"- {item}" for item in report["files"])
    else:
        lines.append("- none")
    if report["warnings"]:
        lines.append("[workflow] warnings:")
        lines.extend(f"- {item}" for item in report["warnings"])
    else:
        lines.append("[workflow] warnings: none")
    return "\n".join(lines) + "\n"


def update_handoff_index(root: Path, handoff_rel: str) -> None:
    memory_path = root / "MEMORY.md"
    if not memory_path.is_file():
        fail("missing file: MEMORY.md")

    lines = memory_path.read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("## Handoff Index")
    except ValueError:
        fail("MEMORY.md missing section: ## Handoff Index")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break

    existing_files = set()
    for line in lines[start + 1 : end]:
        stripped = line.strip()
        if stripped.startswith("- project/output/handoff/"):
            existing_files.add(stripped[2:].strip())
        elif stripped.startswith("- `project/output/handoff/`"):
            existing_files.add(stripped[3:-1].strip())
        elif stripped.startswith("- `project/output/handoff/"):
            existing_files.add(stripped[3:].rstrip("`").strip())

    existing_files.add(handoff_rel)
    replacement = [
        "## Handoff Index",
        f"- latest: {handoff_rel}",
        "- files:",
    ]
    replacement.extend(f"  - {item}" for item in sorted(existing_files))
    new_lines = lines[:start] + replacement + lines[end:]
    atomic_write_text(memory_path, "\n".join(new_lines).rstrip() + "\n")


def submit_handoff(
    root: Path,
    state: Dict[str, Any],
    *,
    task_id: str,
    file_path: str,
    index: bool,
) -> str:
    if detect_root_kind(root) != "instance":
        fail("submit-handoff requires a rendered instance root")
    task_from_id(state, task_id)
    path = check_handoff(root, file_path, require_content=True)
    rel = handoff_relpath(root, path)
    if index:
        update_handoff_index(root, rel)
    return rel
