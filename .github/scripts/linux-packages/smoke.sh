#!/usr/bin/env bash
# The smoke test of docs/spec.md 4.2, in a fresh container of the target's
# image: install the package with the distro's package manager, run the
# binary with --version, validate the desktop entry. Where the target also
# built the tarball, unpack it and do the same with what is inside. Where
# the call names a smoke command, the app's own checks run as well: after
# the package is installed, and once more for the unpacked tarball.
#
# Where the call names plugins (docs/spec.md 4.3), their packages are
# installed after that, on top of the main package: one alone, then the
# rest through the meta package. Each has to ask for the main package in
# exactly this version and to put its files into its folder of the plugins
# directory and nowhere else. The smoke command then runs a third time, and
# at the end one plugin package is removed again, with its folder.
#
#   smoke.sh DIR    the directory with the package, the plugin packages and
#                   maybe the tarball: the build job's folder for the release
#
#   TREBUCHET_APP, TREBUCHET_BINARY, TREBUCHET_PACKAGE_VERSION
#   TREBUCHET_FORMAT               deb or rpm
#   TREBUCHET_DESKTOP_FILE         the call's desktop-file input, or empty
#   TREBUCHET_SMOKE_COMMAND        the call's smoke-command input, or empty
#   TREBUCHET_WORKING_DIRECTORY    the call's working-directory input: where
#                                  the smoke command runs, in the checkout
#                                  of the app this script is started from
#   TREBUCHET_SMOKE_FILES          the folder with what the build job put
#                                  aside for this test; it need not exist
#   TREBUCHET_PLUGIN_IDS           the ids of the call's plugins, with spaces
#                                  between them; empty for none
#   TREBUCHET_PLUGINS_DIR          the call's plugins-dir input
#
# The smoke command is told what it is testing:
#
#   TREBUCHET_SMOKE        package: the package is installed and the binary
#                          is on the PATH. tarball: the tarball is unpacked.
#                          plugins: the plugin packages are installed too.
#   TREBUCHET_SMOKE_DIR    for the tarball, the unpacked folder with the
#                          binary at its top level; empty for the package
#   TREBUCHET_DIST         DIR, with every file the build job uploaded for
#                          the release
#   TREBUCHET_SMOKE_FILES  the folder of files for this test only, which no
#                          release gets; empty where the build put none there
#
# The app's checks run before anything but the package is installed: the
# validator of the desktop entry comes last, so that a library it brings
# cannot stand in for one the package forgot to ask for.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

app="${TREBUCHET_APP:?}"
binary="${TREBUCHET_BINARY:?}"
version="${TREBUCHET_PACKAGE_VERSION:?}"
format="${TREBUCHET_FORMAT:?}"
desktop="${TREBUCHET_DESKTOP_FILE:-}"
extra="${TREBUCHET_SMOKE_COMMAND:-}"
read -r -a plugin_ids <<< "${TREBUCHET_PLUGIN_IDS:-}"
plugins_dir="${TREBUCHET_PLUGINS_DIR:-}"
workdir="$PWD/${TREBUCHET_WORKING_DIRECTORY:-.}"
dir="$(cd "${1:?usage: smoke.sh DIR}" && pwd)"
# Always a folder for the smoke command, empty where the build put nothing
# aside and no artifact came.
files="${TREBUCHET_SMOKE_FILES:-}"
if [ -z "$files" ]; then files="$(mktemp -d)"; fi
mkdir -p "$files"
files="$(cd "$files" && pwd)"

if [ -n "$extra" ] && [ ! -d "$workdir" ]; then
  die "smoke-command: no $workdir: the app's repository is not checked out here"
fi

# The app's own checks, for the package or for the tarball.
smoke_command() {
  local what="$1" unpacked="$2"
  [ -n "$extra" ] || return 0
  echo "smoke command for the $what: $extra"
  (
    cd "$workdir"
    TREBUCHET_SMOKE="$what" TREBUCHET_SMOKE_DIR="$unpacked" TREBUCHET_DIST="$dir" \
      TREBUCHET_SMOKE_FILES="$files" bash -euo pipefail -c "$extra"
  ) || die "the smoke command failed for the $what"
  echo "smoke command passed for the $what"
}

