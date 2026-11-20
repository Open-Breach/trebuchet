#!/usr/bin/env bash
# Read a registry the way an app does, and hold it to what it says
# (docs/registry.md): fetch the index and its signature, verify the one with
# the other against the public key, then download the files the index names
# and compare each with the size and the SHA-256 the index gives for it.
#
#   check.sh [--index] BASE_URL [APP [VERSION]]
#
# BASE_URL is where the registry is served, https://get.openbreach.dev for
# the real one. With APP, only that app's files are downloaded; with
# VERSION, only those of that release; with --index, none. The index is
# always verified whole.
#
# The public key is keys/registry.pub; TREBUCHET_REGISTRY_PUBLIC_KEY names
# another file, for a registry that is signed with a test key. With
# TREBUCHET_REGISTRY_FRESH set, the two index files are asked for under an
# address no cache has seen, so that the answer is the bucket's own.
#
# It writes nothing anywhere but a temporary directory, and needs curl, jq
# and minisign.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
public="${TREBUCHET_REGISTRY_PUBLIC_KEY:-$here/../keys/registry.pub}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

files=1
if [ "${1:-}" = --index ]; then
  files=""
  shift
fi
base="${1:?usage: check.sh [--index] BASE_URL [APP [VERSION]]}"
base="${base%/}"
app="${2:-}"
version="${3:-}"
# https, or plain HTTP to this machine: what Rick's client asks at all.
[[ "$base" =~ ^(https://|http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/|$)) ]] \
  || fail "$base is neither an https:// address nor an address of this machine"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh=""
[ -z "${TREBUCHET_REGISTRY_FRESH:-}" ] || fresh="?fresh=$(date +%s)-$$"
fetch() {
  curl -fsSL --retry 3 --proto '=https,http' -o "$2" "$1" || fail "$1 could not be fetched"
}
fetch "$base/registry/index.json$fresh" "$work/index.json"
fetch "$base/registry/index.json.minisig$fresh" "$work/index.json.minisig"

minisign -V -H -p "$public" -m "$work/index.json" > /dev/null 2>&1 \
  || fail "the index of $base does not verify against $(basename "$public")"
jq -e 'type == "object" and .schema == 1 and (.apps | type) == "object"' "$work/index.json" > /dev/null 2>&1 \
  || fail "the index of $base verifies and is not an index of schema 1"
echo "the index of $base verifies against $(basename "$public"); generated $(jq -r '.generated' "$work/index.json")"
jq -r '.apps | to_entries[] | "  \(.key): latest \(.value.latest.version // "not named"), \([.value.plugins // [] | .[].builds[]] | length) build(s)"' "$work/index.json"

if [ -n "$app" ]; then
  jq -e --arg app "$app" '.apps | has($app)' "$work/index.json" > /dev/null || fail "the index of $base has no app $app"
fi

[ -n "$files" ] || exit 0

count=0
failed=0
while IFS=$'\t' read -r id build_app build_version platform url size sha256; do
  count=$((count + 1))
  name="$id for $build_app $build_version on $platform"
  if [[ ! "$url" =~ ^(https://|http://(127\.0\.0\.1|localhost)(:[0-9]+)?/) ]]; then
    echo "::error::$name: $url is not an address an app would ask" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! curl -fsSL --retry 3 --proto '=https,http' -o "$work/file" "$url"; then
    echo "::error::$name: $url does not download" >&2
    failed=$((failed + 1))
    continue
  fi
  got_size="$(stat -c %s "$work/file")"
  got_sha256="$(sha256sum "$work/file" | cut -d ' ' -f 1)"
  if [ "$got_size" != "$size" ] || [ "$got_sha256" != "$sha256" ]; then
    echo "::error::$name: $url is $got_size bytes with SHA-256 $got_sha256; the index says $size bytes and $sha256" >&2
    failed=$((failed + 1))
    continue
  fi
  echo "  ok  $url"
done < <(jq -r --arg app "$app" --arg version "$version" '
  .apps | to_entries[] | select($app == "" or .key == $app) | .key as $name
  | .value.plugins // [] | .[] | .id as $id | .builds[]
  | select($version == "" or .app_version == $version)
  | [$id, $name, .app_version, .platform, .url, (.size | tostring), .sha256] | @tsv' "$work/index.json")

[ "$failed" -eq 0 ] || fail "$failed of $count file(s) are not what the index says"
echo "$count file(s) downloaded, each with the size and the SHA-256 the index names"
