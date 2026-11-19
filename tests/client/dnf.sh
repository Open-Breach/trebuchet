#!/bin/sh
# The user's side of the dnf repository, run as root in a container of an rpm
# target: add the repository the way docs/install.md says, then install from
# it.
#
#   dnf.sh accept URL KEY PACKAGE NEWEST OLDER
#   dnf.sh reject URL KEY PACKAGE
#
# URL is the root of the rpm repositories and KEY the armoured public key.
# accept: dnf verifies repomd.xml with KEY, PACKAGE installs in version NEWEST
# and downgrades to OLDER. reject: KEY is not the key the repository was
# signed with, and dnf has to refuse it.
set -eu

mode="$1" url="$2" key="$3" package="$4"

# \$releasever and \$basearch are dnf's: the Fedora version and the
# architecture of the machine.
cat > /etc/yum.repos.d/openbreach.repo << EOF2
[openbreach]
name=Open-Breach
baseurl=$url/fedora-\$releasever/\$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file://$key
EOF2

# Only this repository, so that the test needs no network.
if [ "$mode" = reject ]; then
  if dnf -y --repo openbreach install "$package"; then
    echo "FAIL: dnf accepted the repository with a key it was not signed with" >&2
    exit 1
  fi
  echo "dnf refused the repository with the wrong key, as it should"
  exit 0
fi

newest="$5" older="$6"
dnf -y --repo openbreach install "$package"
got="$("$package" --version)"
[ "$got" = "$package $newest" ] || {
  echo "FAIL: installed '$got', expected '$package $newest'" >&2
  exit 1
}
dnf -y --repo openbreach downgrade "$package-$older"
got="$("$package" --version)"
[ "$got" = "$package $older" ] || {
  echo "FAIL: after the downgrade '$got', expected '$package $older'" >&2
  exit 1
}
echo "dnf: $package $newest installed, downgraded to $older"