# package_file NAME: the one file in DIR that is the package NAME in this
# version, by the names package.sh and plugins.sh give.
package_file() {
  local found
  case "$format" in
    deb) found="$(find "$dir" -maxdepth 1 -name "$1_${version}_*.deb" | sort)" ;;
    rpm) found="$(find "$dir" -maxdepth 1 -name "$1-${version}-*.rpm" | sort)" ;;
    *) die "unknown format $format" ;;
  esac
  if [ -z "$found" ] || [ "$(wc -l <<< "$found")" != 1 ]; then
    die "expected exactly one package of $1 $version in $dir"
  fi
  echo "$found"
}

package="$(package_file "$app")"
# The plugin packages the call names and the meta package, and no package
# the call does not name.
plugin_packages=()
if [ "${#plugin_ids[@]}" -gt 0 ]; then
  [ -n "$plugins_dir" ] || die "plugins without plugins-dir"
  for id in "${plugin_ids[@]}"; do
    plugin_packages+=("$(package_file "$app-plugin-$id")")
  done
  meta_package="$(package_file "$app-plugins")"
fi
expected=$((1 + ${#plugin_packages[@]} + (${#plugin_packages[@]} > 0 ? 1 : 0)))
[ "$(find "$dir" -maxdepth 1 -name "*.$format" | wc -l)" -eq "$expected" ] \
  || die "expected $expected .$format file(s) in $dir, the package and its plugin packages: $(find "$dir" -maxdepth 1 -name "*.$format" -printf '%f ')"
echo "smoke test of $(basename "$package")"

# Only what the package declares is installed with it: recommended packages
# are left out, so a missing dependency shows.
case "$format" in
  deb)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$package"
    installed="$(dpkg-query --show --showformat '${Version}' "$app")"
    ;;
  rpm)
    dnf -y --setopt=install_weak_deps=False install "$package"
    installed="$(rpm --query --queryformat '%{VERSION}' "$app")"
    ;;
  *) die "unknown format $format" ;;
esac
[ "$installed" = "$version" ] || die "installed $app is version $installed, expected $version"

# From a directory that is not the package's, so that the PATH finds it.
cd /
command -v "$binary" > /dev/null || die "$binary is not on the PATH after installing $app"
echo "\$ $binary --version"
"$binary" --version

entry=""
if [ -n "$desktop" ]; then
  entry="/usr/share/applications/$(basename "$desktop")"
  [ -f "$entry" ] || die "the package does not install $entry"
fi

smoke_command package ""

tarball="$(find "$dir" -maxdepth 1 -name '*.tar.gz' | sort)"
tarball_entry=""
if [ -n "$tarball" ]; then
  [ "$(wc -l <<< "$tarball")" = 1 ] || die "more than one tarball in $dir"
  echo "smoke test of $(basename "$tarball")"
  name="$(basename "$tarball" .tar.gz)"
  unpacked="$(mktemp -d)"
  tar --extract --gzip --file "$tarball" --directory "$unpacked"
  [ "$(ls -A "$unpacked")" = "$name" ] || die "the tarball's one top-level folder is not $name"
  cd "$unpacked/$name"
  [ -x "./$binary" ] || die "no executable $binary at the top of the tarball"
  # The package installed above brought the libraries the binary needs.
  echo "\$ ./$binary --version"
  "./$binary" --version
  if [ -n "$desktop" ]; then
    tarball_entry="$unpacked/$name/share/applications/$(basename "$desktop")"
    [ -f "$tarball_entry" ] || die "the tarball has no share/applications/$(basename "$desktop")"
  fi
  smoke_command tarball "$unpacked/$name"
  find . -type f | sort | sed -n '1,40p'
  cd /
fi

# --- the plugin packages -----------------------------------------------------

