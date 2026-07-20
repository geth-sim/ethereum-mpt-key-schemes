#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT_DIR/config.env"

SOURCE_DIR="$ROOT_DIR/sources"
GETH_DIR="$SOURCE_DIR/go-ethereum"
SYNC_GETH_DIR="$SOURCE_DIR/go-ethereum-sync"
GOLEVELDB_FAST_DIR="$SOURCE_DIR/goleveldb-fast"
GOLEVELDB_STATS_DIR="$SOURCE_DIR/goleveldb-stats"
DATA_ANALYSIS_DIR="$SOURCE_DIR/data-analysis"
BIN_DIR="$ROOT_DIR/bin"
RUNTIME_DIR="$ROOT_DIR/runtime"
LOG_DIR="$ROOT_DIR/logs"
GETH_DATADIR="$RUNTIME_DIR/geth"
: "${SIMULATOR_WORKDIR:=$RUNTIME_DIR/simulator}"
: "${SIMULATOR_DB:=$RUNTIME_DIR/simulator-db}"
RPC_URL="http://$GETH_RPC_HOST:$GETH_RPC_PORT"
RPC_READY_FILE="$RUNTIME_DIR/rpc-ready-$TARGET_BLOCK-$TARGET_HASH"

mkdir -p "$SOURCE_DIR" "$BIN_DIR" "$RUNTIME_DIR" "$LOG_DIR"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

rpc_call() {
  local method="$1"
  local params="$2"
  local timeout="${3:-10}"
  curl -fsS --max-time "$timeout" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
    "$RPC_URL"
}

wait_for_rpc() {
  local attempts="${1:-120}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if rpc_call web3_clientVersion '[]' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local attempts="${3:-60}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if (echo >"/dev/tcp/$host/$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}
