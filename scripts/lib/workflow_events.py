#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from workflow_state import (
    current_timestamp,
    detect_root_kind,
    fail,
    init_feedback_files,
    load_runtime_state,
    load_structured,
    normalize_relpath,
    task_from_id,
    write_queue_board,
)


REQUIRED_EVENT_FIELDS = [
    "timestamp",
    "event_id",
    "event_type",
    "task_id",
    "role",
    "actor",
    "owner",
    "from_status",
    "to_status",
    "artifacts",
    "note",
    "metadata",
]

ALLOWED_ACTIONS = {
    "refresh_queue_board",
    "render_main_brain_queue",
    "write_run_summary",
    "emit_next_action_hint",
    "ensure_feedback_skeleton",
    "ensure_retrospective_skeleton",
    "mark_worker_failure_note",
    "suggest_reopen",
    "suggest_close_review",
    "suggest_cancel",
}


def event_log_path(root: Path) -> Path:
    return root / "project/runtime/event_log.jsonl"


def callback_hooks_path(root: Path) -> Path:
    return root / "project/spec/callback_hooks.yaml"


def callback_run_dir(root: Path) -> Path:
    return root / "project/output/review/callback_runs"


def relref(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def normalize_artifact(root: Path, ref: str) -> str:
    if not ref:
        return ref
    candidate = Path(ref)
    if candidate.is_absolute():
        return relref(root, candidate)
    return normalize_relpath(ref)


def parse_scalar(value: str) -> Any:
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered == "null":
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def parse_metadata(entries: Sequence[str]) -> Dict[str, Any]:
    metadata: Dict[str, Any] = {}
    for entry in entries:
        if "=" not in entry:
            fail(f"invalid metadata entry: {entry}")
        key, raw_value = entry.split("=", 1)
        key = key.strip()
        if not key:
            fail(f"invalid metadata key in entry: {entry}")
        metadata[key] = parse_scalar(raw_value.strip())
    return metadata


def validate_event_object(event: Dict[str, Any], *, context: str) -> None:
    missing = [field for field in REQUIRED_EVENT_FIELDS if field not in event]
    if missing:
        fail(f"{context} missing fields: {', '.join(missing)}")
    if not isinstance(event["artifacts"], list):
        fail(f"{context} field 'artifacts' must be a list")
    if not isinstance(event["metadata"], dict):
        fail(f"{context} field 'metadata' must be an object")


def load_events(root: Path) -> List[Dict[str, Any]]:
    path = event_log_path(root)
    if not path.is_file():
        fail(f"missing file: {path}")
    events: List[Dict[str, Any]] = []
    for lineno, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"invalid JSONL in {path} line {lineno}: {exc}")
        if not isinstance(payload, dict):
            fail(f"invalid event payload in {path} line {lineno}: must be an object")
        validate_event_object(payload, context=f"event_log line {lineno}")
        events.append(payload)
    return events


def load_hook_config(root: Path) -> Dict[str, Any]:
    path = callback_hooks_path(root)
    payload = load_structured(path)
    if not isinstance(payload, dict):
        fail("project/spec/callback_hooks.yaml must contain an object")
    if "schema_version" not in payload:
        fail("callback_hooks.yaml missing schema_version")
    if "hooks" not in payload or not isinstance(payload["hooks"], list):
        fail("callback_hooks.yaml must define a top-level hooks array")
    for hook in payload["hooks"]:
        if not isinstance(hook, dict):
            fail("each callback hook must be an object")
        for field in ["name", "on", "when", "actions", "enabled"]:
            if field not in hook:
                fail(f"callback hook missing field: {field}")
        if not isinstance(hook["on"], list) or not hook["on"]:
            fail(f"callback hook {hook['name']} field 'on' must be a non-empty list")
        if not isinstance(hook["when"], dict):
            fail(f"callback hook {hook['name']} field 'when' must be an object")
        if not isinstance(hook["actions"], list) or not hook["actions"]:
            fail(f"callback hook {hook['name']} field 'actions' must be a non-empty list")
        if not isinstance(hook["enabled"], bool):
            fail(f"callback hook {hook['name']} field 'enabled' must be boolean")
        for action in hook["actions"]:
            if not isinstance(action, dict) or "type" not in action:
                fail(f"callback hook {hook['name']} contains an invalid action")
            action_type = action["type"]
            if action_type not in ALLOWED_ACTIONS:
                fail(f"callback hook {hook['name']} references unsupported action: {action_type}")
    return payload


