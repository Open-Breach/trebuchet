#!/usr/bin/env bash
# The registry's signing script and the key check of registry-key.yml, with
# throwaway minisign keys made here. A key reaches the scripts the way the
# real one does: the contents of its secret key file in
# REGISTRY_SIGNING_KEY and its password in REGISTRY_SIGNING_PASSWORD. The
# real key is never used: every call names the test's own public key in
# TREBUCHET_REGISTRY_PUBLIC_KEY.
#
# It also holds keys/registry.pub to what it has to be: a minisign public
# key whose id is the one its comment names, and nothing secret.
#
# Needs minisign 0.10 or newer; on Debian or Ubuntu:
#
#   sudo apt-get install minisign
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
command -v minisign > /dev/null || fail "minisign is not installed; see the top of this file"

sign="$repo_root/registry/sign.sh"
check="$repo_root/.github/scripts/registry/check-key.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the committed public key -----------------------------------------------

published="$repo_root/keys/registry.pub"
assert_file "$published"
[ "$(wc -l < "$published")" -eq 2 ] || fail "keys/registry.pub is not the two lines of a minisign public key file"
# minisign writes the id as a number: an id that begins with a zero has
# fewer than sixteen digits there.
sed -n 1p "$published" | grep -Eq '^untrusted comment: minisign public key [0-9A-F]{1,16}$' \
  || fail "keys/registry.pub: the first line is not the comment minisign writes"
! grep -qi 'secret' "$published" || fail "keys/registry.pub names a SECRET key; the key has leaked and has to be replaced"
bytes="$(sed -n 2p "$published" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
# Ed, eight bytes of key id, 32 bytes of key: nothing else fits in there.
if [ "${#bytes}" -ne 84 ] || [ "${bytes:0:4}" != 4564 ]; then
  fail "keys/registry.pub: the second line is not a minisign public key"
fi
id=""
for ((i = 18; i >= 4; i -= 2)); do id+="${bytes:i:2}"; done
id="${id^^}"
while [ "${#id}" -gt 1 ] && [ "${id:0:1}" = 0 ]; do id="${id:1}"; done
commented="$(sed -n 's/^untrusted comment: minisign public key //p' "$published")"
[ "$id" = "$commented" ] || fail "keys/registry.pub: the key's id is $id, its comment says $commented"
# The documentation that prints the id prints this one.
assert_contains "$repo_root/keys/README.md" "$commented"

# --- keys of the test's own ---------------------------------------------------

# make_minisign_key DIR [PASSWORD]: a key pair in DIR, public.pub and
# secret.key; without a password the secret key is not encrypted.
make_minisign_key() {
  mkdir -p "$1"
  if [ -n "${2:-}" ]; then
    printf '%s\n%s\n' "$2" "$2" | minisign -G -f -p "$1/public.pub" -s "$1/secret.key" > /dev/null 2>&1
  else
    minisign -G -W -f -p "$1/public.pub" -s "$1/secret.key" > /dev/null 2>&1
  fi
  if [ ! -s "$1/public.pub" ] || [ ! -s "$1/secret.key" ]; then
    fail "minisign made no key pair in $1"
  fi
}
make_minisign_key "$work/key" "a test password"
make_minisign_key "$work/other" "another password"
make_minisign_key "$work/open"

# with_key DIR PASSWORD COMMAND...: run a command with the key of DIR as the
# publisher has the real one, and DIR's public key as the published one.
with_key() {
  local dir="$1" password="$2"
  shift 2
  REGISTRY_SIGNING_KEY="$(cat "$dir/secret.key")" REGISTRY_SIGNING_PASSWORD="$password" \
    TREBUCHET_REGISTRY_PUBLIC_KEY="${PUBLIC_KEY:-$dir/public.pub}" "$@"
}

# --- sign.sh ---------------------------------------------------------------------

