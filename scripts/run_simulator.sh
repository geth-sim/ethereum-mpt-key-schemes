#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

case "$SIMULATOR_VARIANT" in
  fast)
    simulator_binary="$BIN_DIR/state-simulator-fast"
    ;;
  stats)
    simulator_binary="$BIN_DIR/state-simulator-stats"
    ;;
  *)
    die "unknown SIMULATOR_VARIANT=$SIMULATOR_VARIANT (available: fast, stats)"
    ;;
esac
[[ -x "$simulator_binary" ]] || die "simulator is not built; run ./scripts/build.sh first"
mkdir -p "$SIMULATOR_WORKDIR" "$SIMULATOR_DB"

simulator_args=(
  --port "$SIMULATOR_PORT"
  --scheme "$SIMULATOR_SCHEME"
  --state-mode "$SIMULATOR_STATE_MODE"
  --pathdb-history="$SIMULATOR_PATHDB_HISTORY"
  --db "$SIMULATOR_DB_BACKEND"
  --compression "$SIMULATOR_COMPRESSION"
  --myhash-cache-mb "$SIMULATOR_MYHASH_CACHE_MB"
  --myhash-cache-mode "$SIMULATOR_MYHASH_CACHE_MODE"
  --disk-size-multiplier "$SIMULATOR_DISK_SIZE_MULTIPLIER"
  --version-wrap "$SIMULATOR_VERSION_WRAP"
  --disk-size-interval "$SIMULATOR_DISK_SIZE_INTERVAL"
  --leveldb-stats-interval "$SIMULATOR_LEVELDB_STATS_INTERVAL"
)

case "$SIMULATOR_MYHASH" in
  true) simulator_args+=(--myhash) ;;
  false) ;;
  *) die "SIMULATOR_MYHASH must be true or false" ;;
esac
case "$SIMULATOR_PATHDB_HISTORY" in
  true | false) ;;
  *) die "SIMULATOR_PATHDB_HISTORY must be true or false" ;;
esac
case "$SIMULATOR_ACCURATE_READ_COUNTERS" in
  true) simulator_args+=(--accurate-read-counters) ;;
  false) ;;
  *) die "SIMULATOR_ACCURATE_READ_COUNTERS must be true or false" ;;
esac
case "$SIMULATOR_CHILD_STATS" in
  true) simulator_args+=(--child-stats) ;;
  false) ;;
  *) die "SIMULATOR_CHILD_STATS must be true or false" ;;
esac

echo "Starting state simulator on $SIMULATOR_HOST:$SIMULATOR_PORT"
echo "Simulator variant: $SIMULATOR_VARIANT"
echo "Scheme/backend: $SIMULATOR_SCHEME / $SIMULATOR_DB_BACKEND+$SIMULATOR_COMPRESSION / $SIMULATOR_STATE_MODE"
echo "Runtime files: $SIMULATOR_WORKDIR"
echo "State database: $SIMULATOR_DB"
echo "Keep this terminal open while the client runs."
cd "$SIMULATOR_WORKDIR"
exec "$simulator_binary" "${simulator_args[@]}"
