#!/usr/bin/env bash
# actionlint on every workflow. Uses the actionlint on the PATH if there is
# one; otherwise downloads the pinned release and checks it against the
# checksum below before running it. With shellcheck on the PATH, actionlint
# also checks the `run:` scripts inside the workflows.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# From actionlint_<version>_checksums.txt of the release.
version="1.7.12"
sha256_amd64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
sha256_arm64="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"

if command -v actionlint > /dev/null; then
  actionlint="actionlint"
else
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) arch="amd64" sha256="$sha256_amd64" ;;
    Linux-aarch64) arch="arm64" sha256="$sha256_arm64" ;;
    *)
      echo "no actionlint on the PATH and no pinned download for $(uname -s) $(uname -m); install actionlint $version" >&2
      exit 1
      ;;
  esac
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  archive="actionlint_${version}_linux_${arch}.tar.gz"
  curl -fsSL -o "$dir/$archive" "https://github.com/rhysd/actionlint/releases/download/v$version/$archive"
  echo "$sha256  $dir/$archive" | sha256sum --check --quiet
  tar -xzf "$dir/$archive" -C "$dir" actionlint
  actionlint="$dir/actionlint"
fi

"$actionlint" -version | head -n 1
"$actionlint" -color
echo "actionlint: clean"
