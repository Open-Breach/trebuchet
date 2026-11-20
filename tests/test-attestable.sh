#!/usr/bin/env bash
# attestable.sh decides whether a release is attested: a public repository's
# is, a private one's is skipped with a line in the job summary, and any
# other answer is refused. GitHub is not asked here: the visibility is
# given.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

script="$repo_root/.github/scripts/linux-packages/attestable.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# decide VISIBILITY: run the script as the job would, with its output and
# its summary in files of their own.
decide() {
  : > "$work/output"
  : > "$work/summary"
  GITHUB_REPOSITORY=example/app TREBUCHET_VISIBILITY="$1" \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" "$script" > "$work/log" 2>&1
}

# Public: attested, and nothing in the summary.
decide public || fail "a public repository: $(cat "$work/log")"
assert_contains "$work/output" "attest=true"
[ ! -s "$work/summary" ] || fail "a line in the summary for a public repository: $(cat "$work/summary")"

# Private and internal: skipped, and said in the summary.
for visibility in private internal; do
  decide "$visibility" || fail "a $visibility repository: $(cat "$work/log")"
  assert_contains "$work/output" "attest=false"
  assert_contains "$work/summary" "Skipped: \`example/app\` is $visibility."
  assert_contains "$work/summary" "Enterprise Cloud"
done

# Anything else is not guessed at.
if decide secret; then fail "an unknown visibility passed"; fi
assert_contains "$work/log" "neither public nor private"
[ ! -s "$work/output" ] || fail "an answer although the job stopped: $(cat "$work/output")"

echo "attestable.sh: public attested, private and internal skipped, an unknown answer refused"
