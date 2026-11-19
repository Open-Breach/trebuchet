#!/bin/sh
# The user's side of the apt repository, run as root in a container of a deb
# target: add the key and the source the way docs/install.md says, then
# install from it.
#
#   apt.sh accept URL KEYRING SUITE PACKAGE NEWEST OLDER
#   apt.sh reject URL KEYRING SUITE
#
# accept: `apt-get update` verifies the suite with KEYRING, PACKAGE installs
# in version NEWEST and downgrades to OLDER. reject: KEYRING is not the key
# the suite was signed with, and apt has to refuse it.
set -eu

mode="$1" url="$2" keyring="$3" suite="$4"
export DEBIAN_FRONTEND=noninteractive

install -D -m 644 "$keyring" /etc/apt/keyrings/openbreach.gpg
echo "deb [signed-by=/etc/apt/keyrings/openbreach.gpg] $url $suite main" \
  > /etc/apt/sources.list.d/openbreach.list

# Only this source, so that the test needs no network, and any warning is an
# error, so that a signature apt merely complains about fails the test.
update() {
  apt-get update \
    -o Dir::Etc::sourcelist=sources.list.d/openbreach.list \
    -o Dir::Etc::sourceparts=- \
    -o APT::Get::List-Cleanup=0 \
    -o APT::Update::Error-Mode=any
}

if [ "$mode" = reject ]; then
  if update; then
    echo "FAIL: apt accepted $suite with a key it was not signed with" >&2
    exit 1
  fi
  echo "apt refused $suite with the wrong key, as it should"
  exit 0
fi

package="$5" newest="$6" older="$7"
update
apt-get install -y "$package"
got="$("$package" --version)"
[ "$got" = "$package $newest" ] || {
  echo "FAIL: installed '$got', expected '$package $newest'" >&2
  exit 1
}
apt-get install -y --allow-downgrades "$package=$older"
got="$("$package" --version)"
[ "$got" = "$package $older" ] || {
  echo "FAIL: after the downgrade '$got', expected '$package $older'" >&2
  exit 1
}
echo "apt: $suite: $package $newest installed, downgraded to $older"
