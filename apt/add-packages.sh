#!/usr/bin/env bash
# Copy .deb files into the pool of the apt repository.
#
#   apt/add-packages.sh APT_ROOT FILE.deb...
#
# A file is named <package>_<version>_<target>_<arch>.deb, as
# linux-packages.yml names it, and goes to APT_ROOT/pool/<target>/. A file
# whose target or architecture is not in targets.json is an error: nothing is
# published for a distro this repository does not list.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 APT_ROOT [FILE.deb...]" >&2
  exit 2
fi
root="$1"
shift

mapfile -t suites < <(jq -r '.targets[] | select(.format == "deb") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].deb' "$targets")

for file in "$@"; do
  name="$(basename "$file")"
  suite=""
  for candidate in "${suites[@]}"; do
    case "$name" in
      *_"$candidate"_*.deb) suite="$candidate" ;;
    esac
  done
  if [ -z "$suite" ]; then
    echo "$name: no deb target of targets.json in the file name" >&2
    exit 1
  fi
  # The architecture is the package's own, not the file name's. The file name
  # has to end in it all the same: apt-ftparchive selects by that ending.
  arch="$(dpkg-deb --field "$file" Architecture)"
  known=""
  for candidate in all "${arches[@]}"; do
    if [ "$arch" = "$candidate" ]; then known=1; fi
  done
  if [ -z "$known" ]; then
    echo "$name: architecture $arch is not in targets.json" >&2
    exit 1
  fi
  case "$name" in
    *_"$arch".deb) ;;
    *)
      echo "$name: the package is for $arch, the file name does not end in _$arch.deb" >&2
      exit 1
      ;;
  esac
  mkdir -p "$root/pool/$suite"
  cp -f "$file" "$root/pool/$suite/$name"
  echo "apt: $name -> pool/$suite/"
done
