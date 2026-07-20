#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

suite_report="${1:-$RUNTIME_DIR/core-smoke-${TARGET_BLOCK}/smoke-report.json}"
output_dir="${2:-$(dirname "$suite_report")/graphs}"
analysis_script="$DATA_ANALYSIS_DIR/analyze_artifact_results.py"

[[ -f "$suite_report" ]] ||
  die "input run report not found: $suite_report"
[[ -f "$analysis_script" ]] ||
  die "pinned analysis source not found; run ./scripts/build.sh first"
command -v "$ANALYSIS_PYTHON" >/dev/null 2>&1 ||
  die "analysis Python not found: $ANALYSIS_PYTHON"

if ! "$ANALYSIS_PYTHON" -c 'import matplotlib, numpy, pandas' >/dev/null 2>&1; then
  die "analysis dependencies are missing; install sources/data-analysis/requirements-artifact.txt"
fi

exec "$ANALYSIS_PYTHON" "$analysis_script" \
  --suite-report "$suite_report" \
  --artifact-root "$ROOT_DIR" \
  --output-dir "$output_dir" \
  "${@:3}"
