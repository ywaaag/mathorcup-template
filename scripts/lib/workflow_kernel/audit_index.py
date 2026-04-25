from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from workflow_kernel.schema import (
    FEEDBACK_HEADINGS,
    FEEDBACK_REQUIRED_CONTENT_HEADINGS,
    RETRO_HEADINGS,
    RETRO_REQUIRED_CONTENT_HEADINGS,
    fail,
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
