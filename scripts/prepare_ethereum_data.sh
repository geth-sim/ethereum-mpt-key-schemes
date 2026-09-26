#!/usr/bin/env bash
set -euo pipefail
# Preserve explicit empty values so a missing shell variable cannot silently
# select the default target from config.env.
target_block_was_set="${TARGET_BLOCK+x}"
target_block_override="${TARGET_BLOCK-}"
target_hash_was_set="${TARGET_HASH+x}"
target_hash_override="${TARGET_HASH-}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
[[ -z "$target_block_was_set" ]] || TARGET_BLOCK="$target_block_override"
[[ -z "$target_hash_was_set" ]] || TARGET_HASH="$target_hash_override"
[[ "$TARGET_BLOCK" =~ ^(0|[1-9][0-9]*)$ ]] ||
  die "TARGET_BLOCK must be a non-negative integer without leading zeros"
[[ "$TARGET_HASH" =~ ^0x[[:xdigit:]]{64}$ ]] ||
  die "TARGET_HASH must be the matching 0x-prefixed block hash"
export TARGET_BLOCK TARGET_HASH

for command in curl jq python3 mariadb mariadb-install-db mariadbd setsid nohup flock; do
  require_command "$command"
done
python3 -c 'import pymysql' >/dev/null 2>&1 ||
  die "PyMySQL is required (tested version: 1.0.2)"
[[ -x "$BIN_DIR/geth" ]] || die "geth is not built; run ./scripts/build.sh first"

exec 9>"$RUNTIME_DIR/prepare-ethereum-data.lock"
flock -n 9 || die "Ethereum data preparation is already running in this checkout"

rpc_log="$LOG_DIR/prepare-ethereum-rpc.log"
mariadb_log="$LOG_DIR/mariadb.console.log"
rpc_pid=""
mariadb_pid=""
import_pid=""
keep_mariadb=false

stop_service() {
  local pid="$1"
  # Each service gets its own process group, including acquisition subprocesses.
  kill -- "-$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$import_pid" ]]; then
    kill "$import_pid" >/dev/null 2>&1 || true
    wait "$import_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$rpc_pid" ]]; then
    stop_service "$rpc_pid"
    rm -f "$RPC_READY_FILE"
  fi
  if [[ -n "$mariadb_pid" && "$keep_mariadb" != true ]]; then
    stop_service "$mariadb_pid"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mariadb_query() {
  MYSQL_PWD="$MARIADB_PASSWORD" mariadb --no-defaults \
    --protocol=tcp --connect-timeout=2 \
    --host="$MARIADB_HOST" --port="$MARIADB_PORT" --user="$MARIADB_USER" \
    --database="$MARIADB_DATABASE" --batch --skip-column-names -e "$1"
}

local_mariadb_ready() {
  local datadir
  datadir="$(mariadb_query '
    SELECT @@datadir;
    SELECT 1 FROM blocks LIMIT 0;
    SELECT 1 FROM transactions LIMIT 0;
    SELECT 1 FROM transactions_accesslist LIMIT 0;
    SELECT 1 FROM uncles LIMIT 0;
  ' 2>/dev/null)" || return 1
  [[ "${datadir%/}" == "$RUNTIME_DIR/mariadb/data" ]]
}

if wait_for_tcp "$GETH_RPC_HOST" "$GETH_RPC_PORT" 1; then
  die "RPC port $GETH_RPC_PORT is already in use; stop the existing RPC before preparing data"
fi
if wait_for_tcp "$MARIADB_HOST" "$MARIADB_PORT" 1 && ! local_mariadb_ready; then
  die "port $MARIADB_PORT is in use by a server other than this artifact's ready MariaDB"
fi

echo "Preparing Ethereum data through block $TARGET_BLOCK (log: $rpc_log)"
rm -f "$RPC_READY_FILE"
setsid "$ROOT_DIR/scripts/sync_and_serve.sh" >"$rpc_log" 2>&1 < /dev/null 9>&- &
rpc_pid=$!
while true; do
  if ! kill -0 "$rpc_pid" >/dev/null 2>&1; then
    tail -n 20 "$rpc_log" >&2
    die "Ethereum data preparation / RPC failed; see $rpc_log"
  fi
  if [[ -f "$RPC_READY_FILE" && "$(<"$RPC_READY_FILE")" == "${TARGET_HASH,,}" ]]; then
    break
  fi
  sleep 1
done

if local_mariadb_ready; then
  echo "Using the running artifact MariaDB at $MARIADB_HOST:$MARIADB_PORT"
else
  echo "Starting MariaDB in the background (log: $mariadb_log)"
  nohup setsid "$ROOT_DIR/scripts/start_mariadb.sh" >"$mariadb_log" 2>&1 < /dev/null 9>&- &
  mariadb_pid=$!
  mariadb_ready=false
  for ((attempt = 1; attempt <= 120; attempt++)); do
    if ! kill -0 "$mariadb_pid" >/dev/null 2>&1; then
      tail -n 20 "$mariadb_log" >&2
      die "MariaDB startup failed; see $mariadb_log and $LOG_DIR/mariadb.log"
    fi
    if local_mariadb_ready; then
      mariadb_ready=true
      break
    fi
    sleep 1
  done
  [[ "$mariadb_ready" == true ]] || die "MariaDB did not become ready; see $mariadb_log"
fi

echo "Importing blocks 0..$TARGET_BLOCK into MariaDB"
PYTHONUNBUFFERED=1 "$ROOT_DIR/scripts/import_mariadb.sh" 9>&- &
import_pid=$!
wait "$import_pid" || die "MariaDB import failed; see the error above"
import_pid=""
stop_service "$rpc_pid"
rpc_pid=""
keep_mariadb=true

echo
echo "READY: Ethereum data through block $TARGET_BLOCK is available in MariaDB."
echo "MariaDB is running in the background. You can run experiments in this terminal."
