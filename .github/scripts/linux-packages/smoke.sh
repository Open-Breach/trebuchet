#!/usr/bin/env bash
# The smoke test of docs/spec.md 4.2, in a fresh container of the target's
# image: install the package with the distro's package manager, run the
# binary with --version, validate the desktop entry. Where the target also
# built the tarball, unpack it and do the same with what is inside.
#
#   smoke.sh DIR    the directory with the package, and maybe the tarball
#
#   TREBUCHET_APP, TREBUCHET_BINARY, TREBUCHET_PACKAGE_VERSION
#   TREBUCHET_FORMAT          deb or rpm
#   TREBUCHET_DESKTOP_FILE    the call's desktop-file input, or empty
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
binary="${TREBUCHET_BINARY:?}"
version="${TREBUCHET_PACKAGE_VERSION:?}"
format="${TREBUCHET_FORMAT:?}"
desktop="${TREBUCHET_DESKTOP_FILE:-}"
dir="$(cd "${1:?usage: smoke.sh DIR}" && pwd)"

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
    [ -z "$desktop" ] || apt-get install -y --no-install-recommends desktop-file-utils
    installed="$(dpkg-query --show --showformat '${Version}' "$app")"
    ;;
  rpm)
    dnf -y --setopt=install_weak_deps=False install "$package"
    [ -z "$desktop" ] || dnf -y --setopt=install_weak_deps=False install desktop-file-utils
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

if [ -n "$desktop" ]; then
  entry="/usr/share/applications/$(basename "$desktop")"
  [ -f "$entry" ] || die "the package does not install $entry"
  desktop-file-validate "$entry"
  echo "desktop entry $entry is valid"
fi

tarball="$(find "$dir" -maxdepth 1 -name '*.tar.gz' | sort)"
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
    entry="share/applications/$(basename "$desktop")"
    [ -f "$entry" ] || die "the tarball has no $entry"
    desktop-file-validate "$entry"
    echo "desktop entry $entry is valid"
  fi
  find . -type f | sort | sed -n '1,40p'
fi

echo "smoke test passed"
