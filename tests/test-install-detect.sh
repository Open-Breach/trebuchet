#!/usr/bin/env bash
# install.sh picks the repository from /etc/os-release. Here it is given the
# os-release of the targets and of the derivatives docs/install.md lists, and
# asked with --dry-run which repository it would use. Nothing is installed
# and nothing is downloaded.
#
# The os-release files are cut down to the fields a distro of that kind
# sets; ID_LIKE and the codename of the base are what the choice hangs on.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The targets the cases below arrive at; all of targets.json has to be here
# in the end.
reached=""

# expect_target NAME TARGET OS_RELEASE_TEXT
expect_target() {
  local name="$1" target="$2" out
  printf '%s\n' "$3" > "$work/os-release"
  out="$(OPENBREACH_OS_RELEASE="$work/os-release" sh "$repo_root/install.sh" --dry-run example 2>&1)" \
    || fail "$name: install.sh --dry-run failed: $out"
  grep -q "using the Open-Breach repository for $target\$" <<< "$out" \
    || fail "$name: expected $target, got: $(head -n 1 <<< "$out")"
  case "$target" in
    fedora-*)
      # dnf's own variables, written literally into the repository file.
      # shellcheck disable=SC2016
      grep -qF 'baseurl=https://get.openbreach.dev/rpm/fedora-$releasever/$basearch' <<< "$out" || fail "$name: no dnf repository in: $out"
      grep -qF 'repo_gpgcheck=1' <<< "$out" || fail "$name: the dnf repository is not verified"
      ;;
    *)
      grep -qE "deb \[arch=[a-z0-9]+ signed-by=/etc/apt/keyrings/openbreach.gpg\] https://get.openbreach.dev/apt $target main" <<< "$out" \
        || fail "$name: no apt source for $target in: $out"
      ;;
  esac
  reached="$reached $target"
  echo "ok  $name -> $target"
}

# expect_refusal NAME PATTERN OS_RELEASE_TEXT
expect_refusal() {
  local name="$1" pattern="$2" out
  printf '%s\n' "$3" > "$work/os-release"
  if out="$(OPENBREACH_OS_RELEASE="$work/os-release" sh "$repo_root/install.sh" --dry-run example 2>&1)"; then
    fail "$name: install.sh should have refused, said: $out"
  fi
  grep -q "$pattern" <<< "$out" || fail "$name: expected a message with '$pattern', got: $out"
  echo "ok  $name refused"
}

# The apt source names the machine's architecture, so dpkg has to be there.
command -v dpkg > /dev/null || fail "this test needs dpkg"

# The base distros: every target of targets.json.
expect_target "Debian 12" debian-12 'ID=debian
VERSION_ID="12"
VERSION_CODENAME=bookworm
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'
expect_target "Debian 13" debian-13 'ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"'
expect_target "Ubuntu 24.04" ubuntu-24.04 'ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
PRETTY_NAME="Ubuntu 24.04.1 LTS"'
expect_target "Ubuntu 26.04" ubuntu-26.04 'ID=ubuntu
ID_LIKE=debian
VERSION_ID="26.04"
VERSION_CODENAME=resolute
UBUNTU_CODENAME=resolute
PRETTY_NAME="Ubuntu 26.04.1 LTS"'
expect_target "Fedora 44" fedora-44 'ID=fedora
VERSION_ID=44
PRETTY_NAME="Fedora Linux 44 (Workstation Edition)"'
expect_target "Fedora 45" fedora-45 'ID=fedora
VERSION_ID=45
PRETTY_NAME="Fedora Linux 45 (Workstation Edition)"'

