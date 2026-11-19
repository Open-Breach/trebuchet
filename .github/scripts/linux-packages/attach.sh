#!/usr/bin/env bash
# Attach the packages and tarballs to the GitHub Release of the calling
# repository. A release that exists for the tag, draft or published, gets the
# files; where there is none yet, a draft is created for them, and publishing
# it is left to the caller.
#
#   attach.sh TAG FILE...
#
#   GH_TOKEN             a token that may write the repository's contents
#   GITHUB_REPOSITORY    the calling repository
#   GITHUB_SHA           the commit a new draft is created on
set -euo pipefail

tag="${1:?usage: attach.sh TAG FILE...}"
shift
[ "$#" -gt 0 ] || {
  echo "::error::nothing to attach"
  exit 1
}
repo="${GITHUB_REPOSITORY:?}"

if ! gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
  echo "no release for $tag yet: creating a draft"
  # Another job of the same run may have created it in between; the upload
  # below tells.
  gh release create "$tag" --repo "$repo" --draft --title "$tag" --notes "" --target "${GITHUB_SHA:?}" \
    || echo "could not create the release; trying the upload all the same"
fi

# --clobber, so that a re-run replaces what the failed run left.
gh release upload "$tag" "$@" --repo "$repo" --clobber
echo "attached to $tag:"
printf '  %s\n' "${@##*/}"
