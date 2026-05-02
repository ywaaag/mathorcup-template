#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
OUTPUT_FORMAT="text"
WRITE=true
OUT_MD=""
OUT_JSON=""

usage() {
    cat <<'EOF'
Usage: bash scripts/artifact_index.sh [--target <dir>] [--json|--format text|json] [--no-write] [--out-md <path>] [--out-json <path>]

Build a read-only index of packets, feedback, retrospectives, callbacks, exec runs, handoffs, and adjudications.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root)
            TARGET_DIR="$(abs_path "$2")"
            shift 2
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --format)
            case "$2" in
                text|json)
                    OUTPUT_FORMAT="$2"
                    shift 2
                    ;;
                *)
                    die "unknown format: $2"
                    ;;
            esac
            ;;
        --no-write)
            WRITE=false
            shift
            ;;
        --out-md)
            OUT_MD="$(abs_path "$2")"
            WRITE=true
            shift 2
            ;;
        --out-json)
            OUT_JSON="$(abs_path "$2")"
            WRITE=true
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

if [[ -z "$OUT_MD" ]]; then
    OUT_MD="$TARGET_DIR/project/output/review/artifact_index.md"
fi
if [[ -z "$OUT_JSON" ]]; then
    OUT_JSON="$TARGET_DIR/project/output/review/artifact_index.json"
fi

ROOT_KIND="$(workflow_root_kind "$SCRIPT_DIR" "$TARGET_DIR")"
if [[ "$ROOT_KIND" != "instance" && "$WRITE" == true ]]; then
    die "artifact_index.sh writes derived review artifacts only for rendered instance roots. Re-run with --target <rendered-instance> or use --no-write for a template-source scan."
fi

python3 - "$TARGET_DIR" "$OUTPUT_FORMAT" "$WRITE" "$OUT_MD" "$OUT_JSON" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
output_format = sys.argv[2]
write = sys.argv[3] == "true"
out_md = Path(sys.argv[4])
out_json = Path(sys.argv[5])

patterns = {
    "packets": ["project/workflow/packets/*.md", "project/output/review/exec_runs/*_exec_packet.md"],
    "feedback": ["project/output/review/*_feedback.md"],
    "retrospectives": ["project/output/retrospectives/*_retrospective.md"],
    "callback_runs": ["project/output/review/callback_runs/*"],
    "exec_runs": ["project/output/review/exec_runs/*"],
    "handoffs": ["project/output/handoff/P*.md"],
    "adjudications": ["project/output/review/*_adjudication*.md"],
    "paper_acceptance": ["project/output/review/paper_acceptance_check.md", "project/output/review/paper_acceptance_check.json"],
    "model_manifests": ["project/output/model_manifest.json"],
}

def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()

def infer_task(path: Path) -> str:
    name = path.name
    match = re.search(r"(TASK_[A-Z0-9_]+)", name)
    if match:
        return match.group(1)
    text = ""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")[:4000]
    except Exception:
        return ""
    match = re.search(r"TASK_[A-Z0-9_]+", text)
    return match.group(0) if match else ""

def item(path: Path, category: str) -> dict:
    return {
        "category": category,
        "path": rel(path),
        "task_id": infer_task(path),
        "size_bytes": path.stat().st_size,
        "mtime": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat(),
    }

entries = []
seen = set()
for category, globs in patterns.items():
    for pattern in globs:
        for path in sorted(root.glob(pattern)):
            if not path.is_file():
                continue
            key = str(path.resolve())
            if key in seen:
                continue
            seen.add(key)
            entries.append(item(path, category))

entries.sort(key=lambda row: (row["task_id"], row["category"], row["path"]))
by_task = {}
by_category = {}
for row in entries:
    by_task.setdefault(row["task_id"] or "-", []).append(row)
    by_category.setdefault(row["category"], 0)
    by_category[row["category"]] += 1

payload = {
    "schema_version": "artifact_index.v1",
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "root": str(root),
    "read_only": not write,
    "writes_artifact": write,
    "output_paths": {
        "markdown": str(out_md) if write else "",
        "json": str(out_json) if write else "",
    },
    "ok": True,
    "status": "OK",
    "counts": {
        "total": len(entries),
        "by_category": by_category,
        "by_task": {task: len(rows) for task, rows in sorted(by_task.items())},
    },
    "artifacts": entries,
}

def render_md(data: dict) -> str:
    lines = [
        "# Artifact Index",
        "",
        f"generated_at: {data['generated_at']}",
        f"root: {data['root']}",
        "",
        "## Counts By Category",
    ]
    if data["counts"]["by_category"]:
        for category, count in sorted(data["counts"]["by_category"].items()):
            lines.append(f"- {category}: {count}")
    else:
        lines.append("- none")
    lines.extend(["", "## Artifacts By Task"])
    for task, rows in sorted(by_task.items()):
        lines.append(f"### {task}")
        for row in rows:
            lines.append(f"- `{row['category']}` `{row['path']}` size={row['size_bytes']} mtime={row['mtime']}")
    return "\n".join(lines) + "\n"

md = render_md(payload)
if write:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(md, encoding="utf-8")
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")

if output_format == "json":
    print(json.dumps(payload, ensure_ascii=True, indent=2))
else:
    print(md, end="")
PY
