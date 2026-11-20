#!/usr/bin/env bash
# Run every test under tests/ (tests/test-*.sh), or the ones named.
#
#   tests/run.sh [tests/test-NAME.sh...]
#
# Needs jq, dpkg-deb, apt-ftparchive (apt-utils), rpmbuild (rpm),
# createrepo_c and gpg; on Debian or Ubuntu:
#
#   sudo apt-get install apt-utils createrepo-c rpm jq gnupg minisign
#
# The tests that install from a repository run apt and dnf in the targets'
# containers and need docker. tests/test-publish.sh also needs the AWS CLI
# and moto's S3 server; its first lines say how to get it.
# tests/test-plugin-packages.sh uses the nfpm on the PATH, or downloads the
# pinned release.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [ "$#" -eq 0 ]; then
  set -- tests/test-*.sh
fi

failed=0
for test in "$@"; do
  echo "== $test"
  if "$test"; then
    echo "== $test: passed"
  else
    echo "== $test: FAILED"
    failed=1
  fi
done
exit "$failed"
