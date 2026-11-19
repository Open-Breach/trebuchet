#!/usr/bin/env bash
# The public key in keys/ is committed in two forms that must never drift:
# openbreach.asc, armoured, and openbreach.gpg, the same key as a binary
# keyring. This checks that they are the same key, that neither holds
# anything secret, and that the fingerprint the documentation prints is the
# key's.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

asc="$repo_root/keys/openbreach.asc"
gpg="$repo_root/keys/openbreach.gpg"
assert_file "$asc"
assert_file "$gpg"

# gpg wants a home of its own; nothing is imported into it.
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'stop_gpg_agent "$GNUPGHOME"; rm -rf "$GNUPGHOME"' EXIT

gpg --batch --no-tty --dearmor < "$asc" | cmp -s - "$gpg" \
  || fail "keys/openbreach.gpg is not keys/openbreach.asc run through gpg --dearmor"

assert_contains "$asc" "-----BEGIN PGP PUBLIC KEY BLOCK-----"
for file in "$asc" "$gpg"; do
  packets="$(gpg --batch --no-tty --list-packets "$file" 2> /dev/null)"
  grep -q '^:public key packet:' <<< "$packets" || fail "$file holds no public key"
  ! grep -q '^:secret' <<< "$packets" || fail "$file holds SECRET key material; the key has leaked and has to be replaced"
done

mapfile -t fingerprints < <(gpg --batch --no-tty --show-keys --with-colons "$gpg" | awk -F : '$1 == "pub" { getline; if ($1 == "fpr") print $10 }')
[ "${#fingerprints[@]}" -eq 1 ] || fail "keys/openbreach.gpg holds ${#fingerprints[@]} keys; exactly one is expected"
# As the documentation prints it: in groups of four.
printed="$(sed 's/..../& /g; s/ $//' <<< "${fingerprints[0]}")"
for doc in keys/README.md docs/install.md; do
  if [ -f "$repo_root/$doc" ]; then
    assert_contains "$repo_root/$doc" "$printed"
  fi
done

echo "keys: one public key, $printed, the same in both files"
