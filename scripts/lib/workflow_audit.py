#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from workflow_events import callback_run_dir, load_events
from workflow_state import (
    FEEDBACK_HEADINGS,
    RETRO_HEADINGS,
    current_timestamp,
    detect_root_kind,
    fail,
    find_active_queue_item,
    load_runtime_state,
    parse_kv_env,
    task_from_id,
    task_map,
)


IMPORTANT_SECTIONS = [
    "## Task ID",
    "## Role",
    "## Work Done",
    "## Verified Facts",
    "## Validation Or Acceptance",
    "## Remaining Risks",
    "## Revised Judgement",
]


def ensure_instance_root(root: Path) -> None:
    if detect_root_kind(root) != "instance":
        fail("audit commands expect a rendered instance root")


def relref(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def parse_timestamp(value: str) -> float:
    if not value:
        return 0.0
    normalized = value.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return 0.0


def read_lines(path: Path) -> List[str]:
    return path.read_text(encoding="utf-8").splitlines()


def markdown_sections(path: Path) -> Dict[str, List[str]]:
    sections: Dict[str, List[str]] = {}
    current: Optional[str] = None
    for raw_line in read_lines(path):
        line = raw_line.rstrip("\n")
        if line.startswith("## "):
            current = line.strip()
            sections[current] = []
            continue
        if current is not None:
            sections[current].append(line.rstrip())
    return sections


def heading_status(path: Path, expected: Sequence[str]) -> Tuple[bool, str]:
    if not path.is_file():
        return False, "missing"
    headings = [line.strip() for line in read_lines(path) if line.startswith("## ")]
    if headings != list(expected):
        return False, "invalid"
    return True, "valid"


def artifact_status(path: Path, expected_headings: Optional[Sequence[str]] = None) -> Dict[str, Any]:
    info: Dict[str, Any] = {
        "path": path,
        "exists": path.is_file(),
        "state": "missing",
        "mtime": path.stat().st_mtime if path.exists() else 0.0,
    }
    if not path.is_file():
        return info
    if expected_headings is None:
        info["state"] = "exists"
        return info
    valid, state = heading_status(path, expected_headings)
    info["valid"] = valid
    info["state"] = state
    return info


def collect_task_events(root: Path, task_id: str) -> List[Dict[str, Any]]:
    return [event for event in load_events(root) if event["task_id"] == task_id]


def collect_callback_reports(
    root: Path,
    *,
    task_id: str,
    event_ids: Optional[Sequence[str]] = None,
    latest: int = 10,
) -> List[Dict[str, Any]]:
    run_dir = callback_run_dir(root)
    if not run_dir.is_dir():
        return []
    allowed_event_ids = set(event_ids or [])
    reports: List[Dict[str, Any]] = []
    for path in sorted(run_dir.glob("*.json"), key=lambda item: item.stat().st_mtime):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if payload.get("task_id") != task_id:
            continue
        event_id = payload.get("event_id", "")
        if allowed_event_ids and event_id not in allowed_event_ids:
            continue
        related_files = [
            relref(root, candidate)
            for candidate in sorted(run_dir.glob(f"{event_id}__*"), key=lambda item: item.stat().st_mtime)
        ]
        reports.append(
            {
                "event_id": event_id,
                "event_type": payload.get("event_type", ""),
                "hook_name": payload.get("hook_name", ""),
                "generated_at": payload.get("generated_at", ""),
                "report_path": relref(root, path),
                "files": related_files,
            }
        )
    if latest > 0:
        reports = reports[-latest:]
    return reports


def collect_exec_artifacts(root: Path, task_id: str, latest: int = 10) -> List[str]:
    run_dir = root / "project/output/review/exec_runs"
    if not run_dir.is_dir():
        return []
    matches = [
        path for path in run_dir.rglob("*")
        if path.is_file() and task_id in path.name
    ]
    matches.sort(key=lambda item: item.stat().st_mtime)
    refs = [relref(root, path) for path in matches]
    if latest > 0:
        refs = refs[-latest:]
    return refs


def collect_adjudication_artifacts(root: Path, task_id: str) -> List[str]:
    review_dir = root / "project/output/review"
    if not review_dir.is_dir():
        return []
    pattern = f"{task_id}_adjudication*.md"
    matches = sorted(review_dir.glob(pattern), key=lambda item: item.stat().st_mtime)
    return [relref(root, path) for path in matches]


def last_event_of_type(events: Sequence[Dict[str, Any]], event_type: str) -> Optional[Dict[str, Any]]:
    for event in reversed(events):
        if event["event_type"] == event_type:
            return event
    return None


def normalize_claim(text: str) -> str:
    lowered = text.strip().lower()
    lowered = lowered.replace("`", "")
    lowered = re.sub(r"\s+", " ", lowered)
    return lowered


def section_items(lines: Sequence[str]) -> List[str]:
    items: List[str] = []
    in_code_block = False
    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block or not stripped:
            continue
        if stripped.startswith("- "):
            stripped = stripped[2:].strip()
        items.append(stripped)
    return items


def important_claims(path: Path) -> Dict[str, List[str]]:
    if not path.is_file():
        return {}
    sections = markdown_sections(path)
    claims: Dict[str, List[str]] = {}
    for heading in IMPORTANT_SECTIONS:
        lines = sections.get(heading, [])
        extracted = section_items(lines)
        if extracted:
            claims[heading] = extracted
    if not claims:
        fallback = [line.strip() for line in read_lines(path) if line.strip()][:8]
        if fallback:
            claims["## Summary"] = fallback
    return claims


def latest_callback_paths(root: Path, task_id: str, limit: int = 5) -> List[str]:
    reports = collect_callback_reports(root, task_id=task_id, latest=limit)
    seen: List[str] = []
    for report in reports:
        for ref in report["files"]:
            if ref not in seen:
                seen.append(ref)
    return seen[-limit:]


def next_step_hints(root: Path, task: Dict[str, Any], feedback: Dict[str, Any], retro: Dict[str, Any], events: Sequence[Dict[str, Any]]) -> List[str]:
    task_id = task["task_id"]
    target = str(root)
    hints: List[str] = []
    latest_event = events[-1]["event_type"] if events else ""

    if task["status"] in {"todo", "ready"}:
        hints.append(f"bash scripts/dispatch_task.sh --task {task_id} --owner <owner> --target {target}")
        return hints

    if task["status"] == "in_progress":
        if latest_event == "worker.failed":
            hints.append(f"bash scripts/cancel_task.sh --task {task_id} --reason 'worker failure after audit' --target {target}")
            hints.append(f"bash scripts/reopen_task.sh --task {task_id} --to ready --reason 'needs retry after worker failure' --target {target}")
            return hints
        if feedback["state"] == "valid":
            hints.append(f"bash scripts/check_worker_feedback.sh --task {task_id} --target {target}")
            hints.append(f"bash scripts/close_task.sh --task {task_id} --to review --target {target}")
            return hints
        if feedback["exists"]:
            hints.append(f"inspect and fix {relref(root, feedback['path'])} before review gate")
            return hints
        hints.append(f"bash scripts/list_history.sh --task {task_id} --target {target}")
        return hints

    if task["status"] == "review":
        hints.append(f"bash scripts/adjudicate_task.sh --task {task_id} --target {target}")
        if retro["state"] == "valid":
            hints.append(f"bash scripts/close_task.sh --task {task_id} --to done --accepted-by main_brain --target {target}")
        else:
            hints.append(f"prepare or fix {relref(root, retro['path'])} before done-level close")
        return hints

    if task["status"] == "blocked":
        hints.append(f"bash scripts/reopen_task.sh --task {task_id} --to ready --reason 'main brain re-queued blocked task' --target {target}")
        return hints

    if task["status"] == "done":
        hints.append(f"bash scripts/reopen_task.sh --task {task_id} --to review --reason 'main brain requested re-audit' --target {target}")
        return hints

    return hints


def show_task(root: Path, task_id: str) -> str:
    ensure_instance_root(root)
    state = load_runtime_state(root)
    task = task_from_id(state, task_id)
    queue_item = find_active_queue_item(state, task_id)
    feedback = artifact_status(root / task["feedback_path"], FEEDBACK_HEADINGS)
    retro = artifact_status(root / task["retrospective_path"], RETRO_HEADINGS)
    events = collect_task_events(root, task_id)
    callbacks = latest_callback_paths(root, task_id, limit=6)
    exec_artifacts = collect_exec_artifacts(root, task_id, latest=6)
    adjudications = collect_adjudication_artifacts(root, task_id)

    lines = [
        f"Task: {task['task_id']}",
        f"  role: {task['role']}",
        f"  title: {task['title']}",
        f"  status: {task['status']}",
        f"  owner: {task['owner'] or '-'}",
        f"  parallel_ok: {'yes' if task['parallel_ok'] else 'no'}",
        f"  accepted_by_main_brain: {'yes' if task['accepted_by_main_brain'] else 'no'}",
        "",
        "Scope:",
        "  allowed_paths:",
    ]
    for path in task["allowed_paths"]:
        lines.append(f"    - {path}")
    lines.append("  forbidden_paths:")
    for path in task["forbidden_paths"]:
        lines.append(f"    - {path}")

    lines.extend(["", "Queue / Lock:"])
    if queue_item:
        lines.append("  claimed: yes")
        lines.append(f"  queue_owner: {queue_item['owner']}")
        lines.append("  locked_paths:")
        for path in queue_item.get("locked_paths", []):
            lines.append(f"    - {path}")
    else:
        lines.append("  claimed: no")
        lines.append("  locked_paths: -")

    lines.extend(
        [
            "",
            "Artifacts:",
            f"  feedback: {relref(root, feedback['path'])} [{feedback['state']}]",
            f"  retrospective: {relref(root, retro['path'])} [{retro['state']}]",
        ]
    )
    if adjudications:
        lines.append("  adjudication_artifacts:")
        for ref in adjudications[-4:]:
            lines.append(f"    - {ref}")

    lines.extend(["", "Recent Events:"])
    if not events:
        lines.append("  - none")
    else:
        for event in events[-6:]:
            transition = ""
            if event["from_status"] or event["to_status"]:
                transition = f" | {event['from_status'] or '-'} -> {event['to_status'] or '-'}"
            note = f" | note={event['note']}" if event["note"] else ""
            lines.append(
                f"  - {event['timestamp']} | {event['event_type']} | actor={event['actor']} | owner={event['owner']}{transition}{note}"
            )

    lines.extend(["", "Recent Callback Artifacts:"])
    if not callbacks:
        lines.append("  - none")
    else:
        for ref in callbacks:
            lines.append(f"  - {ref}")

    lines.extend(["", "Recent Exec Artifacts:"])
    if not exec_artifacts:
        lines.append("  - none")
    else:
        for ref in exec_artifacts:
            lines.append(f"  - {ref}")

    lines.extend(["", "Next Step Hints:"])
    hints = next_step_hints(root, task, feedback, retro, events)
    if not hints:
        lines.append("  - no automatic hint")
    else:
        for hint in hints:
            lines.append(f"  - {hint}")

    return "\n".join(lines) + "\n"


def list_history(
    root: Path,
    task_id: str,
    *,
    latest: int,
    event_type: str,
    actor: str,
) -> str:
    ensure_instance_root(root)
    state = load_runtime_state(root)
    task = task_from_id(state, task_id)
    events = collect_task_events(root, task_id)
    if event_type:
        events = [event for event in events if event["event_type"] == event_type]
    if actor:
        events = [event for event in events if event["actor"] == actor]
    if latest > 0:
        events = events[-latest:]

    queue_history = [
        entry for entry in state["queue"].get("history", [])
        if entry.get("task_id") == task_id and (not actor or entry.get("actor") == actor)
    ]
    if latest > 0:
        queue_history = queue_history[-latest:]

    event_ids = [event["event_id"] for event in events]
    callbacks = collect_callback_reports(root, task_id=task_id, event_ids=event_ids if event_ids else None, latest=latest)
    exec_artifacts = collect_exec_artifacts(root, task_id, latest=latest)
    adjudications = collect_adjudication_artifacts(root, task_id)

    lines = [
        f"History: {task['task_id']}",
        f"  role: {task['role']}",
        f"  status: {task['status']}",
        f"  owner: {task['owner'] or '-'}",
        "",
        "Event Timeline:",
    ]
    if not events:
        lines.append("  - none")
    else:
        for event in events:
            transition = ""
            if event["from_status"] or event["to_status"]:
                transition = f" | {event['from_status'] or '-'} -> {event['to_status'] or '-'}"
            note = f" | note={event['note']}" if event["note"] else ""
            lines.append(
                f"  - {event['timestamp']} | {event['event_type']} | actor={event['actor']} | owner={event['owner']}{transition}{note}"
            )

    lines.extend(["", "Queue History:"])
    if not queue_history:
        lines.append("  - none")
    else:
        for entry in queue_history:
            reason = f" | reason={entry['reason']}" if entry.get("reason") else ""
            lines.append(
                f"  - {entry['timestamp']} | {entry['action']} | actor={entry['actor']} | owner={entry['owner']} | "
                f"{entry['from_status']} -> {entry['to_status']}{reason}"
            )

    lines.extend(["", "Callback Artifacts:"])
    if not callbacks:
        lines.append("  - none")
    else:
        for report in callbacks:
            lines.append(
                f"  - {report['generated_at']} | {report['hook_name']} | {report['report_path']}"
            )

    lines.extend(["", "Exec Run Artifacts:"])
    if not exec_artifacts:
        lines.append("  - none")
    else:
        for ref in exec_artifacts:
            lines.append(f"  - {ref}")

    lines.extend(["", "Adjudication Artifacts:"])
    if not adjudications:
        lines.append("  - none")
    else:
        for ref in adjudications:
            lines.append(f"  - {ref}")

    return "\n".join(lines) + "\n"


def input_candidates_from_events(root: Path, task_id: str) -> List[Path]:
    candidates: List[Path] = []
    for event in collect_task_events(root, task_id):
        for artifact in event.get("artifacts", []):
            artifact_path = root / artifact
            if not artifact_path.is_file():
                continue
            name = artifact_path.name
            if name.endswith("_feedback.md") or name.endswith("_retrospective.md") or name.endswith("_last_message.md"):
                candidates.append(artifact_path)
    return candidates


def comparison_input_candidates(root: Path, state: Dict[str, Any], task_id: str) -> List[Path]:
    task = task_from_id(state, task_id)
    paths: List[Path] = [
        root / task["feedback_path"],
        root / task["retrospective_path"],
    ]
    review_dir = root / "project/output/review"
    if review_dir.is_dir():
        for path in sorted(review_dir.glob(f"*{task_id}*.md"), key=lambda item: item.stat().st_mtime):
            if path.name.endswith("_adjudication.md"):
                continue
            if path.name.endswith("_feedback.md"):
                continue
            paths.append(path)
    paths.extend(input_candidates_from_events(root, task_id))
    unique: List[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path.resolve())
        if key in seen or not path.is_file():
            continue
        seen.add(key)
        unique.append(path)
    return unique


def default_inputs(root: Path, state: Dict[str, Any], task_id: str) -> List[Path]:
    paths: List[Path] = comparison_input_candidates(root, state, task_id)
    for report in collect_callback_reports(root, task_id=task_id, latest=6):
        for ref in report["files"]:
            candidate = root / ref
            if candidate.is_file() and candidate.suffix in {".md", ".json"}:
                paths.append(candidate)
    unique: List[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path.resolve())
        if key in seen or not path.is_file():
            continue
        seen.add(key)
        unique.append(path)
    return unique


def resolve_inputs(root: Path, raw_inputs: Sequence[str]) -> List[Path]:
    resolved: List[Path] = []
    seen: set[str] = set()
    for raw in raw_inputs:
        if not raw.strip():
            continue
        candidate = Path(raw)
        if not candidate.is_absolute():
            candidate = root / raw
        candidate = candidate.resolve()
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        resolved.append(candidate)
    return resolved


def analyze_inputs(paths: Sequence[Path]) -> Tuple[List[Dict[str, Any]], List[str], List[Dict[str, Any]], List[str], Optional[str]]:
    docs: List[Dict[str, Any]] = []
    claim_index: Dict[str, Dict[str, List[Tuple[str, str]]]] = {}
    disagreements: List[Dict[str, Any]] = []
    missing: List[str] = []
    candidate_scores: List[Tuple[int, str]] = []

    for path in paths:
        if not path.is_file():
            missing.append(f"input missing on disk: {path.as_posix()}")
        claims = important_claims(path)
        label = path.name
        docs.append(
            {
                "path": path,
                "label": label,
                "claims": claims,
            }
        )
        score = 0
        for section, items in claims.items():
            for item in items:
                normalized = normalize_claim(item)
                claim_index.setdefault(section, {}).setdefault(normalized, []).append((label, item))
                if section in {"## Verified Facts", "## Validation Or Acceptance", "## Revised Judgement"}:
                    if any(token in normalized for token in ["ok", "pass", "success", "compiled", "accepted", "valid", "consistent"]):
                        score += 2
                    if any(token in normalized for token in ["fail", "error", "missing", "blocked", "conflict", "unresolved", "hang"]):
                        score -= 2
                if section == "## Remaining Risks":
                    score -= 1
        candidate_scores.append((score, label))

    agreements: List[str] = []
    for section, mapping in claim_index.items():
        for entries in mapping.values():
            labels = sorted({label for label, _raw in entries})
            if len(labels) >= 2:
                agreements.append(f"[{section}] {entries[0][1]} (shared by {', '.join(labels)})")

    for section in sorted(claim_index):
        section_docs = []
        for doc in docs:
            items = doc["claims"].get(section, [])
            if items:
                section_docs.append((doc["label"], items))
        if len(section_docs) < 2:
            continue
        normalized_sets = [set(normalize_claim(item) for item in items) for _label, items in section_docs]
        shared = set.intersection(*normalized_sets) if normalized_sets else set()
        union = set.union(*normalized_sets) if normalized_sets else set()
        if union - shared:
            disagreements.append(
                {
                    "section": section,
                    "entries": section_docs,
                }
            )

    if len(docs) < 2:
        missing.append("fewer than two comparable artifacts were available; adjudication is currently a summary, not a cross-worker comparison")
    if not agreements:
        missing.append("no exact shared claims were found across the provided artifacts")
    for section in ["## Verified Facts", "## Validation Or Acceptance"]:
        if sum(1 for doc in docs if doc["claims"].get(section)) < 1:
            missing.append(f"no artifact provided a usable `{section}` section")

    preferred_label: Optional[str] = None
    if candidate_scores:
        ordered = sorted(candidate_scores, reverse=True)
        if len(ordered) == 1 or ordered[0][0] > ordered[1][0]:
            preferred_label = ordered[0][1]

    return docs, agreements, disagreements, missing, preferred_label


def recommended_next_step(
    root: Path,
    task_id: str,
    *,
    decision: str,
    disagreements: Sequence[Dict[str, Any]],
    missing: Sequence[str],
    preferred_label: Optional[str],
) -> Tuple[str, List[str]]:
    target = str(root)
    rationale: List[str] = []

    if disagreements:
        rationale.append("there are unresolved disagreements across worker artifacts")
    if missing:
        rationale.append("evidence is still incomplete")
    if preferred_label:
        rationale.append(f"tentative preferred artifact: {preferred_label}")

    if decision == "close_review" and not disagreements and not missing:
        command = f"bash scripts/close_task.sh --task {task_id} --to review --target {target}"
        rationale.append("feedback evidence is coherent enough for human review gate")
        return command, rationale
    if decision == "reopen":
        command = f"bash scripts/reopen_task.sh --task {task_id} --to ready --reason 'adjudication requested follow-up' --target {target}"
        rationale.append("main brain asked for another bounded worker pass")
        return command, rationale
    if decision == "cancel":
        command = f"bash scripts/cancel_task.sh --task {task_id} --reason 'adjudication requested cancellation' --target {target}"
        rationale.append("main brain requested explicit cancellation instead of silent drift")
        return command, rationale
    return "manual main-brain decision required", rationale


def adjudicate_task(
    root: Path,
    task_id: str,
    *,
    inputs: Sequence[str],
    mode: str,
    output: str,
    decision: str,
    note: str,
) -> str:
    ensure_instance_root(root)
    state = load_runtime_state(root)
    task = task_from_id(state, task_id)
    paths = resolve_inputs(root, inputs) if inputs else default_inputs(root, state, task_id)
    docs, agreements, disagreements, missing, preferred_label = analyze_inputs(paths)
    command, rationale = recommended_next_step(
        root,
        task_id,
        decision=decision,
        disagreements=disagreements,
        missing=missing,
        preferred_label=preferred_label,
    )

    if output:
        output_path = Path(output)
        if not output_path.is_absolute():
            output_path = root / output
    else:
        output_path = root / "project/output/review" / f"{task_id}_adjudication.md"

    lines = [
        "# Adjudication Draft",
        "",
        "## Task",
        f"- task_id: `{task['task_id']}`",
        f"- role: `{task['role']}`",
        f"- title: {task['title']}",
        f"- status: `{task['status']}`",
        f"- owner: `{task['owner'] or '-'}`",
        f"- mode: `{mode}`",
        f"- generated_at: `{current_timestamp()}`",
        f"- requested_decision: `{decision}`",
    ]
    if note:
        lines.append(f"- note: {note}")

    lines.extend(["", "## Inputs Considered"])
    if not docs:
        lines.append("- none")
    else:
        for doc in docs:
            sections = ", ".join(sorted(doc["claims"])) if doc["claims"] else "none"
            lines.append(f"- `{relref(root, doc['path'])}`")
            lines.append(f"  - sections: {sections}")

    lines.extend(["", "## Agreements"])
    if not agreements:
        lines.append("- none")
    else:
        for item in agreements:
            lines.append(f"- {item}")

    lines.extend(["", "## Disagreements"])
    if not disagreements:
        lines.append("- none")
    else:
        for entry in disagreements:
            lines.append(f"- `{entry['section']}`")
            for label, items in entry["entries"]:
                rendered = "; ".join(items[:4])
                lines.append(f"  - {label}: {rendered}")

    lines.extend(["", "## Missing Evidence"])
    if not missing:
        lines.append("- none")
    else:
        for item in missing:
            lines.append(f"- {item}")

    lines.extend(["", "## Recommended Next Step"])
    lines.append(f"- recommendation: {command}")
    if preferred_label:
        lines.append(f"- tentative_preferred_artifact: `{preferred_label}`")
    if rationale:
        for item in rationale:
            lines.append(f"- rationale: {item}")
    else:
        lines.append("- rationale: human review is still required")

    lines.extend(
        [
            "",
            "## Main Brain Decision Placeholder",
            "- final_decision: ",
            "- accepted_inputs: ",
            "- rationale: ",
            "- follow_up_command: ",
        ]
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return relref(root, output_path)


def latest_checked_after(path: Path, event: Optional[Dict[str, Any]]) -> bool:
    if not path.is_file() or event is None:
        return False
    return parse_timestamp(event["timestamp"]) >= path.stat().st_mtime


def main_brain_summary(root: Path) -> str:
    ensure_instance_root(root)
    state = load_runtime_state(root)
    tasks = task_map(state)
    events = load_events(root)
    paper_env = parse_kv_env(root / "project/paper/runtime/paper.env")

    active: List[str] = []
    failed_or_blocked: List[str] = []
    feedback_ready: List[str] = []
    adjudication_candidates: List[str] = []
    decision_queue: List[str] = []

    for task_id, task in sorted(tasks.items()):
        task_events = [event for event in events if event["task_id"] == task_id]
        latest_failure = last_event_of_type(task_events, "worker.failed")
        latest_review_check = last_event_of_type(task_events, "review.checked")
        latest_retro_check = last_event_of_type(task_events, "retrospective.checked")
        feedback_path = root / task["feedback_path"]
        retro_path = root / task["retrospective_path"]
        feedback = artifact_status(feedback_path, FEEDBACK_HEADINGS)
        retro = artifact_status(retro_path, RETRO_HEADINGS)

        if task["status"] == "in_progress":
            active.append(f"{task_id} | owner={task['owner'] or '-'}")
        if task["status"] == "blocked":
            failed_or_blocked.append(f"{task_id} | blocked")
        elif latest_failure is not None:
            failed_or_blocked.append(f"{task_id} | latest_failure={latest_failure['timestamp']}")

        if feedback["state"] == "valid" and not latest_checked_after(feedback_path, latest_review_check) and task["status"] in {"in_progress", "review"}:
            feedback_ready.append(f"{task_id} | feedback ready for check")
        if retro["state"] == "valid" and not latest_checked_after(retro_path, latest_retro_check) and task["status"] in {"review", "done"}:
            feedback_ready.append(f"{task_id} | retrospective ready for check")

        candidate_inputs = comparison_input_candidates(root, state, task_id)
        if ((task["status"] != "done") and len(candidate_inputs) >= 2) or collect_adjudication_artifacts(root, task_id):
            adjudication_candidates.append(f"{task_id} | inputs={len(candidate_inputs)}")

        if task["status"] == "review":
            decision_queue.append(f"{task_id} | review gate active")
        elif task["status"] == "blocked":
            decision_queue.append(f"{task_id} | decide reopen or keep blocked")
        elif task["status"] == "in_progress" and feedback["state"] == "valid":
            decision_queue.append(f"{task_id} | decide check/close after reading feedback")

    lines = [
        "# Main-Brain Summary",
        "",
        f"- generated_at: `{current_timestamp()}`",
        f"- paper_entrypoint: `{paper_env.get('PAPER_ACTIVE_ENTRYPOINT', '')}`",
        "",
        "## Active Tasks",
    ]
    lines.extend([f"- {item}" for item in active] or ["- none"])
    lines.extend(["", "## Failed Or Blocked"])
    lines.extend([f"- {item}" for item in failed_or_blocked] or ["- none"])
    lines.extend(["", "## Feedback / Retrospective Ready For Check"])
    lines.extend([f"- {item}" for item in feedback_ready] or ["- none"])
    lines.extend(["", "## Adjudication Candidates"])
    lines.extend([f"- {item}" for item in adjudication_candidates] or ["- none"])
    lines.extend(["", "## Decision Queue"])
    lines.extend([f"- {item}" for item in decision_queue] or ["- none"])
    return "\n".join(lines) + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    show_task_parser = subparsers.add_parser("show-task")
    show_task_parser.add_argument("--root", required=True)
    show_task_parser.add_argument("--task", required=True)

    list_history_parser = subparsers.add_parser("list-history")
    list_history_parser.add_argument("--root", required=True)
    list_history_parser.add_argument("--task", required=True)
    list_history_parser.add_argument("--latest", type=int, default=20)
    list_history_parser.add_argument("--event-type", default="")
    list_history_parser.add_argument("--actor", default="")

    adjudicate_parser = subparsers.add_parser("adjudicate")
    adjudicate_parser.add_argument("--root", required=True)
    adjudicate_parser.add_argument("--task", required=True)
    adjudicate_parser.add_argument("--inputs", default="")
    adjudicate_parser.add_argument("--mode", default="compare", choices=["compare", "summarize", "choose"])
    adjudicate_parser.add_argument("--output", default="")
    adjudicate_parser.add_argument("--decision", default="manual", choices=["close_review", "reopen", "cancel", "manual"])
    adjudicate_parser.add_argument("--note", default="")

    summary_parser = subparsers.add_parser("main-brain-summary")
    summary_parser.add_argument("--root", required=True)
    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    if args.command == "show-task":
        sys.stdout.write(show_task(root, args.task))
        return 0

    if args.command == "list-history":
        sys.stdout.write(
            list_history(
                root,
                args.task,
                latest=args.latest,
                event_type=args.event_type,
                actor=args.actor,
            )
        )
        return 0

    if args.command == "adjudicate":
        inputs = [item.strip() for item in args.inputs.split(",") if item.strip()]
        output_ref = adjudicate_task(
            root,
            args.task,
            inputs=inputs,
            mode=args.mode,
            output=args.output,
            decision=args.decision,
            note=args.note,
        )
        print(f"[workflow] adjudication written to {output_ref}")
        return 0

    if args.command == "main-brain-summary":
        sys.stdout.write(main_brain_summary(root))
        return 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
