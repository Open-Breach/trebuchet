#!/usr/bin/env bash
# Build the fixture package the tests publish: a shell script that prints its
# version, as a .deb or .rpm for every target and architecture of
# targets.json, named the way linux-packages.yml names its packages.
#
#   tests/fixture/build.sh OUT_DIR VERSION [PACKAGE]
#
# Needs dpkg-deb and rpmbuild. The packages hold no compiled code, so every
# architecture is built on any host.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets="${TREBUCHET_TARGETS:-$here/../../targets.json}"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 OUT_DIR VERSION [PACKAGE]" >&2
  exit 2
fi
mkdir -p "$1"
out="$(cd "$1" && pwd)"
version="$2"
package="${3:-trebuchet-fixture}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/$package" <<EOF
#!/bin/sh
echo "$package $version"
EOF
chmod 755 "$work/bin/$package"

build_deb() {
  local target="$1" arch="$2" root="$work/deb-$1-$2"
  mkdir -p "$root/DEBIAN" "$root/usr/bin"
  cp "$work/bin/$package" "$root/usr/bin/$package"
  cat > "$root/DEBIAN/control" <<EOF
Package: $package
Version: $version
Architecture: $arch
Maintainer: Trebuchet tests <noreply@openbreach.dev>
Section: misc
Priority: optional
Description: Trebuchet test fixture for $target
 Prints its version. Published by the tests only.
EOF
  dpkg-deb --root-owner-group --build "$root" \
    "$out/${package}_${version}_${target}_${arch}.deb" > /dev/null
}

build_rpm() {
  local target="$1" arch="$2" top="$work/rpm-$1-$2"
  mkdir -p "$top/SPECS"
  cat > "$top/SPECS/$package.spec" <<EOF
Name: $package
Version: $version
Release: 1
Summary: Trebuchet test fixture for $target
License: Apache-2.0
AutoReqProv: no

%description
Prints its version. Published by the tests only.

%install
install -D -m 755 "$work/bin/$package" "%{buildroot}/usr/bin/$package"

%files
/usr/bin/$package
EOF
  rpmbuild --quiet -bb --target "$arch" \
    --define "_topdir $top" \
    --define "_build_id_links none" \
    "$top/SPECS/$package.spec" > "$top/rpmbuild.log" 2>&1 || {
    cat "$top/rpmbuild.log" >&2
    exit 1
  }
  cp "$top/RPMS/$arch/$package-$version-1.$arch.rpm" \
    "$out/$package-$version-1.$target.$arch.rpm"
}

while read -r target format; do
  case "$format" in
    deb)
      for arch in $(jq -r '.arches[].deb' "$targets"); do build_deb "$target" "$arch"; done
      ;;
    rpm)
      for arch in $(jq -r '.arches[].rpm' "$targets"); do build_rpm "$target" "$arch"; done
      ;;
    *)
      echo "$target: unknown format $format" >&2
      exit 1
      ;;
  esac
done < <(jq -r '.targets[] | "\(.id) \(.format)"' "$targets")
