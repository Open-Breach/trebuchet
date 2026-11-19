#!/usr/bin/env bash
# The publisher's steps, in the order publish.yml runs them, against an S3
# server on this machine: four releases of the fixture are published one
# after the other, each from an empty working directory that starts with
# what the bucket holds. Then the bucket is checked, and the one-line
# installer installs from it in a container of every target.
#
# The signing key is a throwaway generated here. It reaches the scripts the
# way the real one does: as an armoured export in GPG_PRIVATE_KEY, imported
# into an empty gpg home, with its passphrase in GPG_PASSPHRASE.
#
# Needs the AWS CLI, docker, the network, and moto's S3 server:
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
    PUBLISH_APP="$2" PUBLISH_VERSION="$3" PUBLISH_RELEASE_URL="$4" "$scripts/request.sh"
}
out="$(request repository_dispatch rick 1.2.3 https://github.com/Open-Breach/rick/releases/tag/v1.2.3)"
for line in mode=release app=rick package-version=1.2.3 repository=Open-Breach/rick tag=v1.2.3; do
  grep -qx "$line" <<< "$out" || fail "request.sh: no '$line' in: $out"
done
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

# publish N [VERSION]: one run of the publisher, from an empty directory.
publish() {
  local run="$work/run-$1" incoming=()
  mkdir -p "$run"
  if [ -n "${2:-}" ]; then
    "$repo_root/tests/fixture/build.sh" "$run/incoming" "$2" > /dev/null
    incoming=("$run/incoming")
  fi
  "$scripts/bucket.sh" pull "$run/site" > "$run/pull.log"
  "$scripts/build-site.sh" "$run/site" "$run/removed" "${incoming[@]}" > "$run/build.log"
  "$scripts/bucket.sh" push "$run/site" "$run/removed" > "$run/push.log"
}
listing() {
  s3api s3 ls "s3://$R2_BUCKET" --recursive | awk '{ print $4 }' | sort
}

publish 1 1.0.0
publish 2 1.1.0
old="apt/pool/$(targets_of deb | head -n 1)/trebuchet-fixture_1.1.0_$(targets_of deb | head -n 1)_amd64.deb"
modified="$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old" --query LastModified --output text)"
sleep 1
publish 3 1.2.0
[ ! -s "$work/run-3/removed" ] || fail "three versions and something was pruned"
publish 4 1.3.0
echo "-- four releases published"

# A package that was not touched is not uploaded again.
[ "$(s3api s3api head-object --bucket "$R2_BUCKET" --key "$old" --query LastModified --output text)" = "$modified" ] \
  || fail "$old was uploaded again by a later publish"

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
# Nothing but the site is in the bucket.
stray="$(grep -v -E '^(apt/|rpm/|keys/openbreach\.(gpg|asc)$|install\.sh$)' <<< "$files" || true)"
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
[ "$(header install.sh ContentType)" = "text/plain; charset=utf-8" ] || fail "install.sh is served as $(header install.sh ContentType)"
cmp -s "$repo_root/install.sh" <(s3api s3 cp "s3://$R2_BUCKET/install.sh" -) || fail "install.sh in the bucket is not the repository's"
for form in gpg asc; do
  cmp -s "$work/origin/public.$form" <(s3api s3 cp "s3://$R2_BUCKET/keys/openbreach.$form" -) || fail "keys/openbreach.$form in the bucket is not the published key"
done
echo "-- the bucket holds the last three versions, fresh indexes and nothing else"

# A key whose two files have drifted apart is not published.
mkdir "$work/drifted"
cp "$work/origin/public.gpg" "$work/drifted/public.gpg"
cp "$work/other/public.asc" "$work/drifted/public.asc"
assert_fails env TREBUCHET_PUBLIC_KEY="$work/drifted/public.gpg" "$scripts/build-site.sh" "$work/drifted/site" "$work/drifted/removed"

# A republish adds and removes nothing.
publish 5
[ ! -s "$work/run-5/removed" ] || fail "a republish pruned something"
[ "$(listing | grep -c -E '\.(deb|rpm)$')" = "$(grep -c -E '\.(deb|rpm)$' <<< "$files")" ] || fail "a republish changed the packages"

# The pool of a target that is no longer in targets.json is left alone.
s3api s3 cp "$repo_root/targets.json" "s3://$R2_BUCKET/apt/pool/retired-1/keep.deb" > /dev/null
s3api s3 cp "$repo_root/targets.json" "s3://$R2_BUCKET/rpm/retired-1/x86_64/repodata/repomd.xml" > /dev/null
publish 6
listing | grep -qx "apt/pool/retired-1/keep.deb" || fail "a publish deleted the pool of a retired target"
listing | grep -qx "rpm/retired-1/x86_64/repodata/repomd.xml" || fail "a publish deleted the repository of a retired target"
echo "-- a republish changes nothing, a retired target is left alone"

# What is in the bucket is a site the installer works against: downloaded
# as it is and served over HTTP, as the bucket's domain serves it.
s3api s3 sync "s3://$R2_BUCKET" "$work/served" --no-progress > /dev/null
web_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$web_port" --bind 127.0.0.1 --directory "$work/served" > "$work/web.log" 2>&1 &
web="$!"
url="http://127.0.0.1:$web_port"
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "$url/install.sh" 2> /dev/null; then break; fi
  sleep 0.1
done
for target in $(jq -r '.targets[].id' "$targets"); do
  image="$(image_of "$target")"
  echo "-- $target: the one-liner against what the bucket holds, in $image"
  docker_run --network host -v "$repo_root/tests/client:/client:ro" "$image" \
    sh /client/install.sh "$url" trebuchet-fixture 1.3.0 > "$work/client.log" 2>&1 \
    || { cat "$work/client.log"; fail "$target: install.sh against the bucket's content"; }
  tail -n 1 "$work/client.log"
done

echo "publisher: ok"
