#!/bin/sh
# The user's side of an app's plugin packages (docs/spec.md 4.3), run as
# root in a clean container of a target: add the repository, then install a
# plugin from it the way a user does, by its package name alone.
#
#   plugins.sh apt URL KEYRING SUITE APP NEWEST OLDER
#   plugins.sh dnf URL KEY APP NEWEST OLDER
#
# The repository holds the app in two versions, and for each the plugin
# packages <app>-plugin-alpha and <app>-plugin-beta and the meta package
# <app>-plugins, made by plugins.sh of linux-packages.yml. A plugin's file
# says which version it was made with.
#
#   - Installing a plugin brings the app in the same version.
#   - A plugin of another version than the app is refused.
#   - The older pair installs together, and an upgrade moves both.
#   - The meta package brings every plugin.
#   - Removing the app takes its plugins along.
set -eu

manager="$1" url="$2" key="$3"
if [ "$manager" = apt ]; then
  suite="$4" app="$5" newest="$6" older="$7"
else
  app="$4" newest="$5" older="$6"
fi
plugins="/usr/lib/$app/plugins"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [ "$manager" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  install -D -m 644 "$key" /etc/apt/keyrings/openbreach.gpg
  echo "deb [signed-by=/etc/apt/keyrings/openbreach.gpg] $url $suite main" \
    > /etc/apt/sources.list.d/openbreach.list
  # Only this source, so that the test needs no network.
  apt-get update \
    -o Dir::Etc::sourcelist=sources.list.d/openbreach.list \
    -o Dir::Etc::sourceparts=- \
    -o APT::Get::List-Cleanup=0 \
    -o APT::Update::Error-Mode=any
  add() { apt-get install -y --no-install-recommends "$@"; }
  # A package in one version, as each manager writes it.
  at() { echo "$1=$2"; }
  version_of() { dpkg-query --show --showformat '${Version}' "$1" 2> /dev/null || true; }
  upgrade() { apt-get upgrade -y; }
  remove() { apt-get remove -y "$@"; }
  downgrade() { apt-get install -y --no-install-recommends --allow-downgrades "$@"; }
else
  cat > /etc/yum.repos.d/openbreach.repo << EOF2
[openbreach]
name=Open-Breach
baseurl=$url/fedora-\$releasever/\$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file://$key
EOF2
  add() { dnf -y --repo openbreach --setopt=install_weak_deps=False install "$@"; }
  at() { echo "$1-$2"; }
  version_of() { rpm --query --queryformat '%{VERSION}' "$1" 2> /dev/null | grep -v 'not installed' || true; }
  upgrade() { dnf -y --repo openbreach upgrade; }
  remove() { dnf -y remove "$@"; }
  downgrade() { dnf -y --repo openbreach downgrade "$@"; }
fi

# is PACKAGE VERSION: the package is installed in that version; an empty
# version means it is not installed.
is() {
  got="$(version_of "$1")"
  [ "$got" = "$2" ] || fail "$1 is '${got:-not installed}', expected '${2:-not installed}'"
}
# holds ID VERSION: the plugin's folder holds the files of that version.
holds() {
  grep -qx "$1 of $app $2" "$plugins/$1/plugin.txt" || fail "$plugins/$1/plugin.txt is not $1 of $app $2"
}

# A plugin by its name alone: the newest, and the app in the same version.
add "$app-plugin-alpha"
is "$app-plugin-alpha" "$newest"
is "$app" "$newest"
holds alpha "$newest"
[ "$("$app" --version)" = "$app $newest" ] || fail "the app that came with the plugin is not $app $newest"
[ ! -e "$plugins/beta" ] || fail "one plugin brought another"

# A plugin of another version than the app: the package manager refuses,
# and nothing changes.
if add "$(at "$app" "$newest")" "$(at "$app-plugin-alpha" "$older")"; then
  fail "$app-plugin-alpha $older was installed beside $app $newest"
fi
is "$app-plugin-alpha" "$newest"
is "$app" "$newest"
holds alpha "$newest"

# The older pair, together.
downgrade "$(at "$app" "$older")" "$(at "$app-plugin-alpha" "$older")"
is "$app" "$older"
is "$app-plugin-alpha" "$older"
holds alpha "$older"

# An upgrade moves the app and its plugin, and neither alone.
upgrade
is "$app" "$newest"
is "$app-plugin-alpha" "$newest"
holds alpha "$newest"

# The whole set through the meta package.
add "$app-plugins"
is "$app-plugins" "$newest"
is "$app-plugin-beta" "$newest"
holds beta "$newest"

# The app goes, and its plugins with it: nothing is left in their folders.
remove "$app"
is "$app" ""
is "$app-plugin-alpha" ""
is "$app-plugin-beta" ""
if [ -e "$plugins/alpha" ] || [ -e "$plugins/beta" ]; then
  fail "the plugins' folders outlived their packages"
fi

echo "$manager: $app-plugin-alpha brings $app $newest, refuses $older beside it, upgrades with it, and leaves with it"
