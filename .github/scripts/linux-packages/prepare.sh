#!/usr/bin/env bash
# Get a target's container ready to build and package: the compiler, the
# app's build dependencies, the Rust toolchain and the packaging tool of the
# target's format. Runs as root inside the container, from the directory the
# app is built in.
#
#   TREBUCHET_FORMAT      deb or rpm
#   TREBUCHET_BUILD       cargo or prebuilt
#   TREBUCHET_BUILD_DEPS  space-separated distro packages (cargo only)
#   TREBUCHET_PLUGINS     the call's list of plugin packages, [] for none
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The versions of the cargo tools, pinned here and nowhere else; they are
# built from their crates.io sources. nfpm's is pinned in nfpm.sh.
cargo_deb_version="3.8.0"
cargo_generate_rpm_version="0.21.1"

format="${TREBUCHET_FORMAT:?}"
build="${TREBUCHET_BUILD:?}"
plugins="${TREBUCHET_PLUGINS:-[]}"
read -r -a build_deps <<< "${TREBUCHET_BUILD_DEPS:-}"

tools="/opt/trebuchet"
mkdir -p "$tools/bin"
echo "$tools/bin" >> "${GITHUB_PATH:-/dev/null}"

if [ "$build" = prebuilt ]; then
  "$here/nfpm.sh" "$tools/bin"
  exit 0
fi
# A cargo build makes its plugin packages with nfpm as well.
if [ "$(jq 'length' <<< "$plugins")" -gt 0 ]; then
  "$here/nfpm.sh" "$tools/bin"
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
