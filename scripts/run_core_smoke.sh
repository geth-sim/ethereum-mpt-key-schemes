#!/usr/bin/env bash
set -euo pipefail
target_was_set="${TARGET_BLOCK+x}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

if [[ -z "$target_was_set" ]]; then
  TARGET_BLOCK="$TARGET_500K_BLOCK"
  TARGET_HASH="$TARGET_500K_HASH"
fi

require_command date
require_command jq
require_command python3

[[ -x "$BIN_DIR/state-simulator-stats" ]] ||
  die "detailed simulator is not built; run ./scripts/build.sh first"
((TARGET_BLOCK % SIMULATOR_LEVELDB_STATS_INTERVAL == 0)) ||
  die "TARGET_BLOCK must be a multiple of SIMULATOR_LEVELDB_STATS_INTERVAL"

python3 - <<PY
import pymysql
c = pymysql.connect(
    host="$MARIADB_HOST", port=int("$MARIADB_PORT"), user="$MARIADB_USER",
    password="$MARIADB_PASSWORD", database="$MARIADB_DATABASE")
with c.cursor() as q:
    q.execute("SELECT COUNT(*) FROM blocks WHERE number BETWEEN 0 AND %s", (int("$TARGET_BLOCK"),))
    blocks = q.fetchone()[0]
    q.execute("SELECT COUNT(*) FROM transactions WHERE blocknumber BETWEEN 0 AND %s", (int("$TARGET_BLOCK"),))
    txs = q.fetchone()[0]
if blocks != int("$TARGET_BLOCK") + 1:
    raise SystemExit(f"MariaDB input is incomplete: expected {int('$TARGET_BLOCK') + 1} blocks, got {blocks}")
print(f"MariaDB input: {blocks} blocks, {txs} transactions")
PY

smoke_root="$RUNTIME_DIR/core-smoke-${TARGET_BLOCK}"
workdir="$smoke_root/simulator-output"
db_root="$smoke_root/databases"
log_root="$smoke_root/logs"
rows="$smoke_root/results.jsonl"
report="$smoke_root/smoke-report.json"
mkdir -p "$workdir" "$db_root" "$log_root"
: "${SMOKE_SCHEMES:=H PVstar VPstar}"
: "${RESET_SMOKE_REPORT:=true}"
if [[ "$RESET_SMOKE_REPORT" == "true" ]]; then
  : >"$rows"
elif [[ "$RESET_SMOKE_REPORT" != "false" ]]; then
  die "RESET_SMOKE_REPORT must be true or false"
fi

simulator_pid=""
cleanup_simulator() {
  if [[ -n "$simulator_pid" ]]; then
    kill "$simulator_pid" >/dev/null 2>&1 || true
    wait "$simulator_pid" >/dev/null 2>&1 || true
    simulator_pid=""
  fi
}
trap cleanup_simulator EXIT INT TERM

run_case() {
  local scheme="$1"
  local case_id="smoke_${scheme}"
  local experiment_id="${scheme}_archive_leveldb_snappy_stats"
  local db_path="$db_root/$case_id"
  local console_log="$log_root/${case_id}_simulator.log"
  local client_log="$log_root/${case_id}_client.log"
  local run_dir="$workdir/logFiles/evm/runs/$experiment_id"
  local started finished elapsed_ms

  rm -rf "$db_path" "$run_dir"
  echo "[$case_id] starting detailed-instrumentation replay through block $TARGET_BLOCK"
  started="$(date +%s%N)"
  SIMULATOR_WORKDIR="$workdir" \
  SIMULATOR_DB="$db_path" \
  SIMULATOR_VARIANT=stats \
  SIMULATOR_SCHEME="$scheme" \
  SIMULATOR_STATE_MODE=archive \
  SIMULATOR_DB_BACKEND=leveldb \
  SIMULATOR_COMPRESSION=snappy \
  SIMULATOR_MYHASH=false \
  SIMULATOR_MYHASH_CACHE_MB=0 \
  SIMULATOR_DISK_SIZE_MULTIPLIER=1.0 \
  SIMULATOR_VERSION_WRAP=none \
  SIMULATOR_PATHDB_HISTORY=true \
    "$ROOT_DIR/scripts/run_simulator.sh" >"$console_log" 2>&1 &
  simulator_pid=$!
  wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 120 ||
    die "simulator did not start; see $console_log"

  PYTHONUNBUFFERED=1 TARGET_BLOCK="$TARGET_BLOCK" SIMULATOR_DB="$db_path" \
    "$ROOT_DIR/scripts/run_mariadb_client.sh" \
    >"$client_log" 2>&1
  cleanup_simulator
  finished="$(date +%s%N)"
  elapsed_ms=$(((finished - started) / 1000000))

  local simblocks="$run_dir/simBlocks/evm_simulation_result_${experiment_id}_0_${TARGET_BLOCK}.json"
  local leveldb_stats="$run_dir/leveldbStats/leveldb_stats_${experiment_id}_0_${TARGET_BLOCK}.json"
  local read_stats="$run_dir/leveldbStats/read_stats_${experiment_id}_${TARGET_BLOCK}.json"
  [[ -s "$simblocks" ]] || die "missing simBlocks for $case_id"
  [[ -s "$leveldb_stats" ]] || die "missing aggregate LevelDB stats for $case_id"
  [[ -s "$read_stats" ]] || die "missing detailed LevelDB read stats for $case_id"

  jq -nc \
    --arg case_id "$case_id" --arg experiment_id "$experiment_id" \
    --arg scheme "$scheme" --arg simblocks "${simblocks#"$ROOT_DIR/"}" \
    --arg leveldb_stats "${leveldb_stats#"$ROOT_DIR/"}" \
    --arg read_stats "${read_stats#"$ROOT_DIR/"}" \
    --arg simulator_log "${console_log#"$ROOT_DIR/"}" \
    --arg client_log "${client_log#"$ROOT_DIR/"}" \
    --argjson target_block "$TARGET_BLOCK" --argjson elapsed_ms "$elapsed_ms" \
    --argjson database_bytes "$(du -sb "$db_path" | awk '{print $1}')" '
      {
        case_id: $case_id, experiment_id: $experiment_id, scheme: $scheme,
        variant: "stats", target_block: $target_block,
        elapsed_seconds: ($elapsed_ms / 1000), database_bytes: $database_bytes,
        outputs: {
          simblocks: $simblocks, leveldb_stats: $leveldb_stats,
          read_stats: $read_stats, simulator_log: $simulator_log,
          client_log: $client_log
        }
      }' >>"$rows"
  elapsed_seconds="$(awk -v elapsed_ms="$elapsed_ms" 'BEGIN {printf "%.3f", elapsed_ms/1000}')"
  echo "[$case_id] PASS in $elapsed_seconds seconds"
}

for scheme in $SMOKE_SCHEMES; do
  run_case "$scheme"
done

jq -s \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson target_block "$TARGET_BLOCK" '
    {
      status: "PASS", generated_at_utc: $generated_at_utc,
      target_block: $target_block, case_count: length,
      total_elapsed_seconds: ([.[].elapsed_seconds] | add), cases: .
    }' "$rows" >"$report"

echo "CORE SMOKE: PASS"
echo "Report: $report"
