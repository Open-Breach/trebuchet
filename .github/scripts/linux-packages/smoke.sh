#!/usr/bin/env bash
# The smoke test of docs/spec.md 4.2, in a fresh container of the target's
# image: install the package with the distro's package manager, run the
# binary with --version, validate the desktop entry. Where the target also
# built the tarball, unpack it and do the same with what is inside. Where
# the call names a smoke command, the app's own checks run as well: after
# the package is installed, and once more for the unpacked tarball.
#
#   smoke.sh DIR    the directory with the package, and maybe the tarball
#
#   TREBUCHET_APP, TREBUCHET_BINARY, TREBUCHET_PACKAGE_VERSION
#   TREBUCHET_FORMAT               deb or rpm
#   TREBUCHET_DESKTOP_FILE         the call's desktop-file input, or empty
#   TREBUCHET_SMOKE_COMMAND        the call's smoke-command input, or empty
#   TREBUCHET_WORKING_DIRECTORY    the call's working-directory input: where
#                                  the smoke command runs, in the checkout
#                                  of the app this script is started from
#
# The smoke command is told what it is testing:
#
#   TREBUCHET_SMOKE        package: the package is installed and the binary
#                          is on the PATH. tarball: the tarball is unpacked.
#   TREBUCHET_SMOKE_DIR    for the tarball, the unpacked folder with the
#                          binary at its top level; empty for the package
#   TREBUCHET_DIST         DIR, with every file the build job uploaded
#
# The app's checks run before anything but the package is installed: the
# validator of the desktop entry comes last, so that a library it brings
# cannot stand in for one the package forgot to ask for.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
binary="${TREBUCHET_BINARY:?}"
version="${TREBUCHET_PACKAGE_VERSION:?}"
format="${TREBUCHET_FORMAT:?}"
desktop="${TREBUCHET_DESKTOP_FILE:-}"
extra="${TREBUCHET_SMOKE_COMMAND:-}"
workdir="$PWD/${TREBUCHET_WORKING_DIRECTORY:-.}"
dir="$(cd "${1:?usage: smoke.sh DIR}" && pwd)"

if [ -n "$extra" ] && [ ! -d "$workdir" ]; then
  die "smoke-command: no $workdir: the app's repository is not checked out here"
fi

# The app's own checks, for the package or for the tarball.
smoke_command() {
  local what="$1" unpacked="$2"
  [ -n "$extra" ] || return 0
  echo "smoke command for the $what: $extra"
  (
    cd "$workdir"
    TREBUCHET_SMOKE="$what" TREBUCHET_SMOKE_DIR="$unpacked" TREBUCHET_DIST="$dir" \
      bash -euo pipefail -c "$extra"
  ) || die "the smoke command failed for the $what"
  echo "smoke command passed for the $what"
}

package="$(find "$dir" -maxdepth 1 -name "*.$format" | sort)"
if [ -z "$package" ] || [ "$(wc -l <<< "$package")" != 1 ]; then
  die "expected exactly one .$format in $dir"
fi
echo "smoke test of $(basename "$package")"

# Only what the package declares is installed with it: recommended packages
# are left out, so a missing dependency shows.
case "$format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$package"
    installed="$(dpkg-query --show --showformat '${Version}' "$app")"
    ;;
  rpm)
    dnf -y --setopt=install_weak_deps=False install "$package"
    installed="$(rpm --query --queryformat '%{VERSION}' "$app")"
    ;;
  *) die "unknown format $format" ;;
esac
[ "$installed" = "$version" ] || die "installed $app is version $installed, expected $version"

# From a directory that is not the package's, so that the PATH finds it.
cd /
command -v "$binary" > /dev/null || die "$binary is not on the PATH after installing $app"
echo "\$ $binary --version"
"$binary" --version

entry=""
if [ -n "$desktop" ]; then
  entry="/usr/share/applications/$(basename "$desktop")"
  [ -f "$entry" ] || die "the package does not install $entry"
fi

smoke_command package ""

tarball="$(find "$dir" -maxdepth 1 -name '*.tar.gz' | sort)"
tarball_entry=""
if [ -n "$tarball" ]; then
  [ "$(wc -l <<< "$tarball")" = 1 ] || die "more than one tarball in $dir"
  echo "smoke test of $(basename "$tarball")"
  name="$(basename "$tarball" .tar.gz)"
  unpacked="$(mktemp -d)"
  tar --extract --gzip --file "$tarball" --directory "$unpacked"
  [ "$(ls -A "$unpacked")" = "$name" ] || die "the tarball's one top-level folder is not $name"
  cd "$unpacked/$name"
  [ -x "./$binary" ] || die "no executable $binary at the top of the tarball"
  # The package installed above brought the libraries the binary needs.
  echo "\$ ./$binary --version"
  "./$binary" --version
  if [ -n "$desktop" ]; then
    tarball_entry="$unpacked/$name/share/applications/$(basename "$desktop")"
    [ -f "$tarball_entry" ] || die "the tarball has no share/applications/$(basename "$desktop")"
  fi
  smoke_command tarball "$unpacked/$name"
  find . -type f | sort | sed -n '1,40p'
  cd /
fi

if [ -n "$desktop" ]; then
  case "$format" in
    deb) apt-get install -y --no-install-recommends desktop-file-utils ;;
    rpm) dnf -y --setopt=install_weak_deps=False install desktop-file-utils ;;
  esac
  for file in "$entry" "$tarball_entry"; do
    [ -n "$file" ] || continue
    desktop-file-validate "$file"
    echo "desktop entry $file is valid"
  done
fi

echo "smoke test passed"
