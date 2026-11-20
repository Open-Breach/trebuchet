#!/usr/bin/env bash
# The publisher's steps, in the order publish.yml runs them, against an S3
# server on this machine: four releases of the fixture are published one
# after the other, each from an empty working directory that starts with
# what the bucket holds. Then the bucket is checked, and the one-line
# installer installs from it in a container of every target.
#
# Every release carries plugins, so every run also keeps the plugin
# registry: the index of the bucket is verified, the release is merged into
# it, the index is signed, and the plugin files and the index go up. The
# registry keeps the plugins of every release, where the package pool keeps
# the last three versions: after four releases the first one's packages are
# gone and its plugins are served. What the bucket then serves is read the
# way an app reads it, and a list or a file that was tampered with is
# refused.
#
# The signing keys are throwaways generated here. The GPG key reaches the
# scripts the way the real one does: as an armoured export in
# GPG_PRIVATE_KEY, imported into an empty gpg home, with its passphrase in
# GPG_PASSPHRASE. So does the registry's minisign key: its secret key file
# in REGISTRY_SIGNING_KEY and its password in REGISTRY_SIGNING_PASSWORD.
# The real keys are never used.
#
# Needs the AWS CLI, docker, minisign, the network, and moto's S3 server:
#
#   python3 -m venv /tmp/moto && /tmp/moto/bin/pip install 'moto[server]'
#   TREBUCHET_MOTO_SERVER=/tmp/moto/bin/moto_server tests/test-publish.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
require_docker
scripts="$repo_root/.github/scripts/publish"
moto="${TREBUCHET_MOTO_SERVER:-moto_server}"
command -v "$moto" > /dev/null || fail "moto_server not found; see the top of this file"
command -v aws > /dev/null || fail "the AWS CLI is not installed"
command -v minisign > /dev/null || fail "minisign is not installed"

work="$(mktemp -d)"
server=""
web=""
cleanup() {
  [ -z "$server" ] || kill "$server" 2> /dev/null || true
  [ -z "$web" ] || kill "$web" 2> /dev/null || true
  stop_gpg_agent "$work/origin"
  stop_gpg_agent "$work/gnupg"
  rm -rf "$work"
}
trap cleanup EXIT

# --- the request check ------------------------------------------------------

request() {
  env -u GITHUB_OUTPUT GITHUB_REPOSITORY_OWNER=Open-Breach PUBLISH_EVENT="$1" \
    PUBLISH_APP="$2" PUBLISH_VERSION="$3" PUBLISH_RELEASE_URL="$4" PUBLISH_REMOVE="${5:-}" "$scripts/request.sh"
}
out="$(request repository_dispatch rick 1.2.3 https://github.com/Open-Breach/rick/releases/tag/v1.2.3)"
for line in mode=release app=rick package-version=1.2.3 repository=Open-Breach/rick tag=v1.2.3 \
  release-url=https://github.com/Open-Breach/rick/releases/tag/v1.2.3; do
  grep -qx "$line" <<< "$out" || fail "request.sh: no '$line' in: $out"
done
# A manual run as the form sends it, with the box for a removal not ticked.
grep -qx "mode=release" <<< "$(request workflow_dispatch rick 1.2.3 https://github.com/Open-Breach/rick/releases/tag/v1.2.3 false)" \
  || fail "request.sh: a manual run with remove=false is a release"
# A removal from the registry: a manual run that names an app and a version.
out="$(request workflow_dispatch rick 1.2.3 "" true)"
for line in mode=remove app=rick package-version=1.2.3; do
  grep -qx "$line" <<< "$out" || fail "request.sh: no '$line' in: $out"
done
assert_fails request repository_dispatch rick 1.2.3 "" true
assert_fails request workflow_dispatch rick "" "" true
assert_fails request workflow_dispatch "" 1.2.3 "" true
assert_fails request workflow_dispatch 'rick;id' 1.2.3 "" true
assert_fails request workflow_dispatch rick 1.2.3-rc1 "" true
# The owner's name in any case.
request repository_dispatch rick 1.2.3 https://github.com/open-breach/rick/releases/tag/v1.2.3 > /dev/null
grep -qx "mode=republish" <<< "$(request workflow_dispatch "" "" "")" || fail "request.sh: an empty manual run is a republish"
assert_fails request repository_dispatch "" "" ""
assert_fails request repository_dispatch rick 1.2.3 ""
assert_fails request repository_dispatch rick 1.2.3 https://github.com/someone-else/rick/releases/tag/v1.2.3
assert_fails request repository_dispatch rick 1.2.3 https://example.com/Open-Breach/rick/releases/tag/v1.2.3
assert_fails request repository_dispatch rick 1.2.3 "https://github.com/Open-Breach/rick/releases/tag/v1.2.3?x=1"
assert_fails request repository_dispatch rick 1.2.3 'https://github.com/Open-Breach/rick/releases/tag/v1.2.3;id'
assert_fails request repository_dispatch 'rick;id' 1.2.3 https://github.com/Open-Breach/rick/releases/tag/v1.2.3
assert_fails request repository_dispatch rick v1.2.3 https://github.com/Open-Breach/rick/releases/tag/v1.2.3
assert_fails request repository_dispatch rick 1.2.3-rc1 https://github.com/Open-Breach/rick/releases/tag/v1.2.3-rc1
echo "-- request.sh accepts and refuses as it should"

