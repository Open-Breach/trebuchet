#!/usr/bin/env bash
# attestable.sh decides whether a release is attested: a public repository's
# is, a private one's is skipped with a line in the job summary, and a
# public one whose calling job did not grant the OIDC token fails with the
# permissions named. GitHub is not asked here: the visibility is given.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

script="$repo_root/.github/scripts/linux-packages/attestable.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# decide VISIBILITY [TOKEN_URL]: run the script as the job would, with its
# output and its summary in files of their own.
decide() {
  : > "$work/output"
  : > "$work/summary"
  GITHUB_REPOSITORY=example/app TREBUCHET_VISIBILITY="$1" ACTIONS_ID_TOKEN_REQUEST_URL="${2:-}" \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" "$script" > "$work/log" 2>&1
}

# Public, with the token: attested, and nothing in the summary.
decide public https://token.example || fail "a public repository with the token: $(cat "$work/log")"
assert_contains "$work/output" "attest=true"
[ ! -s "$work/summary" ] || fail "a line in the summary for a public repository: $(cat "$work/summary")"

# Private and internal: skipped, said in the summary, and no token is asked.
for visibility in private internal; do
  decide "$visibility" || fail "a $visibility repository: $(cat "$work/log")"
  assert_contains "$work/output" "attest=false"
  assert_contains "$work/summary" "Skipped: \`example/app\` is $visibility."
  assert_contains "$work/summary" "Enterprise Cloud"
done

# Public without the token: the job stops, and says which permissions.
if decide public; then fail "a public repository without id-token: write passed"; fi
assert_contains "$work/log" "id-token: write and attestations: write"
[ ! -s "$work/output" ] || fail "an answer although the job stopped: $(cat "$work/output")"

# Anything else is not guessed at.
if decide secret https://token.example; then fail "an unknown visibility passed"; fi
assert_contains "$work/log" "neither public nor private"

echo "attestable.sh: public attested, private and internal skipped, a missing token and an unknown answer refused"
