#!/usr/bin/env bash
# Download what a release attaches for the plugin registry: the manifests
# plugins-<platform>.json and the files they name (docs/registry.md).
#
#   fetch-plugins.sh DIR
#
#   PUBLISH_REPOSITORY    owner/name of the app's repository
#   PUBLISH_TAG           the release's tag
#   GH_TOKEN              a token that may read the release
#
# A release without a manifest has no plugins: DIR is left empty, and the
# registry only gets the app's latest version. Whether a file is the one
# its manifest describes is registry/merge.sh's to check; this script only
# brings the files.
set -euo pipefail

die() {
  echo "::error::$*"
  exit 1
}

dir="${1:?usage: fetch-plugins.sh DIR}"
repository="${PUBLISH_REPOSITORY:?}"
tag="${PUBLISH_TAG:?}"

mkdir -p "$dir"
[ -z "$(ls -A "$dir")" ] || die "$dir is not empty"

# The names of the release's files, asked first: a release that has no
# manifest is told apart from a release that could not be read.
assets="$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].name')" \
  || die "the release $tag of $repository could not be read"
mapfile -t manifests < <(grep -E '^plugins-[a-z0-9]+(-[a-z0-9]+)*\.json$' <<< "$assets" | sort || true)
if [ "${#manifests[@]}" -eq 0 ]; then
  echo "the release $tag of $repository has no plugins-<platform>.json: no plugins"
  exit 0
fi

patterns=()
for manifest in "${manifests[@]}"; do patterns+=(--pattern "$manifest"); done
gh release download "$tag" --repo "$repository" --dir "$dir" "${patterns[@]}" \
  || die "the manifests of the release $tag of $repository could not be downloaded"

# The files the manifests name. A name is a plain file name, which is also
# what keeps it from being a pattern or a path; merge.sh says so again.
patterns=()
for manifest in "${manifests[@]}"; do
  jq -e 'type == "object" and (.plugins | type) == "array"' "$dir/$manifest" > /dev/null 2>&1 \
    || die "$manifest is not a manifest: a JSON object with a list of plugins"
  while IFS= read -r file; do
    [[ "$file" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || die "$manifest names '$file', which is not a plain file name"
    grep -qxF "$file" <<< "$assets" || die "$manifest names $file, and the release has no such file"
    patterns+=(--pattern "$file")
  done < <(jq -r '.plugins[] | .file // "" | tostring' "$dir/$manifest")
done
if [ "${#patterns[@]}" -gt 0 ]; then
  gh release download "$tag" --repo "$repository" --dir "$dir" "${patterns[@]}" \
    || die "the plugin files of the release $tag of $repository could not be downloaded"
fi
echo "fetched ${#manifests[@]} manifest(s) and $((${#patterns[@]} / 2)) plugin file(s)"
