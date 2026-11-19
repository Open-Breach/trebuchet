#!/usr/bin/env bash
# The fixture's build: the release binary, then the bundle the packages and
# the tarball are made from, with a data file beside the binary. Stands in
# for an app whose build is more than `cargo build --release`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

cargo build --release --locked
rm -rf target/release/bundle
mkdir -p target/release/bundle/data
cp target/release/trebuchet-fixture target/release/bundle/
echo "bundled for ${TREBUCHET_TARGET:-no target} ${TREBUCHET_ARCH:-}" > target/release/bundle/data/greeting.txt