# --- the key, as the workflow gets it ---------------------------------------

passphrase="correct horse battery staple"
make_test_key "$work/origin" rsa "$passphrase"
make_test_key "$work/other" ed25519
stop_gpg_agent "$work/other"
GPG_PRIVATE_KEY="$(GNUPGHOME="$work/origin" gpg --batch --no-tty --pinentry-mode loopback --passphrase-fd 3 \
  --export-secret-keys --armor 3<<< "$passphrase")"
export GPG_PRIVATE_KEY
export TREBUCHET_PUBLIC_KEY="$work/origin/public.gpg"

# A secret that is not the published key is refused before anything is signed.
assert_fails env GNUPGHOME="$work/refused" "$scripts/import-key.sh" "$work/other/public.gpg"
assert_fails env GNUPGHOME="$work/refused2" GPG_PRIVATE_KEY="" "$scripts/import-key.sh" "$TREBUCHET_PUBLIC_KEY"
stop_gpg_agent "$work/refused"

export GNUPGHOME="$work/gnupg"
"$scripts/import-key.sh" "$TREBUCHET_PUBLIC_KEY"
unset GPG_PRIVATE_KEY
export GPG_PASSPHRASE="$passphrase"

# The registry's key, a minisign pair with a password, and another pair that
# is not the published one.
registry_password="tr0ub4dor and 3"
printf '%s\n%s\n' "$registry_password" "$registry_password" \
  | minisign -G -f -p "$work/registry.pub" -s "$work/registry.key" > /dev/null 2>&1
minisign -G -W -f -p "$work/registry-other.pub" -s "$work/registry-other.key" > /dev/null 2>&1
REGISTRY_SIGNING_KEY="$(cat "$work/registry.key")"
export REGISTRY_SIGNING_KEY
export REGISTRY_SIGNING_PASSWORD="$registry_password"
export TREBUCHET_REGISTRY_PUBLIC_KEY="$work/registry.pub"
export REGISTRY_PUBLISHER="Open-Breach"
# Where the bucket's content is served further down; the index names its
# files by this address.
web_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
url="http://127.0.0.1:$web_port"
export REGISTRY_BASE_URL="$url"

# --- the bucket -------------------------------------------------------------

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
"$moto" -H 127.0.0.1 -p "$port" > "$work/server.log" 2>&1 &
server="$!"
export R2_ENDPOINT="http://127.0.0.1:$port" R2_BUCKET="trebuchet-test"
export AWS_ACCESS_KEY_ID="test" AWS_SECRET_ACCESS_KEY="test"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
s3api() {
  AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url "$R2_ENDPOINT" "$@"
}
for _ in $(seq 1 100); do
  if s3api s3 ls > /dev/null 2>&1; then break; fi
  sleep 0.1
done
s3api s3 mb "s3://$R2_BUCKET" > /dev/null || fail "the S3 server did not start: $(cat "$work/server.log")"

