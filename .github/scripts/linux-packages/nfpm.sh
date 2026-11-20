#!/usr/bin/env bash
# Put the pinned release of nfpm into a directory: its release binary for
# this machine's architecture, checked against the checksums.txt of the
# release. nfpm wraps a prebuilt folder into a package, and makes the plugin
# packages of a cargo build.
#
#   nfpm.sh BIN_DIR
#
# The version and its checksums are pinned here and nowhere else.
set -euo pipefail

nfpm_version="2.49.0"
nfpm_sha256_x86_64="2afaa5ffb5e3493402e31e7c67a5a1fb42133e3f66fc315ca0051934125561c7"
nfpm_sha256_aarch64="d4eee71839e92c68cbd3b101640bad32d2856fc551acae0635be9118e48c9d9c"

bin="${1:?usage: nfpm.sh BIN_DIR}"
mkdir -p "$bin"

case "$(uname -m)" in
  x86_64) asset="nfpm_${nfpm_version}_Linux_x86_64.tar.gz" sha256="$nfpm_sha256_x86_64" ;;
  aarch64) asset="nfpm_${nfpm_version}_Linux_arm64.tar.gz" sha256="$nfpm_sha256_aarch64" ;;
  *)
    echo "::error::no nfpm for $(uname -m)"
    exit 1
    ;;
esac
download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT
curl -fsSL --retry 3 -o "$download/$asset" \
  "https://github.com/goreleaser/nfpm/releases/download/v$nfpm_version/$asset"
echo "$sha256  $download/$asset" | sha256sum --check --quiet
tar -xzf "$download/$asset" -C "$bin" nfpm
"$bin/nfpm" --version | grep -i -m 1 version || true
