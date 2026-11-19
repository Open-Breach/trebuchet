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

# make_test_key HOME rsa|ed25519 [PASSPHRASE]: generate a throwaway signing
# key in a new GNUPGHOME and leave its public half beside it, as a keyring
# (public.gpg, for apt and gpgv) and armoured (public.asc, for dnf). The key
# never leaves HOME; the caller stops its agent (stop_gpg_agent) and deletes
# the directory when it is done.
make_test_key() {
  local home="$1" type="$2" passphrase="${3:-}"
  mkdir -p "$home"
  chmod 700 "$home"
  {
    case "$type" in
      rsa) printf 'Key-Type: RSA\nKey-Length: 3072\n' ;;
      ed25519) printf 'Key-Type: EDDSA\nKey-Curve: ed25519\n' ;;
      *) fail "unknown key type $type" ;;
    esac
    printf 'Key-Usage: sign\nName-Real: Trebuchet test key (%s)\nName-Email: noreply@openbreach.dev\nExpire-Date: 1d\n' "$type"
    if [ -n "$passphrase" ]; then
      printf 'Passphrase: %s\n' "$passphrase"
    else
      printf '%%no-protection\n'
    fi
    printf '%%commit\n'
  } | GNUPGHOME="$home" gpg --batch --quiet --no-tty --generate-key
  GNUPGHOME="$home" gpg --batch --quiet --no-tty --export > "$home/public.gpg"
  GNUPGHOME="$home" gpg --batch --quiet --no-tty --export --armor > "$home/public.asc"
  # The agent remembers the passphrase it was just given. Stopped, so that
  # signing needs the passphrase again, as it does on a machine that only
  # imported the key.
  stop_gpg_agent "$home"
}

# Stop the gpg-agent of a GNUPGHOME, which would otherwise outlive the test.
stop_gpg_agent() {
  GNUPGHOME="$1" gpgconf --kill gpg-agent 2> /dev/null || true
}

# The container image of a target.
image_of() {
  jq -r --arg id "$1" '.targets[] | select(.id == $id) | .image' "$targets"
}

# The tests that need a real apt or dnf run it in the target's container.
require_docker() {
  docker info > /dev/null 2>&1 || fail "this test runs apt and dnf in the targets' containers and needs a working docker"
}

# docker_run ARGS...: `docker run --rm ARGS`. TREBUCHET_TEST_DOCKER_ARGS adds
# arguments for a machine whose containers need them to reach the network,
# such as proxy settings.
docker_run() {
  local extra=()
  if [ -n "${TREBUCHET_TEST_DOCKER_ARGS:-}" ]; then
    read -r -a extra <<< "$TREBUCHET_TEST_DOCKER_ARGS"
  fi
  docker run --rm "${extra[@]}" "$@"
}

# make_site SITE GNUPGHOME VERSION...: lay out under SITE what is served at
# get.openbreach.dev, with the fixture package in the given versions and
# signed with the test key of GNUPGHOME (make_test_key, without passphrase):
#
#   SITE/apt/  SITE/rpm/  SITE/keys/openbreach.{gpg,asc}  SITE/install.sh
make_site() {
  local site="$1" gnupg="$2" packages version
  shift 2
  packages="$(mktemp -d)"
  for version in "$@"; do
    "$repo_root/tests/fixture/build.sh" "$packages" "$version" > /dev/null
  done
  "$repo_root/apt/add-packages.sh" "$site/apt" "$packages"/*.deb > /dev/null
  "$repo_root/rpm/add-packages.sh" "$site/rpm" "$packages"/*.rpm > /dev/null
  rm -rf "$packages"
  "$repo_root/apt/build-index.sh" "$site/apt" > /dev/null
  "$repo_root/rpm/build-index.sh" "$site/rpm" > /dev/null
  GNUPGHOME="$gnupg" "$repo_root/apt/sign.sh" "$site/apt" "$gnupg/public.gpg" > /dev/null
  GNUPGHOME="$gnupg" "$repo_root/rpm/sign.sh" "$site/rpm" "$gnupg/public.gpg" > /dev/null
  mkdir -p "$site/keys"
  cp "$gnupg/public.gpg" "$site/keys/openbreach.gpg"
  cp "$gnupg/public.asc" "$site/keys/openbreach.asc"
  cp "$repo_root/install.sh" "$site/install.sh"
}