printf '{"schema": 1}\n' > "$work/index.json"
out="$(with_key "$work/key" "a test password" "$sign" "$work/index.json")"
assert_file "$work/index.json.minisig"
key_id="$(sed -n 's/^untrusted comment: minisign public key //p' "$work/key/public.pub")"
grep -qF "with the key $key_id" <<< "$out" || fail "sign.sh does not name the key $key_id: $out"
# As docs/registry.md tells a person to verify, and as a reader that takes
# no legacy signature does.
minisign -V -m "$work/index.json" -p "$work/key/public.pub" > /dev/null || fail "the signature does not verify"
minisign -V -H -m "$work/index.json" -p "$work/key/public.pub" > /dev/null || fail "the signature is of the legacy kind"
# Without a trusted comment of the caller's, minisign's own: it names the file.
grep -q '^trusted comment: timestamp:[0-9]*.file:index\.json.hashed$' "$work/index.json.minisig" \
  || fail "unexpected trusted comment: $(sed -n 3p "$work/index.json.minisig")"
# A changed file, and another key, are refused.
printf '{"schema": 2}\n' > "$work/changed.json"
assert_fails minisign -V -m "$work/changed.json" -x "$work/index.json.minisig" -p "$work/key/public.pub"
assert_fails minisign -V -m "$work/index.json" -p "$work/other/public.pub"

# The caller's trusted comment is in the signature, and signed with it.
with_key "$work/key" "a test password" "$sign" "$work/index.json" "a comment of the caller" > /dev/null
grep -qx 'trusted comment: a comment of the caller' "$work/index.json.minisig" || fail "the trusted comment is not the caller's"
minisign -V -m "$work/index.json" -p "$work/key/public.pub" > /dev/null || fail "the signature with a comment does not verify"

# A key without a password, with an empty REGISTRY_SIGNING_PASSWORD.
rm "$work/index.json.minisig"
with_key "$work/open" "" "$sign" "$work/index.json" > /dev/null
minisign -V -H -m "$work/index.json" -p "$work/open/public.pub" > /dev/null || fail "the signature of the key without a password does not verify"

# The secret as it may be pasted: without the comment line, with Windows
# line ends, without the last line end.
rm "$work/index.json.minisig"
pasted="$(sed -n 2p "$work/key/secret.key")"
REGISTRY_SIGNING_KEY="$pasted" REGISTRY_SIGNING_PASSWORD="a test password" \
  TREBUCHET_REGISTRY_PUBLIC_KEY="$work/key/public.pub" "$sign" "$work/index.json" > /dev/null
pasted="$(sed 's/$/\r/' "$work/key/secret.key")"
REGISTRY_SIGNING_KEY="$pasted" REGISTRY_SIGNING_PASSWORD="a test password" \
  TREBUCHET_REGISTRY_PUBLIC_KEY="$work/key/public.pub" "$sign" "$work/index.json" > /dev/null
minisign -V -m "$work/index.json" -p "$work/key/public.pub" > /dev/null || fail "the signature of the pasted key does not verify"

# What stops it, each with a reason, and without a signature left behind.
refused() {
  local expected="$1" out
  shift
  rm -f "$work/index.json.minisig"
  if out="$("$@" 2>&1)"; then
    fail "expected to fail: $*"
  fi
  grep -qF "$expected" <<< "$out" || fail "expected '$expected' in: $out"
  assert_no_file "$work/index.json.minisig"
}
refused "is not the password" with_key "$work/key" "wrong-pass-4711" "$sign" "$work/index.json"
refused "REGISTRY_SIGNING_PASSWORD is empty" with_key "$work/key" "" "$sign" "$work/index.json"
refused "REGISTRY_SIGNING_KEY is not set" \
  env -u REGISTRY_SIGNING_KEY TREBUCHET_REGISTRY_PUBLIC_KEY="$work/key/public.pub" "$sign" "$work/index.json"
