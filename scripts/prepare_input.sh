#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command curl
require_command jq
require_command sha256sum
[[ -x "$BIN_DIR/geth" ]] || die "geth is not built; run ./scripts/build.sh first"

# Every reduced profile shares the pinned 1M input. An explicitly requested
# larger target (for example the paper range) raises the acquisition endpoint.
acquire_block="$INPUT_TARGET_BLOCK"
acquire_hash="$INPUT_TARGET_HASH"
if ((TARGET_BLOCK > acquire_block)); then
  acquire_block="$TARGET_BLOCK"
  acquire_hash="$TARGET_HASH"
fi

acquisition_root="$RUNTIME_DIR/input-acquisition"
era_tmp="$acquisition_root/era.tmp"
target_sync_tmp="$acquisition_root/target-sync.tmp"
input_marker="$GETH_DATADIR/.input-ready-$acquire_block-${acquire_hash,,}"
method_file="$GETH_DATADIR/.input-method"
mkdir -p "$acquisition_root" "$LOG_DIR"
[[ "$ERA_DOWNLOAD_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] ||
  die "ERA_DOWNLOAD_ATTEMPTS must be a positive integer"
[[ "$INPUT_ACQUISITION_FALLBACK" == "target-sync" ||
  "$INPUT_ACQUISITION_FALLBACK" == "none" ]] ||
  die "INPUT_ACQUISITION_FALLBACK must be target-sync or none"

find_reusable_marker() {
  local marker marker_name marker_block
  [[ -f "$input_marker" && -s "$method_file" ]] && return 0
  for marker in "$GETH_DATADIR"/.input-ready-*; do
    [[ -f "$marker" ]] || continue
    marker_name="${marker##*/.input-ready-}"
    marker_block="${marker_name%%-*}"
    if [[ -s "$method_file" && "$marker_block" =~ ^[0-9]+$ ]] &&
      ((marker_block >= acquire_block)); then
      return 0
    fi
  done
  return 1
}

if find_reusable_marker; then
  echo "Reusing verified Ethereum input through at least block $acquire_block"
  exit 0
fi

stop_pid() {
  local pid="$1"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

verify_datadir() {
  local datadir="$1"
  local log_file="$2"
  local geth_pid actual_genesis actual_target

  rm -f "$RPC_READY_FILE"
  "$BIN_DIR/geth" \
    --datadir "$datadir" \
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
    --verbosity 3 >"$log_file" 2>&1 &
  geth_pid=$!

  if ! wait_for_rpc 120; then
    stop_pid "$geth_pid"
    return 1
  fi
  actual_genesis="$(
    rpc_call eth_getBlockByNumber '["0x0",false]' |
      jq -er '.result.hash' | tr '[:upper:]' '[:lower:]'
  )" || {
    stop_pid "$geth_pid"
    return 1
  }
  actual_target="$(
    rpc_call eth_getBlockByNumber \
      "[\"$(printf '0x%x' "$acquire_block")\",false]" |
      jq -er '.result.hash' | tr '[:upper:]' '[:lower:]'
  )" || {
    stop_pid "$geth_pid"
    return 1
  }
  stop_pid "$geth_pid"

  [[ "$actual_genesis" == "${GENESIS_HASH,,}" ]] || return 1
  [[ "$actual_target" == "${acquire_hash,,}" ]] || return 1
}

