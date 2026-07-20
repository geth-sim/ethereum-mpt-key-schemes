#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command curl
require_command date
require_command jq

now_ns() {
  date +%s%N
}

elapsed_ms() {
  local start_ns="$1"
  local end_ns="$2"
  echo $(((end_ns - start_ns) / 1000000))
}

workflow_started="$(now_ns)"
workflow_started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
phase_started="$workflow_started"
"$ROOT_DIR/scripts/build.sh"
phase_finished="$(now_ns)"
build_ms="$(elapsed_ms "$phase_started" "$phase_finished")"

sync_marker="$GETH_DATADIR/.synced-$TARGET_BLOCK-$TARGET_HASH"
target_sync_reused=false
if [[ -f "$sync_marker" ]]; then
  target_sync_reused=true
else
  for marker in "$GETH_DATADIR"/.synced-*; do
    [[ -f "$marker" ]] || continue
    marker_name="${marker##*/.synced-}"
    marker_block="${marker_name%%-*}"
    if [[ "$marker_block" =~ ^[0-9]+$ ]] && ((marker_block >= TARGET_BLOCK)); then
      target_sync_reused=true
      break
    fi
  done
fi

rpc_pid=""
simulator_pid=""
cleanup() {
  if [[ -n "$simulator_pid" ]]; then
    kill "$simulator_pid" >/dev/null 2>&1 || true
    wait "$simulator_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$rpc_pid" ]]; then
    kill "$rpc_pid" >/dev/null 2>&1 || true
    wait "$rpc_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting target sync / RPC service"
phase_started="$(now_ns)"
rm -f "$RPC_READY_FILE"
"$ROOT_DIR/scripts/sync_and_serve.sh" >"$LOG_DIR/sync-and-rpc.console.log" 2>&1 &
rpc_pid=$!
rpc_ready=false
for ((attempt = 1; attempt <= 7200; attempt++)); do
  if [[ -f "$RPC_READY_FILE" ]] && grep -Fxq "${TARGET_HASH,,}" "$RPC_READY_FILE"; then
    rpc_ready=true
    break
  fi
  if ! kill -0 "$rpc_pid" >/dev/null 2>&1; then
    wait "$rpc_pid" || true
    die "target sync / RPC service exited; see $LOG_DIR/sync-and-rpc.console.log"
  fi
  sleep 1
done
[[ "$rpc_ready" == true ]] || die "RPC did not become ready; see $LOG_DIR/sync-and-rpc.console.log"
phase_finished="$(now_ns)"
data_and_rpc_ms="$(elapsed_ms "$phase_started" "$phase_finished")"

echo "Starting simulator"
phase_started="$(now_ns)"
"$ROOT_DIR/scripts/run_simulator.sh" >"$LOG_DIR/simulator.console.log" 2>&1 &
simulator_pid=$!
wait_for_tcp "$SIMULATOR_HOST" "$SIMULATOR_PORT" 120 || die "simulator did not become ready; see $LOG_DIR/simulator.console.log"
phase_finished="$(now_ns)"
simulator_start_ms="$(elapsed_ms "$phase_started" "$phase_finished")"

echo "Starting genesis-to-target replay"
phase_started="$(now_ns)"
"$ROOT_DIR/scripts/run_quick_client.sh"
phase_finished="$(now_ns)"
client_ms="$(elapsed_ms "$phase_started" "$phase_finished")"

phase_started="$(now_ns)"
"$ROOT_DIR/scripts/inspect_quick_results.sh"
phase_finished="$(now_ns)"
inspection_ms="$(elapsed_ms "$phase_started" "$phase_finished")"
workflow_finished="$(now_ns)"
total_ms="$(elapsed_ms "$workflow_started" "$workflow_finished")"

jq -n \
  --arg workflow_started_utc "$workflow_started_utc" \
  --arg target_hash "$TARGET_HASH" \
  --argjson target_block "$TARGET_BLOCK" \
  --argjson target_sync_reused "$target_sync_reused" \
  --argjson build_ms "$build_ms" \
  --argjson data_and_rpc_ms "$data_and_rpc_ms" \
  --argjson simulator_start_ms "$simulator_start_ms" \
  --argjson client_ms "$client_ms" \
  --argjson inspection_ms "$inspection_ms" \
  --argjson total_ms "$total_ms" '
    {
      workflow_started_utc: $workflow_started_utc,
      target_block: $target_block,
      target_hash: $target_hash,
      target_sync_reused: $target_sync_reused,
      build_seconds: ($build_ms / 1000),
      data_acquisition_and_rpc_ready_seconds: ($data_and_rpc_ms / 1000),
      simulator_start_seconds: ($simulator_start_ms / 1000),
      client_replay_and_output_seconds: ($client_ms / 1000),
      result_inspection_seconds: ($inspection_ms / 1000),
      total_seconds: ($total_ms / 1000)
    }
  ' >"$RUNTIME_DIR/phase-timings.json"

echo
echo "REPRODUCIBILITY QUICK CHECK: PASS"
echo "Simulator results: $SIMULATOR_WORKDIR/logFiles/evm/runs"
echo "Phase timings: $RUNTIME_DIR/phase-timings.json"
echo "Logs: $LOG_DIR"
