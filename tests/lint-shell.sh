#!/usr/bin/env bash
# Run shellcheck on every shell script in the repository: the files named
# *.sh that git tracks or would track.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t scripts < <(git ls-files --cached --others --exclude-standard -- '*.sh' | sort)
if [ "${#scripts[@]}" -eq 0 ]; then
  echo "no shell scripts found" >&2
  exit 1
fi

shellcheck --version | sed -n 's/^version: /shellcheck /p'
shellcheck --external-sources --source-path=SCRIPTDIR "${scripts[@]}"
echo "shellcheck: ${#scripts[@]} script(s) clean"
