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
require_command curl
require_command jq
python3 -c 'import pymysql' >/dev/null 2>&1 ||
  die "PyMySQL is required (tested version: 1.0.2)"

# Reuse the hash checked by sync_and_serve, including when importing a shorter
# prefix. Confirm that the running RPC still serves that verified endpoint.
verified_hash=""
for marker in "$RUNTIME_DIR"/rpc-ready-*; do
  [[ -f "$marker" ]] || continue
  marker_name="${marker##*/rpc-ready-}"
  [[ "$marker_name" =~ ^([0-9]+)-(0x[[:xdigit:]]{64})$ ]] || continue
  marker_block="$((10#${BASH_REMATCH[1]}))"
  marker_hash="${BASH_REMATCH[2],,}"
  ((marker_block >= TARGET_BLOCK)) || continue
  stored_hash="$(<"$marker")"
  [[ "${stored_hash,,}" == "$marker_hash" ]] || continue
  actual_hash="$(
    rpc_call eth_getBlockByNumber \
      "[\"$(printf '0x%x' "$marker_block")\",false]" |
      jq -r '.result.hash // empty'
  )" || continue
  [[ "${actual_hash,,}" == "$marker_hash" ]] || continue
  verified_hash="$marker_hash"
  break
done
[[ -n "$verified_hash" ]] ||
  die "no verified local RPC covers block $TARGET_BLOCK; keep ./scripts/sync_and_serve.sh running through at least that block"

target_hash="$verified_hash"
if ((TARGET_BLOCK != marker_block)); then
  target_hash="$(
    rpc_call eth_getBlockByNumber \
      "[\"$(printf '0x%x' "$TARGET_BLOCK")\",false]" |
      jq -er '.result.hash'
  )" || die "local RPC does not contain block $TARGET_BLOCK"
fi

exec python3 "$ROOT_DIR/mariadb/import_rpc.py" \
  --rpc-url "$RPC_URL" \
  --host "$MARIADB_HOST" \
  --port "$MARIADB_PORT" \
  --user "$MARIADB_USER" \
  --password "$MARIADB_PASSWORD" \
  --database "$MARIADB_DATABASE" \
  --start-block 0 \
  --end-block "$TARGET_BLOCK" \
  --target-hash "$target_hash" \
  --commit-interval 1000 \
  --progress-interval "$PROGRESS_INTERVAL"
