#!/usr/bin/env bash
# Keep the plugins of every app's last releases in the registry index, and
# say which files leave the bucket with the rest (docs/spec.md 7.4).
#
#   prune.sh SITE REMOVED_LIST [KEEP]
#
# For every app of SITE/registry/index.json, the builds of its KEEP newest
# releases stay (default 3, as in the package pool) and the builds of older
# releases leave the index. A plugin whose last build leaves, leaves with
# it. The path of each file that left, relative to SITE, is appended to
# REMOVED_LIST, for the publisher to delete in the bucket.
#
# A release is known by its builds: an app's releases are the app versions
# its builds were made with. `latest` is not touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 SITE REMOVED_LIST [KEEP]" >&2
  exit 2
fi
site="$1"
removed="$2"
keep="${3:-3}"
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || {
  echo "KEEP is a positive number, not '$keep'" >&2
  exit 2
}

index="$(registry_index "$site")"
touch "$removed"
[ -e "$index" ] || {
  echo "registry: no index yet, nothing to prune"
  exit 0
}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
registry_read "$index" > "$work/index.json"

jq --argjson keep "$keep" "$registry_jq"'
  . as $index
  | reduce ($index.apps | keys[]) as $app ({ index: $index, gone: [] };
      ($index.apps[$app] | releases | .[$keep:]) as $old
      | if ($old | length) == 0 then .
        else
          .gone += [$index.apps[$app].plugins[].builds[] | select(.app_version as $v | $old | index($v)) | { app: $app, app_version, url }]
          | .index.apps[$app] |= drop_releases($old)
        end)' "$work/index.json" > "$work/pruned.json"

paths="$(registry_removed "$work/pruned.json")"
[ -z "$paths" ] || printf '%s\n' "$paths" >> "$removed"
if [ "$(jq '.gone | length' "$work/pruned.json")" -gt 0 ]; then
  jq '.index' "$work/pruned.json" | registry_write "$index"
fi
jq -r '.gone | group_by([.app, .app_version])[] | "registry: pruned \(.[0].app) \(.[0].app_version): \(length) build(s)"' "$work/pruned.json"
echo "registry: $(jq '.gone | length' "$work/pruned.json") build(s) pruned, the last $keep release(s) of every app stay"
