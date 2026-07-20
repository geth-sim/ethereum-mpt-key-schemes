#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command python3
mkdir -p "$SIMULATOR_DB"

exec python3 "$ROOT_DIR/rpc_state_simulator.py" \
  --rpc-url "$RPC_URL" \
  --simulator-host "$SIMULATOR_HOST" \
  --simulator-port "$SIMULATOR_PORT" \
  --start-block 0 \
  --end-block "$TARGET_BLOCK" \
  --target-hash "$TARGET_HASH" \
  --db-path "$SIMULATOR_DB" \
  --delete-db \
  --progress-interval "$PROGRESS_INTERVAL" \
  --summary-output "$RUNTIME_DIR/quick-summary.json"