refused "holds no key" \
  env REGISTRY_SIGNING_KEY="untrusted comment: nothing below" TREBUCHET_REGISTRY_PUBLIC_KEY="$work/key/public.pub" "$sign" "$work/index.json"
refused "is not a minisign secret key" \
  env REGISTRY_SIGNING_KEY="not a key at all" REGISTRY_SIGNING_PASSWORD=x TREBUCHET_REGISTRY_PUBLIC_KEY="$work/key/public.pub" "$sign" "$work/index.json"
# A key that signs well and is not the published one.
other_id="$(sed -n 's/^untrusted comment: minisign public key //p' "$work/other/public.pub")"
PUBLIC_KEY="$work/key/public.pub" refused "REGISTRY_SIGNING_KEY is the key $other_id, and public.pub is the key $key_id" \
  with_key "$work/other" "another password" "$sign" "$work/index.json"
printf 'not a key\n' > "$work/broken.pub"
PUBLIC_KEY="$work/broken.pub" refused "is not a minisign public key" \
  with_key "$work/key" "a test password" "$sign" "$work/index.json"
# Nothing of a secret is in what a failure prints.
out="$(with_key "$work/key" "wrong-pass-4711" "$sign" "$work/index.json" 2>&1 || true)"
! grep -qF "$(sed -n 2p "$work/key/secret.key")" <<< "$out" || fail "sign.sh printed the secret key"
! grep -qF "wrong-pass-4711" <<< "$out" || fail "sign.sh printed the password"

# A key whose id begins with a zero. minisign's comment leaves the zero out,
# and so does sign.sh: one key has one name. About one key in sixteen is
# such a key, so keys are made until one is.
tries=0
while :; do
  tries=$((tries + 1))
  [ "$tries" -le 2000 ] || fail "no key with an id that begins with a zero in $((tries - 1)) keys"
  make_minisign_key "$work/zero"
  zero_id="$(sed -n 's/^untrusted comment: minisign public key //p' "$work/zero/public.pub")"
  [ "${#zero_id}" -ge 16 ] || break
done
rm -f "$work/index.json.minisig"
out="$(with_key "$work/zero" "" "$sign" "$work/index.json")"
grep -qxF "signed index.json with the key $zero_id" <<< "$out" || fail "sign.sh names the key of the comment $zero_id as: $out"
minisign -V -H -m "$work/index.json" -p "$work/zero/public.pub" > /dev/null || fail "the signature of the key $zero_id does not verify"
PUBLIC_KEY="$work/zero/public.pub" refused "REGISTRY_SIGNING_KEY is the key $key_id, and public.pub is the key $zero_id" \
  with_key "$work/key" "a test password" "$sign" "$work/index.json"
out="$(with_key "$work/zero" "" "$check")"
grep -qF "the secrets hold the key $zero_id, the key of public.pub" <<< "$out" || fail "check-key.sh names the key $zero_id as: $out"

# --- the key check of registry-key.yml -----------------------------------------------

summary="$work/summary.md"
out="$(GITHUB_STEP_SUMMARY="$summary" with_key "$work/key" "a test password" "$check")"
grep -qF "the secrets hold the key $key_id" <<< "$out" || fail "check-key.sh does not name the key: $out"
assert_contains "$summary" "$key_id"
# The secrets of another key than the published one, and a wrong password.
if out="$(PUBLIC_KEY="$work/key/public.pub" with_key "$work/other" "another password" "$check" 2>&1)"; then
  fail "the key check passed for a key that is not the published one"
fi
grep -qF "the secret is not the published key" <<< "$out" || fail "the key check does not say why it failed: $out"
if out="$(with_key "$work/key" "wrong-pass-4711" "$check" 2>&1)"; then
  fail "the key check passed with a wrong password"
fi
grep -qF "is not the password" <<< "$out" || fail "the key check does not say why it failed: $out"

echo "registry key: sign.sh signs and checks against the published key; keys/registry.pub is the key $commented"
