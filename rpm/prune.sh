#!/usr/bin/env bash
# Remove old versions from the dnf repositories.
#
#   rpm/prune.sh RPM_ROOT [KEEP]
#
# In every repository and architecture, for every package, the KEEP highest
# versions stay (default 3, docs/spec.md 4.4) and the files of the others are
# deleted. "Highest" is rpm's order of epoch, version and release, so
# 1.3.0~rc1 is older than 1.3.0. Run before rpm/build-index.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 RPM_ROOT [KEEP]" >&2
  exit 2
fi
root="$1"
keep="${2:-3}"
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || {
  echo "KEEP is a positive number, not '$keep'" >&2
  exit 2
}

# newer A B: true when A, an "epoch version release" triple, is newer than B.
# rpm compares the parts in that order; its own comparison is asked for the
# version and the release.
newer() {
  local a_epoch a_version a_release b_epoch b_version b_release order
  read -r a_epoch a_version a_release <<< "$1"
  read -r b_epoch b_version b_release <<< "$2"
  if [ "$a_epoch" -ne "$b_epoch" ]; then
    [ "$a_epoch" -gt "$b_epoch" ]
    return
  fi
  order="$(rpm --eval "%{lua: print(rpm.vercmp('$a_version', '$b_version'))}")"
  if [ "$order" -ne 0 ]; then
    [ "$order" -gt 0 ]
    return
  fi
  order="$(rpm --eval "%{lua: print(rpm.vercmp('$a_release', '$b_release'))}")"
  [ "$order" -gt 0 ]
}

mapfile -t repos < <(jq -r '.targets[] | select(.format == "rpm") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].rpm' "$targets")

for repo in "${repos[@]}"; do
  for arch in "${arches[@]}"; do
    dir="$root/$repo/$arch"
    [ -d "$dir" ] || continue

    # One line per file: package, "epoch version release", path.
    listing="$(mktemp)"
    while IFS= read -r file; do
      line="$(rpm --query --package --nosignature \
        --queryformat '%{NAME}\t%{EPOCHNUM} %{VERSION} %{RELEASE}' "$file")"
      # Versions go into a Lua string above; nothing but the characters rpm
      # allows in them may get there.
      [[ "$line" =~ ^[A-Za-z0-9+._-]+$'\t'[0-9]+\ [A-Za-z0-9+._~^]+\ [A-Za-z0-9+._~^]+$ ]] || {
        echo "$file: unexpected name or version" >&2
        exit 1
      }
      printf '%s\t%s\n' "$line" "$file" >> "$listing"
    done < <(find "$dir" -maxdepth 1 -name '*.rpm' | sort)

    while IFS= read -r package; do
      mapfile -t versions < <(awk -F '\t' -v package="$package" '$1 == package { print $2 }' "$listing" | sort -u)
      # Highest first, by selection: a package is a handful of versions.
      sorted=()
      while [ "${#versions[@]}" -gt 0 ]; do
        best=0
        for i in "${!versions[@]}"; do
          if newer "${versions[$i]}" "${versions[$best]}"; then best="$i"; fi
        done
        sorted+=("${versions[$best]}")
        unset "versions[$best]"
        versions=("${versions[@]}")
      done
      for version in "${sorted[@]:$keep}"; do
        while IFS= read -r file; do
          rm -f "$file"
          echo "rpm: $repo/$arch: pruned $(basename "$file")"
        done < <(awk -F '\t' -v package="$package" -v version="$version" '$1 == package && $2 == version { print $3 }' "$listing")
      done
    done < <(cut -f 1 "$listing" | sort -u)
    rm -f "$listing"
  done
done
