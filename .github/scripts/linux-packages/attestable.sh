#!/usr/bin/env bash
# Decides whether the job that attaches to the release attests its files
# first (docs/spec.md, decision 10 and section 3, Build attestations).
#
# A public repository's release is attested. A private one's is not: GitHub
# offers attestations to private repositories on its Enterprise Cloud plan
# only, so the step is skipped there, with a line in the job summary. Which
# of the two the calling repository is, GitHub is asked: the repository's
# own record, with the job's token, which may always read it. No input says
# it and no app is named.
#
#   attestable.sh
#
#   GITHUB_REPOSITORY    the calling repository, as the runner sets it
#   GH_TOKEN             the job's token
#   TREBUCHET_VISIBILITY for the tests: the visibility, and GitHub is not
#                        asked
#
# Writes attest=true or attest=false to $GITHUB_OUTPUT. Whether the calling
# job granted the permissions an attestation needs is not looked at here:
# the attest step that follows fails without them, and says so.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

repo="${GITHUB_REPOSITORY:?}"
visibility="${TREBUCHET_VISIBILITY:-}"
if [ -z "$visibility" ]; then
  # `visibility` is public, private or internal; `private` is the older
  # field, for an answer without the first.
  visibility="$(gh api "repos/$repo" --jq '.visibility // (if .private then "private" else "public" end)')" \
    || die "could not ask GitHub whether $repo is public"
fi

case "$visibility" in
  public)
    attest=true
    echo "$repo is public: its release files are attested"
    ;;
  private | internal)
    attest=false
    echo "$repo is $visibility: its release files are not attested"
    {
      echo "### Build attestations"
      echo
      echo "Skipped: \`$repo\` is $visibility. GitHub offers attestations to private repositories on its Enterprise Cloud plan only, so the files of this release carry none."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    ;;
  *) die "GitHub says $repo is '$visibility', which is neither public nor private" ;;
esac

echo "attest=$attest" >> "${GITHUB_OUTPUT:-/dev/stdout}"
