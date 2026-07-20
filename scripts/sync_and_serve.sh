#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command curl
require_command jq
[[ -x "$BIN_DIR/geth" ]] || die "geth is not built; run ./scripts/build.sh first"

mkdir -p "$GETH_DATADIR" "$LOG_DIR"
SYNC_MARKER="$GETH_DATADIR/.synced-$TARGET_BLOCK-$TARGET_HASH"
SYNC_LOG="$LOG_DIR/geth-target-sync.log"
rm -f "$RPC_READY_FILE"

# A datadir acquired for a higher pinned target already contains this prefix.
# Record the requested target locally and let the hash checks below validate it
# after the offline RPC starts. This avoids asking peers for an older block.
if [[ ! -f "$SYNC_MARKER" ]]; then
  for marker in "$GETH_DATADIR"/.synced-*; do
    [[ -f "$marker" ]] || continue
    marker_name="${marker##*/.synced-}"
    marker_block="${marker_name%%-*}"
    if [[ "$marker_block" =~ ^[0-9]+$ ]] && ((marker_block >= TARGET_BLOCK)); then
      echo "Reusing higher completed target from ${marker##*/}"
      touch "$SYNC_MARKER"
      break
    fi
  done
fi

if [[ ! -f "$SYNC_MARKER" ]]; then
  echo "Target-syncing Ethereum mainnet blocks 0..$TARGET_BLOCK"
  echo "Target hash: $TARGET_HASH"
  echo "Waiting for live peers before submitting the full-sync target."
  : >"$SYNC_LOG"

  "$BIN_DIR/geth" \
    --datadir "$GETH_DATADIR" \
    --syncmode full \
    --exitwhensynced \
    --http \
    --http.addr "$GETH_RPC_HOST" \
    --http.port "$GETH_RPC_PORT" \
    --http.api debug,eth,net,web3 \
    --http.vhosts localhost \
    --cache "$GETH_CACHE_MB" \
    --port "$GETH_P2P_PORT" \
    --verbosity 3 >"$SYNC_LOG" 2>&1 &
  sync_pid=$!

  cleanup_sync() {
    kill "$sync_pid" >/dev/null 2>&1 || true
    wait "$sync_pid" >/dev/null 2>&1 || true
  }
  trap cleanup_sync EXIT INT TERM

  wait_for_rpc 120 || die "sync geth RPC did not become ready; see $SYNC_LOG"

  peer_ready=false
  for ((attempt = 1; attempt <= 300; attempt++)); do
    if ! kill -0 "$sync_pid" >/dev/null 2>&1; then
      wait "$sync_pid" || true
      die "sync geth exited while discovering peers; see $SYNC_LOG"
    fi
    peer_hex="$(rpc_call net_peerCount '[]' 2>/dev/null | jq -r '.result // "0x0"' || echo '0x0')"
    peer_count=$((peer_hex))
    if ((peer_count > 0)); then
      peer_ready=true
      echo "Connected peers: $peer_count"
      break
    fi
    if ((attempt % 10 == 0)); then
      echo "Still discovering Ethereum peers ($attempt seconds)"
    fi
    sleep 1
  done
  [[ "$peer_ready" == true ]] || die "no Ethereum peers after 5 minutes; see $SYNC_LOG"

  target_accepted=false
  for ((attempt = 1; attempt <= 10; attempt++)); do
    sync_response="$(rpc_call debug_sync "[\"$TARGET_HASH\"]" "$SYNC_TARGET_RPC_TIMEOUT")"
    if jq -e '.error == null' >/dev/null <<<"$sync_response"; then
      target_accepted=true
      break
    fi
    sync_error="$(jq -r '.error.message // "unknown error"' <<<"$sync_response")"
    if [[ "$sync_error" == "stale sync target, current: $TARGET_BLOCK, received: $TARGET_BLOCK" ]]; then
      echo "The requested target is already active; continuing the existing sync"
      target_accepted=true
      break
    fi
    if [[ "$sync_error" == "request timed out" ]]; then
      echo "Peer could not serve the target yet; retrying debug_sync ($attempt/10)"
      sleep 5
      continue
    fi
    die "geth rejected the sync target: $sync_response"
  done
  [[ "$target_accepted" == true ]] ||
    die "geth peers could not serve target after repeated debug_sync attempts; see $SYNC_LOG"

  echo "Sync target accepted; waiting for block execution to finish"
  while kill -0 "$sync_pid" >/dev/null 2>&1; do
    current_hex="$(rpc_call eth_blockNumber '[]' 2>/dev/null | jq -r '.result // "0x0"' || echo '0x0')"
    echo "geth full-sync progress: $((current_hex))/$TARGET_BLOCK"
    sleep 5
  done
  set +e
  wait "$sync_pid"
  geth_status=$?
  set -e
  trap - EXIT INT TERM

  if ! grep -q "Sync target reached" "$SYNC_LOG"; then
    die "target sync did not reach the pinned block (geth exit status: $geth_status); see $SYNC_LOG"
  fi
  touch "$SYNC_MARKER"
else
  echo "Reusing completed target sync: $SYNC_MARKER"
fi

echo "Starting offline HTTP RPC at $RPC_URL"
"$BIN_DIR/geth" \
  --datadir "$GETH_DATADIR" \
  --http \
  --http.addr "$GETH_RPC_HOST" \
  --http.port "$GETH_RPC_PORT" \
  --http.api eth,net,web3 \
  --http.vhosts localhost \
  --nodiscover \
  --maxpeers 0 \
  --port "$GETH_P2P_PORT" \
  --cache "$GETH_CACHE_MB" \
  --verbosity 3 &
geth_pid=$!

cleanup() {
  rm -f "$RPC_READY_FILE"
  kill "$geth_pid" >/dev/null 2>&1 || true
  wait "$geth_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_for_rpc 120 || die "geth RPC did not become ready at $RPC_URL"

actual_genesis="$(rpc_call eth_getBlockByNumber '["0x0",false]' | jq -er '.result.hash' | tr '[:upper:]' '[:lower:]')"
actual_target="$(rpc_call eth_getBlockByNumber "[\"$(printf '0x%x' "$TARGET_BLOCK")\",false]" | jq -er '.result.hash' | tr '[:upper:]' '[:lower:]')"

[[ "$actual_genesis" == "${GENESIS_HASH,,}" ]] || die "genesis hash mismatch: $actual_genesis"
[[ "$actual_target" == "${TARGET_HASH,,}" ]] || die "target hash mismatch: $actual_target"
printf '%s\n' "$actual_target" >"$RPC_READY_FILE"

echo
echo "READY: local Ethereum RPC is serving verified blocks 0..$TARGET_BLOCK"
echo "RPC URL: $RPC_URL"
echo "Keep this terminal open. Press Ctrl-C after the replay finishes."
wait "$geth_pid"
