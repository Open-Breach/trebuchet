#!/usr/bin/env bash
# Remove old versions from the apt pool.
#
#   apt/prune.sh APT_ROOT [KEEP]
#
# In every suite, for every package and architecture, the KEEP highest
# versions stay (default 3, docs/spec.md 4.4) and the files of the others are
# deleted. "Highest" is dpkg's version order, so 1.3.0~rc1 is older than
# 1.3.0. Run before apt/build-index.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 APT_ROOT [KEEP]" >&2
  exit 2
fi
root="$1"
keep="${2:-3}"
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || {
  echo "KEEP is a positive number, not '$keep'" >&2
  exit 2
}

mapfile -t suites < <(jq -r '.targets[] | select(.format == "deb") | .id' "$targets")

for suite in "${suites[@]}"; do
  pool="$root/pool/$suite"
  [ -d "$pool" ] || continue

  # One line per file: package/architecture, version, path.
  listing="$(mktemp)"
  while IFS= read -r file; do
    printf '%s/%s\t%s\t%s\n' \
      "$(dpkg-deb --field "$file" Package)" \
      "$(dpkg-deb --field "$file" Architecture)" \
      "$(dpkg-deb --field "$file" Version)" \
      "$file" >> "$listing"
  done < <(find "$pool" -maxdepth 1 -name '*.deb' | sort)

  while IFS= read -r group; do
    mapfile -t versions < <(awk -F '\t' -v group="$group" '$1 == group { print $2 }' "$listing" | sort -u)
    # Highest first, by selection: a group is a handful of versions.
    sorted=()
    while [ "${#versions[@]}" -gt 0 ]; do
      best=0
      for i in "${!versions[@]}"; do
        if dpkg --compare-versions "${versions[$i]}" gt "${versions[$best]}"; then best="$i"; fi
      done
      sorted+=("${versions[$best]}")
      unset "versions[$best]"
      versions=("${versions[@]}")
    done
    for version in "${sorted[@]:$keep}"; do
      while IFS= read -r file; do
        rm -f "$file"
        echo "apt: $suite: pruned $(basename "$file")"
      done < <(awk -F '\t' -v group="$group" -v version="$version" '$1 == group && $2 == version { print $3 }' "$listing")
    done
  done < <(cut -f 1 "$listing" | sort -u)
  rm -f "$listing"
done
