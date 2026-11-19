#!/bin/sh
# The one-line installer as a user runs it, as root in a clean container of
# a target: fetch install.sh from the site and pipe it into sh.
#
#   install.sh URL PACKAGE VERSION
#
# URL is where the test serves the site; the script is told to use it in
# place of get.openbreach.dev.
set -eu

url="$1" package="$2" version="$3"

# A clean Debian or Ubuntu image has no curl; the user of the one-liner has.
if command -v apt-get > /dev/null && ! command -v curl > /dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends curl ca-certificates > /dev/null
fi

curl -fsSL "$url/install.sh" | OPENBREACH_REPO_URL="$url" sh -s "$package"

got="$("$package" --version)"
[ "$got" = "$package $version" ] || {
  echo "FAIL: installed '$got', expected '$package $version'" >&2
  exit 1
}

# The repository stays configured, so the package updates with the system.
if command -v apt-get > /dev/null; then
  grep -q "signed-by=/etc/apt/keyrings/openbreach.gpg" /etc/apt/sources.list.d/openbreach.list
  apt-cache policy "$package" | grep -q "$url/apt"
else
  grep -q "repo_gpgcheck=1" /etc/yum.repos.d/openbreach.repo
  dnf -q repoquery --repo openbreach "$package" | grep -q "$package"
fi

# A second run finds everything in place and succeeds.
curl -fsSL "$url/install.sh" | OPENBREACH_REPO_URL="$url" sh -s "$package" > /dev/null

# A package the repository does not have fails, and says so.
if curl -fsSL "$url/install.sh" | OPENBREACH_REPO_URL="$url" sh -s no-such-package-here > /dev/null 2>&1; then
  echo "FAIL: installing a package that does not exist succeeded" >&2
  exit 1
fi

echo "install.sh: $package $version installed"
