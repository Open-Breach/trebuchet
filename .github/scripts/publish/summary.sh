#!/usr/bin/env bash
# Write what a publish did to the job summary.
#
#   summary.sh SITE REMOVED_LIST [INCOMING_DIR]
#
#   PUBLISH_APP, PUBLISH_PACKAGE_VERSION    set for a release, empty for a republish
set -euo pipefail

site="${1:?usage: summary.sh SITE REMOVED_LIST [INCOMING_DIR]}"
removed="${2:?usage: summary.sh SITE REMOVED_LIST [INCOMING_DIR]}"
incoming="${3:-}"

{
  if [ -n "$incoming" ]; then
    echo "### Published ${PUBLISH_APP:-} ${PUBLISH_PACKAGE_VERSION:-}"
    echo
    find "$incoming" -type f | sort | while IFS= read -r file; do
      echo "- \`$(basename "$file")\`"
    done
  else
    echo "### Republished the repositories"
  fi
  echo
  echo "Package files in the repositories: $(find "$site/apt/pool" "$site/rpm" -type f \( -name '*.deb' -o -name '*.rpm' \) | wc -l)"
  if [ -s "$removed" ]; then
    echo
    echo "Pruned:"
    echo
    while IFS= read -r path; do
      echo "- \`$(basename "$path")\`"
    done < "$removed"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
