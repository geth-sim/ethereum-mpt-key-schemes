#!/usr/bin/env bash

go_supports_toolchain_selection() {
  local version
  command -v go >/dev/null 2>&1 || return 1
  version="$(go version 2>/dev/null)" || return 1
  [[ "$version" =~ go([0-9]+)\.([0-9]+) ]] || return 1
  ((BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 21)))
}

if go_supports_toolchain_selection; then
  echo "Using system $(go version)"
else
  require_command curl
  require_command sha256sum
  require_command tar
  require_command uname

  [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] ||
    die "automatic Go bootstrap supports Linux x86-64; install Go 1.21+ manually on this platform"

  bootstrap_root="$RUNTIME_DIR/toolchains"
  bootstrap_dir="$bootstrap_root/go$GO_BOOTSTRAP_VERSION"
  bootstrap_go="$bootstrap_dir/bin/go"
  archive="$bootstrap_root/go$GO_BOOTSTRAP_VERSION.linux-amd64.tar.gz"
  expected_version="go version go$GO_BOOTSTRAP_VERSION linux/amd64"

  if [[ ! -x "$bootstrap_go" || "$("$bootstrap_go" version 2>/dev/null || true)" != "$expected_version" ]]; then
    mkdir -p "$bootstrap_root"
    echo "Installing pinned Go $GO_BOOTSTRAP_VERSION under $bootstrap_dir"
    curl -fL --retry 3 --retry-delay 2 \
      "https://go.dev/dl/go$GO_BOOTSTRAP_VERSION.linux-amd64.tar.gz" \
      -o "$archive"
    echo "$GO_BOOTSTRAP_SHA256  $archive" | sha256sum -c -

    install_tmp="$bootstrap_root/.go$GO_BOOTSTRAP_VERSION.tmp"
    rm -rf "$install_tmp"
    mkdir -p "$install_tmp"
    tar -C "$install_tmp" -xzf "$archive"
    rm -rf "$bootstrap_dir"
    mv "$install_tmp/go" "$bootstrap_dir"
    rm -rf "$install_tmp"
    rm -f "$archive"
  else
    echo "Reusing artifact-local Go $GO_BOOTSTRAP_VERSION"
  fi

  export PATH="$bootstrap_dir/bin:$PATH"
fi

require_command go