# plugins DIR VERSION: what a release of the fixture attaches for the
# registry: two plugins for one platform, one of them for a second.
plugins() {
  "$repo_root/tests/fixture/plugins.sh" "$1" trebuchet-fixture "$2" linux-x64 alpha beta
  "$repo_root/tests/fixture/plugins.sh" "$1" trebuchet-fixture "$2" macos-arm64 alpha
}
release_url() {
  echo "https://github.com/Open-Breach/trebuchet-fixture/releases/tag/v$1"
}
# publish N [VERSION]: one run of the publisher, from an empty directory, in
# the order of publish.yml's steps. With a version it is a release, with its
# packages and its plugins; without one a republish, which leaves the
# registry alone.
publish() {
  local run="$work/run-$1" incoming=()
  mkdir -p "$run"
  if [ -n "${2:-}" ]; then
    "$repo_root/tests/fixture/build.sh" "$run/incoming" "$2" > /dev/null
    incoming=("$run/incoming")
    plugins "$run/plugins" "$2"
  fi
  "$scripts/bucket.sh" pull "$run/site" > "$run/pull.log"
  [ -z "${2:-}" ] || "$scripts/bucket.sh" pull-registry "$run/site" >> "$run/pull.log"
  "$scripts/build-site.sh" "$run/site" "$run/removed" "${incoming[@]}" > "$run/build.log"
  [ -z "${2:-}" ] || "$scripts/build-registry.sh" "$run/site" "$run/registry-removed" release \
    trebuchet-fixture "$2" "$(release_url "$2")" "$run/plugins" >> "$run/build.log"
  "$scripts/bucket.sh" push "$run/site" "$run/removed" > "$run/push.log"
  [ -z "${2:-}" ] || "$scripts/bucket.sh" push-registry "$run/site" "$run/registry-removed" >> "$run/push.log"
}
# registry_run NAME COMMAND...: the registry's three steps of one run, with
# the arguments of build-registry.sh after its two paths.
registry_run() {
  local run="$work/run-$1"
  shift
  mkdir -p "$run"
  "$scripts/bucket.sh" pull-registry "$run/site" > "$run/pull.log"
  "$scripts/build-registry.sh" "$run/site" "$run/registry-removed" "$@" > "$run/build.log" 2>&1 || return 1
  "$scripts/bucket.sh" push-registry "$run/site" "$run/registry-removed" > "$run/push.log"
}
# registry_ok NAME COMMAND...: the same, for a run that has to succeed.
registry_ok() {
  registry_run "$@" || {
    cat "$work/run-$1/build.log"
    fail "the registry's run '$1' failed"
  }
}
listing() {
  s3api s3 ls "s3://$R2_BUCKET" --recursive | awk '{ print $4 }' | sort
}
# The index as the bucket holds it.
bucket_index() {
  s3api s3 cp "s3://$R2_BUCKET/registry/index.json" - 2> /dev/null
}

publish 1 1.0.0
grep -qF "the bucket has no index yet" "$work/run-1/build.log" || fail "the first run did not start the registry's index"
publish 2 1.1.0
grep -qF "the index of the bucket verifies" "$work/run-2/build.log" || fail "the second run did not verify the index of the first"
old="apt/pool/$(targets_of deb | head -n 1)/trebuchet-fixture_1.1.0_$(targets_of deb | head -n 1)_amd64.deb"
modified="$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old" --query LastModified --output text)"
old_plugin="plugins/trebuchet-fixture/1.1.0/alpha-1.1.0-linux-x64.plugin"
plugin_modified="$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old_plugin" --query LastModified --output text)"
sleep 1
publish 3 1.2.0
[ ! -s "$work/run-3/removed" ] || fail "three versions and something was pruned"
publish 4 1.3.0
# The fourth release prunes the first one's packages, and nothing of the
# registry: no release ever takes a plugin file away.
[ -s "$work/run-4/removed" ] || fail "four versions and no package was pruned"
for run in 1 2 3 4; do
  [ ! -s "$work/run-$run/registry-removed" ] || fail "run $run: a release took plugin files out of the registry: $(cat "$work/run-$run/registry-removed")"
done
echo "-- four releases published"

# A package that was not touched is not uploaded again, and neither is a
# plugin file.
[ "$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old" --query LastModified --output text)" = "$modified" ] \
  || fail "$old was uploaded again by a later publish"
[ "$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old_plugin" --query LastModified --output text)" = "$plugin_modified" ] \
  || fail "$old_plugin was uploaded again by a later publish"

files="$(listing)"
for suite in $(targets_of deb); do
  for file in InRelease Release Release.gpg; do
    grep -qx "apt/dists/$suite/$file" <<< "$files" || fail "no apt/dists/$suite/$file in the bucket"
  done
  for arch in $(arches_of deb); do
    grep -qx "apt/dists/$suite/main/binary-$arch/Packages.gz" <<< "$files" || fail "no index for $suite/$arch"
    ! grep -qx "apt/pool/$suite/trebuchet-fixture_1.0.0_${suite}_${arch}.deb" <<< "$files" || fail "$suite/$arch: 1.0.0 was not pruned in the bucket"
    for version in 1.1.0 1.2.0 1.3.0; do
      grep -qx "apt/pool/$suite/trebuchet-fixture_${version}_${suite}_${arch}.deb" <<< "$files" || fail "$suite/$arch: $version is not in the bucket"
    done
  done
done
for repo in $(targets_of rpm); do
  for arch in $(arches_of rpm); do
    ! grep -qx "rpm/$repo/$arch/trebuchet-fixture-1.0.0-1.$repo.$arch.rpm" <<< "$files" || fail "$repo/$arch: 1.0.0 was not pruned in the bucket"
    for version in 1.1.0 1.2.0 1.3.0; do
      grep -qx "rpm/$repo/$arch/trebuchet-fixture-$version-1.$repo.$arch.rpm" <<< "$files" || fail "$repo/$arch: $version is not in the bucket"
    done
    for file in repomd.xml repomd.xml.asc; do
      grep -qx "rpm/$repo/$arch/repodata/$file" <<< "$files" || fail "no rpm/$repo/$arch/repodata/$file in the bucket"
    done
    # The metadata of the three earlier publishes is gone.
    [ "$(grep -c "^rpm/$repo/$arch/repodata/.*-primary\.xml\." <<< "$files")" = 1 ] || fail "$repo/$arch: stale metadata in the bucket"
  done
