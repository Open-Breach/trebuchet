#!/usr/bin/env bash
# Check the inputs of linux-packages.yml and turn targets.json into the build
# matrix: one entry per target and architecture that the call does not
# exclude.
#
# Reads the inputs from the environment (TREBUCHET_*) and writes `matrix`,
# `binary` and `package-version` to $GITHUB_OUTPUT, or to standard output
# when that is not set.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../../../targets.json}"

die() {
  echo "::error::$*"
  exit 1
}

app="${TREBUCHET_APP:-}"
binary="${TREBUCHET_BINARY:-}"
version="${TREBUCHET_VERSION:-}"
description="${TREBUCHET_DESCRIPTION:-}"
build="${TREBUCHET_BUILD:-cargo}"
artifact="${TREBUCHET_ARTIFACT:-}"
build_artifact="${TREBUCHET_BUILD_ARTIFACT:-}"
build_artifact_path="${TREBUCHET_BUILD_ARTIFACT_PATH:-.}"
exclude="${TREBUCHET_EXCLUDE:-}"
runtime_deps="${TREBUCHET_RUNTIME_DEPS:-}"
build_deps="${TREBUCHET_BUILD_DEPS:-}"
runner_x64="${TREBUCHET_RUNNER_X64:-}"
runner_arm64="${TREBUCHET_RUNNER_ARM64:-}"

[ -n "$runtime_deps" ] || runtime_deps='{}'
[ -n "$build_deps" ] || build_deps='{}'
[ -n "$binary" ] || binary="$app"

# The package name, by the rules of the stricter format (Debian policy 5.6.1).
[[ "$app" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] \
  || die "app '$app': lowercase letters, digits, '+', '-' and '.', at least two characters, starting with a letter or digit"
[[ "$binary" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] \
  || die "binary '$binary' is not a plain file name"
# X.Y.Z, with an optional pre-release part as in a tag v1.2.3-rc1.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?$ ]] \
  || die "version '$version' is not X.Y.Z or X.Y.Z-<pre-release>; pass the tag without its leading v"

# The labels the jobs of each architecture run on. The workflow's inputs
# default to Depot's; an empty one would leave a job without a runner.
[[ "$runner_x64" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "runner-x64 '$runner_x64' is not a runner label"
[[ "$runner_arm64" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "runner-arm64 '$runner_arm64' is not a runner label"

case "$build" in
  cargo)
    [ -z "$artifact" ] || die "artifact is for build: prebuilt"
    if [ -n "$build_artifact" ]; then
      # The characters an artifact's name cannot have, and no line break.
      [[ ! "$build_artifact" =~ [\"\:\<\>\|\*\?\\/[:cntrl:]] ]] \
        || die "build-artifact '$build_artifact' is not the name of an artifact"
      # A place inside the app's directory: relative, and never upwards.
      if [[ ! "$build_artifact_path" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || [[ "/$build_artifact_path/" =~ /\.\./ ]]; then
        die "build-artifact-path '$build_artifact_path' is not a path inside working-directory"
      fi
    fi
    ;;
  prebuilt)
    [ -n "$artifact" ] || die "build: prebuilt needs artifact, the name of the uploaded folder"
    [ -z "$build_artifact" ] || die "build-artifact is for build: cargo; a prebuilt folder brings its files itself"
    [ -n "$description" ] || die "build: prebuilt needs description"
    [ "$(jq -n --arg d "$description" '$d | test("\n")')" = false ] || die "description is a single line"
    ;;
  *) die "build '$build' is neither cargo nor prebuilt" ;;
esac

# In a package version a pre-release sorts before the release with a tilde:
# 1.2.3~rc1 < 1.2.3, where 1.2.3-rc1 would sort after it.
tilde='~'
package_version="${version/-/$tilde}"

for name in runtime-deps build-deps; do
  if [ "$name" = runtime-deps ]; then value="$runtime_deps"; else value="$build_deps"; fi
  jq -e 'type == "object" and all(.[]; type == "array" and all(.[]; type == "string"))' <<< "$value" > /dev/null 2>&1 \
    || die "$name is a JSON object of lists of strings, such as {\"debian\": [\"libfoo1\"], \"fedora\": [\"foo-libs\"]}"
  # A key is a distro (debian) or one target (debian-12).
  unknown="$(jq -r --argjson deps "$value" \
    '[.targets[].id] as $ids | ($ids + ($ids | map(sub("-[^-]*$"; "")))) as $known
     | $deps | keys | map(select(. as $key | $known | index($key) | not)) | join(", ")' "$targets")"
  [ -z "$unknown" ] || die "$name: unknown key(s) $unknown; a key is a distro or a target id of targets.json"
  bad="$(jq -r '[.[][] | select(test("^[A-Za-z0-9/][A-Za-z0-9+._:()<>=|~/ -]*$") | not)] | join(", ")' <<< "$value")"
  [ -z "$bad" ] || die "$name: not a package name or dependency: $bad"
done
jq -e 'all(.[][]; test("^[A-Za-z0-9][A-Za-z0-9+._-]*$"))' <<< "$build_deps" > /dev/null \
  || die "build-deps: package names only, without version constraints"

exclude_json="$(jq -cn --arg list "$exclude" '$list | [splits("[,[:space:]]+")] | map(select(. != ""))')"
unknown="$(jq -r --argjson exclude "$exclude_json" \
  '[.targets[].id] as $ids | $exclude | map(select(. as $id | $ids | index($id) | not)) | join(", ")' "$targets")"
[ -z "$unknown" ] || die "exclude: unknown target(s) $unknown; the targets are $(jq -r '[.targets[].id] | join(", ")' "$targets")"

unknown="$(jq -r '[.arches[].id | select(. != "x86_64" and . != "aarch64")] | join(", ")' "$targets")"
[ -z "$unknown" ] || die "targets.json: no runner is known for architecture(s) $unknown"

# The first target that is left builds the tarball as well: targets.json
# lists the oldest base first, so the tarball links against the oldest glibc
# of the set.
matrix="$(jq -c \
  --argjson exclude "$exclude_json" \
  --argjson runtime "$runtime_deps" \
  --argjson build "$build_deps" \
  --arg x64 "$runner_x64" \
  --arg arm64 "$runner_arm64" '
  def deps($map; $id): ($map[$id | sub("-[^-]*$"; "")] // []) + ($map[$id] // []);
  [.targets[] | select(.id as $id | $exclude | index($id) | not)] as $targets
  | .arches as $arches
  | [ $targets[] as $t | $arches[] as $a
      | {
          target: $t.id,
          image: $t.image,
          format: $t.format,
          arch: $a.id,
          pkgarch: $a[$t.format],
          tararch: $a.tarball,
          runner: (if $a.id == "aarch64" then $arm64 else $x64 end),
          tarball: ($t.id == $targets[0].id),
          build_deps: (deps($build; $t.id) | join(" ")),
          runtime_deps: (deps($runtime; $t.id) | tojson)
        } ]' "$targets")"
[ "$matrix" != "[]" ] || die "exclude leaves no target to build"

{
  echo "matrix=$matrix"
  echo "binary=$binary"
  echo "package-version=$package_version"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

echo "$app $version ($build): $(jq -r 'map("\(.target)/\(.arch)") | join(", ")' <<< "$matrix")"
