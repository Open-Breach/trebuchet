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

# A file of the build's own, for the folder the workflow uploads: written in
# the one job per architecture whose build is also the tarball, as an app
# does with files that fit that build and no other. smoke.sh looks for it
# there, and for none of it in the other jobs.
if [ -n "${TREBUCHET_TARGET:-}" ]; then
  case "${TREBUCHET_TARBALL:-}" in
    true)
      mkdir -p "${TREBUCHET_DIST:?}"
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
