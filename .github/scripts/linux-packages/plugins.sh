#!/usr/bin/env bash
# Make the plugin packages of docs/spec.md 4.3 from the same build as the
# main package: one package <app>-plugin-<id> per plugin the call names,
# and the meta package <app>-plugins that pulls in all of them. Runs inside
# the target's container after package.sh, from the directory the app was
# built in, and leaves the packages in the output directory beside the main
# one, named the same way.
#
# A plugin's package holds the folder the call names for it, installed as
# <plugins-dir>/<id>/, and depends on the main package in exactly this
# version: a plugin is built with one build of the app and fits no other.
# The call's own dependencies for the plugin are added to that.
#
#   TREBUCHET_APP, TREBUCHET_PACKAGE_VERSION
#   TREBUCHET_TARGET, TREBUCHET_FORMAT, TREBUCHET_PKGARCH
#   TREBUCHET_DIST            output directory
#   TREBUCHET_PLUGINS         JSON list of { id, summary, files, runtime-deps }
#   TREBUCHET_PLUGINS_DIR     where the app's plugins are installed
#   TREBUCHET_CARGO_PACKAGE   the crate whose metadata names the maintainer,
#                             the licence and the home page (default: app)
#   TREBUCHET_MAINTAINER, TREBUCHET_LICENSE, TREBUCHET_HOMEPAGE
#                             the same three, said outright; then no crate
#                             is asked
#
# Needs jq and nfpm, and the tool of the target's format to read the result
# back: dpkg-deb or rpm.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
version="${TREBUCHET_PACKAGE_VERSION:?}"
target="${TREBUCHET_TARGET:?}"
format="${TREBUCHET_FORMAT:?}"
pkgarch="${TREBUCHET_PKGARCH:?}"
plugins="${TREBUCHET_PLUGINS:-[]}"
plugins_dir="${TREBUCHET_PLUGINS_DIR:-}"
mkdir -p "${TREBUCHET_DIST:?}"
dist="$(cd "$TREBUCHET_DIST" && pwd)"

count="$(jq 'length' <<< "$plugins")"
if [ "$count" -eq 0 ]; then
  echo "the call names no plugins: no plugin packages"
  exit 0
fi
[ -n "$plugins_dir" ] || die "plugins-dir is not set"
case "$format" in
  deb | rpm) ;;
  *) die "unknown format $format" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Who makes the packages, under which licence, and where the app lives: the
# main package's own answers, from the crate that carries its metadata.
maintainer="${TREBUCHET_MAINTAINER:-}"
license="${TREBUCHET_LICENSE:-}"
homepage="${TREBUCHET_HOMEPAGE:-}"
if [ -z "$maintainer" ]; then
  crate="${TREBUCHET_CARGO_PACKAGE:-$app}"
  package="$(cargo metadata --no-deps --format-version 1 \
    | jq -c --arg name "$crate" '.packages[] | select(.name == $name)')"
  [ -n "$package" ] || die "no crate named $crate in this Cargo workspace; set cargo-package"
  maintainer="$(jq -r '.metadata.deb.maintainer // .authors[0] // ""' <<< "$package")"
  license="$(jq -r '.license // ""' <<< "$package")"
  homepage="$(jq -r '.homepage // .repository // ""' <<< "$package")"
fi
[ -n "$maintainer" ] || die "no maintainer for the plugin packages: the crate names none in package.metadata.deb.maintainer or authors"

# The file names of package.sh: the publisher finds a package's suite or
# repository by them (docs/repositories.md).
release="1"
file_name() {
  case "$format" in
    deb) echo "$1_${version}_${target}_${pkgarch}.deb" ;;
    rpm) echo "$1-${version}-${release}.${target}.${pkgarch}.rpm" ;;
  esac
}
# A dependency on exactly this version of a package, in the format's syntax.
exactly() {
  case "$format" in
    deb) echo "$1 (= $version)" ;;
    rpm) echo "$1 = $version" ;;
  esac
}