done
for file in install.sh keys/openbreach.gpg keys/openbreach.asc; do
  grep -qx "$file" <<< "$files" || fail "no $file in the bucket"
done
# The registry: the index with its signature, and the plugin files of all
# four releases. 1.0.0 is among them, whose packages were pruned above: an
# app of any released version still finds its plugins.
for file in registry/index.json registry/index.json.minisig; do
  grep -qx "$file" <<< "$files" || fail "no $file in the bucket"
done
expected_plugins=""
for version in 1.0.0 1.1.0 1.2.0 1.3.0; do
  for file in "alpha-$version-linux-x64.plugin" "alpha-$version-macos-arm64.plugin" "beta-$version-linux-x64.plugin"; do
    expected_plugins+="plugins/trebuchet-fixture/$version/$file"$'\n'
  done
done
[ "$(grep '^plugins/' <<< "$files")" = "${expected_plugins%$'\n'}" ] \
  || fail "unexpected plugin files in the bucket: $(grep '^plugins/' <<< "$files")"
# And the index names every one of them: twelve builds of four releases.
[ "$(bucket_index | jq -r '[.apps["trebuchet-fixture"].plugins[].builds[].app_version] | unique | join(" ")')" = "1.0.0 1.1.0 1.2.0 1.3.0" ] \
  || fail "the index does not hold the builds of all four releases"
[ "$(bucket_index | jq '[.apps["trebuchet-fixture"].plugins[].builds[]] | length')" -eq 12 ] || fail "expected twelve builds in the index"
[ "$(bucket_index | jq -r '.apps["trebuchet-fixture"].plugins[].builds[].url' | sed "s|^$url/||" | sort)" = "${expected_plugins%$'\n'}" ] \
  || fail "the index does not name exactly the plugin files of the bucket"
# Nothing but the site is in the bucket.
stray="$(grep -v -E '^(apt/|rpm/|plugins/|registry/index\.json(\.minisig)?$|keys/openbreach\.(gpg|asc)$|install\.sh$)' <<< "$files" || true)"
[ -z "$stray" ] || fail "unexpected objects in the bucket: $stray"

# Index files are cached for a moment only, packages carry no such header,
# and the installer can be read in a browser.
header() {
  s3api s3api head-object --bucket "$R2_BUCKET" --key "$1" --query "$2" --output text
}
suite="$(targets_of deb | head -n 1)"
repo="$(targets_of rpm | head -n 1)"
for key in "apt/dists/$suite/InRelease" "apt/dists/$suite/main/binary-amd64/Packages.gz" "rpm/$repo/x86_64/repodata/repomd.xml"; do
  [ "$(header "$key" CacheControl)" = "public, max-age=60" ] || fail "$key: Cache-Control is '$(header "$key" CacheControl)'"
done
[ "$(header "$old" CacheControl)" = None ] || fail "$old carries a Cache-Control header"
# The registry's index changes and is cached for a moment; a plugin file
# never changes and may be kept.
for key in registry/index.json registry/index.json.minisig; do
  [ "$(header "$key" CacheControl)" = "public, max-age=60" ] || fail "$key: Cache-Control is '$(header "$key" CacheControl)'"
done
[ "$(header registry/index.json ContentType)" = "application/json" ] || fail "the index is served as $(header registry/index.json ContentType)"
[ "$(header "$old_plugin" CacheControl)" = "public, max-age=31536000, immutable" ] \
  || fail "$old_plugin: Cache-Control is '$(header "$old_plugin" CacheControl)'"
[ "$(header install.sh ContentType)" = "text/plain; charset=utf-8" ] || fail "install.sh is served as $(header install.sh ContentType)"
cmp -s "$repo_root/install.sh" <(s3api s3 cp "s3://$R2_BUCKET/install.sh" -) || fail "install.sh in the bucket is not the repository's"
for form in gpg asc; do
  cmp -s "$work/origin/public.$form" <(s3api s3 cp "s3://$R2_BUCKET/keys/openbreach.$form" -) || fail "keys/openbreach.$form in the bucket is not the published key"
done
echo "-- the bucket holds the last three versions of every package, the plugins of every release, fresh indexes and nothing else"

# A key whose two files have drifted apart is not published.
mkdir "$work/drifted"
cp "$work/origin/public.gpg" "$work/drifted/public.gpg"
cp "$work/other/public.asc" "$work/drifted/public.asc"
assert_fails env TREBUCHET_PUBLIC_KEY="$work/drifted/public.gpg" "$scripts/build-site.sh" "$work/drifted/site" "$work/drifted/removed"

