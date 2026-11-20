#!/usr/bin/env bash
# Copy the package pool from the bucket, and the site back to it, through
# the bucket's S3 API.
#
#   bucket.sh pull SITE                  the pool of every target, into SITE
#   bucket.sh push SITE REMOVED_LIST     SITE into the bucket
#
# And the same for the plugin registry (docs/registry.md), whose index is
# SITE/registry/index.json with its signature beside it:
#
#   bucket.sh pull-registry SITE                  the index and its signature
#   bucket.sh push-registry SITE REMOVED_LIST     new plugin files, then the
#                                                 index, then the deletions
#
#   R2_BUCKET                                     the bucket's name
#   R2_ENDPOINT                                   its S3 endpoint
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY      a token for that bucket
#
# Only the targets of targets.json are touched. What the bucket holds for a
# target that has been removed from the list stays as it is.
#
# push never deletes by comparison of the pool: a package file is deleted
# only when REMOVED_LIST names it. The index directories (dists/<suite>,
# repodata) are rebuilt whole on every run, so there what the new index no
# longer has is deleted.
#
# The registry's commands touch registry/index.json, its signature, and
# files under plugins/. A plugin file is uploaded when SITE holds it, which
# is when a build was new, and deleted only when REMOVED_LIST names it,
# which is when its release was removed by hand. Plugin files are never
# pruned: the bucket keeps those of every release.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../../../targets.json}"

command="${1:-}"
site="${2:-}"
case "$command" in
  pull | push | pull-registry | push-registry) ;;
  *) site="" ;;
esac
if [ -z "$site" ]; then
  echo "usage: $0 pull SITE | push SITE REMOVED_LIST | pull-registry SITE | push-registry SITE REMOVED_LIST" >&2
  exit 2
fi
bucket="s3://${R2_BUCKET:?}"
: "${R2_ENDPOINT:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"

# R2 has one region, named auto. Checksums only where S3 requires them:
# newer AWS CLIs add them to every request, which not every S3-compatible
# store accepts.
export AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
export AWS_EC2_METADATA_DISABLED=true

s3() {
  aws --endpoint-url "$R2_ENDPOINT" s3 "$@"
}

mapfile -t suites < <(jq -r '.targets[] | select(.format == "deb") | .id' "$targets")
mapfile -t repos < <(jq -r '.targets[] | select(.format == "rpm") | .id' "$targets")
mapfile -t arches < <(jq -r '.arches[].rpm' "$targets")

# Index files change with every publish while their names stay the same, so
# the CDN may keep them for a moment only. Packages get no header.
index_cache="public, max-age=60"
static_cache="public, max-age=300"
# A plugin file never changes once it is published (docs/spec.md 7.2).
plugin_cache="public, max-age=31536000, immutable"

# --- the plugin registry ------------------------------------------------------

if [ "$command" = pull-registry ]; then
  mkdir -p "$site/registry"
  for file in index.json index.json.minisig; do
    key="registry/$file"
    # A file that is not there is a registry that has not started, and is
    # told apart from a bucket that did not answer: a run that could not
    # read the index must never start a new one over it.
    if out="$(aws --endpoint-url "$R2_ENDPOINT" s3api head-object --bucket "$R2_BUCKET" --key "$key" 2>&1)"; then
      s3 cp "$bucket/$key" "$site/registry/$file" --no-progress
    elif grep -q -e '(404)' -e 'Not Found' <<< "$out"; then
      echo "no $key in the bucket"
    else
      echo "::error::the bucket did not say whether it holds $key"
      exit 1
    fi
  done
  exit 0
fi

