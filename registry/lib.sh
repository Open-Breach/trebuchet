# Shared by the registry scripts; sourced, not run.
# shellcheck shell=bash

# The index's schema (docs/spec.md 7.2). It goes up only for a change an old
# reader cannot ignore.
# shellcheck disable=SC2034  # read by the scripts that source this file
registry_schema=1

# To standard error: some of what these scripts print is a list for the
# next script, and a reason must never end up in one.
die() {
  echo "::error::$*" >&2
  exit 1
}

# jq definitions the scripts share: the order of versions. A version is
# X.Y.Z with an optional pre-release part, and 1.2.3-rc1 is older than 1.2.3.
# A jq program: its $names are jq's, not the shell's.
# shellcheck disable=SC2034,SC2016
registry_jq='
  def version_key:
    (index("-")) as $cut
    | (if $cut then .[:$cut] else . end | split(".") | map(tonumber? // 0)) as $numbers
    | [$numbers, (if $cut then 0 else 1 end), (if $cut then .[$cut + 1:] else "" end)];
  # The releases of an app that have a build in the index, newest first.
  def releases: [.plugins // [] | .[].builds[].app_version] | unique | sort_by(version_key) | reverse;
  # An app without the builds of the releases $gone, and without the plugins
  # that have no build left. An app without plugins has no list of them.
  def drop_releases($gone):
    if has("plugins") then
      .plugins |= map(.builds |= map(select(.app_version as $v | $gone | index($v) | not)) | select(.builds | length > 0))
      | if (.plugins | length) == 0 then del(.plugins) else . end
    else . end;
'

# registry_index SITE: the path of the index in a local copy of the site.
registry_index() {
  printf '%s/registry/index.json' "$1"
}

# registry_read INDEX: print the index, or an empty one where there is none
# yet. An index of a newer schema, or a file that is no index, stops the run:
# it is never replaced by something this version made up.
registry_read() {
  local index="$1"
  if [ ! -e "$index" ]; then
    jq -n --argjson schema "$registry_schema" '{ schema: $schema, generated: "", apps: {} }'
    return
  fi
  jq -e 'type == "object" and (.schema | type) == "number" and ((.apps // {}) | type) == "object"' "$index" > /dev/null 2>&1 \
    || die "$index is not a registry index"
  jq -e --argjson schema "$registry_schema" '.schema <= $schema' "$index" > /dev/null \
    || die "$index has schema $(jq '.schema' "$index"), and this publisher writes schema $registry_schema: a newer publisher wrote it"
  jq '.apps //= {}' "$index"
}

# registry_write INDEX: write the index read from standard input, with the
# time it was made, through a file beside it, so that a failed run leaves
# the old one whole. TREBUCHET_REGISTRY_NOW names the time; that is for the
# tests.
registry_write() {
  local index="$1" now
  now="${TREBUCHET_REGISTRY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  mkdir -p "$(dirname "$index")"
  jq --arg now "$now" --argjson schema "$registry_schema" '
    # The keys in the order of the specification, the apps by name, the
    # plugins by id: the same content is the same file.
    { schema: $schema, generated: $now }
    + (del(.schema, .generated, .apps))
    + { apps: (.apps | to_entries | sort_by(.key) | from_entries) }' > "$index.new"
  mv "$index.new" "$index"
}

# registry_removed RESULT: print the paths, relative to the site, of the
# files of the builds a script took out of the index. RESULT is a JSON file
# whose `gone` lists them with their app, app version and url. A file is
# only ever named inside the folder of its app and release: a build whose
# address points anywhere else stops the run, and nothing is deleted for it.
registry_removed() {
  local bad
  bad="$(jq -r '.gone[] | (.url | sub("^https?://[^/]+/"; "")) as $path
    | select($path | test("^plugins/[^/]+/[^/]+/[A-Za-z0-9][A-Za-z0-9._+-]*$") | not) | .url' "$1" | head -n 1)"
  [ -z "$bad" ] || die "$bad is not the address of a plugin file of the registry; the index is not changed"
  bad="$(jq -r '.gone[] | (.url | sub("^https?://[^/]+/"; "")) as $path | "plugins/\(.app)/\(.app_version)/" as $folder
    | select($path | startswith($folder) | not) | .url' "$1" | head -n 1)"
  [ -z "$bad" ] || die "$bad is not in the folder of its app and release; the index is not changed"
  jq -r '[.gone[].url | sub("^https?://[^/]+/"; "")] | unique[]' "$1"
}
