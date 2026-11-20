#!/usr/bin/env bash
# Make what a release of an app with plugins attaches for one platform
# (docs/spec.md 7.4): one file per plugin and the manifest
# plugins-<platform>.json that lists them, with their sizes and hashes.
#
#   tests/fixture/plugins.sh OUT_DIR APP VERSION PLATFORM ID...
#
# A plugin file is a few lines of text that name what it stands for; the
# publisher never opens one, so it need be nothing more. The same arguments
# give the same bytes. A plugin's description names the release, and so
# does its `meta`, which also holds what no publisher needs to understand.
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: $0 OUT_DIR APP VERSION PLATFORM ID..." >&2
  exit 2
fi
mkdir -p "$1"
out="$(cd "$1" && pwd)"
app="$2"
version="$3"
platform="$4"
shift 4

entries="[]"
for id in "$@"; do
  file="$id-$version-$platform.plugin"
  printf 'plugin %s of %s %s for %s\n%s\n' "$id" "$app" "$version" "$platform" \
    "$(printf '%s' "$id $app $version $platform" | sha256sum | cut -d ' ' -f 1)" > "$out/$file"
  entries="$(jq --arg id "$id" --arg version "$version" --arg file "$file" \
    --argjson size "$(stat -c %s "$out/$file")" --arg sha256 "$(sha256sum "$out/$file" | cut -d ' ' -f 1)" \
    '. + [{
      id: $id,
      name: "The \($id) plugin",
      description: "What \($id) does, as of \($version).",
      version: $version,
      api_version: 7,
      meta: { points: ["one", "two"], triggers: { markers: [".\($id)"] }, since: $version, anything: [1, true, null, { deep: "er" }] },
      file: $file,
      size: $size,
      sha256: $sha256
    }]' <<< "$entries")"
done
jq -n --arg app "$app" --arg version "$version" --arg platform "$platform" --argjson plugins "$entries" \
  '{ app: $app, app_version: $version, platform: $platform, plugins: $plugins }' > "$out/plugins-$platform.json"
