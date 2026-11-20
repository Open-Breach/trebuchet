#!/usr/bin/env bash
# Sign a file with the registry's minisign key and check the signature
# against the public key this repository publishes (docs/spec.md 7.5).
#
#   sign.sh FILE [TRUSTED_COMMENT]
#
#   REGISTRY_SIGNING_KEY        the contents of the minisign secret key file
#   REGISTRY_SIGNING_PASSWORD   its password; empty for a key made without one
#
# Writes FILE.minisig beside FILE. The signature is the kind minisign makes
# today, over the file's BLAKE2b hash: an app that reads the registry takes
# no other, so the legacy kind is refused here as well.
#
# The public key is keys/registry.pub. TREBUCHET_REGISTRY_PUBLIC_KEY names
# another file; that is for the tests, which sign with a key of their own.
#
# The secret key is read from the environment, written to a file only this
# run can read, and deleted when the script ends. The password goes to
# minisign on standard input. Nothing of either is printed, and what
# minisign itself prints is not passed on. The key id that is printed is
# public: it is in every signature and in the public key file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "::error::$*"
  exit 1
}

file="${1:?usage: sign.sh FILE [TRUSTED_COMMENT]}"
comment="${2:-}"
public="${TREBUCHET_REGISTRY_PUBLIC_KEY:-$here/../keys/registry.pub}"
[ -f "$file" ] || die "$file does not exist"
[ -f "$public" ] || die "$public is missing: the registry's public key is committed as keys/registry.pub"
[ -n "${REGISTRY_SIGNING_KEY:-}" ] || die "the secret REGISTRY_SIGNING_KEY is not set"
command -v minisign > /dev/null || die "minisign is not installed"

# The line of a minisign file that holds the key or the signature: the
# first one that is neither a comment nor empty. Read from standard input.
payload() {
  tr -d '\r' | awk '!/^(untrusted|trusted) comment:/ && NF && !seen { line = $1; seen = 1 } END { if (seen) print line }'
}
# That line's bytes in hexadecimal; nothing for a line that is not base64.
hex() {
  { base64 -d 2> /dev/null || true; } | od -An -v -tx1 | tr -d ' \n'
}
# The id by which a key and its signatures name the key: the eight bytes
# after the two of the algorithm, printed as minisign prints it in the
# comment of a public key file. That is as one number, last byte first, and
# so without the zeros an id may begin with: 0D7279AD8D4D6D51 is
# D7279AD8D4D6D51 there, and here.
key_id() {
  local bytes="${1:4:16}" id="" i
  for ((i = 14; i >= 0; i -= 2)); do id+="${bytes:i:2}"; done
  id="${id^^}"
  while [ "${#id}" -gt 1 ] && [ "${id:0:1}" = 0 ]; do id="${id:1}"; done
  printf '%s' "$id"
}

# 4564 is Ed, the algorithm of a key; a public key is 42 bytes.
public_hex="$(payload < "$public" | hex)"
if [ "${public_hex:0:4}" != 4564 ] || [ "${#public_hex}" -ne 84 ]; then
  die "$public is not a minisign public key"
fi
public_id="$(key_id "$public_hex")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# The secret as minisign reads it: a comment line and the key. A secret
# pasted without its comment line, with Windows line ends or without a last
# line end is the same key.
secret_line="$(printf '%s\n' "$REGISTRY_SIGNING_KEY" | payload)"
[ -n "$secret_line" ] || die "REGISTRY_SIGNING_KEY holds no key: it has to be the whole contents of the minisign secret key file"
(
  umask 077
  printf 'untrusted comment: minisign encrypted secret key\n%s\n' "$secret_line" > "$work/secret.key"
)
unset secret_line

args=(-S -s "$work/secret.key" -x "$work/signature" -m "$file")
[ -z "$comment" ] || args+=(-t "$comment")
status=0
if [ -n "${REGISTRY_SIGNING_PASSWORD:-}" ]; then
  printf '%s\n' "$REGISTRY_SIGNING_PASSWORD" | minisign "${args[@]}" > "$work/minisign.log" 2>&1 || status=$?
else
  # A key made with `minisign -G -W` has no password and is read with -W.
  minisign "${args[@]}" -W > "$work/minisign.log" 2>&1 < /dev/null || status=$?
fi
if [ "$status" -ne 0 ] || [ ! -s "$work/signature" ]; then
  if grep -qi 'wrong password' "$work/minisign.log"; then
    die "REGISTRY_SIGNING_PASSWORD is not the password of the key in REGISTRY_SIGNING_KEY"
  elif [ -z "${REGISTRY_SIGNING_PASSWORD:-}" ]; then
    die "minisign could not sign: REGISTRY_SIGNING_PASSWORD is empty, and REGISTRY_SIGNING_KEY is not a minisign secret key without a password"
  fi
  die "minisign could not sign: REGISTRY_SIGNING_KEY is not a minisign secret key, the whole contents of the file that minisign -G wrote"
fi

# 4544 is ED, a signature over the file's hash; 4564, Ed, is the legacy kind.
signature_hex="$(payload < "$work/signature" | hex)"
[ "${signature_hex:0:4}" = 4544 ] \
  || die "the signature is of minisign's legacy kind, which no reader of the registry takes; this needs minisign 0.10 or newer"
signed_id="$(key_id "$signature_hex")"
[ "$signed_id" = "$public_id" ] \
  || die "REGISTRY_SIGNING_KEY is the key $signed_id, and $(basename "$public") is the key $public_id: the secret is not the published key"
minisign -V -p "$public" -x "$work/signature" -m "$file" > /dev/null 2>&1 \
  || die "the signature of $(basename "$file") does not verify against $(basename "$public")"

mv "$work/signature" "$file.minisig"
echo "signed $(basename "$file") with the key $signed_id"
