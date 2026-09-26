#!/usr/bin/env bash
set -euo pipefail
target_was_set="${TARGET_BLOCK+x}"
target_override="${TARGET_BLOCK-}"
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
[[ -z "$target_was_set" ]] || TARGET_BLOCK="$target_override"
[[ "$TARGET_BLOCK" =~ ^(0|[1-9][0-9]*)$ ]] ||
  die "TARGET_BLOCK must be a non-negative integer without leading zeros"

require_command python3

export SIMULATOR_DB_HOST="$MARIADB_HOST"
export SIMULATOR_DB_PORT="$MARIADB_PORT"
export SIMULATOR_DB_USER="$MARIADB_USER"
export SIMULATOR_DB_PASSWORD="$MARIADB_PASSWORD"
export SIMULATOR_DB_NAME="$MARIADB_DATABASE"
export SIMULATOR_STATE_DB_PATH="$SIMULATOR_DB"
export SIMULATOR_DELETE_STATE_DB=true
export SIMULATOR_RESULT_SAVE_INTERVAL

# Check the complete requested prefix before the client can reset its state DB.
python3 - "$TARGET_BLOCK" <<'PY'
import os
import sys

try:
    import pymysql
except ImportError:
    raise SystemExit("ERROR: PyMySQL is required (tested version: 1.0.2)")

target = int(sys.argv[1])
try:
    with pymysql.connect(
        host=os.environ["SIMULATOR_DB_HOST"],
        port=int(os.environ["SIMULATOR_DB_PORT"]),
        user=os.environ["SIMULATOR_DB_USER"],
        password=os.environ["SIMULATOR_DB_PASSWORD"],
        database=os.environ["SIMULATOR_DB_NAME"],
        connect_timeout=10,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT COUNT(*), MIN(number), MAX(number) "
                "FROM blocks WHERE number BETWEEN 0 AND %s",
                (target,),
            )
            count, first, last = cursor.fetchone()
except pymysql.MySQLError as error:
    raise SystemExit(f"ERROR: cannot read MariaDB input: {error}")

if count != target + 1:
    present = "no blocks" if count == 0 else f"blocks {first}..{last} ({count} rows)"
    raise SystemExit(
        f"ERROR: MariaDB input is incomplete for blocks 0..{target}: "
        f"found {present}; expected {target + 1} blocks.\n"
        f"Prepare Ethereum data through block {target} before replaying."
    )
PY

mkdir -p "$SIMULATOR_DB"
exec python3 "$GETH_DIR/build/bin/experiment/state_simulator.py" \
  "$SIMULATOR_PORT" 0 "$TARGET_BLOCK" 0
