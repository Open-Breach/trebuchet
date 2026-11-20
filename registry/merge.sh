#!/usr/bin/env bash
# Merge one release of an app into the registry index (docs/spec.md 7.4 and
# 7.6): write the app's latest version, and add the plugins the release
# carries, where it carries any.
#
#   merge.sh SITE APP VERSION RELEASE_URL [INCOMING_DIR]
#
# SITE is a local copy of what is served: the index is SITE/registry/index.json,
# as the bucket has it, or missing where there is none yet. INCOMING_DIR holds
# what the release attached: one manifest plugins-<platform>.json per
# platform, and the files the manifests name. Without it, or without a
# manifest in it, the release has no plugins and only `latest` is written.
#
#   REGISTRY_BASE_URL     where SITE is served; default https://get.openbreach.dev
#   REGISTRY_PUBLISHER    who publishes the plugins; default: the owner of
#                         the repository the workflow runs in
#
# Every file a manifest names is checked against the size and the SHA-256
# the manifest gives before anything is written. Then:
#
#   - a build that is not in the index yet is added, and its file is copied
#     to SITE/plugins/<app>/<version>/, for the publisher to upload;
#   - a build that is already there, under the same plugin, plugin version,
#     app version and platform, is left alone, and its file is not copied:
#     the run can be repeated;
#   - a plugin's name, description and meta become those of this release,
#     unless the index holds a build of a later one;
#   - `latest` becomes this release, unless the index names a later one.
#
# What an app says about a plugin is data here: `meta` is copied and never
# read, and nothing knows what a plugin is for.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 SITE APP VERSION RELEASE_URL [INCOMING_DIR]" >&2
  exit 2
fi
site="$1"
app="$2"
version="$3"
url="$4"
incoming="${5:-}"
base="${REGISTRY_BASE_URL:-https://get.openbreach.dev}"
base="${base%/}"
publisher="${REGISTRY_PUBLISHER:-${GITHUB_REPOSITORY_OWNER:-}}"