# A republish adds and removes nothing, and leaves the registry alone.
index_modified="$(header registry/index.json LastModified)"
sleep 1
publish 5
[ ! -s "$work/run-5/removed" ] || fail "a republish pruned something"
[ "$(listing | grep -c -E '\.(deb|rpm)$')" = "$(grep -c -E '\.(deb|rpm)$' <<< "$files")" ] || fail "a republish changed the packages"
[ "$(header registry/index.json LastModified)" = "$index_modified" ] || fail "a republish wrote the registry's index"

# The pool of a target that is no longer in targets.json is left alone.
s3api s3 cp "$repo_root/targets.json" "s3://$R2_BUCKET/apt/pool/retired-1/keep.deb" > /dev/null
s3api s3 cp "$repo_root/targets.json" "s3://$R2_BUCKET/rpm/retired-1/x86_64/repodata/repomd.xml" > /dev/null
publish 6
# The listing is taken whole before it is searched: a search that stops at
# its first match would otherwise end the listing early, and fail it.
now="$(listing)"
grep -qx "apt/pool/retired-1/keep.deb" <<< "$now" || fail "a publish deleted the pool of a retired target"
grep -qx "rpm/retired-1/x86_64/repodata/repomd.xml" <<< "$now" || fail "a publish deleted the repository of a retired target"
echo "-- a republish changes nothing, a retired target is left alone"

# --- the registry, run by run -------------------------------------------------

index_before="$(bucket_index)"
plugins_before="$(listing | grep '^plugins/')"
unchanged() {
  [ "$(bucket_index)" = "$index_before" ] || fail "$1: the index in the bucket changed"
  [ "$(listing | grep '^plugins/')" = "$plugins_before" ] || fail "$1: the plugin files in the bucket changed"
}

# The same release once more: nothing is uploaded but the index, which
# differs in `generated` alone.
sleep 1
plugins "$work/run-again/plugins" 1.3.0
registry_ok again release trebuchet-fixture 1.3.0 "$(release_url 1.3.0)" "$work/run-again/plugins"
[ -z "$(find "$work/run-again/site/plugins" -type f 2> /dev/null)" ] || fail "the same release again staged plugin files"
[ "$(header "$old_plugin" LastModified)" = "$plugin_modified" ] || fail "the same release again uploaded a plugin file"
[ "$(bucket_index | jq -S 'del(.generated)')" = "$(jq -S 'del(.generated)' <<< "$index_before")" ] \
  || fail "the same release again changed more than generated"
index_before="$(bucket_index)"

# A release with a file that is not what its manifest says: the run stops
# before the bucket is touched.
plugins "$work/run-wrong/plugins" 1.4.0
echo "tampered" >> "$work/run-wrong/plugins/beta-1.4.0-linux-x64.plugin"
if registry_run wrong release trebuchet-fixture 1.4.0 "$(release_url 1.4.0)" "$work/run-wrong/plugins"; then
  fail "a release with a wrong plugin file was published"
fi
grep -qF "beta-1.4.0-linux-x64.plugin has" "$work/run-wrong/build.log" || fail "no reason for the refusal: $(cat "$work/run-wrong/build.log")"
unchanged "a wrong plugin file"

# The secrets of another key than the published one: nothing is signed, and
# the bucket is as it was.
plugins "$work/run-key/plugins" 1.4.0
if REGISTRY_SIGNING_KEY="$(cat "$work/registry-other.key")" REGISTRY_SIGNING_PASSWORD="" \
  registry_run key release trebuchet-fixture 1.4.0 "$(release_url 1.4.0)" "$work/run-key/plugins"; then
  fail "an index signed with another key was published"
fi
grep -qF "the secret is not the published key" "$work/run-key/build.log" || fail "no reason for the refusal: $(cat "$work/run-key/build.log")"
unchanged "a key that is not the published one"

# An index in the bucket that this publisher did not sign: nothing is built
# on it, whatever the release.
bucket_index | sed 's/"The alpha plugin"/"The alpha plugiN"/' > "$work/tampered-index.json"
s3api s3 cp "$work/tampered-index.json" "s3://$R2_BUCKET/registry/index.json" > /dev/null
plugins "$work/run-tampered/plugins" 1.4.0
if registry_run tampered release trebuchet-fixture 1.4.0 "$(release_url 1.4.0)" "$work/run-tampered/plugins"; then
  fail "a release was merged into an index that does not verify"
