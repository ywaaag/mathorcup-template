from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

from workflow_kernel.schema import detect_root_kind


POLICY_FIELDS = [
    "Failure Cause",
    "Missing Context",
    "Suggested Rule",
    "Suggested Contract Update",
    "Reusable Lesson",
]
PROMOTE_FIELD = "Should Promote To Contract"
IGNORED_VALUES = {"none", "n/a", "no", "empty", "no meaningful change"}


@dataclass(frozen=True)
class ExtractedField:
    field_name: str
    content: str


@dataclass(frozen=True)
class PolicyHintEntry:
    source_file: str
    task_id: str
    should_promote: str
    fields: Tuple[ExtractedField, ...]


def template_source_notice(root: Path) -> str:
    return "\n".join(
        [
            "Policy hints extraction writes only a candidate review artifact.",
            "",
            f"Current root is template-source: {root}",
            "Do not run this against the template source as if it were a rendered instance.",
            "",
            "Render a temporary instance first:",
            '  tmpdir="$(mktemp -d)"',
            '  bash scripts/setup.sh demo --render-only --target "$tmpdir"',
            '  bash scripts/extract_policy_hints.sh --target "$tmpdir"',
            "",
        ]
    )


def output_path(root: Path) -> Path:
    return root / "project/output/review/policy_hints_candidate.md"


def generated_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_sections(text: str) -> Dict[str, str]:
    sections: Dict[str, List[str]] = {}
    current: str | None = None
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.startswith("## "):
            current = line[3:].strip()
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    return {heading: "\n".join(lines).strip() for heading, lines in sections.items()}


def normalize_block_lines(block: str) -> List[str]:
    lines: List[str] = []
    for raw_line in block.splitlines():
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("- "):
            stripped = stripped[2:].strip()
        elif stripped == "-":
            stripped = ""
        if stripped:
            lines.append(stripped)
    return lines


def is_ignored_block(block: str) -> bool:
    lines = normalize_block_lines(block)
    if not lines:
        return True
    return all(line.casefold() in IGNORED_VALUES for line in lines)


def cleaned_block(block: str) -> str:
    kept = []
    for raw_line in block.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            continue
        stripped = line.lstrip()
        if stripped.startswith("- "):
            candidate = stripped[2:].strip()
            if candidate and candidate.casefold() in IGNORED_VALUES:
                continue
            kept.append(candidate)
            continue
        kept.append(line.strip())
    return "\n".join(kept).strip()


def task_id_from_path(path: Path, sections: Dict[str, str]) -> str:
    name = path.name
    for suffix in ("_feedback.md", "_retrospective.md"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    task_id_block = sections.get("Task ID", "")
    values = normalize_block_lines(task_id_block)
    if values:
        return values[0]
    return path.stem


def should_promote_value(sections: Dict[str, str]) -> str:
    raw = sections.get(PROMOTE_FIELD, "")
    values = normalize_block_lines(raw)
    if not values:
        return "no"
    return values[0]


def collect_entry(root: Path, path: Path) -> PolicyHintEntry | None:
    sections = parse_sections(path.read_text(encoding="utf-8"))
    fields: List[ExtractedField] = []
    for field_name in POLICY_FIELDS:
        raw = sections.get(field_name, "")
        if is_ignored_block(raw):
            continue
        cleaned = cleaned_block(raw)
        if not cleaned:
            continue
        fields.append(ExtractedField(field_name=field_name, content=cleaned))

    promote = should_promote_value(sections)
    if not fields and promote.casefold() in IGNORED_VALUES:
        return None

    relpath = path.relative_to(root).as_posix()
    return PolicyHintEntry(
        source_file=relpath,
        task_id=task_id_from_path(path, sections),
        should_promote=promote,
        fields=tuple(fields),
    )


def candidate_sources(root: Path) -> Iterable[Path]:
    review_dir = root / "project/output/review"
    retro_dir = root / "project/output/retrospectives"
    yield from sorted(review_dir.glob("*_feedback.md"))
    yield from sorted(retro_dir.glob("*_retrospective.md"))


def render_candidate(root: Path, entries: Sequence[PolicyHintEntry]) -> str:
    lines = [
        "# Policy Hints Candidate",
        "",
        f"- generated_at: {generated_timestamp()}",
        "- note: this is a candidate review artifact, not runtime truth, and it does not take effect automatically",
        "- main_brain_next_step: manually review these hints and decide whether to open a scaffold/contract update task",
        "",
    ]
    if not entries:
        lines.extend(
            [
                "## Findings",
                "",
                "- no policy hints found",
                "",
            ]
        )
        return "\n".join(lines)

    lines.extend(["## Findings", ""])
    for entry in entries:
        lines.append(f"### {entry.task_id}")
        lines.append(f"- source file: {entry.source_file}")
        lines.append(f"- task_id: {entry.task_id}")
        lines.append(f"- should_promote_to_contract: {entry.should_promote}")
        if entry.fields:
            for item in entry.fields:
                lines.append(f"- field name: {item.field_name}")
                content_lines = item.content.splitlines()
                if len(content_lines) == 1:
                    lines.append(f"  extracted content: {content_lines[0]}")
                else:
                    lines.append("  extracted content:")
                    for content_line in content_lines:
                        lines.append(f"    {content_line}")
        else:
            lines.append("- field name: Should Promote To Contract")
            lines.append(f"  extracted content: {entry.should_promote}")
        lines.append("- main_brain_next_step: manually review and decide whether to open a scaffold contract update task")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def extract_policy_hints(root: Path) -> Tuple[str, int]:
    if detect_root_kind(root) == "template_source":
        return template_source_notice(root), 0

    entries = [entry for path in candidate_sources(root) if (entry := collect_entry(root, path)) is not None]
    artifact_path = output_path(root)
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_text(render_candidate(root, entries), encoding="utf-8")

    lines = [
        "Policy hints extraction complete.",
        "Only the candidate artifact was written; runtime truth files were not modified.",
        f"Root: {root}",
        f"Artifact: {artifact_path}",
        f"Entries: {len(entries)}",
        "",
    ]
    if not entries:
        lines.append("Result: no policy hints found")
    else:
        lines.append("Result: candidate policy hints written for main-brain review")
    lines.append("")
    return "\n".join(lines), 0
