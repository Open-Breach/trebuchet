#!/usr/bin/env bash
# Rebuild the apt indexes over the whole pool.
#
#   apt/build-index.sh APT_ROOT
#
# One suite per deb target of targets.json, component main, every
# architecture in the same suite (docs/spec.md 4.4):
#
#   APT_ROOT/pool/<suite>/*.deb
#   APT_ROOT/dists/<suite>/main/binary-<arch>/Packages{,.gz}
#   APT_ROOT/dists/<suite>/Release
#
# A suite without packages still gets its (empty) indexes, so `apt update`
# works from the first day. The Release file is left unsigned and the old
# signatures are removed with it; apt/sign.sh comes next.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 APT_ROOT" >&2
  exit 2
fi
mkdir -p "$1"
cd "$1"

mapfile -t suites < <(jq -r '.targets[] | select(.format == "deb") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].deb' "$targets")

for suite in "${suites[@]}"; do
  mkdir -p "pool/$suite"
  rm -rf "dists/$suite"
  for arch in "${arches[@]}"; do
    dir="dists/$suite/main/binary-$arch"
    mkdir -p "$dir"
    # Run from APT_ROOT, so that Filename: is the path apt asks the server for.
    apt-ftparchive --arch "$arch" packages "pool/$suite" > "$dir/Packages"
    gzip -9 --no-name --keep "$dir/Packages"
  done
  # Written beside the suite and moved in, so that the Release file does not
  # list itself.
  apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=Open-Breach" \
    -o "APT::FTPArchive::Release::Label=Open-Breach" \
    -o "APT::FTPArchive::Release::Suite=$suite" \
    -o "APT::FTPArchive::Release::Codename=$suite" \
    -o "APT::FTPArchive::Release::Components=main" \
    -o "APT::FTPArchive::Release::Architectures=${arches[*]}" \
    release "dists/$suite" > "dists/$suite.Release"
  mv "dists/$suite.Release" "dists/$suite/Release"
  echo "apt: $suite: $(find "pool/$suite" -name '*.deb' | wc -l) package file(s)"
done
