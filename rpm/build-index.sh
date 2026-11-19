#!/usr/bin/env bash
# Rebuild the dnf repository metadata over every package.
#
#   rpm/build-index.sh RPM_ROOT
#
# One repository per rpm target of targets.json, one directory per
# architecture (docs/spec.md 4.4):
#
#   RPM_ROOT/<target>/<arch>/*.rpm
#   RPM_ROOT/<target>/<arch>/repodata/repomd.xml
#
# A repository without packages still gets its (empty) metadata, so
# `dnf install` reports "no match" rather than a broken repository.
# repomd.xml is left unsigned and the old signature is removed with it;
# rpm/sign.sh comes next.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 RPM_ROOT" >&2
  exit 2
fi
root="$1"

mapfile -t repos < <(jq -r '.targets[] | select(.format == "rpm") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].rpm' "$targets")

for repo in "${repos[@]}"; do
  for arch in "${arches[@]}"; do
    dir="$root/$repo/$arch"
    mkdir -p "$dir"
    rm -rf "$dir/repodata"
    # No sqlite databases: dnf does not read them, and the default differs
    # between createrepo_c versions.
    createrepo_c --quiet --no-database "$dir"
    echo "rpm: $repo/$arch: $(find "$dir" -maxdepth 1 -name '*.rpm' | wc -l) package file(s)"
  done
done