# The derivatives docs/install.md lists.
expect_target "Linux Mint 22" ubuntu-24.04 'ID=linuxmint
ID_LIKE="ubuntu debian"
VERSION_ID="22"
VERSION_CODENAME=wilma
UBUNTU_CODENAME=noble
PRETTY_NAME="Linux Mint 22"'
expect_target "Pop!_OS 24.04" ubuntu-24.04 'ID=pop
ID_LIKE="ubuntu debian"
VERSION_ID="24.04"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
PRETTY_NAME="Pop!_OS 24.04 LTS"'
expect_target "Zorin OS 18" ubuntu-24.04 'ID=zorin
ID_LIKE="ubuntu debian"
VERSION_ID="18"
UBUNTU_CODENAME=noble
PRETTY_NAME="Zorin OS 18"'
expect_target "elementary OS 8" ubuntu-24.04 'ID=elementary
ID_LIKE="ubuntu debian"
VERSION_ID="8"
UBUNTU_CODENAME=noble
PRETTY_NAME="elementary OS 8"'
expect_target "KDE neon" ubuntu-24.04 'ID=neon
ID_LIKE="ubuntu debian"
VERSION_ID="24.04"
UBUNTU_CODENAME=noble
PRETTY_NAME="KDE neon 6.2"'
expect_target "LMDE 6" debian-12 'ID=linuxmint
ID_LIKE=debian
VERSION_ID="6"
VERSION_CODENAME=faye
DEBIAN_CODENAME=bookworm
PRETTY_NAME="LMDE 6 (faye)"'
expect_target "LMDE 7" debian-13 'ID=linuxmint
ID_LIKE=debian
VERSION_ID="7"
VERSION_CODENAME=gigi
DEBIAN_CODENAME=trixie
PRETTY_NAME="LMDE 7 (gigi)"'
expect_target "Nobara 44" fedora-44 'ID=nobara
ID_LIKE="rhel centos fedora"
VERSION_ID=44
PRETTY_NAME="Nobara Linux 44 (KDE Plasma)"'
expect_target "Ultramarine 44" fedora-44 'ID=ultramarine
ID_LIKE=fedora
VERSION_ID=44
PRETTY_NAME="Ultramarine Linux 44"'

# A derivative that has moved to a newer base follows it without being
# listed anywhere: its os-release names the base.
expect_target "a derivative of Ubuntu 26.04" ubuntu-26.04 'ID=example
ID_LIKE="ubuntu debian"
VERSION_ID="1"
UBUNTU_CODENAME=resolute
PRETTY_NAME="Example Linux 1"'
expect_target "a derivative that follows Fedora 45" fedora-45 'ID=example
ID_LIKE=fedora
VERSION_ID=45
PRETTY_NAME="Example Linux 45"'

# Not served this way.
expect_refusal "Arch" "AUR" 'ID=arch
PRETTY_NAME="Arch Linux"'
expect_refusal "Manjaro" "AUR" 'ID=manjaro
ID_LIKE=arch
PRETTY_NAME="Manjaro Linux"'
expect_refusal "NixOS" "not a distro this script knows" 'ID=nixos
VERSION_ID="24.11"
PRETTY_NAME="NixOS 24.11"'
expect_refusal "a Debian derivative without a codename of its base" "cannot tell which release" 'ID=example
ID_LIKE=debian
PRETTY_NAME="Example Linux"'

# What is not a package name does not reach a package manager.
printf 'ID=debian\nVERSION_ID="12"\n' > "$work/os-release"
for bad in 'rick;id' 'Rick' '--force-yes' 'a b'; do
  assert_fails env OPENBREACH_OS_RELEASE="$work/os-release" sh "$repo_root/install.sh" --dry-run "$bad"
done
assert_fails env OPENBREACH_OS_RELEASE="$work/os-release" sh "$repo_root/install.sh" --dry-run

# Every target is reached by a case above and is in the install
# documentation, so a change to targets.json cannot leave either behind.
for id in $(jq -r '.targets[].id' "$targets"); do
  case " $reached " in
    *" $id "*) ;;
    *) fail "no case in this test arrives at the target $id" ;;
  esac
  assert_contains "$repo_root/docs/install.md" "$id"
done
# And nothing above expects a target that is no longer built.
for id in $reached; do
  jq -e --arg id "$id" 'any(.targets[]; .id == $id)' "$targets" > /dev/null \
    || fail "a case in this test expects $id, which is not in targets.json"
done

echo "install.sh distro detection: ok"
