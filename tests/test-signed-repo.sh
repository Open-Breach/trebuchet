#!/usr/bin/env bash
# The repositories as the publisher makes them and as a user meets them:
# five versions of the fixture go into the pool, the old ones are pruned, the
# indexes are rebuilt and signed with a throwaway key generated here, and
# then the real apt and dnf, each in a container of its target, add the
# repository, verify it, install the newest version and downgrade.
#
# Twice: with an RSA key that has a passphrase, and with an Ed25519 key that
# has none. The keys live in a temporary directory that is deleted at the
# end; no key of this repository's is involved.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
require_docker

work="$(mktemp -d)"
cleanup() {
  for home in "$work"/*/gnupg "$work"/*/other-gnupg; do
    [ -d "$home" ] && stop_gpg_agent "$home"
  done
  rm -rf "$work"
}
trap cleanup EXIT
chmod 755 "$work"

# Oldest first. With three kept, the first two go.
versions=(1.0.0 1.1.0 1.2.0 1.3.0~rc1 1.3.0)
for version in "${versions[@]}"; do
  "$repo_root/tests/fixture/build.sh" "$work/packages" "$version" > /dev/null
done

run_case() {
  local type="$1" passphrase="$2" dir="$work/$1"
  local gnupg="$dir/gnupg" other="$dir/other-gnupg" repo="$dir/repo"
  echo "-- $type key, $([ -n "$passphrase" ] && echo "with" || echo "without") a passphrase"

  make_test_key "$gnupg" "$type" "$passphrase"
  # A second key, to show that a wrong key is refused everywhere.
  make_test_key "$other" ed25519

  "$repo_root/apt/add-packages.sh" "$repo/apt" "$work/packages"/*.deb > /dev/null
  "$repo_root/rpm/add-packages.sh" "$repo/rpm" "$work/packages"/*.rpm > /dev/null
  "$repo_root/apt/prune.sh" "$repo/apt"
  "$repo_root/rpm/prune.sh" "$repo/rpm"
  for suite in $(targets_of deb); do
    for arch in $(arches_of deb); do
      for version in 1.0.0 1.1.0; do
        assert_no_file "$repo/apt/pool/$suite/trebuchet-fixture_${version}_${suite}_${arch}.deb"
      done
      for version in 1.2.0 1.3.0~rc1 1.3.0; do
        assert_file "$repo/apt/pool/$suite/trebuchet-fixture_${version}_${suite}_${arch}.deb"
      done
    done
  done
  for target in $(targets_of rpm); do
    for arch in $(arches_of rpm); do
      for version in 1.0.0 1.1.0; do
        assert_no_file "$repo/rpm/$target/$arch/trebuchet-fixture-$version-1.$target.$arch.rpm"
      done
      for version in 1.2.0 1.3.0~rc1 1.3.0; do
        assert_file "$repo/rpm/$target/$arch/trebuchet-fixture-$version-1.$target.$arch.rpm"
      done
    done
  done
  # A second prune finds nothing to do.
  [ -z "$("$repo_root/apt/prune.sh" "$repo/apt")" ] || fail "apt/prune.sh pruned twice"
  [ -z "$("$repo_root/rpm/prune.sh" "$repo/rpm")" ] || fail "rpm/prune.sh pruned twice"

  "$repo_root/apt/build-index.sh" "$repo/apt" > /dev/null
  "$repo_root/rpm/build-index.sh" "$repo/rpm" > /dev/null

  # Signing with a key other than the published one is caught at once.
  assert_fails env GNUPGHOME="$gnupg" GPG_PASSPHRASE="$passphrase" \
    "$repo_root/apt/sign.sh" "$repo/apt" "$other/public.gpg"
  assert_fails env GNUPGHOME="$gnupg" GPG_PASSPHRASE="$passphrase" \
    "$repo_root/rpm/sign.sh" "$repo/rpm" "$other/public.gpg"
  # And so is a missing passphrase. The agent is stopped first: it remembers
  # the passphrase from the attempt above.
  if [ -n "$passphrase" ]; then
    stop_gpg_agent "$gnupg"
    assert_fails env GNUPGHOME="$gnupg" GPG_PASSPHRASE="" \
      "$repo_root/apt/sign.sh" "$repo/apt" "$gnupg/public.gpg"
    assert_fails env GNUPGHOME="$gnupg" GPG_PASSPHRASE="not the passphrase" \
      "$repo_root/rpm/sign.sh" "$repo/rpm" "$gnupg/public.gpg"
  fi

  GNUPGHOME="$gnupg" GPG_PASSPHRASE="$passphrase" "$repo_root/apt/sign.sh" "$repo/apt" "$gnupg/public.gpg"
  GNUPGHOME="$gnupg" GPG_PASSPHRASE="$passphrase" "$repo_root/rpm/sign.sh" "$repo/rpm" "$gnupg/public.gpg"
  for suite in $(targets_of deb); do
    assert_file "$repo/apt/dists/$suite/InRelease"
    assert_file "$repo/apt/dists/$suite/Release.gpg"
    assert_contains "$repo/apt/dists/$suite/InRelease" "-----BEGIN PGP SIGNED MESSAGE-----"
    for arch in $(arches_of deb); do
      [ "$(grep -c '^Package: ' "$repo/apt/dists/$suite/main/binary-$arch/Packages")" = 3 ] || fail "$suite/$arch: expected three versions in the index"
    done
  done
  for target in $(targets_of rpm); do
    for arch in $(arches_of rpm); do
      assert_file "$repo/rpm/$target/$arch/repodata/repomd.xml.asc"
      repodata "$repo/rpm/$target/$arch" primary | grep -q 'packages="3"' || fail "$target/$arch: expected three versions in the metadata"
    done
  done
  # Rebuilding the index drops the signatures with it, so that an unsigned
  # index is never left beside an old signature.
  cp -R "$repo" "$dir/rebuilt"
  "$repo_root/apt/build-index.sh" "$dir/rebuilt/apt" > /dev/null
  "$repo_root/rpm/build-index.sh" "$dir/rebuilt/rpm" > /dev/null
  [ -z "$(find "$dir/rebuilt" -name InRelease -o -name Release.gpg -o -name repomd.xml.asc)" ] || fail "signatures survived a rebuild of the index"

  # Readable by the unprivileged user apt downloads as.
  chmod -R a+rX "$dir"
  chmod 700 "$gnupg" "$other"

  for suite in $(targets_of deb); do
    image="$(image_of "$suite")"
    echo "-- $suite: apt in $image"
    docker run --rm -v "$dir:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
      sh /client/apt.sh reject file:///t/repo/apt /t/other-gnupg/public.gpg "$suite" > "$dir/client.log" 2>&1 \
      || { cat "$dir/client.log"; fail "$suite: apt with the wrong key"; }
    tail -n 1 "$dir/client.log"
    docker run --rm -v "$dir:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
      sh /client/apt.sh accept file:///t/repo/apt /t/gnupg/public.gpg "$suite" trebuchet-fixture 1.3.0 1.2.0 > "$dir/client.log" 2>&1 \
      || { cat "$dir/client.log"; fail "$suite: apt with the published key"; }
    tail -n 1 "$dir/client.log"
  done
  for target in $(targets_of rpm); do
    image="$(image_of "$target")"
    echo "-- $target: dnf in $image"
    docker run --rm -v "$dir:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
      sh /client/dnf.sh reject file:///t/repo/rpm /t/other-gnupg/public.asc trebuchet-fixture > "$dir/client.log" 2>&1 \
      || { cat "$dir/client.log"; fail "$target: dnf with the wrong key"; }
    tail -n 1 "$dir/client.log"
    docker run --rm -v "$dir:/t:ro" -v "$repo_root/tests/client:/client:ro" "$image" \
      sh /client/dnf.sh accept file:///t/repo/rpm /t/gnupg/public.asc trebuchet-fixture 1.3.0 1.2.0 > "$dir/client.log" 2>&1 \
      || { cat "$dir/client.log"; fail "$target: dnf with the published key"; }
    tail -n 1 "$dir/client.log"
  done
}

run_case rsa "correct horse battery staple"
run_case ed25519 ""

echo "signed repositories: ok"
