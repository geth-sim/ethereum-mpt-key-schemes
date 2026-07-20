#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
report="${1:-$root_dir/runtime/core-smoke-500000/smoke-report.json}"
shift || true

exec python3 "$root_dir/analysis/extract_storage_metrics.py" "$report" "$@"
