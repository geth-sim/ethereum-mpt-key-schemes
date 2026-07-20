#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command python3
mkdir -p "$SIMULATOR_DB"

export SIMULATOR_DB_HOST="$MARIADB_HOST"
export SIMULATOR_DB_PORT="$MARIADB_PORT"
export SIMULATOR_DB_USER="$MARIADB_USER"
export SIMULATOR_DB_PASSWORD="$MARIADB_PASSWORD"
export SIMULATOR_DB_NAME="$MARIADB_DATABASE"
export SIMULATOR_STATE_DB_PATH="$SIMULATOR_DB"
export SIMULATOR_DELETE_STATE_DB=true

exec python3 "$GETH_DIR/build/bin/experiment/state_simulator.py" \
  "$SIMULATOR_PORT" 0 "$TARGET_BLOCK" 0