fi
grep -qF "is not signed with registry.pub" "$work/run-tampered/build.log" || fail "no reason for the refusal: $(cat "$work/run-tampered/build.log")"
cmp -s "$work/tampered-index.json" <(bucket_index) || fail "the publisher wrote over an index it refused"
printf '%s\n' "$index_before" > "$work/good-index.json"
s3api s3 cp "$work/good-index.json" "s3://$R2_BUCKET/registry/index.json" > /dev/null
# An index without its signature is the same case.
s3api s3 rm "s3://$R2_BUCKET/registry/index.json.minisig" > /dev/null
if registry_run unsigned release trebuchet-fixture 1.4.0 "$(release_url 1.4.0)" "$work/run-tampered/plugins"; then
  fail "a release was merged into an index without a signature"
fi
s3api s3 cp "$work/run-again/site/registry/index.json.minisig" "s3://$R2_BUCKET/registry/index.json.minisig" > /dev/null
unchanged "an index that does not verify"

# A bucket that does not answer is not a registry that has not started.
if R2_ENDPOINT="http://127.0.0.1:1" "$scripts/bucket.sh" pull-registry "$work/run-down/site" > "$work/run-down.log" 2>&1; then
  fail "pull-registry took a bucket that does not answer for an empty one"
fi
grep -qF "did not say whether it holds" "$work/run-down.log" || fail "unexpected reason: $(cat "$work/run-down.log")"

# An app without plugins: its release writes latest and uploads no file.
mkdir -p "$work/run-plain/plugins"
registry_ok plain release trebuchet-plain 0.3.1 https://github.com/Open-Breach/trebuchet-plain/releases/tag/v0.3.1 "$work/run-plain/plugins"
[ "$(bucket_index | jq -c '.apps["trebuchet-plain"]')" = '{"latest":{"version":"0.3.1","url":"https://github.com/Open-Breach/trebuchet-plain/releases/tag/v0.3.1"}}' ] \
  || fail "an app without plugins has more than latest: $(bucket_index | jq -c '.apps["trebuchet-plain"]')"
[ "$(listing | grep '^plugins/')" = "$plugins_before" ] || fail "a release without plugins changed the plugin files"

# A release that was yanked: a manual run takes it out, and its files with it.
registry_ok remove remove trebuchet-fixture 1.2.0
[ "$(bucket_index | jq -r '[.apps["trebuchet-fixture"].plugins[].builds[].app_version] | unique | join(" ")')" = "1.0.0 1.1.0 1.3.0" ] \
  || fail "the removed release is still in the index, or another one left with it"
[ "$(sort "$work/run-remove/registry-removed")" = "$(grep '^plugins/trebuchet-fixture/1\.2\.0/' <<< "$plugins_before")" ] \
  || fail "unexpected files to delete: $(cat "$work/run-remove/registry-removed")"
now="$(listing)"
! grep -q '^plugins/trebuchet-fixture/1\.2\.0/' <<< "$now" || fail "the removed release's files are still in the bucket"
[ "$(grep '^plugins/' <<< "$now")" = "$(grep -v '^plugins/trebuchet-fixture/1\.2\.0/' <<< "$plugins_before")" ] \
  || fail "the removal took more than the release's files"
[ "$(bucket_index | jq -r '.apps["trebuchet-fixture"].latest.version')" = "1.3.0" ] || fail "the removal changed latest"
# What it would not delete: a path that is no plugin file of the registry.
for path in "apt/pool/debian-12/x.deb" "plugins/../install.sh" "plugins/a/b" "registry/index.json" "plugins/a/1.0.0/sub/x"; do
  echo "$path" > "$work/bad-removed"
  assert_fails "$scripts/bucket.sh" push-registry "$work/run-remove/site" "$work/bad-removed"
done
now="$(listing)"
grep -qx "install.sh" <<< "$now" || fail "push-registry deleted outside the registry"
echo "-- the registry: repeated, refused, an app without plugins, a release removed"

# --- fetching a release's plugins -----------------------------------------------------

# fetch-plugins.sh asks GitHub through gh. Here a stand-in answers from a
# folder: the names of a release's files, and the files a pattern matches.
mkdir -p "$work/bin" "$work/release"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = release ] || exit 64
action="$2"
shift 3
dir="" patterns=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2" && shift ;;
    --pattern) patterns+=("$2") && shift ;;
    --repo | --json | --jq) shift ;;
  esac
  shift
