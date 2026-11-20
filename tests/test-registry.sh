#!/usr/bin/env bash
# The registry scripts, on releases of a made-up app with plugins
# (tests/fixture/plugins.sh): a first release, the same release again, a
# fourth release that prunes the first, a file whose hash is wrong, an app
# without plugins that only gets `latest`, and a release that is removed.
# The index is signed with a throwaway minisign key made here and verified
# the way a reader does it. The real key is never used.
#
# Needs jq and minisign.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
command -v minisign > /dev/null || fail "minisign is not installed"

registry="$repo_root/registry"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

site="$work/site"
index="$site/registry/index.json"
removed="$work/removed"
base="https://registry.test"
export REGISTRY_BASE_URL="$base"
export REGISTRY_PUBLISHER="Open-Breach"

# release VERSION PLATFORM ID...: the files and the manifest of one platform
# of a release of the app `demo`, in $work/demo-VERSION.
release() {
  local version="$1"
  shift
  "$repo_root/tests/fixture/plugins.sh" "$work/demo-$version" demo "$version" "$@"
}
release_url() {
  echo "https://github.com/Open-Breach/demo/releases/tag/v$1"
}
# merge VERSION [NOW]: merge the release of that version into the index.
merge() {
  TREBUCHET_REGISTRY_NOW="${2:-2026-11-20T10:00:00Z}" \
    "$registry/merge.sh" "$site" demo "$1" "$(release_url "$1")" "$work/demo-$1"
}
# query FILTER: a value of the index.
query() {
  jq -r "$1" "$index"
}
# builds: one line per build of `demo`, "id app_version platform".
# shellcheck disable=SC2016  # a jq program: its $names are jq's
builds() {
  query '.apps.demo.plugins // [] | .[] | .id as $id | .builds[] | "\($id) \(.app_version) \(.platform)"'
}
# staged: the plugin files in the local site, relative to it.
staged() {
  (cd "$site" && find plugins -type f 2> /dev/null | sort)
}

for version in 1.0.0 1.1.0 1.2.0 1.10.0; do
  release "$version" linux-x64 alpha beta
  release "$version" macos-arm64 alpha
done

# --- a first release ---------------------------------------------------------

