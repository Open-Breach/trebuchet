#!/bin/sh
# Install an Open-Breach package from the repositories on get.openbreach.dev.
#
#   curl -fsSL https://get.openbreach.dev/install.sh | sh -s rick
#
# What it does, and nothing else:
#
#   1. reads /etc/os-release to find the distro, or the distro this one is
#      based on;
#   2. adds the Open-Breach repository for it, with the Open-Breach signing
#      key (apt: /etc/apt/keyrings/openbreach.gpg and
#      /etc/apt/sources.list.d/openbreach.list; dnf:
#      /etc/yum.repos.d/openbreach.repo);
#   3. installs the packages named on the command line with apt or dnf.
#
# From then on the packages update and uninstall with the system's own
# tools. The same steps by hand, and the list of distros, are in
# https://github.com/Open-Breach/trebuchet/blob/main/docs/install.md
#
#   --dry-run    say what would be done and change nothing
#
# The source of this script is
# https://github.com/Open-Breach/trebuchet/blob/main/install.sh
set -eu

# Where the repositories are. Another value is for a mirror, or for a test.
base_url="${OPENBREACH_REPO_URL:-https://get.openbreach.dev}"
docs_url="https://github.com/Open-Breach/trebuchet/blob/main/docs/install.md"
os_release="${OPENBREACH_OS_RELEASE:-/etc/os-release}"

dry_run=""
sudo=""

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

# Run a command that changes the system, as root; with --dry-run, only show it.
run() {
  if [ -n "$dry_run" ]; then
    say "  would run: $*"
  else
    say "  $*"
    $sudo "$@"
  fi
}

have() {
  command -v "$1" > /dev/null 2>&1
}

# fetch URL: print what is at URL.
fetch() {
  if have curl; then
    curl -fsSL "$1"
  elif have wget; then
    wget -qO- "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

# write_file PATH: write standard input to PATH as root, readable by all.
write_file() {
  if [ -n "$dry_run" ]; then
    say "  would write $1:"
    sed 's/^/    /'
  else
    say "  writing $1"
    $sudo tee "$1" > /dev/null
    $sudo chmod 644 "$1"
  fi
}

# has_word LIST WORD: is WORD one of the space-separated words of LIST?
has_word() {
  case " $1 " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# The Ubuntu release a codename stands for; a derivative names its base by
# codename (UBUNTU_CODENAME).
ubuntu_version() {
  case "$1" in
    jammy) echo 22.04 ;;
    noble) echo 24.04 ;;
    resolute) echo 26.04 ;;
    *) echo "" ;;
  esac
}

# The same for Debian (DEBIAN_CODENAME).
debian_version() {
  case "$1" in
    bullseye) echo 11 ;;
    bookworm) echo 12 ;;
    trixie) echo 13 ;;
    forky) echo 14 ;;
    *) echo "" ;;
  esac
}

# Set `format` (deb or rpm) and `target` (the suite or repository, such as
# ubuntu-24.04) from os-release. A derivative gets the target of its base:
# Linux Mint 22 that of Ubuntu 24.04, LMDE 7 that of Debian 13, Nobara that
# of the Fedora release it follows. Which releases have a repository is not
# written down here: the script works the name out and asks the server.
detect() {
  [ -r "$os_release" ] || die "cannot read $os_release; see $docs_url for the manual steps"
  ID="" ID_LIKE="" VERSION_ID="" UBUNTU_CODENAME="" DEBIAN_CODENAME="" PRETTY_NAME=""
  # shellcheck source=/dev/null
  . "$os_release"
  distro="${PRETTY_NAME:-$ID}"
  format=""
  target=""

  if [ "$ID" = ubuntu ]; then
    format=deb target="ubuntu-$VERSION_ID"
  elif [ "$ID" = debian ]; then
    format=deb target="debian-$VERSION_ID"
  elif [ "$ID" = fedora ]; then
    format=rpm target="fedora-$VERSION_ID"
  elif has_word "$ID_LIKE" ubuntu; then
    format=deb target="ubuntu-$(ubuntu_version "$UBUNTU_CODENAME")"
  elif has_word "$ID_LIKE" debian; then
    format=deb target="debian-$(debian_version "$DEBIAN_CODENAME")"
  elif has_word "$ID_LIKE" fedora; then
    format=rpm target="fedora-$VERSION_ID"
  elif [ "$ID" = arch ] || has_word "$ID_LIKE" arch; then
    die "$distro: Open-Breach apps for Arch come from the AUR, as <package>-bin (for example: yay -S $1-bin)"
  else
    die "$distro is not a distro this script knows; see $docs_url"
  fi

  case "$target" in
    *-) die "$distro: cannot tell which release of its base distro it follows; see $docs_url for the manual steps" ;;
  esac
}

