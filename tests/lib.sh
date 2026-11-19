# Shared by the tests under tests/; sourced, not run.
# shellcheck shell=bash

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets="${TREBUCHET_TARGETS:-$repo_root/targets.json}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file $1"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "$1 should not exist"
}

# assert_contains FILE FIXED_STRING
assert_contains() {
  grep -qF -- "$2" "$1" || fail "$1 does not contain: $2"
}

# assert_fails COMMAND...: the command must exit non-zero.
assert_fails() {
  if "$@" > /dev/null 2>&1; then
    fail "expected to fail: $*"
  fi
}

# The targets of one package format, one id per line.
targets_of() {
  jq -r --arg format "$1" '.targets[] | select(.format == $format) | .id' "$targets"
}

# The architecture names of one package format, one per line.
arches_of() {
  jq -r --arg format "$1" '.arches[][$format]' "$targets"
}

# Print a repodata file of the given kind (primary, filelists, ...) of the dnf
# repository in DIR, whatever createrepo_c compressed it with.
repodata() {
  local dir="$1" kind="$2" file
  file="$(find "$dir/repodata" -name "*-$kind.xml.*" | head -n 1)"
  [ -n "$file" ] || fail "no $kind metadata in $dir/repodata"
  case "$file" in
    *.gz) gzip -dc "$file" ;;
    *.zst) zstd -dc "$file" ;;
    *.xz) xz -dc "$file" ;;
    *) fail "unknown compression: $file" ;;
  esac
}
