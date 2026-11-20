#!/usr/bin/env bash
# Download the packages of one app and version from a GitHub Release, and
# check that each file is the package its name says.
#
#   fetch.sh DIR
#
#   PUBLISH_REPOSITORY         owner/name of the app's repository
#   PUBLISH_TAG                the release's tag
#   PUBLISH_APP                the package name
#   PUBLISH_PACKAGE_VERSION    the package version
#   PUBLISH_PLUGINS            true: the app's plugin packages as well
#   GH_TOKEN                   a token that may read the release
#
# <app>_<version>_*.deb and <app>-<version>-*.rpm are taken. With
# PUBLISH_PLUGINS, so are the plugin packages of the same version
# (docs/spec.md 4.3): <app>-plugin-<id> and the meta package <app>-plugins.
# Whatever else the release carries is left alone.
set -euo pipefail

die() {
  echo "::error::$*"
  exit 1
}

dir="${1:?usage: fetch.sh DIR}"
repository="${PUBLISH_REPOSITORY:?}"
tag="${PUBLISH_TAG:?}"
app="${PUBLISH_APP:?}"
version="${PUBLISH_PACKAGE_VERSION:?}"

patterns=(--pattern "${app}_${version}_*.deb" --pattern "${app}-${version}-*.rpm")
if [ "${PUBLISH_PLUGINS:-}" = true ]; then
  patterns+=(
    --pattern "${app}-plugin-*_${version}_*.deb" --pattern "${app}-plugins_${version}_*.deb"
    --pattern "${app}-plugin-*-${version}-*.rpm" --pattern "${app}-plugins-${version}-*.rpm"
  )
fi

mkdir -p "$dir"
gh release download "$tag" --repo "$repository" --dir "$dir" "${patterns[@]}" \
  || die "no packages of $app $version in the release $tag of $repository"

count=0
plugins=0
for file in "$dir"/*; do
  base="$(basename "$file")"
  case "$file" in
    *.deb)
      name="$(dpkg-deb --field "$file" Package)"
      got="$(dpkg-deb --field "$file" Version)"
      start="${name}_${version}_"
      ;;
    *.rpm)
      name="$(rpm --query --package --nosignature --queryformat '%{NAME}' "$file")"
      got="$(rpm --query --package --nosignature --queryformat '%{VERSION}' "$file")"
      start="${name}-${version}-"
      ;;
    *) die "unexpected file $base" ;;
  esac
  # The app itself, one of its plugins, or the meta package for them; under
  # a file name that says the same; in the version that was asked for.
  case "$name" in
    "$app") count=$((count + 1)) ;;
    "$app"-plugin-?* | "$app"-plugins) plugins=$((plugins + 1)) ;;
    *) die "$base holds the package '$name', which is neither $app nor one of its plugin packages" ;;
  esac
  [ "$got" = "$version" ] || die "$base holds '$name $got', not version $version"
  [ "${base#"$start"}" != "$base" ] || die "$base holds the package '$name $got'; its name says otherwise"
  echo "fetched $base"
done
[ "$count" -gt 0 ] || die "no packages of $app $version in the release $tag of $repository"
echo "$count package(s) of $app $version, $plugins plugin package(s)"
