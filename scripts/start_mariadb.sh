#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command mariadb
require_command mariadb-install-db
require_command mariadbd

MARIADB_RUNTIME="$RUNTIME_DIR/mariadb"
MARIADB_DATADIR="$MARIADB_RUNTIME/data"
# Keep the Unix socket close to the runtime root. Unix-domain socket paths are
# limited to 107 bytes on Linux, and artifact clones often have long paths.
MARIADB_SOCKET="$RUNTIME_DIR/mariadb.sock"
MARIADB_PIDFILE="$MARIADB_RUNTIME/mariadb.pid"
MARIADB_LOG="$LOG_DIR/mariadb.log"
MARIADB_TMP="$MARIADB_RUNTIME/tmp"

mkdir -p "$MARIADB_RUNTIME" "$MARIADB_TMP" "$LOG_DIR"
if [[ ! -d "$MARIADB_DATADIR/mysql" ]]; then
  echo "Initializing MariaDB data directory: $MARIADB_DATADIR"
  mariadb-install-db \
    --no-defaults \
    --datadir="$MARIADB_DATADIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db
fi

echo "Starting MariaDB at $MARIADB_HOST:$MARIADB_PORT"
mariadbd \
  --no-defaults \
  --datadir="$MARIADB_DATADIR" \
  --socket="$MARIADB_SOCKET" \
  --port="$MARIADB_PORT" \
  --bind-address="$MARIADB_HOST" \
  --pid-file="$MARIADB_PIDFILE" \
  --log-error="$MARIADB_LOG" \
  --tmpdir="$MARIADB_TMP" &
mariadb_pid=$!

cleanup() {
  kill "$mariadb_pid" >/dev/null 2>&1 || true
  wait "$mariadb_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

ready=false
for ((attempt = 1; attempt <= 60; attempt++)); do
  if mariadb --protocol=socket --socket="$MARIADB_SOCKET" -uroot \
    -e 'SELECT 1' >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$mariadb_pid" >/dev/null 2>&1; then
    die "MariaDB exited during startup; see $MARIADB_LOG"
  fi
  sleep 1
done
[[ "$ready" == true ]] || die "MariaDB did not become ready; see $MARIADB_LOG"

escaped_password="${MARIADB_PASSWORD//\'/\'\'}"
mariadb --protocol=socket --socket="$MARIADB_SOCKET" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE\`;
CREATE USER IF NOT EXISTS '$MARIADB_USER'@'127.0.0.1'
  IDENTIFIED BY '$escaped_password';
GRANT ALL PRIVILEGES ON \`$MARIADB_DATABASE\`.* TO '$MARIADB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
mariadb --protocol=socket --socket="$MARIADB_SOCKET" -uroot \
  "$MARIADB_DATABASE" <"$ROOT_DIR/mariadb/schema.sql"

echo
echo "READY: MariaDB schema is available at $MARIADB_HOST:$MARIADB_PORT"
echo "Data directory: $MARIADB_DATADIR"
echo "Keep this terminal open. Press Ctrl-C after import and replay finish."
wait "$mariadb_pid"
