#!/usr/bin/env bash
set -euo pipefail
target_was_set="${TARGET_BLOCK+x}"
target_override="${TARGET_BLOCK-}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run_paper_experiment.sh <E1-E7> validation [case-id]
  ./scripts/run_paper_experiment.sh <E1-E7> paper [case-id]
  ./scripts/run_paper_experiment.sh <E1-E7> list

validation runs only manifest rows marked validation=true; replays default to 50K.
paper runs every case for the experiment; replays default to 10M.
Set TARGET_BLOCK to override the replay end block. No hash is needed for replay.
Set PAPER_EXPERIMENT_ROOT to keep a separate set of experiment results.
E2 reuses a completed E1_PVstar database from the same profile, or builds it if missing.
EOF
}

experiment="${1:-}"
profile="${2:-}"
case_filter="${3:-}"
manifest="$ROOT_DIR/experiments/paper-experiments.json"
[[ "$experiment" =~ ^E[1-7]$ ]] || { usage; exit 2; }
[[ -f "$manifest" ]] || die "missing $manifest"
require_command jq

if [[ "$profile" == "list" ]]; then
  jq -r --arg experiment "$experiment" '
    .cases[] | select(.experiment == $experiment) |
    [.id, .kind, .purpose, (.variant // "-"), (.scheme // "-"),
     (.state_mode // "-"), (.backend // "-"), (.compression // "-"),
     (if .validation then "validation" else "paper-only" end)] | @tsv
  ' "$manifest"
  exit
fi
[[ "$profile" == "validation" || "$profile" == "paper" ]] || { usage; exit 2; }
require_command python3
export PAPER_EXPERIMENT_ROOT="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' \
  "${PAPER_EXPERIMENT_ROOT:-$RUNTIME_DIR/paper-experiments}")"

if [[ -z "$target_was_set" ]]; then
  if [[ "$profile" == "validation" ]]; then
    TARGET_BLOCK="$TARGET_50K_BLOCK"
  else
    TARGET_BLOCK="$TARGET_10M_BLOCK"
  fi
else
  TARGET_BLOCK="$target_override"
fi
[[ "$TARGET_BLOCK" =~ ^[1-9][0-9]*$ ]] ||
  die "TARGET_BLOCK must be a positive integer without leading zeros"

simulator_pid=""
prerequisite_pid=""
cleanup_simulator() {
  if [[ -n "$simulator_pid" ]]; then
    kill "$simulator_pid" >/dev/null 2>&1 || true
    wait "$simulator_pid" >/dev/null 2>&1 || true
    simulator_pid=""
  fi
}
cleanup() {
  if [[ -n "$prerequisite_pid" ]]; then
    kill -- "-$prerequisite_pid" >/dev/null 2>&1 || true
    wait "$prerequisite_pid" >/dev/null 2>&1 || true
    prerequisite_pid=""
  fi
  cleanup_simulator
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

inspect_e2_source() {
  python3 - "$ROOT_DIR/scripts" "$1" "$profile" "${target_was_set:+$TARGET_BLOCK}" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
from e2_db_rewrite import inspect_source_database

try:
    info = inspect_source_database(sys.argv[2], sys.argv[3],
                                   int(sys.argv[4]) if sys.argv[4] else None)
except (ValueError, OSError) as error:
    raise SystemExit(
        f"ERROR: {error}. The existing database was not changed.\n"
        f"To rebuild it, run ./scripts/run_paper_experiment.sh E1 {sys.argv[3]} E1_PVstar "
        "with the desired TARGET_BLOCK."
    )
print(json.dumps(info))
PY
}

run_e2() {
  local source_db="$PAPER_EXPERIMENT_ROOT/$profile/E1/E1_PVstar/database"
  local case_root="$PAPER_EXPERIMENT_ROOT/$profile/E2"
  local workdir="$case_root/output"
  local log="$case_root/simulator.log"
  local summary="$case_root/rewrite-report.json"
  local -a rewrite_cases=() rewrite_args=()
  local case_id attempt ready=false source_info source_report source_target

  mapfile -t rewrite_cases < <(jq -r \
    --arg profile "$profile" --arg case_filter "$case_filter" '
      .cases[] | select(.experiment == "E2" and .kind == "database-rewrite") |
      select($profile == "paper" or .validation == true) |
      select($case_filter == "" or .id == $case_filter) | .id
    ' "$manifest")
  ((${#rewrite_cases[@]} > 0)) || die "no matching E2 rewrite cases"
  require_command tee
  if wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 1; then
    die "simulator port $SIMULATOR_PORT is already in use; stop the existing simulator before running E2"
  fi
  source_info="$(inspect_e2_source "$source_db")"
  if [[ "$source_info" == null ]]; then
    require_command setsid
    echo "E1_PVstar database is missing; preparing blocks 0..$TARGET_BLOCK for E2."
    TARGET_BLOCK="$TARGET_BLOCK" setsid \
      "$ROOT_DIR/scripts/run_paper_experiment.sh" E1 "$profile" E1_PVstar < /dev/null &
    prerequisite_pid=$!
    wait "$prerequisite_pid" || die "E1_PVstar preparation failed; E2 was not started"
    prerequisite_pid=""
    source_info="$(inspect_e2_source "$source_db")"
    [[ "$source_info" != null ]] || die "E1_PVstar completed without a source database"
  fi
  source_report="$(jq -r '.report' <<<"$source_info")"
  source_target="$(jq -r '.target_block' <<<"$source_info")"
  if [[ -n "$case_filter" ]]; then
    log="$case_root/simulator_${case_filter}.log"
    summary="$case_root/rewrite-report_${case_filter}.json"
  fi
  for case_id in "${rewrite_cases[@]}"; do
    rewrite_args+=(--case "$case_id")
  done
  mkdir -p "$workdir"
  echo "E2 uses the completed E1_PVstar database through block $source_target: $source_db"
  echo "E2 progress is shown below and saved to $log"

  SIMULATOR_WORKDIR="$workdir" SIMULATOR_DB="$source_db" \
  SIMULATOR_VARIANT=fast SIMULATOR_SCHEME=PVstar \
  SIMULATOR_STATE_MODE=archive SIMULATOR_DB_BACKEND=leveldb \
  SIMULATOR_COMPRESSION=snappy SIMULATOR_MYHASH=false \
  SIMULATOR_MYHASH_CACHE_MB=0 SIMULATOR_DISK_SIZE_MULTIPLIER=1.0 \
  SIMULATOR_VERSION_WRAP=none \
    "$ROOT_DIR/scripts/run_simulator.sh" > >(tee "$log") 2>&1 &
  simulator_pid=$!
  for ((attempt = 1; attempt <= 120; attempt++)); do
    kill -0 "$simulator_pid" >/dev/null 2>&1 ||
      die "simulator exited during startup; see $log"
    if wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 1; then
      ready=true
      break
    fi
  done
  [[ "$ready" == true ]] || die "simulator failed to start; see $log"

  python3 -u "$ROOT_DIR/scripts/e2_db_rewrite.py" \
    --host "$SIMULATOR_HOST" --port "$SIMULATOR_PORT" \
    --db-path "$source_db" --seed 1 --output "$summary" "${rewrite_args[@]}"
  cleanup_simulator

  jq --arg profile "$profile" \
    --arg source_database "${source_db#"$ROOT_DIR/"}" \
    --arg source_report "${source_report#"$ROOT_DIR/"}" \
    --argjson source_target_block "$source_target" \
    --argjson source_database_bytes "$(du -sb "$source_db" | awk '{print $1}')" '
      . + {experiment: "E2", profile: $profile,
        source_database: $source_database, source_database_bytes: $source_database_bytes,
        source_report: $source_report, source_target_block: $source_target_block}
    ' "$summary" >"$summary.tmp"
  mv "$summary.tmp" "$summary"
  jq -e --argjson count "${#rewrite_cases[@]}" \
    '.status == "PASS" and (.rewrites | length) == $count' "$summary" >/dev/null
  echo "E2 $profile: PASS"
  echo "Report: $summary"
}

# Rewrites reuse the saved E1 database; only a missing prerequisite needs replay.
if [[ "$experiment" == "E2" ]]; then
  run_e2
  exit
fi

require_command date
[[ "$SIMULATOR_RESULT_SAVE_INTERVAL" =~ ^[1-9][0-9]*$ ]] ||
  die "SIMULATOR_RESULT_SAVE_INTERVAL must be a positive integer"

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
    raise SystemExit(f"MariaDB input is incomplete through {int('$TARGET_BLOCK')}: got {blocks} blocks")
if txs == 0:
    raise SystemExit("selected validation range contains no transactions")
print(f"MariaDB input: {blocks} blocks, {txs} transactions")
PY

run_root="$PAPER_EXPERIMENT_ROOT/$profile/$experiment"
if [[ -n "$case_filter" ]]; then
  rows="$run_root/results_${case_filter}.jsonl"
  report="$run_root/run-report_${case_filter}.json"
else
  rows="$run_root/results.jsonl"
  report="$run_root/run-report.json"
fi
mkdir -p "$run_root"
: >"$rows"

query='.cases[] | select(.experiment == $experiment and .kind == "replay")'
if [[ "$profile" == "validation" ]]; then
  query+=' | select(.validation == true)'
fi
if [[ -n "$case_filter" ]]; then
  query+=' | select(.id == $case_filter)'
fi
mapfile -t cases < <(jq -c --arg experiment "$experiment" --arg case_filter "$case_filter" "$query" "$manifest")
((${#cases[@]} > 0)) || die "no matching replay cases"

failed_cases=0
for row in "${cases[@]}"; do
  case_id="$(jq -r '.id' <<<"$row")"
  variant="$(jq -r '.variant' <<<"$row")"
  scheme="$(jq -r '.scheme' <<<"$row")"
  state_mode="$(jq -r '.state_mode' <<<"$row")"
  backend="$(jq -r '.backend' <<<"$row")"
  compression="$(jq -r '.compression' <<<"$row")"
  myhash="$(jq -r '.myhash // false' <<<"$row")"
  myhash_cache_mb="$(jq -r '.myhash_cache_mb // 0' <<<"$row")"
  myhash_cache_mode="$(jq -r '.myhash_cache_mode // "unified"' <<<"$row")"
  multiplier="$(jq -r '.disk_size_multiplier // 1.0' <<<"$row")"
  version_wrap="$(jq -r '.version_wrap // "none"' <<<"$row")"
  pathdb_history="$(jq -r '.pathdb_history // true' <<<"$row")"
  child_stats="$(jq -r --argjson fallback "$SIMULATOR_CHILD_STATS" \
    'if has("child_stats") then .child_stats else $fallback end' <<<"$row")"
  accurate_read_counters="$(jq -r --argjson fallback "$SIMULATOR_ACCURATE_READ_COUNTERS" \
    'if has("accurate_read_counters") then .accurate_read_counters else $fallback end' <<<"$row")"
  [[ "$child_stats" == true || "$child_stats" == false ]] || die "invalid child_stats for $case_id"
  [[ "$accurate_read_counters" == true || "$accurate_read_counters" == false ]] || die "invalid accurate_read_counters for $case_id"
  if [[ "$profile" == "validation" && "$scheme" == "P" ]]; then
    pathdb_history=false
  fi

  case_root="$run_root/$case_id"
  workdir="$case_root/output"
  db_path="$case_root/database"
  simulator_log="$case_root/simulator.log"
  client_log="$case_root/client.log"
  mkdir -p "$workdir"
  # Fresh replays must not mix counters or checkpoints from an older run.
  rm -f "$workdir/additional_node_stats.txt"
  rm -rf "$workdir/logFiles/evm/runs"
  rm -rf "$db_path"
  started="$(date +%s%N)"
  echo "[$case_id] $profile replay through block $TARGET_BLOCK"
  SIMULATOR_WORKDIR="$workdir" SIMULATOR_DB="$db_path" \
  SIMULATOR_VARIANT="$variant" SIMULATOR_SCHEME="$scheme" \
  SIMULATOR_STATE_MODE="$state_mode" SIMULATOR_DB_BACKEND="$backend" \
  SIMULATOR_COMPRESSION="$compression" SIMULATOR_MYHASH="$myhash" \
  SIMULATOR_MYHASH_CACHE_MB="$myhash_cache_mb" \
  SIMULATOR_MYHASH_CACHE_MODE="$myhash_cache_mode" \
  SIMULATOR_DISK_SIZE_MULTIPLIER="$multiplier" \
  SIMULATOR_VERSION_WRAP="$version_wrap" \
  SIMULATOR_PATHDB_HISTORY="$pathdb_history" \
  SIMULATOR_CHILD_STATS="$child_stats" \
  SIMULATOR_ACCURATE_READ_COUNTERS="$accurate_read_counters" \
  SIMULATOR_LEVELDB_STATS_INTERVAL="$SIMULATOR_RESULT_SAVE_INTERVAL" \
    "$ROOT_DIR/scripts/run_simulator.sh" >"$simulator_log" 2>&1 &
  simulator_pid=$!

  client_status=1
  if wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 120; then
    set +e
    PYTHONUNBUFFERED=1 TARGET_BLOCK="$TARGET_BLOCK" SIMULATOR_DB="$db_path" \
      "$ROOT_DIR/scripts/run_mariadb_client.sh" >"$client_log" 2>&1
    client_status=$?
    set -e
  else
    echo "simulator did not become ready" >"$client_log"
  fi
  cleanup_simulator
  finished="$(date +%s%N)"
  elapsed_ms=$(((finished - started) / 1000000))

  experiment_id="$(sed -n 's/^experiment ID: //p' "$simulator_log" | tail -1)"
  run_dir=""
  simblocks=""
  leveldb_stats=""
  read_stats=""
  additional_node_stats=""
  if [[ "$child_stats" == true && -s "$workdir/additional_node_stats.txt" ]]; then
    additional_node_stats="$workdir/additional_node_stats.txt"
  fi
  completed_block=-1
  if [[ -n "$experiment_id" ]]; then
    run_dir="$workdir/logFiles/evm/runs/$experiment_id"
    for candidate in "$run_dir"/simBlocks/evm_simulation_result_"${experiment_id}"_0_*.json; do
      [[ -s "$candidate" ]] || continue
      candidate_name="${candidate##*/}"
      candidate_block="${candidate_name##*_0_}"
      candidate_block="${candidate_block%.json}"
      if [[ "$candidate_block" =~ ^[0-9]+$ ]] && ((candidate_block > completed_block)); then
        completed_block="$candidate_block"
        simblocks="$candidate"
      fi
    done

    if [[ "$backend" == "leveldb" && "$completed_block" -ge 0 ]]; then
      candidate="$run_dir/leveldbStats/leveldb_stats_${experiment_id}_0_${completed_block}.json"
      [[ -s "$candidate" ]] && leveldb_stats="$candidate"
      if [[ "$variant" == "stats" ]]; then
        candidate="$run_dir/leveldbStats/read_stats_${experiment_id}_${completed_block}.json"
        [[ -s "$candidate" ]] && read_stats="$candidate"
      fi
    fi
  fi

  status="complete"
  if ((client_status != 0)) || ((completed_block != TARGET_BLOCK)); then
    if ((completed_block >= 0)); then
      status="partial"
    else
      status="failed"
    fi
    failed_cases=$((failed_cases + 1))
  elif [[ "$backend" == "leveldb" && -z "$leveldb_stats" ]]; then
    status="failed"
    failed_cases=$((failed_cases + 1))
  elif [[ "$backend" == "leveldb" && "$variant" == "stats" && -z "$read_stats" ]]; then
    status="failed"
    failed_cases=$((failed_cases + 1))
  elif [[ "$child_stats" == true && -z "$additional_node_stats" ]]; then
    status="failed"
    failed_cases=$((failed_cases + 1))
  fi

  database_bytes=0
  [[ -d "$db_path" ]] && database_bytes="$(du -sb "$db_path" | awk '{print $1}')"
  jq -n --argjson manifest_case "$row" \
    --arg case_id "$case_id" --arg variant "$variant" --arg scheme "$scheme" \
    --arg state_mode "$state_mode" --arg backend "$backend" \
    --arg compression "$compression" --arg status "$status" \
    --arg profile "$profile" --arg experiment_id "$experiment_id" \
    --argjson pathdb_history "$pathdb_history" \
    --argjson child_stats "$child_stats" \
    --argjson accurate_read_counters "$accurate_read_counters" \
    --argjson leveldb_stats_interval "$SIMULATOR_RESULT_SAVE_INTERVAL" \
    --arg simblocks "${simblocks#"$ROOT_DIR/"}" \
    --arg leveldb_stats "${leveldb_stats#"$ROOT_DIR/"}" \
    --arg read_stats "${read_stats#"$ROOT_DIR/"}" \
    --arg additional_node_stats "${additional_node_stats#"$ROOT_DIR/"}" \
    --arg simulator_log "${simulator_log#"$ROOT_DIR/"}" \
    --arg client_log "${client_log#"$ROOT_DIR/"}" \
    --argjson target_block "$TARGET_BLOCK" \
    --argjson completed_block "$completed_block" \
    --argjson client_exit_status "$client_status" \
    --argjson elapsed_ms "$elapsed_ms" \
    --argjson database_bytes "$database_bytes" '
      {
        case_id: $case_id, experiment_id: $experiment_id,
        variant: $variant, scheme: $scheme, state_mode: $state_mode,
        backend: $backend, compression: $compression, status: $status,
        manifest_case: $manifest_case, profile: $profile,
        resolved: {experiment_id: $experiment_id, target_block: $target_block,
          completed_block: $completed_block, pathdb_history: $pathdb_history,
          child_stats: $child_stats, accurate_read_counters: $accurate_read_counters,
          leveldb_stats_interval: $leveldb_stats_interval,
          result_save_interval: $leveldb_stats_interval},
        client_exit_status: $client_exit_status,
        elapsed_seconds: ($elapsed_ms / 1000), database_bytes: $database_bytes,
        outputs: {
          simblocks: (if $simblocks == "" then null else $simblocks end),
          leveldb_stats: (if $leveldb_stats == "" then null else $leveldb_stats end),
          read_stats: (if $read_stats == "" then null else $read_stats end),
          additional_node_stats: (if $additional_node_stats == "" then null else $additional_node_stats end),
          simulator_log: $simulator_log, client_log: $client_log
        }
      }' >>"$rows"
  echo "[$case_id] $status at block $completed_block in $(awk "BEGIN {printf \"%.3f\", $elapsed_ms/1000}") seconds"
done

jq -s --arg experiment "$experiment" --arg profile "$profile" \
  --argjson target_block "$TARGET_BLOCK" \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {status:(if all(.[]; .status == "complete") then "PASS" else "PARTIAL" end),
     experiment:$experiment, profile:$profile,
     target_block:$target_block,
     generated_at_utc:$generated_at_utc, case_count:length,
     complete_case_count:([.[] | select(.status == "complete")] | length),
     partial_case_count:([.[] | select(.status == "partial")] | length),
     failed_case_count:([.[] | select(.status == "failed")] | length),
     total_elapsed_seconds:([.[].elapsed_seconds]|add), cases:.}' \
  "$rows" >"$report"
echo "$experiment $profile: $(jq -r '.status' "$report")"
echo "Report: $report"
((failed_cases == 0)) || exit 1
