#!/usr/bin/env bash
# Dry run of the index scripts against the fixture package: build it for every
# target and architecture, add it to an empty pool, rebuild the apt and dnf
# indexes and check what they list. Nothing is signed and nothing leaves the
# machine.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$repo_root/tests/fixture/build.sh" "$work/packages" 1.0.0

# A file for a distro that targets.json does not list is refused, and so is a
# file whose name lies about its architecture.
first_deb="$(find "$work/packages" -name '*.deb' | sort | head -n 1)"
first_rpm="$(find "$work/packages" -name '*.rpm' | sort | head -n 1)"
mkdir "$work/bad"
cp "$first_deb" "$work/bad/trebuchet-fixture_1.0.0_nodistro-1_amd64.deb"
cp "$first_rpm" "$work/bad/trebuchet-fixture-1.0.0-1.nodistro-1.x86_64.rpm"
cp "$first_deb" "$work/bad/$(basename "${first_deb%_*.deb}")_riscv64.deb"
assert_fails "$repo_root/apt/add-packages.sh" "$work/none/apt" "$work/bad/trebuchet-fixture_1.0.0_nodistro-1_amd64.deb"
assert_fails "$repo_root/rpm/add-packages.sh" "$work/none/rpm" "$work/bad/trebuchet-fixture-1.0.0-1.nodistro-1.x86_64.rpm"
assert_fails "$repo_root/apt/add-packages.sh" "$work/none/apt" "$work/bad/$(basename "${first_deb%_*.deb}")_riscv64.deb"
assert_no_file "$work/none"

# An empty pool gives empty but complete indexes.
"$repo_root/apt/build-index.sh" "$work/empty/apt"
"$repo_root/rpm/build-index.sh" "$work/empty/rpm"
for suite in $(targets_of deb); do
  assert_file "$work/empty/apt/dists/$suite/Release"
  for arch in $(arches_of deb); do
    assert_file "$work/empty/apt/dists/$suite/main/binary-$arch/Packages"
    [ ! -s "$work/empty/apt/dists/$suite/main/binary-$arch/Packages" ] || fail "$suite/$arch: packages in an empty pool"
  done
done
for repo in $(targets_of rpm); do
  for arch in $(arches_of rpm); do
    assert_file "$work/empty/rpm/$repo/$arch/repodata/repomd.xml"
    repodata "$work/empty/rpm/$repo/$arch" primary | grep -q 'packages="0"' || fail "$repo/$arch: packages in an empty repository"
  done
done

# The fixture, added and indexed.
"$repo_root/apt/add-packages.sh" "$work/repo/apt" "$work/packages"/*.deb
"$repo_root/rpm/add-packages.sh" "$work/repo/rpm" "$work/packages"/*.rpm
"$repo_root/apt/build-index.sh" "$work/repo/apt"
"$repo_root/rpm/build-index.sh" "$work/repo/rpm"

for suite in $(targets_of deb); do
  dists="$work/repo/apt/dists/$suite"
  assert_contains "$dists/Release" "Suite: $suite"
  assert_contains "$dists/Release" "Codename: $suite"
  assert_contains "$dists/Release" "Components: main"
  assert_contains "$dists/Release" "Architectures: $(arches_of deb | paste -sd ' ')"
  assert_no_file "$dists/InRelease"
  assert_no_file "$dists/Release.gpg"
  for arch in $(arches_of deb); do
    packages="$dists/main/binary-$arch/Packages"
    [ "$(grep -c '^Package: ' "$packages")" = 1 ] || fail "$suite/$arch: expected exactly one package"
    assert_contains "$packages" "Package: trebuchet-fixture"
    assert_contains "$packages" "Version: 1.0.0"
    assert_contains "$packages" "Architecture: $arch"
    # The path apt will ask the server for exists, relative to the apt root.
    filename="$(sed -n 's/^Filename: //p' "$packages")"
    [ "$filename" = "pool/$suite/trebuchet-fixture_1.0.0_${suite}_${arch}.deb" ] || fail "$suite/$arch: unexpected Filename $filename"
    assert_file "$work/repo/apt/$filename"
    # The Release file vouches for both forms of the index.
    for index in Packages Packages.gz; do
      sum="$(sha256sum "$dists/main/binary-$arch/$index" | cut -d ' ' -f 1)"
      grep -q "^ $sum .* main/binary-$arch/$index\$" "$dists/Release" || fail "$suite: Release does not list $arch/$index with its SHA-256"
    done
    gzip -dc "$packages.gz" | cmp -s - "$packages" || fail "$suite/$arch: Packages.gz is not Packages"
  done
done

for repo in $(targets_of rpm); do
  for arch in $(arches_of rpm); do
    dir="$work/repo/rpm/$repo/$arch"
    assert_file "$dir/repodata/repomd.xml"
    assert_no_file "$dir/repodata/repomd.xml.asc"
    primary="$(repodata "$dir" primary)"
    grep -q 'packages="1"' <<< "$primary" || fail "$repo/$arch: expected exactly one package"
    grep -q '<name>trebuchet-fixture</name>' <<< "$primary" || fail "$repo/$arch: the fixture is not in the metadata"
    grep -q "<arch>$arch</arch>" <<< "$primary" || fail "$repo/$arch: wrong architecture in the metadata"
    grep -q 'ver="1.0.0" rel="1"' <<< "$primary" || fail "$repo/$arch: wrong version in the metadata"
    href="$(sed -n 's/.*<location href="\([^"]*\)".*/\1/p' <<< "$primary")"
    [ "$href" = "trebuchet-fixture-1.0.0-1.$repo.$arch.rpm" ] || fail "$repo/$arch: unexpected location $href"
    assert_file "$dir/$href"
  done
done

# A second run over the same pool replaces the indexes and nothing else.
before="$(cd "$work/repo" && find apt/pool rpm -name '*.deb' -o -name '*.rpm' | sort)"
"$repo_root/apt/build-index.sh" "$work/repo/apt" > /dev/null
"$repo_root/rpm/build-index.sh" "$work/repo/rpm" > /dev/null
after="$(cd "$work/repo" && find apt/pool rpm -name '*.deb' -o -name '*.rpm' | sort)"
[ "$before" = "$after" ] || fail "rebuilding the indexes changed the pool"
for repo in $(targets_of rpm); do
  for arch in $(arches_of rpm); do
    [ "$(find "$work/repo/rpm/$repo/$arch/repodata" -name '*-primary.xml.*' | wc -l)" = 1 ] || fail "$repo/$arch: stale metadata left behind"
  done
done

echo "index dry run: ok"
