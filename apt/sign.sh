#!/usr/bin/env bash
# Sign the Release file of every apt suite.
#
#   apt/sign.sh APT_ROOT PUBLIC_KEYRING
#
# Writes, beside each dists/<suite>/Release:
#
#   Release.gpg   detached signature
#   InRelease     the Release file, clear-signed
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
  echo "usage: $0 APT_ROOT PUBLIC_KEYRING" >&2
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

mapfile -t suites < <(jq -r '.targets[] | select(.format == "deb") | .id' "$targets")

for suite in "${suites[@]}"; do
  dir="$root/dists/$suite"
  [ -f "$dir/Release" ] || {
    echo "$dir/Release: missing; run apt/build-index.sh first" >&2
    exit 1
  }
  rm -f "$dir/Release.gpg" "$dir/InRelease"
  sign --armor --detach-sign --output "$dir/Release.gpg" "$dir/Release"
  sign --clearsign --output "$dir/InRelease" "$dir/Release"

  gpgv --quiet --keyring "$keyring" "$dir/Release.gpg" "$dir/Release" 2> /dev/null || {
    echo "$dir/Release.gpg does not verify against $keyring: the signing key is not the published key" >&2
    exit 1
  }
  gpgv --quiet --keyring "$keyring" --output - "$dir/InRelease" 2> /dev/null | cmp -s - "$dir/Release" || {
    echo "$dir/InRelease does not verify against $keyring, or is not the Release file" >&2
    exit 1
  }
  echo "apt: $suite: signed"
done
