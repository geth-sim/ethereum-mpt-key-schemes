#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

echo "Removing all reproducible/generated files"
rm -rf "$SOURCE_DIR" "$BIN_DIR" "$RUNTIME_DIR" "$LOG_DIR"
find "$ROOT_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
echo "The next ./scripts/reproduce.sh run will clone, build, acquire input, and replay from scratch."
