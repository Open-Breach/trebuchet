#!/usr/bin/env bash
# Bring a local copy of the site up to date: add the new packages to the
# pool, prune old versions, rebuild and sign every index, and lay out the
# files that are served beside the repositories.
#
#   build-site.sh SITE REMOVED_LIST [INCOMING_DIR]
#
# SITE holds the pool as it is in the bucket (bucket.sh pull). INCOMING_DIR
# holds the new .deb and .rpm files; without it nothing is added. The paths
# of the package files that pruning removed, relative to SITE, are written
# to REMOVED_LIST, for bucket.sh push to delete in the bucket.
#
# Signs with the key in GNUPGHOME (GPG_PASSPHRASE if it has one) and checks
# the signatures against the published public key, keys/openbreach.gpg. The
# same key as text, keys/openbreach.asc, is served beside it.
# TREBUCHET_PUBLIC_KEY names another keyring, with its .asc beside it; that
# is for the tests.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 SITE REMOVED_LIST [INCOMING_DIR]" >&2
  exit 2
fi
mkdir -p "$1"
site="$(cd "$1" && pwd)"
removed="$2"
incoming="${3:-}"
keyring="${TREBUCHET_PUBLIC_KEY:-$root/keys/openbreach.gpg}"
armoured="${keyring%.gpg}.asc"
for file in "$keyring" "$armoured"; do
  [ -f "$file" ] || {
    echo "::error::$file is missing: the public key is committed as a .gpg keyring and an .asc text file"
    exit 1
  }
done
# The two files are one key. Users get both, so a difference stops the run.
gpg --batch --no-tty --dearmor < "$armoured" | cmp -s - "$keyring" || {
  echo "::error::$keyring is not $armoured run through gpg --dearmor"
  exit 1
}

packages() {
  (cd "$site" && find apt/pool rpm -type f \( -name '*.deb' -o -name '*.rpm' \) 2> /dev/null | sort)
}

if [ -n "$incoming" ]; then
  shopt -s nullglob
  debs=("$incoming"/*.deb)
  rpms=("$incoming"/*.rpm)
  shopt -u nullglob
  [ "${#debs[@]}" -eq 0 ] || "$root/apt/add-packages.sh" "$site/apt" "${debs[@]}"
  [ "${#rpms[@]}" -eq 0 ] || "$root/rpm/add-packages.sh" "$site/rpm" "${rpms[@]}"
fi

before="$(packages)"
"$root/apt/prune.sh" "$site/apt"
"$root/rpm/prune.sh" "$site/rpm"
comm -23 <(printf '%s\n' "$before") <(packages) | sed '/^$/d' > "$removed"

"$root/apt/build-index.sh" "$site/apt"
"$root/rpm/build-index.sh" "$site/rpm"
"$root/apt/sign.sh" "$site/apt" "$keyring"
"$root/rpm/sign.sh" "$site/rpm" "$keyring"

# Beside the repositories: the installer, and the public key as a keyring
# for apt and as text for dnf.
mkdir -p "$site/keys"
cp "$root/install.sh" "$site/install.sh"
cp "$keyring" "$site/keys/openbreach.gpg"
cp "$armoured" "$site/keys/openbreach.asc"
echo "site: $(packages | wc -l) package file(s), $(wc -l < "$removed") removed"
