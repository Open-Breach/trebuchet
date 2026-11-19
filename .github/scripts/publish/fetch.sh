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
#   GH_TOKEN                   a token that may read the release
#
# Only <app>_<version>_*.deb and <app>-<version>-*.rpm are taken; whatever
# else the release carries is left alone.
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

mkdir -p "$dir"
gh release download "$tag" --repo "$repository" --dir "$dir" \
  --pattern "${app}_${version}_*.deb" --pattern "${app}-${version}-*.rpm" \
  || die "no packages of $app $version in the release $tag of $repository"

count=0
for file in "$dir"/*; do
  case "$file" in
    *.deb) got="$(dpkg-deb --field "$file" Package) $(dpkg-deb --field "$file" Version)" ;;
    *.rpm) got="$(rpm --query --package --nosignature --queryformat '%{NAME} %{VERSION}' "$file")" ;;
    *) die "unexpected file $(basename "$file")" ;;
  esac
  [ "$got" = "$app $version" ] || die "$(basename "$file") holds '$got', not '$app $version'"
  echo "fetched $(basename "$file")"
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no packages of $app $version in the release $tag of $repository"
