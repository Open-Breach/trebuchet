#!/usr/bin/env bash
# Check a publish request before anything acts on it, and say which release
# it means.
#
# A request names an app, a version and the URL of the GitHub Release that
# carries the packages. It comes from an app's release workflow
# (repository_dispatch) or from a manual run (workflow_dispatch). A manual
# run without any of the three is a republish: nothing new is fetched, the
# repositories are rebuilt and signed as they are. A manual run may instead
# name a release to take out of the plugin registry: an app and a version,
# with PUBLISH_REMOVE set.
#
#   PUBLISH_APP, PUBLISH_VERSION, PUBLISH_RELEASE_URL    the request
#   PUBLISH_REMOVE             true: remove the release from the registry
#   PUBLISH_EVENT              repository_dispatch or workflow_dispatch
#   GITHUB_REPOSITORY_OWNER    releases of this owner only
#
# Writes mode (release, republish or remove), app, package-version,
# repository, tag and release-url to $GITHUB_OUTPUT, or to standard output
# when that is not set.
set -euo pipefail

die() {
  echo "::error::$*"
  exit 1
}

app="${PUBLISH_APP:-}"
version="${PUBLISH_VERSION:-}"
url="${PUBLISH_RELEASE_URL:-}"
event="${PUBLISH_EVENT:-}"
remove="${PUBLISH_REMOVE:-}"
owner="${GITHUB_REPOSITORY_OWNER:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

# A removal is a person's decision: no release workflow sends one.
if [ "$remove" = true ]; then
  [ "$event" = workflow_dispatch ] || die "a release is removed from the registry by a manual run only"
  if [ -z "$app" ] || [ -z "$version" ]; then
    die "to remove a release from the registry, name its app and its version"
  fi
  [[ "$app" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "app is not a package name"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version is not X.Y.Z"
  {
    echo "mode=remove"
    echo "app=$app"
    echo "package-version=$version"
  } >> "$out"
  echo "remove: $app $version leaves the plugin registry"
  exit 0
fi

if [ -z "$app$version$url" ]; then
  [ "$event" = workflow_dispatch ] || die "the request names no app, version and release URL"
  echo "mode=republish" >> "$out"
  echo "republish: nothing new is fetched"
  exit 0
fi
if [ -z "$app" ] || [ -z "$version" ] || [ -z "$url" ]; then
  die "a request needs all three of app, version and release URL (or none of them, for a manual republish)"
fi

[[ "$app" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "app is not a package name"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?$ ]] || die "version is not X.Y.Z or X.Y.Z-<pre-release>"
# There is one channel. A pre-release in it would reach every user as an
# update, so it is not published.
[[ "$version" != *-* ]] || die "version $version is a pre-release; the repositories carry releases only"

[[ "$url" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/tag/([A-Za-z0-9_.+-]+)$ ]] \
  || die "release URL is not https://github.com/<owner>/<repository>/releases/tag/<tag>"
url_owner="${BASH_REMATCH[1]}"
repository="${BASH_REMATCH[2]}"
tag="${BASH_REMATCH[3]}"
# Packages are taken from this organisation's own releases and nowhere else.
[ "${url_owner,,}" = "${owner,,}" ] || die "the release belongs to $url_owner; only releases of $owner are published"

{
  echo "mode=release"
  echo "app=$app"
  echo "package-version=$version"
  echo "repository=$url_owner/$repository"
  echo "tag=$tag"
  echo "release-url=$url"
} >> "$out"
echo "release: $app $version from $url_owner/$repository, tag $tag"
