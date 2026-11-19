#!/usr/bin/env bash
# Sign the repomd.xml of every dnf repository.
#
#   rpm/sign.sh RPM_ROOT PUBLIC_KEYRING
#
# Writes repodata/repomd.xml.asc, the detached signature dnf checks with
# repo_gpgcheck=1, beside each <target>/<arch>/repodata/repomd.xml.
#
# The secret key is the one in gpg's keyring (GNUPGHOME); with more than one
# there, TREBUCHET_GPG_KEY names it. A passphrase is read from GPG_PASSPHRASE
# and handed to gpg on a file descriptor, never on a command line.
#
# Every signature is then checked with gpgv against PUBLIC_KEYRING, the
# public key users are given (keys/openbreach.gpg): a repository signed with
# any other key fails here, not on a user's machine.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../targets.json}"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 RPM_ROOT PUBLIC_KEYRING" >&2
  exit 2
fi
root="$1"
keyring="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[ -f "$keyring" ] || {
  echo "$keyring: no such public keyring" >&2
  exit 1
}

sign() {
  local args=(--batch --yes --no-tty --digest-algo SHA512)
  if [ -n "${TREBUCHET_GPG_KEY:-}" ]; then
    args+=(--local-user "$TREBUCHET_GPG_KEY")
  fi
  if [ -n "${GPG_PASSPHRASE:-}" ]; then
    gpg "${args[@]}" --pinentry-mode loopback --passphrase-fd 3 "$@" 3<<< "$GPG_PASSPHRASE"
  else
    gpg "${args[@]}" "$@"
  fi
}

mapfile -t repos < <(jq -r '.targets[] | select(.format == "rpm") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].rpm' "$targets")

for repo in "${repos[@]}"; do
  for arch in "${arches[@]}"; do
    repomd="$root/$repo/$arch/repodata/repomd.xml"
    [ -f "$repomd" ] || {
      echo "$repomd: missing; run rpm/build-index.sh first" >&2
      exit 1
    }
    rm -f "$repomd.asc"
    sign --armor --detach-sign --output "$repomd.asc" "$repomd"
    gpgv --quiet --keyring "$keyring" "$repomd.asc" "$repomd" 2> /dev/null || {
      echo "$repomd.asc does not verify against $keyring: the signing key is not the published key" >&2
      exit 1
    }
    echo "rpm: $repo/$arch: signed"
  done
done
