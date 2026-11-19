#!/usr/bin/env bash
# Copy the package pool from the bucket, and the site back to it, through
# the bucket's S3 API.
#
#   bucket.sh pull SITE                  the pool of every target, into SITE
#   bucket.sh push SITE REMOVED_LIST     SITE into the bucket
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
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../../../targets.json}"

command="${1:-}"
site="${2:-}"
if [ -z "$site" ] || { [ "$command" != pull ] && [ "$command" != push ]; }; then
  echo "usage: $0 pull SITE | push SITE REMOVED_LIST" >&2
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
