#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command python3
[[ -f "$RPC_READY_FILE" ]] ||
  die "verified local RPC is not ready; keep ./scripts/sync_and_serve.sh running"
python3 -c 'import pymysql' >/dev/null 2>&1 ||
  die "PyMySQL is required (tested version: 1.0.2)"

exec python3 "$ROOT_DIR/mariadb/import_rpc.py" \
  --rpc-url "$RPC_URL" \
  --host "$MARIADB_HOST" \
  --port "$MARIADB_PORT" \
  --user "$MARIADB_USER" \
  --password "$MARIADB_PASSWORD" \
  --database "$MARIADB_DATABASE" \
  --start-block 0 \
  --end-block "$TARGET_BLOCK" \
  --target-hash "$TARGET_HASH" \
  --commit-interval 1000 \
  --progress-interval "$PROGRESS_INTERVAL"
