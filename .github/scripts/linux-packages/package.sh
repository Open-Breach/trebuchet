#!/usr/bin/env bash
# Make the target's package, a .deb or an .rpm, and leave it in the output
# directory under the name the publisher expects. Runs inside the target's
# container, from the directory the app was built in.
#
# cargo:    cargo-deb or cargo-generate-rpm, with the packaging metadata of
#           the app's Cargo.toml. The version and the extra runtime
#           dependencies come from the call.
# prebuilt: nfpm around the prebuilt folder, which goes to /opt/<app> with a
#           link to its binary in /usr/bin. Everything comes from the call.
#
#   TREBUCHET_APP, TREBUCHET_BINARY, TREBUCHET_PACKAGE_VERSION
#   TREBUCHET_TARGET, TREBUCHET_FORMAT, TREBUCHET_PKGARCH
#   TREBUCHET_BUILD           cargo or prebuilt
#   TREBUCHET_RUNTIME_DEPS    JSON list of dependencies, in the format's syntax
#   TREBUCHET_DIST            output directory
#   TREBUCHET_CARGO_PACKAGE   cargo: crate with the metadata (default: app)
#   TREBUCHET_BUNDLE_DIR      prebuilt: the folder
#   TREBUCHET_DESCRIPTION, TREBUCHET_MAINTAINER,
#   TREBUCHET_DESKTOP_FILE, TREBUCHET_ICON    prebuilt
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
binary="${TREBUCHET_BINARY:?}"
version="${TREBUCHET_PACKAGE_VERSION:?}"
target="${TREBUCHET_TARGET:?}"
format="${TREBUCHET_FORMAT:?}"
pkgarch="${TREBUCHET_PKGARCH:?}"
build="${TREBUCHET_BUILD:?}"
runtime_deps="${TREBUCHET_RUNTIME_DEPS:-[]}"
mkdir -p "${TREBUCHET_DIST:?}"
dist="$(cd "$TREBUCHET_DIST" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The file name is how the publisher finds a package's suite or repository
# (docs/repositories.md).
deb_name() { echo "${app}_${version}_${target}_${pkgarch}.deb"; }
rpm_name() { echo "${app}-${version}-$1.${target}.${pkgarch}.rpm"; }

cargo_package() {
  local crate="${TREBUCHET_CARGO_PACKAGE:-$app}" package manifest
  package="$(cargo metadata --no-deps --format-version 1 \
    | jq -c --arg name "$crate" '.packages[] | select(.name == $name)')"
  [ -n "$package" ] || die "no crate named $crate in this Cargo workspace; set cargo-package"
  manifest="$(jq -r '.manifest_path' <<< "$package")"

  case "$format" in
    deb)
      local out args base name depends
      out="$dist/$(deb_name)"
      args=(--no-build --package "$crate" --deb-version "$version" --output "$out")
      if [ "$(jq 'length' <<< "$runtime_deps")" -gt 0 ]; then
        # cargo-deb takes dependencies from Cargo.toml only. The call's are
        # added to the manifest's own in a variant that changes nothing else.
        base="$(jq -r '.metadata.deb.depends // "$auto" | if type == "array" then join(", ") else . end' <<< "$package")"
        name="$(jq -r '.metadata.deb.name // .name' <<< "$package")"
        depends="$(jq -r --arg base "$base" '([$base | select(. != "")] + .) | join(", ")' <<< "$runtime_deps")"
        {
          echo
          echo "[package.metadata.deb.variants.trebuchet]"
          echo "name = $(jq -n --arg v "$name" '$v')"
          echo "depends = $(jq -n --arg v "$depends" '$v')"
        } >> "$manifest"
        args+=(--variant trebuchet)
      fi
      cargo deb "${args[@]}"
      ;;
    rpm)
      local args requires release crate_dir
      args=(--output "$work/package.rpm" --set-metadata "version = $(jq -n --arg v "$version" '$v')")
      # cargo-generate-rpm selects a workspace member by its directory, where
      # cargo-deb takes the crate's name.
      crate_dir="$(dirname "$manifest")"
      if [ "$crate_dir" != "$PWD" ]; then
        args+=(--package "$(realpath --relative-to="$PWD" "$crate_dir")")
      fi
      if [ "$(jq 'length' <<< "$runtime_deps")" -gt 0 ]; then
        # --set-metadata replaces the whole requires table, so the call's
        # dependencies are merged into the manifest's own first. "name" or
        # "name >= 1.2" becomes name = "*" or name = ">= 1.2".
        requires="$(jq -r --argjson base "$(jq -c '.metadata["generate-rpm"].requires // {}' <<< "$package")" '
          ($base + (map(capture("^(?<key>[^ ]+) *(?<value>.*)$") | .value |= (if . == "" then "*" else . end)) | from_entries))
          | to_entries | map("\(.key | tojson) = \(.value | tojson)") | join(", ")' <<< "$runtime_deps")"
        args+=(--set-metadata "requires = { $requires }")
      fi
      cargo generate-rpm "${args[@]}"
      release="$(rpm --query --package --nosignature --queryformat '%{RELEASE}' "$work/package.rpm")"
      mv "$work/package.rpm" "$dist/$(rpm_name "$release")"
      ;;
  esac
}

