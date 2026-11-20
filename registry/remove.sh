#!/usr/bin/env bash
# Take one release of an app out of the registry index: a release that was
# yanked (docs/spec.md 7.4).
#
#   remove.sh SITE REMOVED_LIST APP VERSION
#
# Every build of APP that was made with VERSION leaves
# SITE/registry/index.json, and a plugin whose last build leaves, leaves
# with it. The path of each file that left, relative to SITE, is appended
# to REMOVED_LIST, for the publisher to delete in the bucket.
#
# Where `latest` names the release, `latest` leaves too: the index does not
# know the release before it. Publishing that release again names it.
#
# A release the index has nothing of is an error, so that a mistyped version
# does not pass for a removal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

if [ "$#" -ne 4 ]; then
  echo "usage: $0 SITE REMOVED_LIST APP VERSION" >&2
  exit 2
fi
site="$1"
removed="$2"
app="$3"
version="$4"
[[ "$app" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "app '$app' is not a package name"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?$ ]] || die "version '$version' is not X.Y.Z"

index="$(registry_index "$site")"
[ -e "$index" ] || die "there is no index to remove $app $version from"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
registry_read "$index" > "$work/index.json"

jq --arg app "$app" --arg version "$version" "$registry_jq"'
  . as $index
  | ($index.apps[$app] // {}) as $old
  | [$old.plugins // [] | .[].builds[] | select(.app_version == $version) | { app: $app, app_version, url }] as $gone
  | (($old.latest | type) == "object" and $old.latest.version == $version) as $was_latest
  | {
      index: ($index | if .apps[$app] then
        .apps[$app] |= (drop_releases([$version]) | if $was_latest then del(.latest) else . end)
      else . end),
      gone: $gone, was_latest: $was_latest
    }' "$work/index.json" > "$work/removed.json"

count="$(jq '.gone | length' "$work/removed.json")"
was_latest="$(jq -r '.was_latest' "$work/removed.json")"
if [ "$count" -eq 0 ] && [ "$was_latest" != true ]; then
  die "the index has nothing of $app $version"
fi
paths="$(registry_removed "$work/removed.json")"
touch "$removed"
[ -z "$paths" ] || printf '%s\n' "$paths" >> "$removed"
jq '.index' "$work/removed.json" | registry_write "$index"
echo "registry: removed $app $version: $count build(s)"
if [ "$was_latest" = true ]; then
  echo "::warning::$app $version was the latest release of $app. The index names none now: publish the release before it again, and it is named."
fi
