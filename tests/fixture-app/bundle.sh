#!/usr/bin/env bash
# The fixture's build: the release binary, then the bundle the packages and
# the tarball are made from, with a data file beside the binary. Stands in
# for an app whose build is more than `cargo build --release`.
#
#   bundle.sh [file]
#
# A file named here is one an earlier job of the workflow made
# (`build-artifact`): the build fails without it, and it is bundled beside
# the binary's data.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

extra="${1:-}"
if [ -n "$extra" ] && [ ! -f "$extra" ]; then
  echo "bundle.sh: no $extra: the build artifact was not put there" >&2
  exit 1
fi

cargo build --release --locked
rm -rf target/release/bundle
mkdir -p target/release/bundle/data
cp target/release/trebuchet-fixture target/release/bundle/
echo "bundled for ${TREBUCHET_TARGET:-no target} ${TREBUCHET_ARCH:-}" > target/release/bundle/data/greeting.txt
if [ -n "$extra" ]; then cp "$extra" target/release/bundle/data/; fi

# The two folders the workflow hands a build's files on through. Both are
# there when the build command starts: nothing here makes them.
#
# A file of the build's own, for the folder the workflow uploads for the
# release: written in the one job per architecture whose build is also the
# tarball, as an app does with files that fit that build and no other.
# smoke.sh looks for it there, and for none of it in the other jobs.
#
# And a file for the smoke test only, in the other folder, from every job
# and under the same name in each: smoke.sh finds it in the test's folder,
# this job's own, and not among the files for the release.
if [ -n "${TREBUCHET_TARGET:-}" ]; then
  [ -d "${TREBUCHET_DIST:?}" ] || {
    echo "bundle.sh: no folder $TREBUCHET_DIST: the workflow did not make it" >&2
    exit 1
  }
  [ -d "${TREBUCHET_SMOKE_FILES:?}" ] || {
    echo "bundle.sh: no folder $TREBUCHET_SMOKE_FILES: the workflow did not make it" >&2
    exit 1
  }
  echo "for the smoke test of $TREBUCHET_TARGET $TREBUCHET_ARCH" > "$TREBUCHET_SMOKE_FILES/for-the-test.txt"
  case "${TREBUCHET_TARBALL:-}" in
    true)
      echo "from the build of $TREBUCHET_TARGET $TREBUCHET_ARCH" \
        > "$TREBUCHET_DIST/trebuchet-fixture-$TREBUCHET_VERSION-$TREBUCHET_ARCH.built-on.txt"
      ;;
    false) ;;
    *)
      echo "bundle.sh: TREBUCHET_TARBALL is '${TREBUCHET_TARBALL:-}', neither true nor false" >&2
      exit 1
      ;;
  esac
fi
