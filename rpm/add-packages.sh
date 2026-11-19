#!/usr/bin/env bash
# Copy .rpm files into the dnf repositories.
#
#   rpm/add-packages.sh RPM_ROOT FILE.rpm...
#
# A file is named <package>-<version>-<release>.<target>.<arch>.rpm, as
# linux-packages.yml names it, and goes to RPM_ROOT/<target>/<arch>/. A noarch
# package goes into every architecture's directory. A file whose target or
# architecture is not in targets.json is an error: nothing is published for a
# distro this repository does not list.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 RPM_ROOT [FILE.rpm...]" >&2
  exit 2
fi
root="$1"
shift

mapfile -t repos < <(jq -r '.targets[] | select(.format == "rpm") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].rpm' "$targets")

for file in "$@"; do
  name="$(basename "$file")"
  repo=""
  for candidate in "${repos[@]}"; do
    case "$name" in
      *."$candidate".*.rpm) repo="$candidate" ;;
    esac
  done
  if [ -z "$repo" ]; then
    echo "$name: no rpm target of targets.json in the file name" >&2
    exit 1
  fi
  # The architecture is the package's own, not the file name's.
  arch="$(rpm --query --package --nosignature --queryformat '%{ARCH}' "$file")"
  if [ "$arch" = "noarch" ]; then
    into=("${arches[@]}")
  else
    into=()
    for candidate in "${arches[@]}"; do
      if [ "$arch" = "$candidate" ]; then into=("$arch"); fi
    done
  fi
  if [ "${#into[@]}" -eq 0 ]; then
    echo "$name: architecture $arch is not in targets.json" >&2
    exit 1
  fi
  for dir in "${into[@]}"; do
    mkdir -p "$root/$repo/$dir"
    cp -f "$file" "$root/$repo/$dir/$name"
    echo "rpm: $name -> $repo/$dir/"
  done
done
