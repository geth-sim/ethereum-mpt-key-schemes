#!/usr/bin/env bash
set -euo pipefail
target_was_set="${TARGET_BLOCK+x}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run_paper_experiment.sh E1 validation [case-id]
  ./scripts/run_paper_experiment.sh E1 paper [case-id]
  ./scripts/run_paper_experiment.sh E1 list

validation runs only manifest rows marked validation=true (50K by default).
paper runs every replay row for the experiment (10M by default).
Set TARGET_BLOCK explicitly to override either default.
EOF
}

experiment="${1:-}"
profile="${2:-}"
case_filter="${3:-}"
manifest="$ROOT_DIR/experiments/paper-experiments.json"
[[ "$experiment" =~ ^E[1-7]$ ]] || { usage; exit 2; }
[[ -f "$manifest" ]] || die "missing $manifest"

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

if [[ -z "$target_was_set" ]]; then
  if [[ "$profile" == "validation" ]]; then
    TARGET_BLOCK="$TARGET_50K_BLOCK"
    TARGET_HASH="$TARGET_50K_HASH"
  else
    TARGET_BLOCK="$TARGET_10M_BLOCK"
    TARGET_HASH="$TARGET_10M_HASH"
  fi
fi
if [[ "$experiment" == "E2" ]]; then
  die "E2 is a post-processing database rewrite; use ./scripts/run_e2_db_rewrites.sh"
fi

require_command date
require_command jq
require_command python3

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

run_root="$RUNTIME_DIR/paper-experiments/$profile/$experiment"
if [[ -n "$case_filter" ]]; then
  rows="$run_root/results_${case_filter}.jsonl"
  report="$run_root/run-report_${case_filter}.json"
else
  rows="$run_root/results.jsonl"
  report="$run_root/run-report.json"
fi
mkdir -p "$run_root"
: >"$rows"

simulator_pid=""
cleanup_simulator() {
  if [[ -n "$simulator_pid" ]]; then
    kill "$simulator_pid" >/dev/null 2>&1 || true
    wait "$simulator_pid" >/dev/null 2>&1 || true
    simulator_pid=""
  fi
}
trap cleanup_simulator EXIT INT TERM

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
  if [[ "$profile" == "validation" && "$scheme" == "P" ]]; then
    pathdb_history=false
  fi

  case_root="$run_root/$case_id"
  workdir="$case_root/output"
  db_path="$case_root/database"
  simulator_log="$case_root/simulator.log"
  client_log="$case_root/client.log"
  mkdir -p "$workdir"
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
  SIMULATOR_LEVELDB_STATS_INTERVAL="$TARGET_BLOCK" \
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
  fi

  database_bytes=0
  [[ -d "$db_path" ]] && database_bytes="$(du -sb "$db_path" | awk '{print $1}')"
  jq -n --argjson manifest_case "$row" \
    --arg case_id "$case_id" --arg variant "$variant" --arg scheme "$scheme" \
    --arg state_mode "$state_mode" --arg backend "$backend" \
    --arg compression "$compression" --arg status "$status" \
    --arg profile "$profile" --arg experiment_id "$experiment_id" \
    --argjson pathdb_history "$pathdb_history" \
    --arg simblocks "${simblocks#"$ROOT_DIR/"}" \
    --arg leveldb_stats "${leveldb_stats#"$ROOT_DIR/"}" \
    --arg read_stats "${read_stats#"$ROOT_DIR/"}" \
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
          completed_block: $completed_block, pathdb_history: $pathdb_history},
        client_exit_status: $client_exit_status,
        elapsed_seconds: ($elapsed_ms / 1000), database_bytes: $database_bytes,
        outputs: {
          simblocks: (if $simblocks == "" then null else $simblocks end),
          leveldb_stats: (if $leveldb_stats == "" then null else $leveldb_stats end),
          read_stats: (if $read_stats == "" then null else $read_stats end),
          simulator_log: $simulator_log, client_log: $client_log
        }
      }' >>"$rows"
  echo "[$case_id] $status at block $completed_block in $(awk "BEGIN {printf \"%.3f\", $elapsed_ms/1000}") seconds"
done

jq -s --arg experiment "$experiment" --arg profile "$profile" \
  --arg target_hash "$TARGET_HASH" --argjson target_block "$TARGET_BLOCK" \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {status:(if all(.[]; .status == "complete") then "PASS" else "PARTIAL" end),
     experiment:$experiment, profile:$profile,
     target_block:$target_block, target_hash:$target_hash,
     generated_at_utc:$generated_at_utc, case_count:length,
     complete_case_count:([.[] | select(.status == "complete")] | length),
     partial_case_count:([.[] | select(.status == "partial")] | length),
     failed_case_count:([.[] | select(.status == "failed")] | length),
     total_elapsed_seconds:([.[].elapsed_seconds]|add), cases:.}' \
  "$rows" >"$report"
echo "$experiment $profile: $(jq -r '.status' "$report")"
echo "Report: $report"
((failed_cases == 0)) || exit 1