out="$(merge 1.0.0)"
grep -qF "3 build(s) added, 0 already there; latest is 1.0.0" <<< "$out" || fail "unexpected summary: $out"
[ "$(query '.schema')" = 1 ] || fail "schema is not 1"
[ "$(query '.generated')" = "2026-11-20T10:00:00Z" ] || fail "generated is not the time of the run"
[ "$(query '.apps.demo.latest | "\(.version) \(.url)"')" = "1.0.0 $(release_url 1.0.0)" ] || fail "latest is not the release"
[ "$(builds)" = "alpha 1.0.0 linux-x64
alpha 1.0.0 macos-arm64
beta 1.0.0 linux-x64" ] || fail "unexpected builds: $(builds)"
# The keys of the specification, in its order.
[ "$(query 'keys_unsorted | join(" ")')" = "schema generated apps" ] || fail "unexpected keys of the index"
[ "$(query '.apps.demo | keys_unsorted | join(" ")')" = "latest plugins" ] || fail "unexpected keys of an app"
[ "$(query '.apps.demo.plugins[0] | keys_unsorted | join(" ")')" = "id name description publisher meta builds" ] \
  || fail "unexpected keys of a plugin"
[ "$(query '.apps.demo.plugins[0].builds[0] | keys_unsorted | join(" ")')" = "version app_version api_version platform url size sha256" ] \
  || fail "unexpected keys of a build"
[ "$(query '.apps.demo.plugins[0] | "\(.name)|\(.description)|\(.publisher)"')" = "The alpha plugin|What alpha does, as of 1.0.0.|Open-Breach" ] \
  || fail "unexpected name, description or publisher"
# meta is the manifest's, whatever it holds.
[ "$(query '.apps.demo.plugins[0].meta | tojson')" = "$(jq -c '.plugins[0].meta' "$work/demo-1.0.0/plugins-linux-x64.json")" ] \
  || fail "meta is not the manifest's"
# Every build names a file that is staged, with its size and hash.
while IFS=$'\t' read -r url size sha256; do
  path="${url#"$base"/}"
  [ "$path" != "$url" ] || fail "$url is not under $base"
  assert_file "$site/$path"
  [ "$(stat -c %s "$site/$path")" = "$size" ] || fail "$path is not $size bytes"
  [ "$(sha256sum "$site/$path" | cut -d ' ' -f 1)" = "$sha256" ] || fail "$path has another SHA-256 than the index says"
done < <(query '.apps.demo.plugins[].builds[] | [.url, .size, .sha256] | @tsv')
[ "$(staged | wc -l)" -eq 3 ] || fail "expected three staged files: $(staged)"
[ "$(query '.apps.demo.plugins[0].builds[0].url')" = "$base/plugins/demo/1.0.0/alpha-1.0.0-linux-x64.plugin" ] || fail "unexpected url"

# Signed, and verified as a reader does it: the kind of signature over the
# file's hash, against the public key alone.
minisign -G -W -f -p "$work/registry.pub" -s "$work/registry.key" > /dev/null 2>&1
sign() {
  REGISTRY_SIGNING_KEY="$(cat "$work/registry.key")" REGISTRY_SIGNING_PASSWORD="" \
    TREBUCHET_REGISTRY_PUBLIC_KEY="$work/registry.pub" "$registry/sign.sh" "$index" > /dev/null
}
sign
minisign -V -H -m "$index" -p "$work/registry.pub" > /dev/null || fail "the index does not verify"
# One byte of the index changed, and it is refused.
sed 's/"The alpha plugin"/"The alpha plugiN"/' "$index" > "$work/tampered.json"
! cmp -s "$index" "$work/tampered.json" || fail "the tampered index is the index"
assert_fails minisign -V -m "$work/tampered.json" -x "$index.minisig" -p "$work/registry.pub"

# --- the same release again --------------------------------------------------------

cp "$index" "$work/first.json"
# As a second publisher run has it: the index from the bucket, no files.
rm -rf "$site/plugins"
out="$(merge 1.0.0 2026-11-20T11:00:00Z)"
grep -qF "0 build(s) added, 3 already there" <<< "$out" || fail "unexpected summary of the repeated release: $out"
[ "$(query '.generated')" = "2026-11-20T11:00:00Z" ] || fail "generated did not change"
diff <(jq 'del(.generated)' "$work/first.json") <(jq 'del(.generated)' "$index") > /dev/null \
  || fail "the same release again changed more than generated"
# Nothing but that one line differs in the file itself.
[ "$(diff "$work/first.json" "$index" | grep -c '^[<>]')" -eq 2 ] || fail "more than the line of generated differs"
[ -z "$(staged)" ] || fail "a build that is already there was staged again: $(staged)"

# A build that is there, and whose file in the release is another one now:
# the index keeps what it has, and says so.
mkdir -p "$work/changed"
cp "$work/demo-1.0.0"/* "$work/changed/"
echo "changed after it was published" >> "$work/changed/beta-1.0.0-linux-x64.plugin"
jq --argjson size "$(stat -c %s "$work/changed/beta-1.0.0-linux-x64.plugin")" \
  --arg sha256 "$(sha256sum "$work/changed/beta-1.0.0-linux-x64.plugin" | cut -d ' ' -f 1)" \
  '(.plugins[] | select(.id == "beta")) |= (.size = $size | .sha256 = $sha256)' \
  "$work/demo-1.0.0/plugins-linux-x64.json" > "$work/changed/plugins-linux-x64.json"
out="$(TREBUCHET_REGISTRY_NOW=2026-11-20T11:00:00Z "$registry/merge.sh" "$site" demo 1.0.0 "$(release_url 1.0.0)" "$work/changed")"
grep -qF "::warning::beta-1.0.0-linux-x64.plugin is already published" <<< "$out" || fail "no warning for a changed file: $out"
diff <(jq 'del(.generated)' "$work/first.json") <(jq 'del(.generated)' "$index") > /dev/null \
  || fail "a changed file of a published build changed the index"
[ -z "$(staged)" ] || fail "a changed file of a published build was staged: $(staged)"

# --- what stops a run before anything is written ---------------------------------------

cp "$index" "$work/before.json"
# refused EXPECTED DIR [VERSION]: merging DIR fails with that message and
# leaves the index and the staged files as they were.
refused() {
  local expected="$1" dir="$2" version="${3:-2.0.0}" out
  if out="$("$registry/merge.sh" "$site" demo "$version" "$(release_url "$version")" "$dir" 2>&1)"; then
    fail "expected to fail: $expected"
  fi
  grep -qF "$expected" <<< "$out" || fail "expected '$expected' in: $out"
  cmp -s "$work/before.json" "$index" || fail "the index changed although the run failed: $expected"
  [ -z "$(staged)" ] || fail "files were staged although the run failed: $expected"
}
# bad NAME: a copy of a good release 2.0.0 to break, in $work/NAME.
bad() {
  rm -rf "${work:?}/$1"
  "$repo_root/tests/fixture/plugins.sh" "$work/$1" demo 2.0.0 linux-x64 alpha beta
  "$repo_root/tests/fixture/plugins.sh" "$work/$1" demo 2.0.0 macos-arm64 alpha
}
# edit NAME FILTER: change the linux manifest of a bad release.
edit() {
  jq "$2" "$work/$1/plugins-linux-x64.json" > "$work/$1/manifest.new"
  mv "$work/$1/manifest.new" "$work/$1/plugins-linux-x64.json"
}

# The last file of the last manifest is wrong: everything before it was
# good, and nothing of it is written.
bad hash
echo "one more line" >> "$work/hash/alpha-2.0.0-macos-arm64.plugin"
refused "alpha-2.0.0-macos-arm64.plugin has" "$work/hash"
bad hash
printf 'X' | dd of="$work/hash/beta-2.0.0-linux-x64.plugin" bs=1 seek=3 conv=notrunc 2> /dev/null
refused "the SHA-256 of beta-2.0.0-linux-x64.plugin is" "$work/hash"
bad missing
rm "$work/missing/beta-2.0.0-linux-x64.plugin"
refused "the release has no file beta-2.0.0-linux-x64.plugin" "$work/missing"
bad app
edit app '.app = "another"'
refused "is the manifest of 'another 2.0.0 linux-x64'" "$work/app"
bad version
refused "this release is 'demo 2.0.1'" "$work/version" 2.0.1
bad platform
mv "$work/platform/plugins-linux-x64.json" "$work/platform/plugins-linux-arm64.json"
refused "the file's name says 'linux-arm64'" "$work/platform"
bad path
edit path '.plugins[0].file = "../alpha-2.0.0-linux-x64.plugin"'
refused "file is not a plain file name" "$work/path"
bad id
edit id '.plugins[0].id = "Alpha/../x"'
refused "id is not a plugin id" "$work/id"
bad sha
edit sha '.plugins[0].sha256 = "abc"'
refused "sha256 is not 64 hexadecimal digits" "$work/sha"
bad size
edit size '.plugins[0].size = "106"'
refused "size is not a number of bytes" "$work/size"
bad api
edit api '.plugins[0].api_version = 7.5'
refused "api_version is not a whole number" "$work/api"
bad meta
edit meta '.plugins[0].meta = "points"'
refused "meta is not an object" "$work/meta"
bad twice
edit twice '.plugins += [.plugins[0]]'
refused "lists more than once: alpha" "$work/twice"
bad same-file
cp "$work/same-file/alpha-2.0.0-linux-x64.plugin" "$work/same-file/alpha-2.0.0-macos-arm64.plugin"
jq --slurpfile linux "$work/same-file/plugins-linux-x64.json" '.plugins[0] = ($linux[0].plugins[0])' \
  "$work/same-file/plugins-macos-arm64.json" > "$work/same-file/manifest.new"
mv "$work/same-file/manifest.new" "$work/same-file/plugins-macos-arm64.json"
refused "named by more than one manifest of the release: alpha-2.0.0-linux-x64.plugin" "$work/same-file"
bad json
echo '[]' > "$work/json/plugins-linux-x64.json"
refused "is not a manifest" "$work/json"
# A pre-release, a request that is not one, an index of a newer publisher.
bad good
refused "the registry carries releases only" "$work/good" 2.0.0-rc1
assert_fails "$registry/merge.sh" "$site" demo 2.0.0 "http://github.com/Open-Breach/demo/releases/tag/v2.0.0" "$work/good"
assert_fails "$registry/merge.sh" "$site" 'demo;id' 2.0.0 "$(release_url 2.0.0)" "$work/good"
mkdir -p "$work/newer/registry"
jq '.schema = 2' "$index" > "$work/newer/registry/index.json"
assert_fails "$registry/merge.sh" "$work/newer" demo 2.0.0 "$(release_url 2.0.0)" "$work/good"
[ "$(jq '.schema' "$work/newer/registry/index.json")" = 2 ] || fail "an index of a newer schema was rewritten"
echo 'not json' > "$work/newer/registry/index.json"
assert_fails "$registry/merge.sh" "$work/newer" demo 2.0.0 "$(release_url 2.0.0)" "$work/good"
[ "$(cat "$work/newer/registry/index.json")" = "not json" ] || fail "a file that is no index was replaced"

# --- three more releases: the fourth prunes the first ---------------------------------

: > "$removed"
for version in 1.1.0 1.2.0; do
  merge "$version" > /dev/null
  "$registry/prune.sh" "$site" "$removed" > /dev/null
done
[ ! -s "$removed" ] || fail "three releases, and something was pruned: $(cat "$removed")"
[ "$(builds | wc -l)" -eq 9 ] || fail "expected nine builds of three releases"
# Name, description and meta follow the newest build.
[ "$(query '.apps.demo.plugins[0].description')" = "What alpha does, as of 1.2.0." ] || fail "the description is not the newest build's"
[ "$(query '.apps.demo.plugins[0].meta.since')" = "1.2.0" ] || fail "meta is not the newest build's"

# 1.10.0 is newer than 1.2.0: versions are compared as versions.
merge 1.10.0 > /dev/null
out="$("$registry/prune.sh" "$site" "$removed")"
grep -qF "registry: pruned demo 1.0.0: 3 build(s)" <<< "$out" || fail "unexpected summary of the pruning: $out"
[ "$(query '.apps.demo.latest.version')" = "1.10.0" ] || fail "latest is not 1.10.0"
[ "$(query '[.apps.demo.plugins[].builds[].app_version] | unique | join(" ")')" = "1.1.0 1.10.0 1.2.0" ] \
  || fail "the builds of 1.0.0 are still in the index"
[ "$(sort "$removed")" = "plugins/demo/1.0.0/alpha-1.0.0-linux-x64.plugin
plugins/demo/1.0.0/alpha-1.0.0-macos-arm64.plugin
plugins/demo/1.0.0/beta-1.0.0-linux-x64.plugin" ] || fail "unexpected files to delete: $(cat "$removed")"
# The builds of a release stand in the order of the versions, oldest first.
[ "$(query '[.apps.demo.plugins[0].builds[].app_version] | unique_by(.) | length')" -eq 3 ] || fail "alpha has builds of more than three releases"
[ "$(query '.apps.demo.plugins[0].builds | first.app_version + " " + last.app_version')" = "1.1.0 1.10.0" ] \
  || fail "the builds are not in the order of the versions"
# Pruning again finds nothing.
cp "$index" "$work/pruned.json"
: > "$removed"
"$registry/prune.sh" "$site" "$removed" > /dev/null
[ ! -s "$removed" ] || fail "pruning twice removed something"
cmp -s "$work/pruned.json" "$index" || fail "pruning twice changed the index"

# An older release, published again after a newer one: its builds come back
# until they are pruned, and neither latest nor the description follow it.
out="$(merge 1.0.0)"
grep -qF "3 build(s) added" <<< "$out" || fail "the older release was not added again: $out"
[ "$(query '.apps.demo.latest.version')" = "1.10.0" ] || fail "an older release became latest"
[ "$(query '.apps.demo.plugins[0].description')" = "What alpha does, as of 1.10.0." ] || fail "an older release gave the description"
"$registry/prune.sh" "$site" "$removed" > /dev/null
[ "$(wc -l < "$removed")" -eq 3 ] || fail "the older release was not pruned again"
rm -rf "$site/plugins"

# A plugin that later releases no longer carry leaves with its last build.
for version in 2.0.0 2.1.0 2.2.0; do
  "$repo_root/tests/fixture/plugins.sh" "$work/demo-$version" demo "$version" linux-x64 alpha
  merge "$version" > /dev/null
  "$registry/prune.sh" "$site" "$removed" > /dev/null
done
[ "$(query '[.apps.demo.plugins[].id] | join(" ")')" = "alpha" ] || fail "beta is still in the index: $(builds)"
[ "$(builds)" = "alpha 2.0.0 linux-x64
alpha 2.1.0 linux-x64
alpha 2.2.0 linux-x64" ] || fail "unexpected builds: $(builds)"
grep -qx "plugins/demo/1.10.0/beta-1.10.0-linux-x64.plugin" "$removed" || fail "beta's last file is not among the files to delete"

# --- an app without plugins --------------------------------------------------------------

cp "$index" "$work/before.json"
out="$(TREBUCHET_REGISTRY_NOW=2026-11-20T12:00:00Z "$registry/merge.sh" "$site" plain 0.3.1 https://github.com/Open-Breach/plain/releases/tag/v0.3.1)"
grep -qF "0 build(s) added, 0 already there; latest is 0.3.1" <<< "$out" || fail "unexpected summary: $out"
[ "$(query '.apps.plain | tojson')" = '{"latest":{"version":"0.3.1","url":"https://github.com/Open-Breach/plain/releases/tag/v0.3.1"}}' ] \
  || fail "an app without plugins has more than latest: $(query '.apps.plain | tojson')"
# The other app is as it was, and the apps stand in the order of their names.
[ "$(query '.apps.demo | tojson')" = "$(jq -r '.apps.demo | tojson' "$work/before.json")" ] || fail "another app's release changed demo"
[ "$(query '.apps | keys_unsorted | join(" ")')" = "demo plain" ] || fail "the apps are not in the order of their names"
# An empty folder of a release is a release without plugins too.
mkdir "$work/empty"
"$registry/merge.sh" "$site" plain 0.3.2 https://github.com/Open-Breach/plain/releases/tag/v0.3.2 "$work/empty" > /dev/null
[ "$(query '.apps.plain.latest.version')" = "0.3.2" ] || fail "latest of the app without plugins did not move"
# Pruning leaves it alone.
"$registry/prune.sh" "$site" "$removed" > /dev/null
[ "$(query '.apps.plain.latest.version')" = "0.3.2" ] || fail "pruning touched an app without plugins"

# What a reader does not know, the publisher keeps.
jq '.note = "kept" | .apps.demo.channel = "stable" | .apps.demo.plugins[0].homepage = "https://example.org"' "$index" > "$work/extra.json"
cp "$work/extra.json" "$index"
"$repo_root/tests/fixture/plugins.sh" "$work/demo-2.3.0" demo 2.3.0 linux-x64 alpha
merge 2.3.0 > /dev/null
[ "$(query '"\(.note) \(.apps.demo.channel) \(.apps.demo.plugins[0].homepage)"')" = "kept stable https://example.org" ] \
  || fail "the publisher dropped fields it does not know"

# --- a release that is removed ----------------------------------------------------------------

: > "$removed"
"$registry/prune.sh" "$site" "$removed" > /dev/null
# Not the newest: its builds go, latest stays.
out="$("$registry/remove.sh" "$site" "$removed" demo 2.2.0)"
grep -qF "registry: removed demo 2.2.0: 1 build(s)" <<< "$out" || fail "unexpected summary of the removal: $out"
grep -qx "plugins/demo/2.2.0/alpha-2.2.0-linux-x64.plugin" "$removed" || fail "the removed release's file is not among the files to delete"
[ "$(builds)" = "alpha 2.1.0 linux-x64
alpha 2.3.0 linux-x64" ] || fail "unexpected builds after the removal: $(builds)"
[ "$(query '.apps.demo.latest.version')" = "2.3.0" ] || fail "removing an older release changed latest"
# The newest: latest goes with it, and the release before is named by
# publishing it again.
out="$("$registry/remove.sh" "$site" "$removed" demo 2.3.0)"
grep -qF "::warning::demo 2.3.0 was the latest release of demo" <<< "$out" || fail "no word about latest: $out"
[ "$(query '.apps.demo | has("latest")')" = false ] || fail "latest still names the removed release"
[ "$(query '.apps.demo.channel')" = "stable" ] || fail "the removal dropped a field it does not know"
merge 2.1.0 > /dev/null
[ "$(query '.apps.demo.latest | "\(.version) \(.url)"')" = "2.1.0 $(release_url 2.1.0)" ] || fail "publishing the release before did not name it"
[ "$(builds)" = "alpha 2.1.0 linux-x64" ] || fail "publishing the release before added builds: $(builds)"
# A release the index has nothing of.
cp "$index" "$work/before.json"
assert_fails "$registry/remove.sh" "$site" "$removed" demo 9.9.9
assert_fails "$registry/remove.sh" "$site" "$removed" nobody 2.1.0
cmp -s "$work/before.json" "$index" || fail "a removal that failed changed the index"
# An app without plugins: its release is latest and nothing else.
"$registry/remove.sh" "$site" "$removed" plain 0.3.2 > /dev/null
[ "$(query '.apps.plain | tojson')" = "{}" ] || fail "unexpected rest of the app without plugins: $(query '.apps.plain | tojson')"
# The last release of an app with plugins: no plugins are left.
"$registry/remove.sh" "$site" "$removed" demo 2.1.0 > /dev/null
[ "$(query '.apps.demo | has("plugins")')" = false ] || fail "an app without builds still lists plugins"

# A build whose address points out of its folder is never named for deletion.
merge 2.1.0 > /dev/null
jq '.apps.demo.plugins[0].builds[0].url = "https://registry.test/apt/pool/debian-12/rick_1.0.0_debian-12_amd64.deb"' "$index" > "$work/outside.json"
cp "$work/outside.json" "$index"
: > "$removed"
assert_fails "$registry/remove.sh" "$site" "$removed" demo 2.1.0
[ ! -s "$removed" ] || fail "a file outside the registry's folders was named for deletion"
jq '.apps.demo.plugins[0].builds[0].url = "https://registry.test/plugins/other/2.1.0/alpha-2.1.0-linux-x64.plugin"' "$index" > "$work/outside.json"
cp "$work/outside.json" "$index"
assert_fails "$registry/remove.sh" "$site" "$removed" demo 2.1.0
[ ! -s "$removed" ] || fail "a file of another app's folder was named for deletion"

# The index after all of this still signs and verifies.
sign
minisign -V -H -m "$index" -p "$work/registry.pub" > /dev/null || fail "the last index does not verify"

echo "registry: merged, repeated, pruned, refused and removed"
