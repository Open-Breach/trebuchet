#!/usr/bin/env bash
# An app's plugin packages (docs/spec.md 4.3), as linux-packages.yml makes
# them and as a user meets them: plugins.sh makes the packages of two
# plugins and the meta package for two versions of the fixture, for every
# target and architecture; they go into the repositories beside the app's
# own packages, the indexes are built and signed with a throwaway key, and
# then the real apt and dnf, each in a clean container of its target,
# install a plugin by its name.
#
# What that shows: a plugin brings the app in its own version, a plugin of
# another version than the app is refused by the package manager, an
# upgrade moves the two together, the meta package brings every plugin, and
# the pool and its pruning take a plugin package like any other.
#
# Needs docker, and nfpm: the one on the PATH, or the pinned release, which
# is then downloaded.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
require_docker
scripts="$repo_root/.github/scripts/linux-packages"

work="$(mktemp -d)"
cleanup() {
  stop_gpg_agent "$work/gnupg"
  rm -rf "$work"
}
trap cleanup EXIT
chmod 755 "$work"

if ! command -v nfpm > /dev/null; then
  "$scripts/nfpm.sh" "$work/bin" > /dev/null
  export PATH="$work/bin:$PATH"
fi

app="trebuchet-fixture"
plugins='[
  { "id": "alpha", "summary": "The first plugin of the fixture", "files": "alpha" },
  { "id": "beta", "summary": "The second plugin of the fixture", "files": "beta",
    "runtime-deps": { "debian": ["trebuchet-fixture (>= 1.0)"], "ubuntu": ["trebuchet-fixture (>= 1.0)"], "fedora": ["trebuchet-fixture >= 1.0"] } }
]'

# plugin_packages VERSION: the plugin packages of one release, for every
# target and architecture, into $work/packages. The folders plugins.sh
# packages are laid out here, as a build lays them out.
plugin_packages() {
  local version="$1" src="$work/build-$1" target format arch
  mkdir -p "$src/alpha/data" "$src/beta"
  echo "alpha of $app $version" > "$src/alpha/plugin.txt"
  echo "more" > "$src/alpha/data/more.txt"
  printf '#!/bin/sh\necho alpha\n' > "$src/alpha/run.sh"
  chmod 755 "$src/alpha/run.sh"
  echo "beta of $app $version" > "$src/beta/plugin.txt"
  while read -r target format; do
    for arch in $(arches_of "$format"); do
      (
        cd "$src"
        TREBUCHET_APP="$app" TREBUCHET_PACKAGE_VERSION="$version" TREBUCHET_TARGET="$target" \
          TREBUCHET_FORMAT="$format" TREBUCHET_PKGARCH="$arch" TREBUCHET_DIST="$work/packages" \
          TREBUCHET_PLUGINS="$plugins" TREBUCHET_PLUGINS_DIR="/usr/lib/$app/plugins" \
          TREBUCHET_MAINTAINER="Trebuchet tests <noreply@openbreach.dev>" TREBUCHET_LICENSE="Apache-2.0" \
          "$scripts/plugins.sh" > /dev/null
      )
    done
  done < <(jq -r '.targets[] | "\(.id) \(.format)"' "$targets")
}

# Four releases: with three kept, the first is pruned, plugins and all.
versions=(1.0.0 1.1.0 1.2.0 1.3.0)
for version in "${versions[@]}"; do
  "$repo_root/tests/fixture/build.sh" "$work/packages" "$version" > /dev/null
  plugin_packages "$version"
done

# What plugins.sh made, read back: the names the publisher goes by, the
# dependency on the app in exactly this version, the plugin's own
# dependency, and the files in the plugin's folder with their modes.
deb="$work/packages/${app}-plugin-alpha_1.3.0_$(targets_of deb | head -n 1)_amd64.deb"
rpm_target="$(targets_of rpm | head -n 1)"
rpm="$work/packages/${app}-plugin-beta-1.3.0-1.$rpm_target.x86_64.rpm"
assert_file "$deb"
assert_file "$rpm"
[ "$(dpkg-deb --field "$deb" Depends)" = "$app (= 1.3.0)" ] || fail "the deb depends on: $(dpkg-deb --field "$deb" Depends)"
[ "$(dpkg-deb --field "$deb" Description | sed -n 1p)" = "The first plugin of the fixture" ] || fail "the deb's summary is not the call's"
listing="$(dpkg-deb --contents "$deb")"
grep -qE "^-rwxr-xr-x root/root .* \./usr/lib/$app/plugins/alpha/run\.sh$" <<< "$listing" || fail "run.sh is not installed to be run: $listing"
grep -qE "^-rw-r--r-- root/root .* \./usr/lib/$app/plugins/alpha/data/more\.txt$" <<< "$listing" || fail "data/more.txt is not where it belongs: $listing"
requires="$(rpm --query --package --nosignature --requires "$rpm")"
grep -qx "$app = 1.3.0" <<< "$requires" || fail "the rpm does not require the app in exactly its version: $requires"
grep -qx "$app >= 1.0" <<< "$requires" || fail "the rpm does not carry the plugin's own dependency: $requires"
[ "$(rpm --query --package --nosignature --queryformat '%{SUMMARY}' "$rpm")" = "The second plugin of the fixture" ] || fail "the rpm's summary is not the call's"
# The rpm owns its folder, so that removing it leaves none behind.
rpm --query --package --nosignature --list "$rpm" | grep -qx "/usr/lib/$app/plugins/beta" || fail "the rpm does not own its folder"
meta="$work/packages/${app}-plugins_1.3.0_$(targets_of deb | head -n 1)_amd64.deb"
[ "$(dpkg-deb --field "$meta" Depends)" = "$app-plugin-alpha (= 1.3.0), $app-plugin-beta (= 1.3.0)" ] \
  || fail "the meta package depends on: $(dpkg-deb --field "$meta" Depends)"
