#!/usr/bin/env bash
# Run every test under tests/ (tests/test-*.sh), or the ones named.
#
#   tests/run.sh [tests/test-NAME.sh...]
#
# Needs jq, dpkg-deb, apt-ftparchive (apt-utils), rpmbuild (rpm) and
# createrepo_c; on Debian or Ubuntu:
#
#   sudo apt-get install apt-utils createrepo-c rpm jq
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