[[ "$app" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "app '$app' is not a package name"
# One channel, as in the package repositories: releases only.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$version' is not X.Y.Z; the registry carries releases only"
[[ "$url" =~ ^https://[A-Za-z0-9._~:/?#@!$\&\'()*+,\;=%-]+$ ]] || die "the release URL is not an https:// address"
[[ "$base" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~/-]*)?$ ]] || die "REGISTRY_BASE_URL '$base' is not the address of a site"
[ -n "$publisher" ] || die "REGISTRY_PUBLISHER is not set, and neither is GITHUB_REPOSITORY_OWNER"

index="$(registry_index "$site")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
registry_read "$index" > "$work/index.json"

manifests=()
if [ -n "$incoming" ]; then
  [ -d "$incoming" ] || die "$incoming is not a directory"
  mapfile -t manifests < <(find "$incoming" -maxdepth 1 -type f -name 'plugins-*.json' | sort)
fi

# --- the manifests, and every file they name ----------------------------------

# What is wrong with a manifest's list of plugins, one line each. A jq
# program: its $names are jq's, not the shell's.
# shellcheck disable=SC2016
problems='
  .plugins | to_entries[] | "plugin \(.key + 1)" as $where | .value
  | if type != "object" then "\($where) is not an object"
    elif (.id | type) != "string" or (.id | test("^[a-z0-9][a-z0-9._-]*$") | not)
      then "\($where): id is not a plugin id: lowercase letters, digits, \".\", \"_\" and \"-\""
    elif (.name | type) != "string" or (.name | test("^[^\n]+$") | not) then "\(.id): name is not one line of text"
    elif (.description // "" | type) != "string" then "\(.id): description is not text"
    elif (.version | type) != "string" or (.version | test("^[0-9A-Za-z][0-9A-Za-z.+~-]*$") | not) then "\(.id): version is not a version"
    elif (.api_version | type) != "number" or .api_version != (.api_version | floor) or .api_version < 0
      then "\(.id): api_version is not a whole number"
    elif (.meta // {} | type) != "object" then "\(.id): meta is not an object"
    elif (.file | type) != "string" or (.file | test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") | not) then "\(.id): file is not a plain file name"
    elif (.size | type) != "number" or .size != (.size | floor) or .size < 0 then "\(.id): size is not a number of bytes"
    elif (.sha256 | type) != "string" or (.sha256 | test("^[0-9A-Fa-f]{64}$") | not) then "\(.id): sha256 is not 64 hexadecimal digits"
    else empty end'

: > "$work/files"
for manifest in "${manifests[@]}"; do
  name="$(basename "$manifest")"
  platform="${name#plugins-}"
  platform="${platform%.json}"
  [[ "$platform" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "$name: '$platform' is not the name of a platform"
  jq -e 'type == "object" and (.plugins | type) == "array"' "$manifest" > /dev/null 2>&1 \
    || die "$name is not a manifest: a JSON object with a list of plugins"
  got="$(jq -r '[.app, .app_version, .platform] | map(tostring) | join(" ")' "$manifest")"
  [ "$got" = "$app $version $platform" ] \
    || die "$name is the manifest of '$got'; this release is '$app $version', and the file's name says '$platform'"
  problem="$(jq -r "[$problems] | first // empty" "$manifest")"
  [ -z "$problem" ] || die "$name: $problem"
  twice="$(jq -r '[.plugins[].id] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$manifest")"
  [ -z "$twice" ] || die "$name lists more than once: $twice"

  while IFS=$'\t' read -r id file size sha256; do
    [ -f "$incoming/$file" ] || die "$name: $id: the release has no file $file"
    actual="$(stat -c %s "$incoming/$file")"
    [ "$actual" = "$size" ] || die "$name: $id: $file has $actual bytes, the manifest says $size"
    actual="$(sha256sum "$incoming/$file" | cut -d ' ' -f 1)"
    [ "$actual" = "${sha256,,}" ] || die "$name: $id: the SHA-256 of $file is $actual, the manifest says ${sha256,,}"
    printf '%s\n' "$file" >> "$work/files"
  done < <(jq -r '.plugins[] | [.id, .file, (.size | tostring), .sha256] | @tsv' "$manifest")
done
# The files of every platform lie in one folder of the bucket.
twice="$(sort "$work/files" | uniq -d | paste -sd ' ')"
[ -z "$twice" ] || die "named by more than one manifest of the release: $twice"

# --- the index --------------------------------------------------------------------

if [ "${#manifests[@]}" -gt 0 ]; then
  jq -s 'map({ platform, plugins }) | sort_by(.platform)' "${manifests[@]}" > "$work/incoming.json"
else
  echo '[]' > "$work/incoming.json"
fi

jq --arg app "$app" --arg version "$version" --arg url "$url" --arg base "$base" --arg publisher "$publisher" \
  --slurpfile incoming "$work/incoming.json" "$registry_jq"'
  def build_key: [.version, .app_version, .platform];
  . as $index
  | ($index.apps[$app] // {}) as $old
  | ($version | version_key) as $this
  | (reduce ($incoming[0][] | .platform as $platform | .plugins[] | . + { platform: $platform }) as $entry
      ({ plugins: (($old.plugins // []) | map({ key: .id, value: . }) | from_entries), seen: {}, added: [], kept: [], differing: [] };
        $entry.id as $id
        | .plugins[$id] as $had
        | {
            version: $entry.version, app_version: $version, api_version: $entry.api_version, platform: $entry.platform,
            url: "\($base)/plugins/\($app)/\($version)/\($entry.file)", size: $entry.size, sha256: ($entry.sha256 | ascii_downcase)
          } as $build
        # Name, description and meta are those of the newest build: of this
        # release, unless the index has a build of a later one. Within the
        # release, of the first platform that carries the plugin.
        | if .seen[$id] then .
          else
            .seen[$id] = true
            | (($had.builds // []) | map(.app_version | version_key) | max) as $newest
            | if $newest == null or $newest <= $this then
                .plugins[$id] = (
                  { id: $id, name: $entry.name, description: ($entry.description // ""), publisher: $publisher,
                    meta: ($entry.meta // {}), builds: ($had.builds // []) }
                  + (($had // {}) | del(.id, .name, .description, .publisher, .meta, .builds)))
              else . end
          end
        | ((.plugins[$id].builds // []) | map(select(build_key == ($build | build_key))) | first) as $same
        | if $same == null then
            .plugins[$id].builds += [$build] | .added += [$entry.file]
          elif $same.sha256 == $build.sha256 and $same.size == $build.size then
            .kept += [$entry.file]
          else
            .differing += [$entry.file]
          end)) as $merged
  | ([$merged.plugins[]] | sort_by(.id)
      | map(.builds |= sort_by([(.app_version | version_key), (.version | version_key), .platform]))) as $plugins
  | (if ($old.latest | type) == "object" and ($old.latest.version | type) == "string"
        and ($old.latest.version | version_key) > $this
     then $old.latest else { version: $version, url: $url } end) as $latest
  | {
      index: ($index | .apps[$app] = (
        { latest: $latest }
        + (if ($plugins | length) > 0 then { plugins: $plugins } else {} end)
        + ($old | del(.latest, .plugins)))),
      added: $merged.added, kept: $merged.kept, differing: $merged.differing, latest: $latest.version
    }' "$work/index.json" > "$work/merged.json"

# --- written only now ---------------------------------------------------------------

mapfile -t added < <(jq -r '.added[]' "$work/merged.json")
for file in "${added[@]}"; do
  mkdir -p "$site/plugins/$app/$version"
  cp -f "$incoming/$file" "$site/plugins/$app/$version/$file"
done
jq '.index' "$work/merged.json" | registry_write "$index"

while IFS= read -r file; do
  echo "::warning::$file is already published for $app $version with another size or SHA-256. A published file never changes: the index keeps the one it has. To replace it, remove the release from the registry and publish it again."
done < <(jq -r '.differing[]' "$work/merged.json")
echo "registry: $app $version: ${#added[@]} build(s) added, $(jq '.kept + .differing | length' "$work/merged.json") already there; latest is $(jq -r '.latest' "$work/merged.json")"