# What a package file asks for, one dependency per line.
requires() {
  case "$format" in
    deb) dpkg-deb --field "$1" Depends | sed 's/, */\n/g' ;;
    rpm) rpm --query --package --nosignature --requires "$1" ;;
  esac
}
# A dependency on exactly this version of a package, in the format's syntax.
exactly() {
  case "$format" in
    deb) echo "$1 (= $version)" ;;
    rpm) echo "$1 = $version" ;;
  esac
}
install_files() {
  case "$format" in
    deb) apt-get install -y --no-install-recommends "$@" ;;
    rpm) dnf -y --setopt=install_weak_deps=False install "$@" ;;
  esac
}
installed_version() {
  case "$format" in
    deb) dpkg-query --show --showformat '${Version}' "$1" 2> /dev/null || true ;;
    rpm) rpm --query --queryformat '%{VERSION}' "$1" 2> /dev/null || true ;;
  esac
}
# The paths an installed package owns.
owned() {
  case "$format" in
    deb) dpkg-query --listfiles "$1" ;;
    rpm) rpm --query --list "$1" ;;
  esac
}
# installed_plugin ID: the plugin's package is installed in this version,
# and what it owns is its folder of the plugins directory, the files in it,
# and nothing anywhere else.
installed_plugin() {
  local id="$1" name="$app-plugin-$1" folder="$plugins_dir/$1" path
  [ "$(installed_version "$name")" = "$version" ] || die "$name is not installed in version $version"
  [ -d "$folder" ] || die "$name does not install $folder"
  [ -n "$(find "$folder" -type f -print -quit)" ] || die "$name installs no file in $folder"
  while IFS= read -r path; do
    case "$path" in
      "$folder" | "$folder"/*) [ -e "$path" ] || die "$name lists $path, which is not on disk" ;;
      # dpkg also lists the directories above: the root, and each one on
      # the way down.
      /. | "") ;;
      *) [ "${folder#"$path"/}" != "$folder" ] || die "$name installs $path, outside $folder" ;;
    esac
  done < <(owned "$name")
  echo "$name $version is installed in $folder"
}

if [ "${#plugin_packages[@]}" -gt 0 ]; then
  cd /
  for i in "${!plugin_ids[@]}"; do
    id="${plugin_ids[$i]}"
    file="${plugin_packages[$i]}"
    # A plugin fits the build it was made with: its package says so.
    requires "$file" | grep -qxF "$(exactly "$app")" \
      || die "$(basename "$file") does not depend on $(exactly "$app"): $(requires "$file" | paste -sd ',')"
    # With identical files in two packages rpm would say nothing.
    [ ! -e "$plugins_dir/$id" ] || die "the main package already installs $plugins_dir/$id; the plugin's folder belongs to its own package only"
  done
  for id in "${plugin_ids[@]}"; do
    requires "$meta_package" | grep -qxF "$(exactly "$app-plugin-$id")" \
      || die "$(basename "$meta_package") does not depend on $(exactly "$app-plugin-$id")"
  done

  # One alone, on top of the main package.
  echo "smoke test of $(basename "${plugin_packages[0]}")"
  install_files "${plugin_packages[0]}"
  installed_plugin "${plugin_ids[0]}"
  for id in "${plugin_ids[@]:1}"; do
    [ ! -e "$plugins_dir/$id" ] || die "installing $app-plugin-${plugin_ids[0]} also installed $plugins_dir/$id"
  done
  # The rest through the meta package, which asks for every one of them.
  echo "smoke test of $(basename "$meta_package")"
  install_files "$meta_package" "${plugin_packages[@]:1}"
  [ "$(installed_version "$app-plugins")" = "$version" ] || die "$app-plugins is not installed in version $version"
  for id in "${plugin_ids[@]}"; do
    installed_plugin "$id"
  done
  [ "$(installed_version "$app")" = "$version" ] || die "the plugin packages changed $app to $(installed_version "$app")"

  smoke_command plugins ""

  # Removing a plugin's package takes its folder along, and leaves the app.
  case "$format" in
    deb) apt-get remove -y "$app-plugin-${plugin_ids[0]}" ;;
    rpm) dnf -y remove "$app-plugin-${plugin_ids[0]}" ;;
  esac
  [ ! -e "$plugins_dir/${plugin_ids[0]}" ] || die "removing $app-plugin-${plugin_ids[0]} left $plugins_dir/${plugin_ids[0]} behind"
  [ "$(installed_version "$app")" = "$version" ] || die "removing a plugin package removed $app"
  echo "the plugin packages passed"
fi

if [ -n "$desktop" ]; then
  case "$format" in
    deb) apt-get install -y --no-install-recommends desktop-file-utils ;;
    rpm) dnf -y --setopt=install_weak_deps=False install desktop-file-utils ;;
  esac
  for file in "$entry" "$tarball_entry"; do
    [ -n "$file" ] || continue
    desktop-file-validate "$file"
    echo "desktop entry $file is valid"
  done
fi

echo "smoke test passed"
