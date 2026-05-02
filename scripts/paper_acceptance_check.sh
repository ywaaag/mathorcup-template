#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
OUTPUT_FORMAT="text"
WRITE_REPORT=false
REPORT_OUT=""

usage() {
    cat <<'EOF'
Usage: bash scripts/paper_acceptance_check.sh [--target <dir>] [--json|--format text|json] [--write-report] [--report-out <path>]

Read-only paper acceptance check. It does not build paper files and does not advance workflow state.
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
        --write-report)
            WRITE_REPORT=true
            shift
            ;;
        --report-out)
            REPORT_OUT="$(abs_path "$2")"
            WRITE_REPORT=true
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

load_root_env "$TARGET_DIR"
load_paper_env "$TARGET_DIR"

if [[ -z "$REPORT_OUT" ]]; then
    REPORT_OUT="$TARGET_DIR/project/output/review/paper_acceptance_check.md"
fi

ROOT_KIND="$(workflow_root_kind "$SCRIPT_DIR" "$TARGET_DIR")"
if [[ "$ROOT_KIND" != "instance" && "$WRITE_REPORT" == true ]]; then
    die "paper_acceptance_check.sh writes review reports only for rendered instance roots. Re-run with --target <rendered-instance> or omit --write-report for a template-source scan."
fi

python3 - "$TARGET_DIR" "$OUTPUT_FORMAT" "$WRITE_REPORT" "$REPORT_OUT" <<'PY'
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
output_format = sys.argv[2]
write_report = sys.argv[3] == "true"
report_out = Path(sys.argv[4])

entry = os.environ.get("PAPER_ACTIVE_ENTRYPOINT", "main.tex")
accept_pdf = os.environ.get("PAPER_ACCEPT_PDF", "project/paper/main.pdf")
accept_log = os.environ.get("PAPER_ACCEPT_LOG", "project/paper/main.log")
accept_aux = os.environ.get("PAPER_ACCEPT_AUX", "project/paper/main.aux")
paper_host_rel = os.environ.get("PAPER_HOST_REL_DIR", "project/paper")
paper_build_dir = os.environ.get("PAPER_BUILD_DIR", "")

entry_path = root / paper_host_rel / entry
pdf_path = root / accept_pdf
log_path = root / accept_log
aux_path = root / accept_aux

def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()

def file_info(path: Path) -> dict:
    exists = path.is_file()
    info = {
        "path": rel(path),
        "exists": exists,
        "size_bytes": path.stat().st_size if exists else 0,
        "mtime": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat() if exists else "",
    }
    return info

def count_pdf_pages(path: Path) -> tuple[int | None, str]:
    if not path.is_file():
        return None, "missing"
    commands = [
        ["pdfinfo", str(path)],
        ["python3", "-c", "import sys; from PyPDF2 import PdfReader; print(len(PdfReader(sys.argv[1]).pages))", str(path)],
    ]
    for cmd in commands:
        result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode != 0:
            continue
        if cmd[0] == "pdfinfo":
            for line in result.stdout.splitlines():
                if line.startswith("Pages:"):
                    try:
                        return int(line.split(":", 1)[1].strip()), "pdfinfo"
                    except ValueError:
                        pass
        else:
            try:
                return int(result.stdout.strip()), "PyPDF2"
            except ValueError:
                pass
    return None, "unavailable"

def log_findings(path: Path) -> dict:
    findings = {
        "fatal_errors": [],
        "undefined_refs": [],
        "overfull_hbox": [],
        "warnings": [],
    }
    if not path.is_file():
        return findings
    patterns = {
        "fatal_errors": re.compile(r"(^! |Fatal error|Emergency stop|LaTeX Error)", re.IGNORECASE),
        "undefined_refs": re.compile(r"(undefined references|Reference .* undefined|Citation .* undefined|There were undefined)", re.IGNORECASE),
        "overfull_hbox": re.compile(r"Overfull \\\\hbox", re.IGNORECASE),
        "warnings": re.compile(r"LaTeX Warning|Package .* Warning", re.IGNORECASE),
    }
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        for key, pattern in patterns.items():
            if pattern.search(line):
                findings[key].append(line.strip())
                break
    return {key: values[:20] for key, values in findings.items()}

