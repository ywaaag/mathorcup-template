#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from workflow_kernel.audit_index import check_feedback, check_retrospective, init_feedback_files
from workflow_kernel.packet import make_task_packet
from workflow_kernel.render import list_tasks, write_queue_board
from workflow_kernel.schema import (
    FEEDBACK_HEADINGS,
    REQUIRED_ROLE_FIELDS,
    REQUIRED_TASK_FIELDS,
    RETRO_HEADINGS,
    TASK_STATUSES,
    TEMPLATE_SOURCE_REQUIRED_FILES,
    any_path_matches,
    check_required_paths,
    detect_root_kind,
    ensure_fields,
    fail,
    load_runtime_state,
    load_structured,
    normalize_relpath,
    parse_kv_env,
    path_matches,
    paths_overlap,
    queue_items,
    resolve_config_ref,
    role_map,
    save_structured,
    task_from_id,
    task_map,
    validate_template_source,
)
from workflow_kernel.transitions import (
    append_history,
    batch_check,
    cancel_task,
    claim_task,
    claim_task_impl,
    close_task,
    current_timestamp,
    find_active_queue_item,
    parse_task_locks,
    reopen_task,
    task_field_value,
)
from workflow_kernel.validate import (
    validate_codex_bridge,
    validate_contracts,
    validate_feedback,
    validate_handoffs,
    validate_memory,
    validate_paper_config,
    validate_queue,
    validate_retrospectives,
    validate_roles,
    validate_tasks,
)