# Is there a repository for the target? A distro release that Open-Breach
# does not build for has none.
check_target() {
  case "$format" in
    deb) probe="$base_url/apt/dists/$target/InRelease" ;;
    rpm) probe="$base_url/rpm/$target/$(uname -m)/repodata/repomd.xml" ;;
  esac
  if [ -n "$dry_run" ]; then
    say "  would check that $probe exists"
  elif ! fetch "$probe" > /dev/null 2>&1; then
    die "there is no Open-Breach repository for $distro ($target, $(uname -m)); the distros with one are listed in $docs_url"
  fi
}

install_deb() {
  arch="$(dpkg --print-architecture)"
  say "Adding the Open-Breach signing key"
  run mkdir -p -m 755 /etc/apt/keyrings
  if [ -n "$dry_run" ]; then
    say "  would download $base_url/keys/openbreach.gpg to /etc/apt/keyrings/openbreach.gpg"
  else
    key="$(mktemp)"
    fetch "$base_url/keys/openbreach.gpg" > "$key" || die "could not download $base_url/keys/openbreach.gpg"
    say "  installing /etc/apt/keyrings/openbreach.gpg"
    $sudo install -m 644 "$key" /etc/apt/keyrings/openbreach.gpg
    rm -f "$key"
  fi

  say "Adding the apt repository $target"
  write_file /etc/apt/sources.list.d/openbreach.list << EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/openbreach.gpg] $base_url/apt $target main
EOF

  say "Installing $*"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_rpm() {
  say "Adding the dnf repository"
  # \$releasever and \$basearch are filled in by dnf: the Fedora release and
  # the machine's architecture. The key is fetched and imported by dnf when
  # it first reads the repository.
  write_file /etc/yum.repos.d/openbreach.repo << EOF
[openbreach]
name=Open-Breach
baseurl=$base_url/rpm/fedora-\$releasever/\$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=$base_url/keys/openbreach.asc
EOF

  say "Installing $*"
  run dnf install -y "$@"
}

main() {
  packages=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=1 ;;
      -h | --help)
        say "usage: curl -fsSL $base_url/install.sh | sh -s [--dry-run] PACKAGE..."
        say "The manual steps and the list of distros: $docs_url"
        exit 0
        ;;
      -*) die "unknown option $arg" ;;
      *)
        # A package name and nothing else reaches the package manager.
        case "$arg" in
          *[!a-z0-9+.-]* | "") die "'$arg' is not a package name" ;;
        esac
        packages="$packages $arg"
        ;;
    esac
  done
  [ -n "$packages" ] || die "name the package to install, as in: curl -fsSL $base_url/install.sh | sh -s rick"
  # shellcheck disable=SC2086 # one word per package, checked above
  set -- $packages

  detect "$1"
  say "$distro: using the Open-Breach repository for $target"

  if [ -z "$dry_run" ] && [ "$(id -u)" -ne 0 ]; then
    have sudo || die "run this as root, or install sudo"
    sudo="sudo"
  fi

  check_target
  case "$format" in
    deb) install_deb "$@" ;;
    rpm) install_rpm "$@" ;;
  esac

  [ -n "$dry_run" ] || say "Done. $* will update with the rest of the system."
}

# Called on the last line, so that a download cut short runs nothing.
main "$@"
