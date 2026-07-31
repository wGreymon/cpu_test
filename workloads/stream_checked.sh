#!/usr/bin/env bash
# 运行 STREAM，并把其内置数值校验结果转换为可靠的进程退出码。
set -uo pipefail
export LC_ALL=C

tmp=$(mktemp "${TMPDIR:-/tmp}/stream_checked.XXXXXX") || exit 2
trap 'rm -f "$tmp"' EXIT

rc=0
stream "$@" > "$tmp" 2>&1 || rc=$?
cat "$tmp"
(( rc == 0 )) || exit "$rc"

if ! grep -q 'Solution Validates' "$tmp"; then
    echo "STREAM correctness validation missing or failed" >&2
    exit 3
fi