def run_validate(root: Path, mode: str) -> None:
    root_kind = detect_root_kind(root)
    if root_kind == "template_source":
        if mode != "template_source":
            fail(
                "template-source repo detected; instance validation modes expect rendered files under project/. "
                "Run `bash scripts/validate_agent_docs.sh --template-source-only`, or render a target via "
                "`bash scripts/setup.sh demo --render-only --target <dir>` and validate that directory."
            )
        validate_template_source(root)
        validate_codex_bridge(root, template_source=True)
        print("[validate_agent_docs] OK (template-source)")
        return

    state = load_runtime_state(root)
    if mode in {"all", "memory"}:
        validate_memory(root)
    if mode in {"all", "handoff"}:
        validate_handoffs(root)
    if mode in {"all", "contracts"}:
        validate_contracts(root)
        validate_codex_bridge(root, template_source=False)
    if mode in {"all", "paper"}:
        validate_paper_config(root)
    if mode in {"all", "roles"}:
        validate_roles(root, state)
    if mode in {"all", "tasks"}:
        validate_tasks(root, state)
    if mode in {"all", "queue"}:
        validate_queue(root, state)
    if mode in {"all", "feedback"}:
        validate_feedback(root, state)
    if mode in {"all", "retrospective"}:
        validate_retrospectives(root, state)
    print("[validate_agent_docs] OK")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--root", required=True)
    validate.add_argument(
        "--mode",
        default="all",
        choices=[
            "all",
            "memory",
            "handoff",
            "contracts",
            "paper",
            "roles",
            "tasks",
            "queue",
            "feedback",
            "retrospective",
            "template_source",
        ],
    )

    root_kind = subparsers.add_parser("root-kind")
    root_kind.add_argument("--root", required=True)

    packet = subparsers.add_parser("task-packet")
    packet.add_argument("--root", required=True)
    packet.add_argument("--role")
    packet.add_argument("--task")

    task_field = subparsers.add_parser("task-field")
    task_field.add_argument("--root", required=True)
    task_field.add_argument("--task", required=True)
    task_field.add_argument(
        "--field",
        required=True,
        choices=[
            "task_id",
            "role",
            "title",
            "status",
            "owner",
            "allowed_paths",
            "parallel_ok",
            "feedback_path",
            "retrospective_path",
            "cwd",
            "acceptance_artifacts",
            "paper_entrypoint",
            "paper_accept_pdf",
            "paper_accept_log",
        ],
    )

    list_tasks_parser = subparsers.add_parser("list-tasks")
    list_tasks_parser.add_argument("--root", required=True)
    list_tasks_parser.add_argument("--role", default="")
    list_tasks_parser.add_argument("--status", default="", choices=[""] + sorted(TASK_STATUSES))
    list_tasks_parser.add_argument("--open-only", action="store_true")

    batch_check_parser = subparsers.add_parser("batch-check")
    batch_check_parser.add_argument("--root", required=True)
    batch_check_parser.add_argument("--task", action="append", default=[])
    batch_check_parser.add_argument("--lock", action="append", default=[])

    claim = subparsers.add_parser("claim-task")
    claim.add_argument("--root", required=True)
    claim.add_argument("--task", required=True)
    claim.add_argument("--owner", required=True)
    claim.add_argument("--lock", action="append", default=[])
    claim.add_argument("--actor", default="")

    close = subparsers.add_parser("close-task")
    close.add_argument("--root", required=True)
    close.add_argument("--task", required=True)
    close.add_argument("--to", required=True)
    close.add_argument("--accepted-by", default="")
    close.add_argument("--actor", default="main_brain")

    cancel = subparsers.add_parser("cancel-task")
    cancel.add_argument("--root", required=True)
    cancel.add_argument("--task", required=True)
    cancel.add_argument("--reason", required=True)
    cancel.add_argument("--actor", default="main_brain")
    cancel.add_argument("--to", default="blocked", choices=["blocked", "ready"])

    reopen = subparsers.add_parser("reopen-task")
    reopen.add_argument("--root", required=True)
    reopen.add_argument("--task", required=True)
    reopen.add_argument("--to", required=True, choices=["ready", "review", "in_progress"])
    reopen.add_argument("--reason", required=True)
    reopen.add_argument("--actor", default="main_brain")
    reopen.add_argument("--owner", default="")
    reopen.add_argument("--lock", action="append", default=[])

    check_feedback_parser = subparsers.add_parser("check-feedback")
    check_feedback_parser.add_argument("--root", required=True)
    check_feedback_parser.add_argument("--task")
    check_feedback_parser.add_argument("--file")

    check_retro_parser = subparsers.add_parser("check-retrospective")
    check_retro_parser.add_argument("--root", required=True)
    check_retro_parser.add_argument("--task")
    check_retro_parser.add_argument("--file")

    render_queue = subparsers.add_parser("render-queue")
    render_queue.add_argument("--root", required=True)

    init_feedback_parser = subparsers.add_parser("init-feedback")
    init_feedback_parser.add_argument("--root", required=True)
    init_feedback_parser.add_argument("--task", required=True)
    init_feedback_parser.add_argument("--feedback-only", action="store_true")
    init_feedback_parser.add_argument("--with-retrospective", action="store_true")
    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve() if hasattr(args, "root") else None

    if args.command == "validate":
        run_validate(root, args.mode)
        return 0

    if args.command == "root-kind":
        print(detect_root_kind(root))
        return 0

    state = load_runtime_state(root)

    if args.command == "task-packet":
        role_name = args.role
        if args.task:
            task = task_from_id(state, args.task)
            if role_name and role_name != task["role"]:
                fail(f"task {args.task} belongs to role {task['role']}, not {role_name}")
            role_name = task["role"]
        if not role_name:
            fail("task-packet requires --role or --task")
        sys.stdout.write(make_task_packet(root, state, role_name, args.task))
        return 0

    if args.command == "task-field":
        print(task_field_value(root, state, args.task, args.field))
        return 0

    if args.command == "list-tasks":
        sys.stdout.write(
            list_tasks(
                state,
                role=args.role,
                status=args.status,
                open_only=args.open_only,
            )
        )
        return 0

    if args.command == "batch-check":
        print(json.dumps(batch_check(root, state, args.task, parse_task_locks(args.lock)), ensure_ascii=True, indent=2))
        return 0

    if args.command == "claim-task":
        claim_task(root, state, args.task, args.owner, args.lock, args.actor)
        print(f"[workflow] claimed task {args.task}")
        return 0

    if args.command == "close-task":
        close_task(root, state, args.task, args.to, args.accepted_by, args.actor)
        print(f"[workflow] closed task {args.task} -> {args.to}")
        return 0

    if args.command == "cancel-task":
        cancel_task(root, state, args.task, args.to, args.reason, args.actor)
        print(f"[workflow] cancelled task {args.task} -> {args.to}")
        return 0

    if args.command == "reopen-task":
        reopen_task(root, state, args.task, args.to, args.reason, args.actor, args.owner, args.lock)
        print(f"[workflow] reopened task {args.task} -> {args.to}")
        return 0

    if args.command == "check-feedback":
        check_feedback(root, state, task_id=args.task, file_path=args.file, require_exists=True)
        print("[workflow] worker feedback OK")
        return 0

    if args.command == "check-retrospective":
        check_retrospective(root, state, task_id=args.task, file_path=args.file, require_exists=True)
        print("[workflow] retrospective OK")
        return 0

    if args.command == "render-queue":
        write_queue_board(root, state)
        print("[workflow] queue board refreshed")
        return 0

    if args.command == "init-feedback":
        if args.feedback_only and args.with_retrospective:
            fail("--feedback-only and --with-retrospective cannot be used together")
        results = init_feedback_files(
            root,
            state,
            args.task,
            create_feedback=True,
            create_retrospective=args.with_retrospective,
        )
        for line in results:
            print(f"[workflow] {line}")
        return 0

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