if [ "$command" = push-registry ]; then
  removed="${3:?usage: $0 push-registry SITE REMOVED_LIST}"
  for file in index.json index.json.minisig; do
    [ -s "$site/registry/$file" ] || {
      echo "::error::no registry/$file to upload: the index goes up with its signature or not at all"
      exit 1
    }
  done
  # 1. The plugin files, before the index names them.
  if [ -d "$site/plugins" ]; then
    while IFS= read -r path; do
      [[ "$path" =~ ^plugins/[a-z0-9][a-z0-9+.-]+/[0-9A-Za-z.~+-]+/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        echo "::error::refusing to upload $path: not a plugin file of the registry"
        exit 1
      }
      s3 cp "$site/$path" "$bucket/$path" --no-progress --cache-control "$plugin_cache" \
        --content-type "application/octet-stream"
    done < <(cd "$site" && find plugins -type f | sort)
  fi
  # 2. The index, then its signature. Every file the index names is there.
  s3 cp "$site/registry/index.json" "$bucket/registry/index.json" --no-progress --cache-control "$index_cache" \
    --content-type "application/json"
  s3 cp "$site/registry/index.json.minisig" "$bucket/registry/index.json.minisig" --no-progress --cache-control "$index_cache" \
    --content-type "text/plain; charset=utf-8"
  # 3. The files of the builds that left the index, by name. Last: the index
  #    that is served no longer names them.
  while IFS= read -r path; do
    case "$path" in
      "") ;;
      *..* | */) echo "::error::refusing to delete $path: not a plugin file of the registry" && exit 1 ;;
      plugins/*/*/*)
        [[ "$path" =~ ^plugins/[^/]+/[^/]+/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
          echo "::error::refusing to delete $path: not a plugin file of the registry"
          exit 1
        }
        s3 rm "$bucket/$path"
        ;;
      *)
        echo "::error::refusing to delete $path: not a plugin file of the registry"
        exit 1
        ;;
    esac
  done < "$removed"
  exit 0
fi

# --- the package repositories ---------------------------------------------------

if [ "$command" = pull ]; then
  for suite in "${suites[@]}"; do
    mkdir -p "$site/apt/pool/$suite"
    s3 sync "$bucket/apt/pool/$suite" "$site/apt/pool/$suite" --no-progress
  done
  for repo in "${repos[@]}"; do
    for arch in "${arches[@]}"; do
      mkdir -p "$site/rpm/$repo/$arch"
      s3 sync "$bucket/rpm/$repo/$arch" "$site/rpm/$repo/$arch" --exclude 'repodata/*' --no-progress
    done
  done
  exit 0
fi

removed="${3:?usage: $0 push SITE REMOVED_LIST}"

# 1. The packages, before any index names them.
for suite in "${suites[@]}"; do
  s3 sync "$site/apt/pool/$suite" "$bucket/apt/pool/$suite" --no-progress
done
for repo in "${repos[@]}"; do
  for arch in "${arches[@]}"; do
    s3 sync "$site/rpm/$repo/$arch" "$bucket/rpm/$repo/$arch" --exclude 'repodata/*' --no-progress
  done
done

# 2. The indexes. The signed entry points go last, so that what they list is
#    already there; then what the new index no longer has is deleted.
for suite in "${suites[@]}"; do
  dists="apt/dists/$suite"
  s3 sync "$site/$dists" "$bucket/$dists" --no-progress --cache-control "$index_cache" \
    --exclude Release --exclude Release.gpg --exclude InRelease
  for file in Release Release.gpg InRelease; do
    s3 cp "$site/$dists/$file" "$bucket/$dists/$file" --no-progress --cache-control "$index_cache"
  done
  s3 sync "$site/$dists" "$bucket/$dists" --no-progress --cache-control "$index_cache" --delete
done
for repo in "${repos[@]}"; do
  for arch in "${arches[@]}"; do
    repodata="rpm/$repo/$arch/repodata"
    s3 sync "$site/$repodata" "$bucket/$repodata" --no-progress --cache-control "$index_cache" \
      --exclude repomd.xml --exclude repomd.xml.asc
    for file in repomd.xml repomd.xml.asc; do
      s3 cp "$site/$repodata/$file" "$bucket/$repodata/$file" --no-progress --cache-control "$index_cache"
    done
    s3 sync "$site/$repodata" "$bucket/$repodata" --no-progress --cache-control "$index_cache" --delete
  done
done

# 3. The package files that pruning removed, by name.
while IFS= read -r path; do
  case "$path" in
    apt/pool/*/*.deb | rpm/*/*/*.rpm) s3 rm "$bucket/$path" ;;
    "") ;;
    *)
      echo "::error::refusing to delete $path: not a package file of the pool"
      exit 1
      ;;
  esac
done < "$removed"

# 4. The installer and the public key. As text where a person may want to
#    read them in a browser.
s3 cp "$site/install.sh" "$bucket/install.sh" --no-progress --cache-control "$static_cache" \
  --content-type "text/plain; charset=utf-8"
s3 cp "$site/keys/openbreach.asc" "$bucket/keys/openbreach.asc" --no-progress --cache-control "$static_cache" \
  --content-type "text/plain; charset=utf-8"
s3 cp "$site/keys/openbreach.gpg" "$bucket/keys/openbreach.gpg" --no-progress --cache-control "$static_cache" \
  --content-type "application/octet-stream"
