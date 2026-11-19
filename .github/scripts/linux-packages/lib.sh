# Shared by the scripts of linux-packages.yml; sourced, not run.
# shellcheck shell=bash

die() {
  echo "::error::$*"
  exit 1
}

# stage_icon ICON APP DEST: put the app's icon under DEST in the XDG layout,
# DEST standing for share/icons.
#
# ICON is a `hicolor` directory, copied as it is, or one file: an SVG goes to
# hicolor/scalable/apps/<app>.svg, a PNG to hicolor/<size>x<size>/apps/<app>.png
# with the size read from the file.
stage_icon() {
  local icon="$1" app="$2" dest="$3" width height
  if [ -d "$icon" ]; then
    [ "$(basename "$icon")" = hicolor ] || die "icon $icon: a directory has to be a hicolor icon theme directory"
    mkdir -p "$dest/hicolor"
    cp -R "$icon/." "$dest/hicolor/"
    return
  fi
  [ -f "$icon" ] || die "icon $icon does not exist"
  case "$icon" in
    *.svg)
      mkdir -p "$dest/hicolor/scalable/apps"
      cp "$icon" "$dest/hicolor/scalable/apps/$app.svg"
      ;;
    *.png)
      # Width and height are the two big-endian 32-bit numbers at byte 16.
      read -r width height < <(od -An -j16 -N8 -tu1 "$icon" \
        | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4, $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 }')
      if [ "${width:-0}" -le 0 ] || [ "$width" != "$height" ]; then
        die "icon $icon: not a square PNG"
      fi
      mkdir -p "$dest/hicolor/${width}x${height}/apps"
      cp "$icon" "$dest/hicolor/${width}x${height}/apps/$app.png"
      ;;
    *) die "icon $icon: an .svg file, a .png file or a hicolor directory" ;;
  esac
}