[ -z "$(dpkg-deb --contents "$meta" | grep -v '/$' || true)" ] || fail "the meta package holds files"

# What stops plugins.sh: a folder the build did not lay out, an empty one,
# a symbolic link.
refused() {
  local expected="$1" list="$2" out
  if out="$(cd "$work/build-1.3.0" && TREBUCHET_APP="$app" TREBUCHET_PACKAGE_VERSION=9.9.9 TREBUCHET_TARGET=debian-12 \
    TREBUCHET_FORMAT=deb TREBUCHET_PKGARCH=amd64 TREBUCHET_DIST="$work/refused" TREBUCHET_PLUGINS="$list" \
    TREBUCHET_PLUGINS_DIR="/usr/lib/$app/plugins" TREBUCHET_MAINTAINER="x <x@example.org>" "$scripts/plugins.sh" 2>&1)"; then
    fail "expected to fail: $expected"
  fi
  grep -qF "$expected" <<< "$out" || fail "expected '$expected' in: $out"
}
refused "no folder gamma" '[{"id": "gamma", "summary": "x", "files": "gamma"}]'
mkdir "$work/build-1.3.0/empty"
refused "holds no file" '[{"id": "empty", "summary": "x", "files": "empty"}]'
mkdir "$work/build-1.3.0/linked"
ln -s ../alpha/plugin.txt "$work/build-1.3.0/linked/plugin.txt"
refused "holds a symbolic link" '[{"id": "linked", "summary": "x", "files": "linked"}]'
echo "-- plugins.sh makes the packages the call names, and refuses a folder that is none"

# --- into the repositories, as the publisher does it ---------------------------

make_test_key "$work/gnupg" ed25519
repo="$work/repo"
"$repo_root/apt/add-packages.sh" "$repo/apt" "$work/packages"/*.deb > /dev/null
"$repo_root/rpm/add-packages.sh" "$repo/rpm" "$work/packages"/*.rpm > /dev/null
"$repo_root/apt/prune.sh" "$repo/apt" > /dev/null
"$repo_root/rpm/prune.sh" "$repo/rpm" > /dev/null
# Every package of the first release is gone, the app's and the plugins',
# and every package of the other three is there.
for name in "$app" "$app-plugin-alpha" "$app-plugin-beta" "$app-plugins"; do
  for suite in $(targets_of deb); do
    for arch in $(arches_of deb); do
      assert_no_file "$repo/apt/pool/$suite/${name}_1.0.0_${suite}_${arch}.deb"
      for version in 1.1.0 1.2.0 1.3.0; do
        assert_file "$repo/apt/pool/$suite/${name}_${version}_${suite}_${arch}.deb"
      done
    done
  done
  for target in $(targets_of rpm); do
    for arch in $(arches_of rpm); do
      assert_no_file "$repo/rpm/$target/$arch/$name-1.0.0-1.$target.$arch.rpm"
      for version in 1.1.0 1.2.0 1.3.0; do
        assert_file "$repo/rpm/$target/$arch/$name-$version-1.$target.$arch.rpm"
      done
    done
  done
done
"$repo_root/apt/build-index.sh" "$repo/apt" > /dev/null
"$repo_root/rpm/build-index.sh" "$repo/rpm" > /dev/null
GNUPGHOME="$work/gnupg" "$repo_root/apt/sign.sh" "$repo/apt" "$work/gnupg/public.gpg" > /dev/null
GNUPGHOME="$work/gnupg" "$repo_root/rpm/sign.sh" "$repo/rpm" "$work/gnupg/public.gpg" > /dev/null
echo "-- the pool holds the app and its plugin packages of the last three releases"

# --- and out of them, as a user does it -------------------------------------------

chmod -R a+rX "$work"
chmod 700 "$work/gnupg"
mkdir "$work/keys"
cp "$work/gnupg/public.gpg" "$work/gnupg/public.asc" "$work/keys/"
chmod -R a+rX "$work/keys"

for suite in $(targets_of deb); do
  image="$(image_of "$suite")"
  echo "-- $suite: apt in $image"
  docker_run -v "$work:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
    sh /client/plugins.sh apt file:///t/repo/apt /t/keys/public.gpg "$suite" "$app" 1.3.0 1.2.0 > "$work/client.log" 2>&1 \
    || { cat "$work/client.log"; fail "$suite: the plugin packages with apt"; }
  tail -n 1 "$work/client.log"
done
for target in $(targets_of rpm); do
  image="$(image_of "$target")"
  echo "-- $target: dnf in $image"
  docker_run -v "$work:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
    sh /client/plugins.sh dnf file:///t/repo/rpm /t/keys/public.asc "$app" 1.3.0 1.2.0 > "$work/client.log" 2>&1 \
    || { cat "$work/client.log"; fail "$target: the plugin packages with dnf"; }
  tail -n 1 "$work/client.log"
done

echo "plugin packages: ok"
