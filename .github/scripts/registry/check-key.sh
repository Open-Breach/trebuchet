#!/usr/bin/env bash
# Prove that the registry's signing key is the published one: sign a
# throwaway file with the secrets and verify the signature against
# keys/registry.pub. Then change the file and see the signature refuse it.
#
#   check-key.sh
#
#   REGISTRY_SIGNING_KEY, REGISTRY_SIGNING_PASSWORD    as registry/sign.sh has them
#
# The file is one line of text with a random number in it. It is no index:
# it is not JSON, so nothing that reads the registry would take it for one,
# whoever served it with its signature. Nothing leaves the run: the file and
# its signature are deleted when the script ends.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
public="${TREBUCHET_REGISTRY_PUBLIC_KEY:-$root/keys/registry.pub}"

die() {
  echo "::error::$*"
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

file="$work/key-check.txt"
printf 'Trebuchet registry key check, not an index: %s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > "$file"

signed="$("$root/registry/sign.sh" "$file" "key check, not an index")" || {
  # sign.sh has said why.
  printf '%s\n' "$signed"
  exit 1
}
printf '%s\n' "$signed"
key="$(sed -n 's/.* with the key \([0-9A-F]\{1,16\}\)$/\1/p' <<< "$signed")"
[ -n "$key" ] || die "sign.sh did not say which key it signed with"

# As a reader does it, and as docs/registry.md tells a person to.
minisign -V -H -p "$public" -m "$file" > /dev/null 2>&1 \
  || die "the signature does not verify against $(basename "$public")"

# One more byte, and the same signature must not verify.
printf 'x' >> "$file"
if minisign -V -p "$public" -m "$file" > /dev/null 2>&1; then
  die "a changed file still verifies: the check proves nothing"
fi

echo "the secrets hold the key $key, the key of $(basename "$public"); a changed file is refused"
{
  echo "### The registry's signing key"
  echo
  echo "A throwaway file signed with \`REGISTRY_SIGNING_KEY\` and \`REGISTRY_SIGNING_PASSWORD\` verifies against \`keys/registry.pub\`, key \`$key\`. The same file with one byte added does not."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
