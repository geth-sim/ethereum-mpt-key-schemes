#!/usr/bin/env bash
set -euo pipefail
target_override="${TARGET_BLOCK:-250000}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
TARGET_BLOCK="$target_override"
[[ "$TARGET_BLOCK" =~ ^[1-9][0-9]*$ ]] || die "TARGET_BLOCK must be a positive integer"
[[ "$SIMULATOR_DISK_SIZE_INTERVAL" =~ ^[1-9][0-9]*$ ]] ||
  die "SIMULATOR_DISK_SIZE_INTERVAL must be a positive integer"
((TARGET_BLOCK % SIMULATOR_DISK_SIZE_INTERVAL == 0)) ||
  die "TARGET_BLOCK must be a multiple of SIMULATOR_DISK_SIZE_INTERVAL"
require_command python3

smoke_report="${1:-$RUNTIME_DIR/core-smoke-1000000/smoke-report.json}"
smoke_root="$RUNTIME_DIR/table4-smoke-$TARGET_BLOCK"
reports=()
analysis_args=()

# Reuse only a complete set of valid LevelDB checkpoints; otherwise replay E1's
# three fast baselines at the Table 4 endpoint, without requiring the 1M smoke.
if python3 - "$ROOT_DIR/analysis" "$smoke_report" "$TARGET_BLOCK" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from extract_backend_storage import smoke_storage
try:
    rows = smoke_storage(Path(sys.argv[2]).resolve(), int(sys.argv[3]))
except (OSError, KeyError, ValueError, TypeError) as error:
    raise SystemExit(f"LevelDB smoke checkpoints cannot be reused: {error}")
print(f"Reusing {len(rows)} LevelDB smoke checkpoints at block {sys.argv[3]}.")
PY
then
  analysis_args+=(--leveldb-smoke-report "$smoke_report")
else
  echo "Running H/PV*/VP* with LevelDB/Snappy through block $TARGET_BLOCK."
  for scheme in H PVstar VPstar; do
    TARGET_BLOCK="$TARGET_BLOCK" PAPER_EXPERIMENT_ROOT="$smoke_root" \
    SIMULATOR_RESULT_SAVE_INTERVAL="$TARGET_BLOCK" \
      "$ROOT_DIR/scripts/run_paper_experiment.sh" E1 validation "E1_$scheme"
    reports+=("$smoke_root/validation/E1/run-report_E1_$scheme.json")
  done
fi

TARGET_BLOCK="$TARGET_BLOCK" PAPER_EXPERIMENT_ROOT="$smoke_root" \
SIMULATOR_RESULT_SAVE_INTERVAL="$TARGET_BLOCK" \
  "$ROOT_DIR/scripts/run_paper_experiment.sh" E6 validation

python3 "$ROOT_DIR/analysis/extract_backend_storage.py" \
  "${reports[@]}" \
  "$smoke_root/validation/E6/run-report.json" \
  "${analysis_args[@]}" --end-block "$TARGET_BLOCK" --unit MB \
  --output-dir "$smoke_root/table4"
echo "TABLE 4 SMOKE: PASS"
echo "Table: $smoke_root/table4/backend_storage.md"
