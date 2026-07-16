#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

TARGET_DIR="$ROOT_DIR"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--root) TARGET_DIR="$(abs_path "$2")"; shift 2 ;;
        -h|--help) echo "Usage: bash scripts/merge_model_manifest.sh [--target <dir>]"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

python3 - "$TARGET_DIR" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
template = root / "project/output/MODEL_MANIFEST_TEMPLATE.json"
fragments_dir = root / "project/output/manifest_fragments"
output = root / "project/output/model_manifest.json"
if not template.is_file():
    raise SystemExit(f"missing manifest template: {template}")
manifest = json.loads(template.read_text(encoding="utf-8"))
fragments = sorted(fragments_dir.glob("*.json"))
if not fragments:
    raise SystemExit(f"no manifest fragments found under {fragments_dir}")

keys = {
    "assumptions": lambda item: item.get("id", ""),
    "algorithm_boundaries": lambda item: item.get("scope", ""),
    "canonical_numbers": lambda item: item.get("name", ""),
    "output_files": lambda item: item.get("path", ""),
    "validation_commands": lambda item: item.get("command", ""),
    "paper_consumers": lambda item: item.get("section_or_table", ""),
}
seen = {name: {} for name in keys}
problem_ids = set()
for fragment_path in fragments:
    fragment = json.loads(fragment_path.read_text(encoding="utf-8"))
    task_id = fragment.get("task_id")
    if not task_id:
        raise SystemExit(f"fragment missing task_id: {fragment_path}")
    if fragment.get("provisional"):
        raise SystemExit(f"provisional fragment cannot enter canonical manifest: {fragment_path}")
    if fragment.get("problem_id"):
        problem_ids.add(str(fragment["problem_id"]))
    manifest["merged_fragments"].append({"task_id": task_id, "path": fragment_path.relative_to(root).as_posix()})
    for section, identity in keys.items():
        for item in fragment.get(section, []):
            item_key = identity(item)
            if not item_key:
                raise SystemExit(f"fragment item in {section} has no identity key: {fragment_path}")
            previous = seen[section].get(item_key)
            if previous is not None and previous != item:
                raise SystemExit(f"conflicting {section} entry '{item_key}' across fragments")
            seen[section][item_key] = item
    provenance = fragment.get("provenance", {})
    for source_hash in provenance.get("source_hashes", []):
        if source_hash not in manifest["provenance"]["source_hashes"]:
            manifest["provenance"]["source_hashes"].append(source_hash)

for section in keys:
    manifest[section] = [seen[section][key] for key in sorted(seen[section])]
manifest["problem_id"] = ",".join(sorted(problem_ids))
manifest["updated_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
manifest["provenance"]["generated_at"] = manifest["updated_at"]
output.write_text(json.dumps(manifest, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
print(f"[workflow] merged {len(fragments)} manifest fragment(s) -> {output}")
PY
