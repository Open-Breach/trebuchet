#!/usr/bin/env bash
# Bring a local copy of the registry index up to date and sign it
# (docs/registry.md): merge a release into it, or take a release out of it.
#
#   build-registry.sh SITE REMOVED_LIST release APP VERSION RELEASE_URL [INCOMING_DIR]
#   build-registry.sh SITE REMOVED_LIST remove APP VERSION
#
# SITE/registry holds the index and its signature as the bucket has them
# (bucket.sh pull-registry), or nothing where the registry has not started.
# INCOMING_DIR holds the release's manifests and plugin files
# (fetch-plugins.sh). The new plugin files are left under SITE/plugins/ and
# the paths of the files that left the index are written to REMOVED_LIST,
# both for bucket.sh push-registry.
#
# A release adds to the index and takes nothing out of it: the registry
# keeps every build of every release (docs/spec.md 7.4), so REMOVED_LIST is
# empty after a release. Files leave only with a release that is removed.
#
#   REGISTRY_SIGNING_KEY, REGISTRY_SIGNING_PASSWORD    as registry/sign.sh has them
#   REGISTRY_BASE_URL, REGISTRY_PUBLISHER              as registry/merge.sh has them
#
# The index of the bucket is verified against the published public key
# before anything is built on it: this script signs what it writes, so it
# only ever continues a list that the key has signed. An index that does not
# verify stops the run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
public="${TREBUCHET_REGISTRY_PUBLIC_KEY:-$root/keys/registry.pub}"

die() {
  echo "::error::$*"
  exit 1
}
usage() {
  echo "usage: $0 SITE REMOVED_LIST release APP VERSION RELEASE_URL [INCOMING_DIR] | $0 SITE REMOVED_LIST remove APP VERSION" >&2
  exit 2
}

[ "$#" -ge 5 ] || usage
mkdir -p "$1"
site="$(cd "$1" && pwd)"
removed="$2"
mode="$3"
app="$4"
version="$5"
index="$site/registry/index.json"
: > "$removed"

if [ -e "$index" ]; then
  minisign -V -H -p "$public" -m "$index" > /dev/null 2>&1 \
    || die "the index in the bucket is not signed with $(basename "$public"): it was changed by something else than this publisher, or the key was replaced. Nothing is built on it. docs/publisher.md says what to do."
  echo "the index of the bucket verifies against $(basename "$public")"
else
  # A signature without its index is of no use to anyone.
  rm -f "$index.minisig"
  echo "the bucket has no index yet: this run starts it"
fi

case "$mode" in
  release)
    { [ "$#" -ge 6 ] && [ "$#" -le 7 ]; } || usage
    "$root/registry/merge.sh" "$site" "$app" "$version" "$6" ${7:+"$7"}
    ;;
  remove)
    [ "$#" -eq 5 ] || usage
    "$root/registry/remove.sh" "$site" "$removed" "$app" "$version"
    ;;
  *) usage ;;
esac

"$root/registry/sign.sh" "$index"

{
  echo "### The plugin registry"
  echo
  if [ "$mode" = release ]; then
    echo "\`$app\` $version is in the index; its latest release is $(jq -r --arg app "$app" '.apps[$app].latest.version // "not named"' "$index")."
    new=""
    [ ! -d "$site/plugins" ] || new="$(cd "$site" && find plugins -type f | sort)"
    if [ -n "$new" ]; then
      echo
      echo "New plugin files:"
      echo
      while IFS= read -r path; do
        echo "- \`$(basename "$path")\`"
      done <<< "$new"
    fi
  else
    echo "\`$app\` $version was taken out of the index."
  fi
  if [ -s "$removed" ]; then
    echo
    echo "Plugin files that left:"
    echo
    while IFS= read -r path; do
      echo "- \`$path\`"
    done < "$removed"
  fi
  echo
  # Every release stays, so both numbers only go up: this is where to see
  # how far (docs/publisher.md, *What grows*).
  echo "Builds in the index: $(jq '[.apps[].plugins // [] | .[].builds[]] | length' "$index"), in $(stat -c %s "$index") bytes."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
