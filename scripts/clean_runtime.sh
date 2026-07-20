#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

echo "Removing generated runtime data under $RUNTIME_DIR"
rm -rf "$RUNTIME_DIR"
echo "Source checkouts and built binaries were kept."

