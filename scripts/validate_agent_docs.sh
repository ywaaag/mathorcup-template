#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="all"

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--memory-only|--handoff-only]" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    case "$1" in
        --memory-only) MODE="memory" ;;
        --handoff-only) MODE="handoff" ;;
        *)
            echo "Usage: $0 [--memory-only|--handoff-only]" >&2
            exit 2
            ;;
    esac
fi

die() {
    echo "[validate_agent_docs] ERROR: $1" >&2
    exit 1
}

validate_memory() {
    local file="$ROOT_DIR/MEMORY.md"
    [[ -f "$file" ]] || die "missing file: MEMORY.md"

    local line_count
    line_count=$(wc -l < "$file")
    if (( line_count > 120 )); then
        die "MEMORY.md exceeds 120 lines (current: $line_count)"
    fi

    local -a expected=(
        "## Phase"
        "## Current Task"
        "## Active Problem"
        "## Decisions"
        "## Blockers"
        "## Next Actions"
        "## Handoff Index"
    )

    mapfile -t headings < <(grep -n '^## ' "$file" || true)
    if (( ${#headings[@]} != ${#expected[@]} )); then
        die "MEMORY.md must contain exactly 7 level-2 headings in fixed order"
    fi

    local i
    for i in "${!expected[@]}"; do
        local line_no="${headings[$i]%%:*}"
        local heading_text="${headings[$i]#*:}"
        if [[ "$heading_text" != "${expected[$i]}" ]]; then
            die "MEMORY.md heading mismatch at line $line_no: expected '${expected[$i]}', got '$heading_text'"
        fi
    done

    local total_lines
    total_lines=$(wc -l < "$file")
    for i in "${!expected[@]}"; do
        local start_line=$(( ${headings[$i]%%:*} + 1 ))
        local end_line
        if (( i + 1 < ${#expected[@]} )); then
            end_line=$(( ${headings[$((i + 1))]%%:*} - 1 ))
        else
            end_line=$total_lines
        fi

        if (( end_line < start_line )); then
            die "MEMORY.md section '${expected[$i]}' is empty"
        fi

        local non_empty
        non_empty=$(sed -n "${start_line},${end_line}p" "$file" | grep -c '[^[:space:]]' || true)
        if (( non_empty == 0 )); then
            die "MEMORY.md section '${expected[$i]}' must have at least one non-empty line"
        fi
    done
}

validate_one_handoff_file() {
    local file="$1"
    local base
    base="$(basename "$file")"

    if [[ ! "$base" =~ ^P[0-9]+_[a-z0-9_]+_[0-9]{8}\.md$ ]]; then
        die "invalid handoff filename: $base (expected P{n}_{topic}_{YYYYMMDD}.md)"
    fi

    local -a expected=(
        "## Problem"
        "## Inputs"
        "## Method"
        "## Outputs"
        "## For Paper Brain"
        "## Risks"
    )

    mapfile -t headings < <(grep -n '^## ' "$file" || true)
    if (( ${#headings[@]} != ${#expected[@]} )); then
        die "$base must contain exactly 6 level-2 headings in fixed order"
    fi

    local i
    for i in "${!expected[@]}"; do
        local line_no="${headings[$i]%%:*}"
        local heading_text="${headings[$i]#*:}"
        if [[ "$heading_text" != "${expected[$i]}" ]]; then
            die "$base heading mismatch at line $line_no: expected '${expected[$i]}', got '$heading_text'"
        fi
    done

    local total_lines
    total_lines=$(wc -l < "$file")
    for i in "${!expected[@]}"; do
        local start_line=$(( ${headings[$i]%%:*} + 1 ))
        local end_line
        if (( i + 1 < ${#expected[@]} )); then
            end_line=$(( ${headings[$((i + 1))]%%:*} - 1 ))
        else
            end_line=$total_lines
        fi

        if (( end_line < start_line )); then
            die "$base section '${expected[$i]}' is empty"
        fi

        local non_empty
        non_empty=$(sed -n "${start_line},${end_line}p" "$file" | grep -c '[^[:space:]]' || true)
        if (( non_empty == 0 )); then
            die "$base section '${expected[$i]}' must have at least one non-empty line"
        fi
        if (( non_empty > 5 )); then
            die "$base section '${expected[$i]}' exceeds 5 non-empty lines"
        fi
    done
}

validate_handoff() {
    local dir="$ROOT_DIR/project/output/handoff"
    [[ -d "$dir" ]] || die "missing directory: project/output/handoff"

    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'HANDOFF_TEMPLATE.md' | sort)

    local file
    for file in "${files[@]}"; do
        validate_one_handoff_file "$file"
    done
}

case "$MODE" in
    all)
        validate_memory
        validate_handoff
        ;;
    memory)
        validate_memory
        ;;
    handoff)
        validate_handoff
        ;;
    *)
        die "unknown mode: $MODE"
        ;;
esac

echo "[validate_agent_docs] OK"