prebuilt_package() {
  local bundle="${TREBUCHET_BUNDLE_DIR:?}" desktop="${TREBUCHET_DESKTOP_FILE:-}" icon="${TREBUCHET_ICON:-}"
  local contents release="" out
  [ -x "$bundle/$binary" ] || die "the prebuilt folder has no executable $binary at its top level"

  contents="$(jq -n --arg bundle "$bundle/" --arg app "$app" --arg binary "$binary" '[
    { src: $bundle, dst: "/opt/\($app)", type: "tree" },
    { src: "/opt/\($app)/\($binary)", dst: "/usr/bin/\($binary)", type: "symlink" }
  ]')"
  if [ -n "$desktop" ]; then
    [ -f "$desktop" ] || die "desktop-file $desktop does not exist"
    contents="$(jq --arg src "$desktop" --arg name "$(basename "$desktop")" \
      '. + [{ src: $src, dst: "/usr/share/applications/\($name)", file_info: { mode: 420 } }]' <<< "$contents")"
  fi
  if [ -n "$icon" ]; then
    # Staged under share/icons the same way the tarball carries it, then
    # listed file by file: the package owns its icons, not the directories
    # of the icon theme.
    stage_icon "$icon" "$app" "$work/share/icons"
    while IFS= read -r file; do
      contents="$(jq --arg src "$work/share/icons/$file" --arg dst "/usr/share/icons/$file" \
        '. + [{ src: $src, dst: $dst, file_info: { mode: 420 } }]' <<< "$contents")"
    done < <(cd "$work/share/icons" && find . -type f | sed 's|^\./||' | sort)
  fi

  case "$format" in
    deb) out="$dist/$(deb_name)" ;;
    rpm)
      release="1"
      out="$dist/$(rpm_name "$release")"
      ;;
  esac
  # JSON is YAML, and jq quotes it right.
  jq -n \
    --arg name "$app" --arg arch "$pkgarch" --arg version "$version" --arg release "$release" \
    --arg maintainer "${TREBUCHET_MAINTAINER:-}" --arg description "${TREBUCHET_DESCRIPTION:-}" \
    --argjson depends "$runtime_deps" --argjson contents "$contents" '
    {
      name: $name, platform: "linux", version: $version, version_schema: "none",
      section: "misc", maintainer: $maintainer, description: $description,
      depends: $depends, contents: $contents
    }
    + (if $release == "" then {} else { release: $release } end)
    # The architecture as the format names it, not translated by nfpm.
    + { deb: { arch: $arch }, rpm: { arch: $arch }, arch: $arch }' > "$work/nfpm.yaml"
  nfpm package --config "$work/nfpm.yaml" --packager "$format" --target "$out"
}

case "$build" in
  cargo) cargo_package ;;
  prebuilt) prebuilt_package ;;
  *) die "unknown build mode $build" ;;
esac

# The package is the one the call names, in the version the call names.
case "$format" in
  deb)
    file="$dist/$(deb_name)"
    [ -f "$file" ] || die "no package at $file"
    got="$(dpkg-deb --field "$file" Package) $(dpkg-deb --field "$file" Version) $(dpkg-deb --field "$file" Architecture)"
    ;;
  rpm)
    file="$(find "$dist" -maxdepth 1 -name "$(rpm_name '*')" | head -n 1)"
    [ -n "$file" ] || die "no package in $dist"
    got="$(rpm --query --package --nosignature --queryformat '%{NAME} %{VERSION} %{ARCH}' "$file")"
    ;;
esac
[ "$got" = "$app $version $pkgarch" ] \
  || die "the package is '$got', the call asks for '$app $version $pkgarch'; app has to be the package name of the packaging metadata"
echo "package: $(basename "$file")"
