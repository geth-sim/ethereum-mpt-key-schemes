#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

require_command git
require_command make
# Uses a suitable system Go, or installs the pinned bootstrap under runtime/.
# shellcheck source=ensure_go.sh
source "$ROOT_DIR/scripts/ensure_go.sh"

clone_and_checkout() {
  local repository="$1"
  local commit="$2"
  local destination="$3"

  if [[ ! -d "$destination/.git" ]]; then
    if [[ -e "$destination" ]]; then
      die "$destination exists but is not a git repository"
    fi
    echo "Cloning $repository"
    git clone --filter=blob:none "$repository" "$destination"
  fi

  if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "Fetching pinned commit $commit"
    git -C "$destination" fetch --depth 1 origin "$commit"
  fi
  git -C "$destination" checkout --detach "$commit"

  local actual
  actual="$(git -C "$destination" rev-parse HEAD)"
  [[ "$actual" == "$commit" ]] || die "revision mismatch in $destination: $actual"
}

clone_and_checkout "$GETH_REPOSITORY" "$GETH_COMMIT" "$GETH_DIR"
clone_and_checkout "$SYNC_GETH_REPOSITORY" "$SYNC_GETH_COMMIT" "$SYNC_GETH_DIR"
clone_and_checkout "$GOLEVELDB_REPOSITORY" "$GOLEVELDB_FAST_COMMIT" "$GOLEVELDB_FAST_DIR"
clone_and_checkout "$GOLEVELDB_REPOSITORY" "$GOLEVELDB_STATS_COMMIT" "$GOLEVELDB_STATS_DIR"
clone_and_checkout "$DATA_ANALYSIS_REPOSITORY" "$DATA_ANALYSIS_COMMIT" "$DATA_ANALYSIS_DIR"

sync_tag_commit="$(git -C "$SYNC_GETH_DIR" rev-parse "$SYNC_GETH_VERSION^{commit}" 2>/dev/null)" ||
  die "geth release tag not found: $SYNC_GETH_VERSION"
[[ "$sync_tag_commit" == "$SYNC_GETH_COMMIT" ]] ||
  die "geth release tag $SYNC_GETH_VERSION does not identify pinned commit $SYNC_GETH_COMMIT"

echo "Building geth $SYNC_GETH_VERSION for ERA import, P2P fallback, and local RPC"
GOTOOLCHAIN="$SYNC_GO_TOOLCHAIN" make -C "$SYNC_GETH_DIR" geth
cp "$SYNC_GETH_DIR/build/bin/geth" "$BIN_DIR/geth.new"
mv -f "$BIN_DIR/geth.new" "$BIN_DIR/geth"

build_simulator() {
  local leveldb_dir="$1"
  local output="$2"
  local build_tags="${3:-}"
  local variant
  variant="$(basename "$output")"
  local modfile=".${variant}.mod"
  local sumfile=".${variant}.sum"
  local leveldb_version
  leveldb_version="$(
    awk '$1 == "github.com/syndtr/goleveldb" { print $2; exit }' "$GETH_DIR/go.mod"
  )"
  [[ -n "$leveldb_version" ]] || die "cannot determine goleveldb module version"

  cp "$GETH_DIR/go.mod" "$GETH_DIR/$modfile"
  cp "$GETH_DIR/go.sum" "$GETH_DIR/$sumfile"
  (
    cd "$GETH_DIR"
    GOTOOLCHAIN="$GO_TOOLCHAIN" go mod edit \
      -modfile="$modfile" \
      -dropreplace="github.com/syndtr/goleveldb@$leveldb_version"
    GOTOOLCHAIN="$GO_TOOLCHAIN" go mod edit \
      -modfile="$modfile" \
      -replace="github.com/syndtr/goleveldb@$leveldb_version=$leveldb_dir"
  )

  echo "Building $variant"
  if [[ -n "$build_tags" ]]; then
    (
      cd "$GETH_DIR"
      GOTOOLCHAIN="$GO_TOOLCHAIN" go build -modfile="$modfile" -tags "$build_tags" -o "$output" ./simulator
    )
  else
    (
      cd "$GETH_DIR"
      GOTOOLCHAIN="$GO_TOOLCHAIN" go build -modfile="$modfile" -o "$output" ./simulator
    )
  fi
  rm -f "$GETH_DIR/$modfile" "$GETH_DIR/$sumfile"
}

build_simulator "$GOLEVELDB_FAST_DIR" "$BIN_DIR/state-simulator-fast"
build_simulator "$GOLEVELDB_STATS_DIR" "$BIN_DIR/state-simulator-stats" "leveldbstats"
# Backward-compatible name used by the default quick workflow.
cp "$BIN_DIR/state-simulator-fast" "$BIN_DIR/state-simulator"

echo "Build completed"
"$BIN_DIR/geth" version | sed -n '1,6p'
echo "Fast simulator:     $BIN_DIR/state-simulator-fast"
echo "Detailed simulator: $BIN_DIR/state-simulator-stats"