write_era_checksum_list() {
  local era_dir="$1"
  local checksum_file="$era_dir/checksums.txt"
  local file checksum first=true
  local -a files=()

  mapfile -t files < <(
    find "$era_dir" -maxdepth 1 -type f -name "*.${ERA_FORMAT}" \
      -printf '%f\n' | LC_ALL=C sort
  )
  ((${#files[@]} > 0)) || return 1

  : >"$checksum_file"
  for file in "${files[@]}"; do
    checksum="$(sha256sum "$era_dir/$file")"
    checksum="${checksum%% *}"
    if [[ "$first" == true ]]; then
      first=false
    else
      printf '\n' >>"$checksum_file"
    fi
    printf '0x%s' "$checksum" >>"$checksum_file"
  done
}

acquire_with_era() {
  local endpoint attempt era_dir
  local download_log="$LOG_DIR/era-download.log"
  local import_log="$LOG_DIR/era-import.log"
  local verify_log="$LOG_DIR/era-verify.log"

  : >"$download_log"
  for endpoint in $ERA_ENDPOINTS; do
    for ((attempt = 1; attempt <= ERA_DOWNLOAD_ATTEMPTS; attempt++)); do
      rm -rf "$era_tmp"
      mkdir -p "$era_tmp"
      echo "ERA download: blocks 0..$acquire_block from $endpoint (attempt $attempt/$ERA_DOWNLOAD_ATTEMPTS)" |
        tee -a "$download_log"
      if "$BIN_DIR/geth" download-era \
        --server "$endpoint" \
        --block "0-$acquire_block" \
        --datadir "$era_tmp" >>"$download_log" 2>&1; then
        era_dir="$era_tmp/geth/chaindata/ancient/chain/era"
        if write_era_checksum_list "$era_dir" &&
          "$BIN_DIR/geth" import-history \
            --era.format "$ERA_FORMAT" \
            --datadir "$era_tmp" "$era_dir" >"$import_log" 2>&1 &&
          verify_datadir "$era_tmp" "$verify_log"; then
          touch "$era_tmp/.input-ready-$acquire_block-${acquire_hash,,}"
          printf 'era\n' >"$era_tmp/.input-method"
          return 0
        fi
        echo "ERA import or verification failed; see $import_log and $verify_log" |
          tee -a "$download_log"
      else
        echo "ERA download failed; retrying if another attempt is available" |
          tee -a "$download_log"
      fi
    done
  done
  return 1
}

acquire_with_target_sync() {
  local sync_pid peer_hex peer_count sync_response sync_error
  local target_accepted=false
  local sync_log="$LOG_DIR/geth-target-sync.log"

  rm -rf "$target_sync_tmp"
  mkdir -p "$target_sync_tmp"
  : >"$sync_log"
  echo "P2P fallback: target-syncing blocks 0..$acquire_block"

  "$BIN_DIR/geth" \
    --datadir "$target_sync_tmp" \
    --ipcdisable \
    --syncmode full \
    --exitwhensynced \
    --http \
    --http.addr "$GETH_RPC_HOST" \
    --http.port "$GETH_RPC_PORT" \
    --http.api debug,eth,net,web3 \
    --http.vhosts localhost \
    --cache "$GETH_CACHE_MB" \
    --port "$GETH_P2P_PORT" \
    --verbosity 3 >"$sync_log" 2>&1 &
  sync_pid=$!

  if ! wait_for_rpc 120; then
    stop_pid "$sync_pid"
    return 1
  fi

  peer_count=0
  for ((attempt = 1; attempt <= 300; attempt++)); do
    if ! kill -0 "$sync_pid" >/dev/null 2>&1; then
      stop_pid "$sync_pid"
      return 1
    fi
    peer_hex="$(
      rpc_call net_peerCount '[]' 2>/dev/null |
        jq -r '.result // "0x0"' || echo '0x0'
    )"
    peer_count=$((peer_hex))
    ((peer_count > 0)) && break
    sleep 1
  done
  if ((peer_count == 0)); then
    stop_pid "$sync_pid"
    return 1
  fi

  for ((attempt = 1; attempt <= 10; attempt++)); do
    sync_response="$(
      rpc_call debug_sync "[\"$acquire_hash\"]" "$SYNC_TARGET_RPC_TIMEOUT"
    )"
    if jq -e '.error == null' >/dev/null <<<"$sync_response"; then
      target_accepted=true
      break
    fi
    sync_error="$(jq -r '.error.message // "unknown error"' <<<"$sync_response")"
    if [[ "$sync_error" == "stale sync target, current: $acquire_block, received: $acquire_block" ]]; then
      target_accepted=true
      break
    fi
    [[ "$sync_error" == "request timed out" ]] || break
    sleep 5
  done
  if [[ "$target_accepted" != true ]]; then
    stop_pid "$sync_pid"
    return 1
  fi

  while kill -0 "$sync_pid" >/dev/null 2>&1; do
    sleep 5
  done
  wait "$sync_pid" || true
  if ! grep -q "Sync target reached" "$sync_log" ||
    ! verify_datadir "$target_sync_tmp" "$LOG_DIR/target-sync-verify.log"; then
    return 1
  fi
  touch "$target_sync_tmp/.input-ready-$acquire_block-${acquire_hash,,}"
  printf 'target-sync\n' >"$target_sync_tmp/.input-method"
}

promote_datadir() {
  local prepared="$1"
  rm -rf "$GETH_DATADIR"
  mv "$prepared" "$GETH_DATADIR"
  rm -rf "$acquisition_root"
}

case "$INPUT_ACQUISITION_METHOD" in
  era)
    if acquire_with_era; then
      promote_datadir "$era_tmp"
    elif [[ "$INPUT_ACQUISITION_FALLBACK" == "target-sync" ]] &&
      acquire_with_target_sync; then
      promote_datadir "$target_sync_tmp"
    else
      die "ERA acquisition failed and no fallback completed; see $LOG_DIR"
    fi
    ;;
  target-sync)
    acquire_with_target_sync ||
      die "target sync failed; see $LOG_DIR/geth-target-sync.log"
    promote_datadir "$target_sync_tmp"
    ;;
  *)
    die "INPUT_ACQUISITION_METHOD must be era or target-sync"
    ;;
esac

echo "INPUT PREPARATION: PASS"
echo "Blocks available: 0..$acquire_block"
echo "Method: $(<"$method_file")"