# package NAME DESCRIPTION DEPENDS_JSON CONTENTS_JSON: one package, read
# back and held to its name, version and architecture.
package() {
  local name="$1" description="$2" depends="$3" contents="$4" out got
  out="$dist/$(file_name "$name")"
  # JSON is YAML, and jq quotes it right.
  jq -n \
    --arg name "$name" --arg arch "$pkgarch" --arg version "$version" --arg release "$release" --arg format "$format" \
    --arg maintainer "$maintainer" --arg license "$license" --arg homepage "$homepage" --arg description "$description" \
    --argjson depends "$depends" --argjson contents "$contents" '
    {
      name: $name, platform: "linux", version: $version, version_schema: "none",
      section: "misc", maintainer: $maintainer, description: $description,
      depends: $depends, contents: $contents
    }
    + (if $license == "" then {} else { license: $license } end)
    + (if $homepage == "" then {} else { homepage: $homepage } end)
    + (if $format == "rpm" then { release: $release } else {} end)
    # The architecture as the format names it, not translated by nfpm.
    + { deb: { arch: $arch }, rpm: { arch: $arch }, arch: $arch }' > "$work/nfpm.yaml"
  nfpm package --config "$work/nfpm.yaml" --packager "$format" --target "$out" > /dev/null
  case "$format" in
    deb) got="$(dpkg-deb --field "$out" Package) $(dpkg-deb --field "$out" Version) $(dpkg-deb --field "$out" Architecture)" ;;
    rpm) got="$(rpm --query --package --nosignature --queryformat '%{NAME} %{VERSION} %{ARCH}' "$out")" ;;
  esac
  [ "$got" = "$name $version $pkgarch" ] || die "the package is '$got', expected '$name $version $pkgarch'"
  echo "package: $(basename "$out")"
}

all="[]"
for ((i = 0; i < count; i++)); do
  id="$(jq -r --argjson i "$i" '.[$i].id' <<< "$plugins")"
  summary="$(jq -r --argjson i "$i" '.[$i].summary' <<< "$plugins")"
  source="$(jq -r --argjson i "$i" '.[$i].files' <<< "$plugins")"
  name="$app-plugin-$id"
  dest="$plugins_dir/$id"

  [ -d "$source" ] || die "plugin $id: no folder $source: the build did not lay it out"
  [ -z "$(find "$source" -type l -print -quit)" ] || die "plugin $id: $source holds a symbolic link; a plugin's folder is plain files and folders"
  [ -n "$(find "$source" -type f -print -quit)" ] || die "plugin $id: $source holds no file"

  # The folder and every folder in it belong to the package, so that
  # removing the package leaves nothing behind; every file keeps whether it
  # can be run and is otherwise read-only for everyone but root.
  contents="$(
    {
      (cd "$source" && find . -type d | sed 's|^\.||' | LC_ALL=C sort) | jq -R --arg dest "$dest" \
        '{ dst: ($dest + .), type: "dir", file_info: { mode: 493 } }'
      while IFS= read -r file; do
        mode=420
        [ ! -x "$source/$file" ] || mode=493
        jq -n --arg src "$source/$file" --arg dst "$dest/$file" --argjson mode "$mode" \
          '{ src: $src, dst: $dst, file_info: { mode: $mode } }'
      done < <(cd "$source" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
    } | jq -s .
  )"
  # The main package in exactly this version, then what the call adds for
  # this plugin on this target: its distro's list and its own.
  depends="$(jq -c --argjson i "$i" --arg target "$target" --arg main "$(exactly "$app")" '
    (.[$i]["runtime-deps"] // {}) as $map
    | [$main] + ($map[$target | sub("-[^-]*$"; "")] // []) + ($map[$target] // [])' <<< "$plugins")"
  description="$(printf '%s\nThe plugin %s of %s, as its own package. It is built with %s %s and fits that version only; the package manager keeps the two together.' \
    "$summary" "$id" "$app" "$app" "$version")"
  package "$name" "$description" "$depends" "$contents"
  all="$(jq -c --arg dep "$(exactly "$name")" '. + [$dep]' <<< "$all")"
done

# The whole set in one name. It holds no file of its own.
description="$(printf 'All plugins of %s\nInstalls every plugin of %s that is a package of its own, each in the version of this package.' "$app" "$app")"
package "$app-plugins" "$description" "$all" "[]"
