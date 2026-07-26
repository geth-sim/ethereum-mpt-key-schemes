#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command curl
require_command jq
[[ -x "$BIN_DIR/geth" ]] || die "geth is not built; run ./scripts/build.sh first"

rm -f "$RPC_READY_FILE"
"$ROOT_DIR/scripts/prepare_input.sh"

echo "Starting offline HTTP RPC at $RPC_URL"
"$BIN_DIR/geth" \
  --datadir "$GETH_DATADIR" \
  --ipcdisable \
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

actual_genesis="$(
  rpc_call eth_getBlockByNumber '["0x0",false]' |
    jq -er '.result.hash' | tr '[:upper:]' '[:lower:]'
)"
actual_target="$(
  rpc_call eth_getBlockByNumber \
    "[\"$(printf '0x%x' "$TARGET_BLOCK")\",false]" |
    jq -er '.result.hash' | tr '[:upper:]' '[:lower:]'
)"

[[ "$actual_genesis" == "${GENESIS_HASH,,}" ]] ||
  die "genesis hash mismatch: $actual_genesis"
[[ "$actual_target" == "${TARGET_HASH,,}" ]] ||
  die "target hash mismatch: $actual_target"
printf '%s\n' "$actual_target" >"$RPC_READY_FILE"

echo
echo "READY: local Ethereum RPC is serving verified blocks 0..$TARGET_BLOCK"
echo "Prepared input method: $(<"$GETH_DATADIR/.input-method")"
echo "RPC URL: $RPC_URL"
echo "Keep this terminal open. Press Ctrl-C after the replay or import finishes."
wait "$geth_pid"