def select_event(events: Sequence[Dict[str, Any]], *, event_id: str, latest: bool, replay_from: str) -> List[Dict[str, Any]]:
    if replay_from:
        selected: List[Dict[str, Any]] = []
        matched = False
        for event in events:
            if event["event_id"] == replay_from:
                matched = True
            if matched:
                selected.append(event)
        if not matched:
            fail(f"unknown event_id for replay: {replay_from}")
        return selected
    if event_id:
        for event in events:
            if event["event_id"] == event_id:
                return [event]
        fail(f"unknown event_id: {event_id}")
    if latest or not events:
        if not events:
            fail("event log is empty")
        return [events[-1]]
    return [events[-1]]


def matches_when(event: Dict[str, Any], when: Dict[str, Any]) -> bool:
    checks = [
        ("task_id_in", event["task_id"]),
        ("role_in", event["role"]),
        ("actor_in", event["actor"]),
        ("owner_in", event["owner"]),
        ("from_status_in", event["from_status"]),
        ("to_status_in", event["to_status"]),
    ]
    for key, value in checks:
        if key in when:
            allowed = when[key]
            if not isinstance(allowed, list) or value not in allowed:
                return False
    if "note_contains" in when:
        needle = str(when["note_contains"])
        if needle not in event["note"]:
            return False
    if "owner_present" in when:
        if bool(event["owner"]) != bool(when["owner_present"]):
            return False
    if "metadata_equals" in when:
        expected = when["metadata_equals"]
        if not isinstance(expected, dict):
            return False
        for key, value in expected.items():
            if event["metadata"].get(key) != value:
                return False
    return True


def derive_hint(event: Dict[str, Any]) -> str:
    event_type = event["event_type"]
    task_id = event["task_id"]
    if event_type == "task.dispatched":
        return f"Inspect the packet for {task_id}, then decide whether to relay it manually or launch bash scripts/run_exec_worker.sh."
    if event_type == "worker.started":
        return f"Worker {task_id} is running. Wait for worker.completed or worker.failed before adjudicating."
    if event_type == "worker.completed":
        return f"Inspect the worker reply for {task_id}, then run check_worker_feedback.sh before deciding close/reopen/cancel."
    if event_type == "worker.failed":
        return f"Inspect the worker failure artifact for {task_id}, then decide whether to cancel or reopen the task."
    if event_type == "review.checked":
        return f"Feedback gate passed for {task_id}. Main brain may now decide whether the task should move to review."
    if event_type == "retrospective.checked":
        return f"Retrospective gate passed for {task_id}. Human acceptance is still required before any done-level close."
    return f"Review event {event_type} for {task_id} and decide the next human-gated step."


def write_markdown(path: Path, lines: Sequence[str]) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return path.as_posix()


