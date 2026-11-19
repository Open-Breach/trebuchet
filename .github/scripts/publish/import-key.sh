#!/usr/bin/env bash
# Import the signing key into an empty gpg home, and check that it is the
# key whose public half this repository publishes.
#
#   import-key.sh PUBLIC_KEYRING
#
#   GPG_PRIVATE_KEY    the armoured secret key
#   GNUPGHOME          an empty directory only this run uses
#
# The key is read from the environment and goes to gpg on standard input.
# Nothing of it is printed; the fingerprint that is printed is public.
set -euo pipefail

die() {
  echo "::error::$*"
  exit 1
}

keyring="${1:?usage: import-key.sh PUBLIC_KEYRING}"
[ -n "${GPG_PRIVATE_KEY:-}" ] || die "the secret GPG_PRIVATE_KEY is not set"
[ -f "$keyring" ] || die "$keyring is missing"
: "${GNUPGHOME:?}"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --no-tty --import 2> /dev/null \
  || die "GPG_PRIVATE_KEY could not be imported; it has to be the armoured export of the secret key"

mapfile -t secret < <(gpg --batch --no-tty --with-colons --list-secret-keys | awk -F : '$1 == "sec" { getline; if ($1 == "fpr") print $10 }')
[ "${#secret[@]}" -eq 1 ] || die "GPG_PRIVATE_KEY holds ${#secret[@]} secret keys; exactly one is expected"

published="$(gpg --batch --no-tty --no-default-keyring --keyring "$(cd "$(dirname "$keyring")" && pwd)/$(basename "$keyring")" \
  --with-colons --list-keys | awk -F : '$1 == "fpr" { print $10 }')"
grep -qx "${secret[0]}" <<< "$published" \
  || die "the secret key ${secret[0]} is not the key published in $keyring"
echo "signing key ${secret[0]}"
