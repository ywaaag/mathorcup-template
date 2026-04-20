from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from workflow_kernel.schema import FEEDBACK_HEADINGS, RETRO_HEADINGS, fail, task_from_id


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


def check_feedback(
    root: Path,
    state: Dict[str, Any],
    *,
    task_id: Optional[str],
    file_path: Optional[str],
    require_exists: bool,
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
    task_id_values = [line.strip() for line in lines if line.strip().startswith("- ")]
    if task_id and f"- {task_id}" not in task_id_values:
        fail(f"retrospective file {path.name} does not contain task id '{task_id}'")
    return path
