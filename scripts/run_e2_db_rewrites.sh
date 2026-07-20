#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

profile="${1:-validation}"
case "$profile" in
  validation)
    source_db="$RUNTIME_DIR/paper-experiments/validation/E1/E1_PVstar/database"
    ;;
  paper)
    source_db="$RUNTIME_DIR/paper-experiments/paper/E1/E1_PVstar/database"
    ;;
  *) die "usage: ./scripts/run_e2_db_rewrites.sh validation|paper" ;;
esac
[[ -d "$source_db" ]] ||
  die "missing PVstar source database: run E1 for the same profile first"

case_root="$RUNTIME_DIR/paper-experiments/$profile/E2"
workdir="$case_root/output"
log="$case_root/simulator.log"
summary="$case_root/rewrite-report.json"
mkdir -p "$workdir"

simulator_pid=""
cleanup() {
  if [[ -n "$simulator_pid" ]]; then
    kill "$simulator_pid" >/dev/null 2>&1 || true
    wait "$simulator_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

SIMULATOR_WORKDIR="$workdir" SIMULATOR_DB="$source_db" \
SIMULATOR_VARIANT=fast SIMULATOR_SCHEME=PVstar \
SIMULATOR_STATE_MODE=archive SIMULATOR_DB_BACKEND=leveldb \
SIMULATOR_COMPRESSION=snappy \
  "$ROOT_DIR/scripts/run_simulator.sh" >"$log" 2>&1 &
simulator_pid=$!
wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 120 ||
  die "simulator failed to start; see $log"

python3 "$ROOT_DIR/scripts/e2_db_rewrite.py" \
  --host "$SIMULATOR_HOST" --port "$SIMULATOR_PORT" \
  --db-path "$source_db" --seed 1 --output "$summary"
cleanup
simulator_pid=""

jq --arg source_database "${source_db#"$ROOT_DIR/"}" \
  --argjson source_database_bytes "$(du -sb "$source_db" | awk '{print $1}')" '
    . + {
      source_database: $source_database,
      source_database_bytes: $source_database_bytes
    }
  ' "$summary" >"$summary.tmp"
mv "$summary.tmp" "$summary"

jq -e '.status == "PASS" and (.rewrites | length) == 3' "$summary" >/dev/null
echo "E2 $profile: PASS"
echo "Report: $summary"
