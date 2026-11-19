#!/usr/bin/env bash
# Make the tarball in the established layout: one top-level folder
# <app>-<version>-linux-<arch>/ with the binary and whatever sits beside it,
# the desktop entry under share/applications/ and the icons under
# share/icons/, so that one copy of share/ into ~/.local/share installs them.
# Runs inside the target's container, from the directory the app was built in.
#
#   TREBUCHET_APP, TREBUCHET_BINARY
#   TREBUCHET_VERSION       as in the tag, 1.2.3 or 1.2.3-rc1
#   TREBUCHET_TARARCH       x64 or arm64
#   TREBUCHET_DIST          output directory
#   TREBUCHET_BUNDLE_DIR    the folder with the binary at its top level; when
#                           empty, the binary cargo built is the whole bundle
#   TREBUCHET_DESKTOP_FILE, TREBUCHET_ICON    optional
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
binary="${TREBUCHET_BINARY:?}"
version="${TREBUCHET_VERSION:?}"
tararch="${TREBUCHET_TARARCH:?}"
bundle="${TREBUCHET_BUNDLE_DIR:-}"
desktop="${TREBUCHET_DESKTOP_FILE:-}"
icon="${TREBUCHET_ICON:-}"
mkdir -p "${TREBUCHET_DIST:?}"
dist="$(cd "$TREBUCHET_DIST" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

name="$app-$version-linux-$tararch"
stage="$work/$name"
mkdir -p "$stage"

if [ -n "$bundle" ]; then
  [ -d "$bundle" ] || die "bundle-dir $bundle does not exist"
  cp -R "$bundle/." "$stage/"
else
  target_dir="$(cargo metadata --no-deps --format-version 1 | jq -r '.target_directory')"
  [ -f "$target_dir/release/$binary" ] || die "no binary at $target_dir/release/$binary; set binary, or bundle-dir if the build lays out a folder"
  cp "$target_dir/release/$binary" "$stage/"
fi
if [ ! -f "$stage/$binary" ] || [ ! -x "$stage/$binary" ]; then
  die "the bundle has no executable $binary at its top level"
fi

if [ -n "$desktop" ]; then
  [ -f "$desktop" ] || die "desktop-file $desktop does not exist"
  mkdir -p "$stage/share/applications"
  cp "$desktop" "$stage/share/applications/"
fi
if [ -n "$icon" ]; then
  stage_icon "$icon" "$app" "$stage/share/icons"
fi

tar --create --gzip --file "$dist/$name.tar.gz" \
  --directory "$work" --owner=0 --group=0 --numeric-owner "$name"
echo "tarball: $name.tar.gz"