pdf_pages, page_counter = count_pdf_pages(pdf_path)
log = log_findings(log_path)

entry_info = file_info(entry_path)
pdf_info = file_info(pdf_path)
log_info = file_info(log_path)
aux_info = file_info(aux_path)

status = "PASS"
checks = []
def add_check(name: str, ok: bool, detail: str) -> None:
    global status
    checks.append({"name": name, "ok": ok, "detail": detail})
    if not ok:
        status = "FAIL"

add_check("entrypoint_exists", entry_info["exists"], entry_info["path"])
add_check("acceptance_pdf_exists", pdf_info["exists"] and pdf_info["size_bytes"] > 0, pdf_info["path"])
add_check("acceptance_log_exists", log_info["exists"] and log_info["size_bytes"] > 0, log_info["path"])
add_check("acceptance_aux_exists", aux_info["exists"] and aux_info["size_bytes"] > 0, aux_info["path"])
if pdf_pages is not None:
    add_check("pdf_page_count_available", pdf_pages > 0, f"{pdf_pages} pages via {page_counter}")
else:
    add_check("pdf_page_count_available", False, page_counter)
add_check("latex_fatal_free", len(log["fatal_errors"]) == 0, f"{len(log['fatal_errors'])} fatal/error lines")
add_check("latex_undefined_refs_free", len(log["undefined_refs"]) == 0, f"{len(log['undefined_refs'])} undefined reference/citation lines")

payload = {
    "schema_version": "paper_acceptance_check.v1",
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    "root": str(root),
    "read_only": True,
    "status": status,
    "ok": status == "PASS",
    "paper_env": {
        "paper_host_rel_dir": paper_host_rel,
        "paper_build_dir": paper_build_dir,
        "active_entrypoint": entry,
        "accept_pdf": accept_pdf,
        "accept_log": accept_log,
        "accept_aux": accept_aux,
    },
    "files": {
        "entrypoint": entry_info,
        "pdf": {**pdf_info, "page_count": pdf_pages, "page_counter": page_counter},
        "log": log_info,
        "aux": aux_info,
    },
    "log_findings": log,
    "checks": checks,
}

def render_text(data: dict) -> str:
    lines = [
        "# Paper Acceptance Check",
        "",
        f"status: {data['status']}",
        f"root: {data['root']}",
        f"generated_at: {data['generated_at']}",
        "",
        "## Paper Env",
    ]
    for key, value in data["paper_env"].items():
        lines.append(f"- {key}: {value or '<empty>'}")
    lines.extend(["", "## Files"])
    for name, info in data["files"].items():
        extra = ""
        if name == "pdf":
            extra = f", pages={info.get('page_count')}, page_counter={info.get('page_counter')}"
        lines.append(f"- {name}: {info['path']} exists={info['exists']} size={info['size_bytes']} mtime={info['mtime']}{extra}")
    lines.extend(["", "## Checks"])
    for check in data["checks"]:
        mark = "PASS" if check["ok"] else "FAIL"
        lines.append(f"- {mark}: {check['name']} ({check['detail']})")
    lines.extend(["", "## Log Findings"])
    for key, values in data["log_findings"].items():
        lines.append(f"### {key}")
        if values:
            lines.extend(f"- {item}" for item in values)
        else:
            lines.append("- none")
    return "\n".join(lines) + "\n"

text = render_text(payload)
if write_report:
    report_out.parent.mkdir(parents=True, exist_ok=True)
    report_out.write_text(text, encoding="utf-8")
    payload["report_path"] = str(report_out)

if output_format == "json":
    print(json.dumps(payload, ensure_ascii=True, indent=2))
else:
    print(text, end="")

sys.exit(0 if payload["ok"] else 1)
PY