done
case "$action" in
  view) ls "$FAKE_RELEASE" ;;
  download)
    found=""
    for file in "$FAKE_RELEASE"/*; do
      for pattern in "${patterns[@]}"; do
        # shellcheck disable=SC2053  # a pattern, as gh takes it
        if [[ "$(basename "$file")" == $pattern ]]; then
          cp "$file" "$dir/"
          found=1
        fi
      done
    done
    [ -n "$found" ] || { echo "no assets match the file pattern" >&2; exit 1; }
    ;;
  *) exit 64 ;;
esac
GH
chmod +x "$work/bin/gh"
fetch_plugins() {
  PATH="$work/bin:$PATH" FAKE_RELEASE="$work/release" GH_TOKEN=none \
    PUBLISH_REPOSITORY=Open-Breach/trebuchet-fixture PUBLISH_TAG=v1.5.0 "$scripts/fetch-plugins.sh" "$1"
}
# A release with packages, an archive and no manifest: no plugins.
"$repo_root/tests/fixture/build.sh" "$work/release" 1.5.0 > /dev/null
echo "an archive" > "$work/release/trebuchet-fixture-1.5.0-linux-x64.tar.gz"
fetch_plugins "$work/fetched-none" > /dev/null
[ -z "$(ls -A "$work/fetched-none")" ] || fail "fetch-plugins.sh fetched something from a release without manifests"
# With manifests: they and the files they name, and nothing else.
plugins "$work/release" 1.5.0
echo '{}' > "$work/release/plugins.json"
fetch_plugins "$work/fetched" > /dev/null
[ "$(find "$work/fetched" -type f -printf '%f\n' | sort)" = "$(find "$work/release" -type f \( -name 'plugins-*.json' -o -name '*.plugin' \) -printf '%f\n' | sort)" ] \
  || fail "fetch-plugins.sh fetched: $(find "$work/fetched" -type f -printf '%f ')"
# What it fetched is a release the registry takes.
registry_ok fetched release trebuchet-fixture 1.5.0 "$(release_url 1.5.0)" "$work/fetched"
[ "$(bucket_index | jq -r '.apps["trebuchet-fixture"].latest.version')" = "1.5.0" ] || fail "the fetched release is not in the index"
# A manifest that names a file the release does not have, or no file name.
rm "$work/release/beta-1.5.0-linux-x64.plugin"
assert_fails fetch_plugins "$work/fetched-missing"
plugins "$work/release" 1.5.0
jq '.plugins[0].file = "../../etc/passwd"' "$work/release/plugins-linux-x64.json" > "$work/manifest.new"
mv "$work/manifest.new" "$work/release/plugins-linux-x64.json"
assert_fails fetch_plugins "$work/fetched-path"
echo "-- fetch-plugins.sh takes the manifests and the files they name"

# fetch.sh, through the same stand-in: the app's packages of the version,
# and with plugins switched on its plugin packages and the meta package
# too. Never another app's package, and never another version.
"$repo_root/tests/fixture/build.sh" "$work/release" 1.5.0 trebuchet-fixture-plugin-alpha > /dev/null
"$repo_root/tests/fixture/build.sh" "$work/release" 1.5.0 trebuchet-fixture-plugins > /dev/null
"$repo_root/tests/fixture/build.sh" "$work/release" 1.4.0 trebuchet-fixture-plugin-alpha > /dev/null
"$repo_root/tests/fixture/build.sh" "$work/release" 1.5.0 another-fixture > /dev/null
fetch_packages() {
  PATH="$work/bin:$PATH" FAKE_RELEASE="$work/release" GH_TOKEN=none PUBLISH_REPOSITORY=Open-Breach/trebuchet-fixture \
    PUBLISH_TAG=v1.5.0 PUBLISH_APP=trebuchet-fixture PUBLISH_PACKAGE_VERSION=1.5.0 PUBLISH_PLUGINS="$2" "$scripts/fetch.sh" "$1"
}
per_package="$(jq '(.targets | length) * (.arches | length)' "$targets")"
fetch_packages "$work/fetched-packages" false > /dev/null
[ "$(find "$work/fetched-packages" -type f | wc -l)" -eq "$per_package" ] || fail "fetch.sh without plugins fetched: $(ls "$work/fetched-packages")"
[ -z "$(find "$work/fetched-packages" -name '*plugin*')" ] || fail "fetch.sh fetched plugin packages while plugins are switched off"
out="$(fetch_packages "$work/fetched-all" true)"
grep -qx "$per_package package(s) of trebuchet-fixture 1.5.0, $((per_package * 2)) plugin package(s)" <<< "$out" || fail "fetch.sh with plugins: $(tail -n 1 <<< "$out")"
[ -z "$(find "$work/fetched-all" -name '*1.4.0*' -o -name 'another-*')" ] || fail "fetch.sh fetched another version or another app"
# What it fetched goes into the pool like any package.
"$repo_root/apt/add-packages.sh" "$work/fetched-pool/apt" "$work/fetched-all"/*.deb > /dev/null
"$repo_root/rpm/add-packages.sh" "$work/fetched-pool/rpm" "$work/fetched-all"/*.rpm > /dev/null
# A file that holds another package than its name says.
suite="$(targets_of deb | head -n 1)"
cp "$work/release/another-fixture_1.5.0_${suite}_amd64.deb" "$work/release/trebuchet-fixture-plugin-bad_1.5.0_${suite}_amd64.deb"
assert_fails fetch_packages "$work/fetched-bad" true
rm "$work/release/trebuchet-fixture-plugin-bad_1.5.0_${suite}_amd64.deb"
cp "$work/release/trebuchet-fixture-plugin-alpha_1.4.0_${suite}_amd64.deb" "$work/release/trebuchet-fixture-plugin-old_1.5.0_${suite}_amd64.deb"
assert_fails fetch_packages "$work/fetched-old" true
echo "-- fetch.sh takes the app's packages, and its plugin packages where plugins are switched on"

# What is in the bucket is a site the installer works against: downloaded
# as it is and served over HTTP, as the bucket's domain serves it.
s3api s3 sync "s3://$R2_BUCKET" "$work/served" --no-progress > /dev/null
python3 -m http.server "$web_port" --bind 127.0.0.1 --directory "$work/served" > "$work/web.log" 2>&1 &
web="$!"
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "$url/install.sh" 2> /dev/null; then break; fi
  sleep 0.1
done

# --- the registry, read as an app reads it --------------------------------------------

check="$repo_root/registry/check.sh"
out="$("$check" "$url")" || fail "the registry the bucket serves does not check out"
grep -qF "12 file(s) downloaded, each with the size and the SHA-256 the index names" <<< "$out" || fail "unexpected result of the check: $out"
grep -qF "trebuchet-plain: latest 0.3.1, 0 build(s)" <<< "$out" || fail "the app without plugins is not in the check: $out"
TREBUCHET_REGISTRY_FRESH=1 "$check" "$url" trebuchet-fixture 1.5.0 | grep -qF "3 file(s) downloaded" || fail "the check of one release"
# The first release, four releases later: its plugins are still served, as
# the index says they are.
"$check" "$url" trebuchet-fixture 1.0.0 | grep -qF "3 file(s) downloaded" || fail "the first release's plugins are no longer served"
"$check" --index "$url" > /dev/null || fail "the check of the index alone"
# By hand, as docs/registry.md says.
minisign -Vm "$work/served/registry/index.json" -p "$work/registry.pub" > /dev/null || fail "minisign -Vm does not verify the served index"

# A list that was tampered with is refused: one byte of it changed, the
# signature of another key beside it, or no signature at all.
refused_by_reader() {
  local expected="$1" out
  if out="$("$check" "$url" 2>&1)"; then
    fail "the reader took $2"
  fi
  grep -qF "$expected" <<< "$out" || fail "$2: expected '$expected' in: $out"
}
cp "$work/served/registry/index.json" "$work/served-index.json"
cp "$work/served/registry/index.json.minisig" "$work/served-index.json.minisig"
sed 's/"The alpha plugin"/"The alpha plugiN"/' "$work/served-index.json" > "$work/served/registry/index.json"
refused_by_reader "does not verify against registry.pub" "an index with one byte changed"
# A url that points elsewhere, in an index nobody signed again.
jq '.apps["trebuchet-fixture"].plugins[0].builds[0].url = "https://example.org/evil.plugin"' "$work/served-index.json" \
  > "$work/served/registry/index.json"
refused_by_reader "does not verify against registry.pub" "an index with another address in it"
cp "$work/served-index.json" "$work/served/registry/index.json"
REGISTRY_SIGNING_KEY="$(cat "$work/registry-other.key")" REGISTRY_SIGNING_PASSWORD="" \
  TREBUCHET_REGISTRY_PUBLIC_KEY="$work/registry-other.pub" "$repo_root/registry/sign.sh" "$work/served/registry/index.json" > /dev/null
refused_by_reader "does not verify against registry.pub" "an index signed with another key"
rm "$work/served/registry/index.json.minisig"
refused_by_reader "could not be fetched" "an index without a signature"
cp "$work/served-index.json.minisig" "$work/served/registry/index.json.minisig"
"$check" --index "$url" > /dev/null || fail "the restored index does not verify"
# A plugin file that is not the one the signed index describes.
echo "one more line" >> "$work/served/plugins/trebuchet-fixture/1.5.0/alpha-1.5.0-linux-x64.plugin"
refused_by_reader "1 of 12 file(s) are not what the index says" "a plugin file that was changed"
rm "$work/served/plugins/trebuchet-fixture/1.5.0/alpha-1.5.0-linux-x64.plugin"
refused_by_reader "does not download" "an index that names a missing file"
echo "-- the served registry verifies; a tampered list and a changed file are refused"
for target in $(jq -r '.targets[].id' "$targets"); do
  image="$(image_of "$target")"
  echo "-- $target: the one-liner against what the bucket holds, in $image"
  docker_run --network host -v "$repo_root/tests/client:/client:ro" "$image" \
    sh /client/install.sh "$url" trebuchet-fixture 1.3.0 > "$work/client.log" 2>&1 \
    || { cat "$work/client.log"; fail "$target: install.sh against the bucket's content"; }
  tail -n 1 "$work/client.log"
done

echo "publisher: ok"
