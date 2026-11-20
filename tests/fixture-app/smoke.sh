#!/usr/bin/env bash
# The fixture's own smoke test, the `smoke-command` of the call: what the
# workflow cannot know about an app. It runs in the fresh container, in this
# directory of a checkout, once after the package is installed, once more
# for the unpacked tarball, and a last time after the plugin packages are
# installed, and is told which.
#
#   TREBUCHET_SMOKE        package, tarball or plugins
#   TREBUCHET_SMOKE_DIR    the unpacked tarball; empty for the package
#   TREBUCHET_DIST         the files the build job uploaded for the release
#   TREBUCHET_SMOKE_FILES  the files the build job put aside for this test
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
files="${TREBUCHET_SMOKE_FILES:?}"
what="${TREBUCHET_SMOKE:-}"

# Started where the call's working-directory points, in the app's checkout.
if [ ! -f Cargo.toml ] || [ ! -f bundle.sh ]; then
  fail "not started in the fixture's directory, but in $PWD"
fi

case "$what" in
  package | plugins)
    [ -z "${TREBUCHET_SMOKE_DIR:-}" ] || fail "TREBUCHET_SMOKE_DIR is set for the $what"
    root=/usr/lib/trebuchet-fixture
    out="$(trebuchet-fixture --version)"
    ;;
  tarball)
    root="${TREBUCHET_SMOKE_DIR:?}"
    out="$("$root/trebuchet-fixture" --version)"
    ;;
  *) fail "TREBUCHET_SMOKE is '$what', neither package, tarball nor plugins" ;;
esac
echo "$out"

# The plugins are packages of their own. The main package and the tarball
# hold none of them; once their packages are installed, each is in its
# folder beside the binary, from this target's build, with its modes.
plugins="$root/plugins"
case "$what" in
  package | tarball)
    [ ! -e "$plugins" ] || fail "$plugins is there before any plugin package is installed"
    ;;
  plugins)
    grep -qx "hello for $target $arch" "$plugins/hello/plugin.txt" || fail "$plugins/hello/plugin.txt is not this target's"
    grep -qx "extra for $target $arch" "$plugins/extra/plugin.txt" || fail "$plugins/extra/plugin.txt is not this target's"
    [ -f "$plugins/hello/data/more.txt" ] || fail "no data/more.txt in the plugin's folder"
    [ "$("$plugins/hello/run.sh")" = "hello from the plugin" ] || fail "the plugin's program does not run"
    [ "$(stat -c %a "$plugins/hello/run.sh")" = 755 ] || fail "the plugin's program is installed with mode $(stat -c %a "$plugins/hello/run.sh")"
    [ "$(stat -c %a "$plugins/hello/plugin.txt")" = 644 ] || fail "a plugin's file is installed with mode $(stat -c %a "$plugins/hello/plugin.txt")"
    ;;
esac

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
  [ "$what" != tarball ] || fail "a tarball is tested where none was built"
fi

# The file the build put aside for this test: in the test's folder, this
# job's own although every job names it alike, and not among the files for
# the release. Nothing for the release is in the test's folder either.
aside="$files/for-the-test.txt"
[ -f "$aside" ] || fail "no for-the-test.txt in the folder for the smoke test, $files"
grep -qx "for the smoke test of $target $arch" "$aside" || fail "for-the-test.txt is not this build's"
[ -z "$(find "$dist" -name 'for-the-test.txt')" ] || fail "for-the-test.txt is among the files for the release"
[ "$(find "$files" -mindepth 1 | wc -l)" = 1 ] || fail "the folder for the smoke test holds more than the one file: $(ls -A "$files")"
echo "fixture smoke test passed for the $what"