def run_callback_action(root: Path, event: Dict[str, Any], action: Dict[str, Any], *, dry_run: bool) -> Dict[str, Any]:
    action_type = action["type"]
    state = load_runtime_state(root)
    task = task_from_id(state, event["task_id"])

    if action_type in {"refresh_queue_board", "render_main_brain_queue"}:
        artifact = "project/workflow/MAIN_BRAIN_QUEUE.md"
        if not dry_run:
            write_queue_board(root, state)
        return {"action": action_type, "status": "ok", "artifacts": [artifact]}

    if action_type == "ensure_feedback_skeleton":
        if dry_run:
            return {
                "action": action_type,
                "status": "dry-run",
                "artifacts": [task["feedback_path"]],
            }
        results = init_feedback_files(
            root,
            state,
            event["task_id"],
            create_feedback=True,
            create_retrospective=False,
        )
        return {
            "action": action_type,
            "status": "ok",
            "artifacts": [task["feedback_path"]],
            "results": results,
        }

    if action_type == "ensure_retrospective_skeleton":
        if dry_run:
            return {
                "action": action_type,
                "status": "dry-run",
                "artifacts": [task["retrospective_path"]],
            }
        results = init_feedback_files(
            root,
            state,
            event["task_id"],
            create_feedback=False,
            create_retrospective=True,
        )
        return {
            "action": action_type,
            "status": "ok",
            "artifacts": [task["retrospective_path"]],
            "results": results,
        }

    if action_type == "write_run_summary":
        summary_path = callback_run_dir(root) / f"{event['event_id']}__summary.md"
        lines = [
            "# Callback Run Summary",
            "",
            f"- event_id: `{event['event_id']}`",
            f"- event_type: `{event['event_type']}`",
            f"- task_id: `{event['task_id']}`",
            f"- role: `{event['role']}`",
            f"- actor: `{event['actor']}`",
            f"- owner: `{event['owner']}`",
            f"- from_status: `{event['from_status']}`",
            f"- to_status: `{event['to_status']}`",
        ]
        if event["artifacts"]:
            lines.extend(["", "## Artifacts"])
            for artifact in event["artifacts"]:
                lines.append(f"- `{artifact}`")
        if event["note"]:
            lines.extend(["", "## Note", f"- {event['note']}"])
        if event["metadata"]:
            lines.extend(["", "## Metadata", "```json", json.dumps(event["metadata"], ensure_ascii=True, indent=2), "```"])
        if dry_run:
            return {"action": action_type, "status": "dry-run", "artifacts": [normalize_artifact(root, summary_path.as_posix())]}
        write_markdown(summary_path, lines)
        return {"action": action_type, "status": "ok", "artifacts": [relref(root, summary_path)]}

    if action_type == "emit_next_action_hint":
        hint = str(action.get("hint") or derive_hint(event))
        return {"action": action_type, "status": "ok", "hint": hint}

    if action_type == "mark_worker_failure_note":
        note_path = callback_run_dir(root) / f"{event['event_id']}__worker_failure.md"
        lines = [
            "# Worker Failure Note",
            "",
            f"- task_id: `{event['task_id']}`",
            f"- owner: `{event['owner']}`",
            f"- actor: `{event['actor']}`",
            f"- event_id: `{event['event_id']}`",
            f"- event_type: `{event['event_type']}`",
            "",
            "## Failure Note",
            f"- {event['note'] or 'worker execution failed'}",
        ]
        if event["artifacts"]:
            lines.extend(["", "## Relevant Artifacts"])
            for artifact in event["artifacts"]:
                lines.append(f"- `{artifact}`")
        if dry_run:
            return {"action": action_type, "status": "dry-run", "artifacts": [normalize_artifact(root, note_path.as_posix())]}
        write_markdown(note_path, lines)
        return {"action": action_type, "status": "ok", "artifacts": [relref(root, note_path)]}

    if action_type == "suggest_reopen":
        target_status = str(action.get("to", "ready"))
        reason = str(action.get("reason") or event["note"] or "callback suggested reopen")
        suggestion = (
            f"bash scripts/reopen_task.sh --task {event['task_id']} --to {target_status} "
            f"--reason {json.dumps(reason)} --target {json.dumps(str(root))}"
        )
        return {"action": action_type, "status": "ok", "suggestion": suggestion}

    if action_type == "suggest_close_review":
        target_status = str(action.get("to", "review"))
        suggestion = f"bash scripts/close_task.sh --task {event['task_id']} --to {target_status} --target {json.dumps(str(root))}"
        return {"action": action_type, "status": "ok", "suggestion": suggestion}

    if action_type == "suggest_cancel":
        target_status = str(action.get("to", "blocked"))
        reason = str(action.get("reason") or event["note"] or "callback suggested cancel")
        suggestion = (
            f"bash scripts/cancel_task.sh --task {event['task_id']} --to {target_status} "
            f"--reason {json.dumps(reason)} --target {json.dumps(str(root))}"
        )
        return {"action": action_type, "status": "ok", "suggestion": suggestion}

    fail(f"unsupported callback action: {action_type}")


def process_events(
    root: Path,
    *,
    event_id: str,
    latest: bool,
    replay_from: str,
    dry_run: bool,
) -> List[Dict[str, Any]]:
    events = load_events(root)
    hooks_payload = load_hook_config(root)
    selected = select_event(events, event_id=event_id, latest=latest, replay_from=replay_from)
    reports: List[Dict[str, Any]] = []
    for event in selected:
        for hook in hooks_payload["hooks"]:
            if not hook["enabled"]:
                continue
            if event["event_type"] not in hook["on"]:
                continue
            if not matches_when(event, hook["when"]):
                continue
            action_results = [run_callback_action(root, event, action, dry_run=dry_run) for action in hook["actions"]]
            report = {
                "generated_at": current_timestamp(),
                "event_id": event["event_id"],
                "event_type": event["event_type"],
                "task_id": event["task_id"],
                "hook_name": hook["name"],
                "dry_run": dry_run,
                "action_results": action_results,
            }
            if not dry_run:
                report_path = callback_run_dir(root) / f"{event['event_id']}__{hook['name'].replace(' ', '_')}.json"
                report_path.parent.mkdir(parents=True, exist_ok=True)
                report_path.write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
                report["report_path"] = relref(root, report_path)
            reports.append(report)
    return reports


