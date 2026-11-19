#!/usr/bin/env bash
# Get a target's container ready to build and package: the compiler, the
# app's build dependencies, the Rust toolchain and the packaging tool of the
# target's format. Runs as root inside the container, from the directory the
# app is built in.
#
#   TREBUCHET_FORMAT      deb or rpm
#   TREBUCHET_BUILD       cargo or prebuilt
#   TREBUCHET_BUILD_DEPS  space-separated distro packages (cargo only)
set -euo pipefail

# The tool versions, pinned here and nowhere else. The cargo tools are built
# from their crates.io sources; nfpm is its release binary, checked against
# the checksums.txt of the release.
cargo_deb_version="3.8.0"
cargo_generate_rpm_version="0.21.1"
nfpm_version="2.49.0"
nfpm_sha256_x86_64="2afaa5ffb5e3493402e31e7c67a5a1fb42133e3f66fc315ca0051934125561c7"
nfpm_sha256_aarch64="d4eee71839e92c68cbd3b101640bad32d2856fc551acae0635be9118e48c9d9c"

format="${TREBUCHET_FORMAT:?}"
build="${TREBUCHET_BUILD:?}"
read -r -a build_deps <<< "${TREBUCHET_BUILD_DEPS:-}"

tools="/opt/trebuchet"
mkdir -p "$tools/bin"
echo "$tools/bin" >> "${GITHUB_PATH:-/dev/null}"

if [ "$build" = prebuilt ]; then
  case "$(uname -m)" in
    x86_64) asset="nfpm_${nfpm_version}_Linux_x86_64.tar.gz" sha256="$nfpm_sha256_x86_64" ;;
    aarch64) asset="nfpm_${nfpm_version}_Linux_arm64.tar.gz" sha256="$nfpm_sha256_aarch64" ;;
    *)
      echo "::error::no nfpm for $(uname -m)"
      exit 1
      ;;
  esac
  download="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$download/$asset" \
    "https://github.com/goreleaser/nfpm/releases/download/v$nfpm_version/$asset"
  echo "$sha256  $download/$asset" | sha256sum --check --quiet
  tar -xzf "$download/$asset" -C "$tools/bin" nfpm
  rm -rf "$download"
  "$tools/bin/nfpm" --version | grep -i -m 1 version || true
  exit 0
fi

case "$format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential pkg-config "${build_deps[@]}"
    ;;
  rpm)
    # rpm-build brings /usr/lib/rpm/find-requires, with which
    # cargo-generate-rpm finds the library dependencies as rpmbuild does.
    dnf -y install gcc gcc-c++ make pkgconf-pkg-config rpm-build "${build_deps[@]}"
    ;;
esac

# The toolchain the app pins in rust-toolchain.toml, or stable without one.
export PATH="$HOME/.cargo/bin:$PATH"
echo "$HOME/.cargo/bin" >> "${GITHUB_PATH:-/dev/null}"
if ! command -v rustup > /dev/null; then
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain none
fi
pinned=""
dir="$PWD"
while :; do
  if [ -f "$dir/rust-toolchain.toml" ] || [ -f "$dir/rust-toolchain" ]; then pinned=1; fi
  if [ "$dir" = / ]; then break; fi
  dir="$(dirname "$dir")"
done
if [ -n "$pinned" ]; then
  rustup toolchain install
else
  rustup default stable
fi
rustc --version
cargo --version

case "$format" in
  deb) cargo install --locked --root "$tools" "cargo-deb@$cargo_deb_version" ;;
  rpm) cargo install --locked --root "$tools" "cargo-generate-rpm@$cargo_generate_rpm_version" ;;
esac
