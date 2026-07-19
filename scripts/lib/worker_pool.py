#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterator, Sequence


BACKENDS = {"native_subagent", "codex_exec"}
STATUSES = {"idle", "busy", "stale", "closed"}


def fail(message: str) -> None:
    raise SystemExit(message)


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def pool_path(root: Path) -> Path:
    return root / "project/runtime/worker_pool.json"


@contextmanager
def locked_pool(root: Path) -> Iterator[None]:
    lock_path = root / "project/runtime/.worker_pool.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def load_pool(root: Path) -> Dict[str, Any]:
    path = pool_path(root)
    if not path.is_file():
        fail(f"missing worker pool: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"invalid worker pool JSON: {exc}")
    validate_pool(payload)
    return payload


def validate_pool(payload: Dict[str, Any]) -> None:
    if not isinstance(payload, dict):
        fail("worker_pool.json must contain an object")
    for field in ("schema_version", "pool_generation", "max_open_threads", "core_workers", "workers", "history"):
        if field not in payload:
            fail(f"worker_pool.json missing field: {field}")
    if payload["schema_version"] != 1:
        fail("worker_pool.json schema_version must be 1")
    if not isinstance(payload["max_open_threads"], int) or payload["max_open_threads"] < 1:
        fail("worker_pool.json max_open_threads must be a positive integer")
    if not isinstance(payload["core_workers"], list) or not all(isinstance(item, str) and item for item in payload["core_workers"]):
        fail("worker_pool.json core_workers must be a list of non-empty strings")
    if len(set(payload["core_workers"])) != len(payload["core_workers"]):
        fail("worker_pool.json core_workers contains duplicates")
    if not isinstance(payload["workers"], dict):
        fail("worker_pool.json workers must be an object")
    if not isinstance(payload["history"], list):
        fail("worker_pool.json history must be a list")
    seen_sessions: set[tuple[str, str]] = set()
    for key, worker in payload["workers"].items():
        if not isinstance(worker, dict):
            fail(f"worker pool entry {key} must be an object")
        for field in ("role", "backend", "session_id", "status", "current_task_id", "last_task_id", "parent_session_id", "updated_at"):
            if field not in worker:
                fail(f"worker pool entry {key} missing field: {field}")
        if worker["backend"] not in BACKENDS:
            fail(f"worker pool entry {key} has invalid backend: {worker['backend']}")
        if worker["status"] not in STATUSES:
            fail(f"worker pool entry {key} has invalid status: {worker['status']}")
        if not worker["session_id"]:
            fail(f"worker pool entry {key} must define session_id")
        identity = (worker["backend"], worker["session_id"])
        if worker["status"] not in {"stale", "closed"} and identity in seen_sessions:
            fail(f"active worker session is registered more than once: {worker['session_id']}")
        if worker["status"] not in {"stale", "closed"}:
            seen_sessions.add(identity)
        if worker["status"] == "busy" and not worker["current_task_id"]:
            fail(f"busy worker pool entry {key} must define current_task_id")
        if worker["status"] != "busy" and worker["current_task_id"]:
            fail(f"non-busy worker pool entry {key} must clear current_task_id")


def save_pool(root: Path, payload: Dict[str, Any]) -> None:
    validate_pool(payload)
    path = pool_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def append_history(pool: Dict[str, Any], action: str, worker_key: str, actor: str, **details: Any) -> None:
    entry = {
        "timestamp": now(),
        "action": action,
        "worker_key": worker_key,
        "actor": actor or "main_brain",
    }
    entry.update({key: value for key, value in details.items() if value not in ("", None)})
    pool["history"].append(entry)


def task_role(root: Path, task_id: str) -> str:
    path = root / "project/runtime/task_registry.json"
    try:
        registry = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read task registry: {exc}")
    for task in registry.get("tasks", []):
        if task.get("task_id") == task_id:
            return str(task.get("role", ""))
    fail(f"unknown task id: {task_id}")
    return ""


def active_task_ids(root: Path) -> set[str]:
    path = root / "project/runtime/work_queue.json"
    try:
        queue = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read work queue: {exc}")
    return {str(item.get("task_id", "")) for item in queue.get("active_items", [])}


def worker_for(pool: Dict[str, Any], worker_key: str) -> Dict[str, Any]:
    worker = pool["workers"].get(worker_key)
    if worker is None:
        fail(f"unknown worker key: {worker_key}")
    return worker


def ensure_capacity(pool: Dict[str, Any], replacing: str = "") -> None:
    open_workers = [
        key for key, worker in pool["workers"].items()
        if worker["status"] not in {"stale", "closed"} and key != replacing
    ]
    if len(open_workers) >= pool["max_open_threads"]:
        fail(
            f"worker pool is at capacity ({len(open_workers)}/{pool['max_open_threads']}); "
            "close an idle burst worker before registering another session"
        )


def command_status(root: Path, args: argparse.Namespace) -> None:
    pool = load_pool(root)
    if args.json:
        print(json.dumps(pool, ensure_ascii=True, indent=2))
        return
    open_count = sum(worker["status"] not in {"stale", "closed"} for worker in pool["workers"].values())
    print("Worker Pool")
    print(f"  generation: {pool['pool_generation']}")
    print(f"  open: {open_count}/{pool['max_open_threads']}")
    if not pool["workers"]:
        print("  workers: none registered")
        return
    for key in sorted(pool["workers"]):
        worker = pool["workers"][key]
        core = "core" if key in pool["core_workers"] else "burst"
        current = worker["current_task_id"] or "-"
        print(
            f"  - {key}: {worker['status']} backend={worker['backend']} "
            f"session={worker['session_id']} task={current} {core}"
        )


def command_register(root: Path, args: argparse.Namespace) -> None:
    with locked_pool(root):
        pool = load_pool(root)
        existing = pool["workers"].get(args.worker_key)
        if existing and existing["status"] not in {"stale", "closed"}:
            if existing["backend"] == args.backend and existing["session_id"] == args.session_id:
                print(f"[worker_pool] already registered: {args.worker_key}")
                return
            fail(f"worker key {args.worker_key} is already open; mark it stale or closed before replacing it")
        if existing and existing["status"] in {"stale", "closed"} and not args.replace:
            fail(f"worker key {args.worker_key} is {existing['status']}; use --replace to register its replacement")
        ensure_capacity(pool, replacing=args.worker_key if existing else "")
        for key, worker in pool["workers"].items():
            if key != args.worker_key and worker["status"] not in {"stale", "closed"}:
                if worker["backend"] == args.backend and worker["session_id"] == args.session_id:
                    fail(f"session {args.session_id} is already registered as {key}")
        pool["workers"][args.worker_key] = {
            "role": args.role,
            "backend": args.backend,
            "session_id": args.session_id,
            "status": "idle",
            "current_task_id": "",
            "last_task_id": args.last_task,
            "parent_session_id": args.parent_session_id,
            "updated_at": now(),
        }
        append_history(
            pool,
            "register",
            args.worker_key,
            args.actor,
            role=args.role,
            backend=args.backend,
            session_id=args.session_id,
            replaced=bool(existing),
        )
        save_pool(root, pool)
    print(f"[worker_pool] registered {args.worker_key} ({args.backend})")


def validate_assignment(root: Path, pool: Dict[str, Any], worker_key: str, task_id: str, session_id: str) -> Dict[str, Any]:
    worker = worker_for(pool, worker_key)
    if worker["status"] not in {"idle", "busy"}:
        fail(f"worker {worker_key} is {worker['status']} and cannot accept work")
    if worker["status"] == "busy" and worker["current_task_id"] != task_id:
        fail(f"worker {worker_key} is already busy with {worker['current_task_id']}")
    if session_id and worker["session_id"] != session_id:
        fail(f"worker {worker_key} session mismatch")
    role = task_role(root, task_id)
    if worker["role"] != role:
        fail(f"worker {worker_key} role {worker['role']} does not match task role {role}")
    if task_id not in active_task_ids(root):
        fail(f"task {task_id} must be claimed before assigning a pool worker")
    return worker


def command_check_assignment(root: Path, args: argparse.Namespace) -> None:
    pool = load_pool(root)
    validate_assignment(root, pool, args.worker_key, args.task, args.session_id)
    print(f"[worker_pool] assignment is valid: {args.worker_key} -> {args.task}")


def command_check_worker(root: Path, args: argparse.Namespace) -> None:
    pool = load_pool(root)
    worker = worker_for(pool, args.worker_key)
    if worker["status"] not in {"idle", "busy"}:
        fail(f"worker {args.worker_key} is {worker['status']} and cannot accept work")
    if worker["status"] == "busy" and worker["current_task_id"] != args.task:
        fail(f"worker {args.worker_key} is already busy with {worker['current_task_id']}")
    if args.session_id and worker["session_id"] != args.session_id:
        fail(f"worker {args.worker_key} session mismatch")
    if args.role and worker["role"] != args.role:
        fail(f"worker {args.worker_key} role {worker['role']} does not match requested role {args.role}")
    print(f"[worker_pool] worker is reusable: {args.worker_key}")


def command_assign(root: Path, args: argparse.Namespace) -> None:
    with locked_pool(root):
        pool = load_pool(root)
        worker = validate_assignment(root, pool, args.worker_key, args.task, args.session_id)
        worker["status"] = "busy"
        worker["current_task_id"] = args.task
        worker["updated_at"] = now()
        append_history(pool, "assign", args.worker_key, args.actor, task_id=args.task)
        save_pool(root, pool)
    print(f"[worker_pool] assigned {args.worker_key} -> {args.task}")


def command_mark_idle(root: Path, args: argparse.Namespace) -> None:
    with locked_pool(root):
        pool = load_pool(root)
        worker = worker_for(pool, args.worker_key)
        if args.task and worker["current_task_id"] not in {"", args.task}:
            fail(f"worker {args.worker_key} is assigned to {worker['current_task_id']}, not {args.task}")
        last_task = args.task or worker["current_task_id"] or worker["last_task_id"]
        worker["status"] = "idle"
        worker["current_task_id"] = ""
        worker["last_task_id"] = last_task
        worker["updated_at"] = now()
        append_history(pool, "idle", args.worker_key, args.actor, task_id=last_task)
        save_pool(root, pool)
    print(f"[worker_pool] idle: {args.worker_key}")


def command_terminal(root: Path, args: argparse.Namespace, status: str) -> None:
    with locked_pool(root):
        pool = load_pool(root)
        worker = worker_for(pool, args.worker_key)
        if worker["status"] == "busy" and not args.force:
            fail(f"worker {args.worker_key} is busy; pass --force only after stopping or losing the session")
        last_task = worker["current_task_id"] or worker["last_task_id"]
        worker["status"] = status
        worker["current_task_id"] = ""
        worker["last_task_id"] = last_task
        worker["updated_at"] = now()
        append_history(pool, status, args.worker_key, args.actor, task_id=last_task, reason=args.reason)
        save_pool(root, pool)
    print(f"[worker_pool] {status}: {args.worker_key}")


def command_select(root: Path, args: argparse.Namespace) -> None:
    pool = load_pool(root)
    candidates = [
        (key, worker) for key, worker in pool["workers"].items()
        if worker["role"] == args.role
        and worker["status"] == "idle"
        and (not args.backend or worker["backend"] == args.backend)
    ]
    candidates.sort(key=lambda item: (item[0] not in pool["core_workers"], item[1]["updated_at"], item[0]))
    if not candidates:
        raise SystemExit(1)
    key, worker = candidates[0]
    if args.json:
        print(json.dumps({"worker_key": key, **worker}, ensure_ascii=True, indent=2))
    else:
        print(f"{key}\t{worker['backend']}\t{worker['session_id']}")


def command_close_all(root: Path, args: argparse.Namespace) -> None:
    with locked_pool(root):
        pool = load_pool(root)
        busy = [key for key, worker in pool["workers"].items() if worker["status"] == "busy"]
        if busy and not args.force:
            fail(f"cannot close all while workers are busy: {', '.join(sorted(busy))}")
        for key, worker in pool["workers"].items():
            if worker["status"] == "closed":
                continue
            last_task = worker["current_task_id"] or worker["last_task_id"]
            worker["status"] = "closed"
            worker["current_task_id"] = ""
            worker["last_task_id"] = last_task
            worker["updated_at"] = now()
            append_history(pool, "closed", key, args.actor, task_id=last_task, reason=args.reason)
        save_pool(root, pool)
    print("[worker_pool] all registered workers marked closed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status")
    status.add_argument("--json", action="store_true")

    register = subparsers.add_parser("register")
    register.add_argument("--worker-key", required=True)
    register.add_argument("--role", required=True)
    register.add_argument("--backend", required=True, choices=sorted(BACKENDS))
    register.add_argument("--session-id", required=True)
    register.add_argument("--parent-session-id", default="")
    register.add_argument("--last-task", default="")
    register.add_argument("--actor", default="main_brain")
    register.add_argument("--replace", action="store_true")

    for name in ("check-assignment", "assign"):
        command = subparsers.add_parser(name)
        command.add_argument("--worker-key", required=True)
        command.add_argument("--task", required=True)
        command.add_argument("--session-id", default="")
        command.add_argument("--actor", default="main_brain")

    check_worker = subparsers.add_parser("check-worker")
    check_worker.add_argument("--worker-key", required=True)
    check_worker.add_argument("--role", default="")
    check_worker.add_argument("--task", default="")
    check_worker.add_argument("--session-id", default="")

    idle = subparsers.add_parser("mark-idle")
    idle.add_argument("--worker-key", required=True)
    idle.add_argument("--task", default="")
    idle.add_argument("--actor", default="main_brain")

    for name in ("mark-stale", "close"):
        command = subparsers.add_parser(name)
        command.add_argument("--worker-key", required=True)
        command.add_argument("--reason", required=True)
        command.add_argument("--actor", default="main_brain")
        command.add_argument("--force", action="store_true")

    select = subparsers.add_parser("select")
    select.add_argument("--role", required=True)
    select.add_argument("--backend", choices=[""] + sorted(BACKENDS), default="")
    select.add_argument("--json", action="store_true")

    close_all = subparsers.add_parser("close-all")
    close_all.add_argument("--reason", required=True)
    close_all.add_argument("--actor", default="main_brain")
    close_all.add_argument("--force", action="store_true")
    return parser


def main(argv: Sequence[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if args.command == "status":
        command_status(root, args)
    elif args.command == "register":
        command_register(root, args)
    elif args.command == "check-assignment":
        command_check_assignment(root, args)
    elif args.command == "check-worker":
        command_check_worker(root, args)
    elif args.command == "assign":
        command_assign(root, args)
    elif args.command == "mark-idle":
        command_mark_idle(root, args)
    elif args.command == "mark-stale":
        command_terminal(root, args, "stale")
    elif args.command == "close":
        command_terminal(root, args, "closed")
    elif args.command == "select":
        command_select(root, args)
    elif args.command == "close-all":
        command_close_all(root, args)
    else:
        parser.error(f"unknown command: {args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))