def emit_event(
    root: Path,
    *,
    event_type: str,
    task_id: str,
    actor: str,
    owner: str,
    from_status: str,
    to_status: str,
    artifacts: Sequence[str],
    note: str,
    metadata: Dict[str, Any],
) -> Dict[str, Any]:
    if detect_root_kind(root) != "instance":
        fail("workflow events can only be emitted inside a rendered instance root")
    state = load_runtime_state(root)
    task = task_from_id(state, task_id)
    resolved_owner = owner if owner else task.get("owner", "")
    event = {
        "timestamp": current_timestamp(),
        "event_id": f"evt_{uuid.uuid4().hex[:12]}",
        "event_type": event_type,
        "task_id": task_id,
        "role": task["role"],
        "actor": actor or resolved_owner or "system",
        "owner": resolved_owner,
        "from_status": from_status,
        "to_status": to_status,
        "artifacts": [normalize_artifact(root, artifact) for artifact in artifacts if artifact],
        "note": note,
        "metadata": metadata,
    }
    validate_event_object(event, context="emitted event")
    path = event_log_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=True) + "\n")
    return event


def validate_event_log(root: Path) -> None:
    if detect_root_kind(root) != "instance":
        fail("event validation expects a rendered instance root")
    load_events(root)
    print("[validate_agent_docs] OK (events)")


def validate_callback_config(root: Path) -> None:
    if detect_root_kind(root) != "instance":
        fail("callback validation expects a rendered instance root")
    load_hook_config(root)
    print("[validate_agent_docs] OK (callbacks)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    emit_parser = subparsers.add_parser("emit")
    emit_parser.add_argument("--root", required=True)
    emit_parser.add_argument("--event-type", required=True)
    emit_parser.add_argument("--task", required=True)
    emit_parser.add_argument("--actor", default="")
    emit_parser.add_argument("--owner", default="")
    emit_parser.add_argument("--from-status", default="")
    emit_parser.add_argument("--to-status", default="")
    emit_parser.add_argument("--artifact", action="append", default=[])
    emit_parser.add_argument("--note", default="")
    emit_parser.add_argument("--metadata", action="append", default=[])

    process_parser = subparsers.add_parser("process")
    process_parser.add_argument("--root", required=True)
    process_parser.add_argument("--event-id", default="")
    process_parser.add_argument("--latest", action="store_true")
    process_parser.add_argument("--replay-from", default="")
    process_parser.add_argument("--dry-run", action="store_true")

    validate_events_parser = subparsers.add_parser("validate-events")
    validate_events_parser.add_argument("--root", required=True)

    validate_callbacks_parser = subparsers.add_parser("validate-callbacks")
    validate_callbacks_parser.add_argument("--root", required=True)
    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    if args.command == "emit":
        event = emit_event(
            root,
            event_type=args.event_type,
            task_id=args.task,
            actor=args.actor,
            owner=args.owner,
            from_status=args.from_status,
            to_status=args.to_status,
            artifacts=args.artifact,
            note=args.note,
            metadata=parse_metadata(args.metadata),
        )
        print(event["event_id"])
        return 0

    if args.command == "process":
        reports = process_events(
            root,
            event_id=args.event_id,
            latest=args.latest,
            replay_from=args.replay_from,
            dry_run=args.dry_run,
        )
        if not reports:
            target_desc = args.event_id or args.replay_from or "latest"
            print(f"[callbacks] no hooks matched for {target_desc}")
            return 0
        for report in reports:
            line = (
                f"[callbacks] event {report['event_id']} -> hook {report['hook_name']} "
                f"({len(report['action_results'])} action(s))"
            )
            if "report_path" in report:
                line += f" [{report['report_path']}]"
            print(line)
        return 0

    if args.command == "validate-events":
        validate_event_log(root)
        return 0

    if args.command == "validate-callbacks":
        validate_callback_config(root)
        return 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
