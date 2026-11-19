#!/usr/bin/env bash
# The fixture's own smoke test, the `smoke-command` of the call: what the
# workflow cannot know about an app. It runs in the fresh container, in this
# directory of a checkout, once after the package is installed and once more
# for the unpacked tarball, and is told which.
#
#   TREBUCHET_SMOKE        package or tarball
#   TREBUCHET_SMOKE_DIR    the unpacked tarball; empty for the package
#   TREBUCHET_DIST         the files the build job uploaded
#   TREBUCHET_TARGET, TREBUCHET_ARCH, TREBUCHET_VERSION
set -euo pipefail

fail() {
  echo "smoke.sh: $*" >&2
  exit 1
}

target="${TREBUCHET_TARGET:?}"
arch="${TREBUCHET_ARCH:?}"
version="${TREBUCHET_VERSION:?}"
dist="${TREBUCHET_DIST:?}"
what="${TREBUCHET_SMOKE:-}"

# Started where the call's working-directory points, in the app's checkout.
if [ ! -f Cargo.toml ] || [ ! -f bundle.sh ]; then
  fail "not started in the fixture's directory, but in $PWD"
fi

case "$what" in
  package)
    [ -z "${TREBUCHET_SMOKE_DIR:-}" ] || fail "TREBUCHET_SMOKE_DIR is set for the package"
    root=/usr/lib/trebuchet-fixture
    out="$(trebuchet-fixture --version)"
    ;;
  tarball)
    root="${TREBUCHET_SMOKE_DIR:?}"
    out="$("$root/trebuchet-fixture" --version)"
    ;;
  *) fail "TREBUCHET_SMOKE is '$what', neither package nor tarball" ;;
esac
echo "$out"

# The bundle is whole, and it is the one this target's job built.
[ "$(sed -n 1p <<< "$out")" = "trebuchet-fixture $version" ] || fail "unexpected version line"
grep -qx "bundled for $target $arch" "$root/data/greeting.txt" \
  || fail "$root/data/greeting.txt is not this target's"
[ -f "$root/data/NOTICE.txt" ] || fail "no NOTICE.txt beside the data"

# The file the build adds to the uploaded folder where its build is also the
# tarball, and nowhere else.
added="$dist/trebuchet-fixture-$version-$arch.built-on.txt"
if [ -n "$(find "$dist" -maxdepth 1 -name '*.tar.gz')" ]; then
  [ -f "$added" ] || fail "no $(basename "$added") beside the tarball"
  grep -qx "from the build of $target $arch" "$added" || fail "$(basename "$added") is not this build's"
else
  [ ! -e "$added" ] || fail "$(basename "$added") from a build that made no tarball"
  [ "$what" = package ] || fail "a tarball is tested where none was built"
fi
echo "fixture smoke test passed for the $what"
