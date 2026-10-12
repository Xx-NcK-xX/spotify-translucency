#!/usr/bin/env bash
# Spotify translucency installer for Linux and macOS.
#
#   ./install.sh                 install / repair (uses saved opacity, default 79)
#   ./install.sh --opacity 70    set window opacity in percent (saved for next time)
#   ./install.sh --font "Name"   use an installed font (saved for next time)
#   ./install.sh --font my.ttf   embed a font file: .ttf .otf .woff .woff2 (saved)
#   ./install.sh --font none     go back to Spotify's own font
#   ./install.sh --uninstall     restore the original Spotify files and settings
#
# Two parts:
#   1. Patches Spotify's UI bundle (Apps/xpui.spa) with spotify-translucency.css,
#      which removes the album-art tint/gradients so the window is one flat colour.
#   2. Makes the window itself translucent. Spotify's CEF window cannot be
#      transparent from CSS, so this uses the desktop's compositor:
#      GNOME -> bundled Spotify Translucency extension, KDE -> KWin window rule,
#      others -> printed instructions. macOS has no supported way (see README).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CSS_SRC="$HERE/spotify-translucency.css"
CSS_NAME="spotify-translucency.css"
LINK="<link href=\"/$CSS_NAME\" rel=\"stylesheet\">"
FONT_FAMILY_CUSTOM="SpotifyTranslucencyCustomFont"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spotify-translucency"
CONFIG="$CONFIG_DIR/config"
DEFAULT_OPACITY=79
OS=$(uname -s)

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------- arguments
ACTION=install
OPACITY=""
FONT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--opacity)  [ $# -ge 2 ] || die "$1 needs a value"; OPACITY=$2; shift 2 ;;
    --opacity=*)   OPACITY=${1#*=}; shift ;;
    -f|--font)     [ $# -ge 2 ] || die "$1 needs a value"; FONT=$2; shift 2 ;;
    --font=*)      FONT=${1#*=}; shift ;;
    -u|--uninstall) ACTION=uninstall; shift ;;
    -h|--help)     usage 0 ;;
    *)             warn "unknown option: $1"; usage 1 ;;
  esac
done

saved_opacity() {
  [ -f "$CONFIG" ] && sed -n 's/^OPACITY=\([0-9][0-9]*\)$/\1/p' "$CONFIG" | head -n1
}

saved_font() {
  [ -f "$CONFIG" ] && sed -n 's/^FONT=//p' "$CONFIG" | head -n1
}

if [ -z "$OPACITY" ]; then
  OPACITY=$(saved_opacity || true)
  OPACITY=${OPACITY:-$DEFAULT_OPACITY}
fi
case "$OPACITY" in ''|*[!0-9]*) die "opacity must be a whole number from 10 to 100" ;; esac
[ "$OPACITY" -ge 10 ] && [ "$OPACITY" -le 100 ] || die "opacity must be from 10 to 100 (got $OPACITY)"

# Font: empty = keep saved choice; "none" = Spotify's font; a file = embed it;
# anything else = the name of an installed font family.
FONT_FILE=""      # path of a font file to embed (stored in CONFIG_DIR)
FONT_FAMILY=""    # CSS family name to use
if [ -z "$FONT" ]; then FONT=$(saved_font || true); fi
case "$FONT" in
  ""|none|NONE|default) FONT="" ;;
  *.ttf|*.otf|*.woff|*.woff2|*.TTF|*.OTF|*.WOFF|*.WOFF2)
    [ -f "$FONT" ] || die "font file not found: $FONT"
    ext=$(printf '%s' "${FONT##*.}" | tr 'A-Z' 'a-z')
    stored="$CONFIG_DIR/custom-font.$ext"
    if [ "$(cd "$(dirname "$FONT")" && pwd)/$(basename "$FONT")" != "$stored" ]; then
      mkdir -p "$CONFIG_DIR"
      rm -f "$CONFIG_DIR"/custom-font.*
      cp "$FONT" "$stored"
    fi
    FONT=$stored FONT_FILE=$stored FONT_FAMILY=$FONT_FAMILY_CUSTOM ;;
  *)
    case "$FONT" in *[!A-Za-z0-9\ _.-]*) die "font name may only contain letters, numbers, spaces, _ . -" ;; esac
    FONT_FAMILY=$FONT ;;
esac

# ---------------------------------------------------------- locate Spotify
find_spa() {
  if [ -n "${SPOTIFY_XPUI:-}" ]; then echo "$SPOTIFY_XPUI"; return; fi
  local c
  if [ "$OS" = Darwin ]; then
    for c in "/Applications/Spotify.app/Contents/Resources/Apps/xpui.spa" \
             "$HOME/Applications/Spotify.app/Contents/Resources/Apps/xpui.spa"; do
      [ -f "$c" ] && { echo "$c"; return; }
    done
  else
    for c in /usr/share/spotify/Apps/xpui.spa \
             /opt/spotify/Apps/xpui.spa \
             /usr/lib/spotify/Apps/xpui.spa \
             "$HOME/.local/share/spotify-launcher/install/usr/share/spotify/Apps/xpui.spa" \
             /var/lib/flatpak/app/com.spotify.Client/current/active/files/extra/share/spotify/Apps/xpui.spa \
             "$HOME/.local/share/flatpak/app/com.spotify.Client/current/active/files/extra/share/spotify/Apps/xpui.spa"; do
      [ -f "$c" ] && { echo "$c"; return; }
    done
    if [ -d /snap/spotify ]; then
      die "Spotify is installed as a Snap, whose files are read-only. Install the .deb or Flatpak version instead (see README)."
    fi
  fi
  return 1
}

# Run a command as root only when the target is not writable by us.
as_root() {
  if [ -w "$(dirname "$SPA")" ] && { [ ! -e "$SPA" ] || [ -w "$SPA" ]; }; then "$@"; else sudo "$@"; fi
}

# ------------------------------------------------------- zip helpers
# Print one member of a zip to stdout.
spa_cat() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -p "$1" "$2" 2>/dev/null
  else
    python3 -I -c 'import sys,zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))' "$1" "$2" 2>/dev/null
  fi
}

is_patched() { spa_cat "$1" index.html | grep -q "$CSS_NAME"; }

font_member() { [ -n "$FONT_FILE" ] && echo "spotify-translucency-font.${FONT_FILE##*.}"; }

font_format() {
  case "${FONT_FILE##*.}" in
    ttf) echo truetype ;; otf) echo opentype ;; woff) echo woff ;; woff2) echo woff2 ;;
  esac
}

# make_css OUT: the stylesheet to ship, plus the font section when --font is set.
make_css() {
  cp "$CSS_SRC" "$1"
  [ -n "$FONT_FAMILY" ] || return 0
  {
    echo
    echo "/* ---- 3. Font (install.sh --font) ---- */"
    if [ -n "$FONT_FILE" ]; then
      echo "@font-face { font-family: \"$FONT_FAMILY\"; src: url(\"/$(font_member)\") format(\"$(font_format)\"); }"
    fi
    echo ":root, .encore-dark-theme, .encore-layout-themes {"
    for v in body title variable; do
      echo "  --encore-$v-font-stack: \"$FONT_FAMILY\", sans-serif !important;"
    done
    echo "  --encore-bodyMono-font-stack: \"$FONT_FAMILY\", monospace !important;"
    echo "}"
    echo "html, body, body *:not(svg):not(svg *) { font-family: \"$FONT_FAMILY\", sans-serif !important; }"
  } >> "$1"
}

# build_patched SRC DST CSS: write a copy of SRC with CSS (and any font) added and linked.
build_patched() {
  local src=$1 dst=$2 css=$3 fm; fm=$(font_member || true)
  if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    local w; w=$(mktemp -d)
    cp "$src" "$w/xpui.spa"
    unzip -q -o "$w/xpui.spa" index.html -d "$w"
    grep -q '</head>' "$w/index.html" || { rm -rf "$w"; die "unexpected Spotify layout (index.html has no </head>)"; }
    if ! grep -q "$CSS_NAME" "$w/index.html"; then
      sed "s#</head>#$LINK</head>#" "$w/index.html" > "$w/index.new" && mv "$w/index.new" "$w/index.html"
    fi
    cp "$css" "$w/$CSS_NAME"
    zip -q -d "$w/xpui.spa" 'spotify-translucency-font.*' >/dev/null 2>&1 || true
    if [ -n "$fm" ]; then
      cp "$FONT_FILE" "$w/$fm"
      (cd "$w" && zip -q xpui.spa index.html "$CSS_NAME" "$fm")
    else
      (cd "$w" && zip -q xpui.spa index.html "$CSS_NAME")
    fi
    cp "$w/xpui.spa" "$dst"
    rm -rf "$w"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I - "$src" "$dst" "$css" "$CSS_NAME" "$LINK" "$FONT_FILE" "$fm" <<'PY'
import sys, zipfile
src, dst, css_path, css_name, link, font_path, font_member = sys.argv[1:8]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename == css_name or item.filename.startswith("spotify-translucency-font."):
            continue
        data = zin.read(item.filename)
        if item.filename == "index.html":
            html = data.decode("utf-8")
            if css_name not in html:
                if "</head>" not in html:
                    sys.exit("unexpected Spotify layout (index.html has no </head>)")
                html = html.replace("</head>", link + "</head>", 1)
            data = html.encode("utf-8")
        zout.writestr(item, data)
    with open(css_path, "rb") as f:
        zout.writestr(css_name, f.read())
    if font_member:
        with open(font_path, "rb") as f:
            zout.writestr(font_member, f.read())
PY
  else
    die "need either zip+unzip or python3 to patch Spotify"
  fi
}

# ------------------------------------------------- stop / start Spotify
WAS_RUNNING=0
stop_spotify() {
  if [ "$OS" = Darwin ]; then
    pgrep -x Spotify >/dev/null 2>&1 || return 0
    WAS_RUNNING=1
    osascript -e 'quit app "Spotify"' >/dev/null 2>&1 || pkill -x Spotify || true
  else
    pgrep -x spotify >/dev/null 2>&1 || return 0
    WAS_RUNNING=1
    pkill -x spotify || true
  fi
  local i
  for i in $(seq 1 30); do
    pgrep -xi spotify >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  warn "Spotify did not quit in time; continuing anyway"
}

start_spotify() {
  [ "$WAS_RUNNING" = 1 ] || return 0
  info "Restarting Spotify"
  if [ "$OS" = Darwin ]; then
    open -a Spotify
  elif [[ "$SPA" == *flatpak* ]]; then
    (setsid flatpak run com.spotify.Client >/dev/null 2>&1 &)
  else
    local bin; bin="$(dirname "$(dirname "$SPA")")/spotify"
    [ -x "$bin" ] || bin=spotify
    (setsid "$bin" >/dev/null 2>&1 &)
  fi
}

# --------------------------------------------------- patch / unpatch
patch_spotify() {
  local bak="$SPA.translucency-backup" src="$SPA" tmp css
  css=$(mktemp)
  make_css "$css"
  if is_patched "$SPA" && spa_cat "$SPA" "$CSS_NAME" | cmp -s - "$css" &&
     { [ -z "$FONT_FILE" ] || spa_cat "$SPA" "$(font_member)" | cmp -s - "$FONT_FILE"; }; then
    info "Spotify UI already patched with the current stylesheet"
    rm -f "$css"
    return
  fi
  if is_patched "$SPA"; then
    # Re-patch from the pristine copy when we have one, so the CSS is refreshed.
    if [ -f "$bak" ] && ! is_patched "$bak"; then src=$bak; fi
  else
    # Fresh install, or Spotify updated and replaced our patch: refresh backup.
    info "Backing up original to $bak"
    as_root cp "$SPA" "$bak"
  fi
  tmp=$(mktemp)
  build_patched "$src" "$tmp" "$css"
  stop_spotify
  as_root cp "$tmp" "$SPA"
  rm -f "$tmp" "$css"
  info "Patched $SPA"
}

unpatch_spotify() {
  local bak="$SPA.translucency-backup"
  if [ -f "$bak" ]; then
    stop_spotify
    as_root cp "$bak" "$SPA"
    as_root rm -f "$bak"
    info "Restored original $SPA"
  elif is_patched "$SPA"; then
    warn "No backup found at $bak; reinstall Spotify to fully remove the patch."
  else
    info "Spotify UI is not patched"
  fi
}

# --------------------------------------------- window opacity: GNOME
BMS_UUID=blur-my-shell@aunetx
BMS_KEY=org.gnome.shell.extensions.blur-my-shell.applications
BMS_SCHEMADIR=""

bms() { gsettings ${BMS_SCHEMADIR:+--schemadir "$BMS_SCHEMADIR"} "$@"; }

bms_available() {
  gsettings list-keys "$BMS_KEY" >/dev/null 2>&1 && return 0
  local d
  for d in "$HOME/.local/share/gnome-shell/extensions/$BMS_UUID" "/usr/share/gnome-shell/extensions/$BMS_UUID"; do
    if [ -f "$d/schemas/gschemas.compiled" ]; then
      BMS_SCHEMADIR="$d/schemas"
      return 0
    fi
  done
  return 1
}

EXT_UUID=spotify-translucency@xx-nck-xx.github.io
EXT_SRC="$HERE/gnome-extension/$EXT_UUID"
EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$EXT_UUID"

# Returns 0 if the extension is running now, 1 if it starts at next login.
ext_enable() {
  gnome-extensions enable "$EXT_UUID" >/dev/null 2>&1 && return 0
  # GNOME on Wayland only discovers new extensions at login, so mark it as
  # enabled in settings and it starts at the next login.
  local list; list=$(gsettings get org.gnome.shell enabled-extensions)
  case "$list" in *"'$EXT_UUID'"*) return 1 ;; esac
  case "$list" in
    "@as []"|"[]") list="['$EXT_UUID']" ;;
    *)             list="${list%]}, '$EXT_UUID']" ;;
  esac
  gsettings set org.gnome.shell enabled-extensions "$list"
  return 1
}

gnome_apply() {
  [ -d "$EXT_SRC" ] || die "missing $EXT_SRC (keep install.sh next to the gnome-extension folder)"
  mkdir -p "$(dirname "$EXT_DIR")"
  rm -rf "$EXT_DIR"
  cp -r "$EXT_SRC" "$EXT_DIR"
  bms_revert
  if [ "$(gsettings get org.gnome.shell disable-user-extensions 2>/dev/null)" = true ]; then
    warn "GNOME user extensions are switched off; turn them on in the Extensions app."
  fi
  if ext_enable; then
    info "GNOME: Spotify window opacity set to $OPACITY% (Spotify Translucency extension)"
  else
    info "GNOME: installed the Spotify Translucency extension (opacity $OPACITY%)"
    warn "Log out and back in once to start it. After that, opacity changes apply instantly."
  fi
}

gnome_revert() {
  if ! gnome-extensions disable "$EXT_UUID" >/dev/null 2>&1; then
    local list; list=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)
    case "$list" in
      *"'$EXT_UUID'"*)
        list=$(printf '%s' "$list" | sed "s/, '$EXT_UUID'//; s/'$EXT_UUID', //; s/'$EXT_UUID'//")
        gsettings set org.gnome.shell enabled-extensions "$list" ;;
    esac
  fi
  if [ -d "$EXT_DIR" ]; then
    rm -rf "$EXT_DIR"
    info "GNOME: removed the Spotify Translucency extension"
  fi
  bms_revert
}

# v1 used Blur my Shell for the opacity; put the user's settings back.
bms_revert() {
  local before="$CONFIG_DIR/gnome-before.txt" schema key value
  [ -f "$before" ] || return 0
  bms_available || return 0
  while read -r schema key value; do
    bms set "$schema" "$key" "$value" || true
  done < "$before"
  rm -f "$before"
  info "GNOME: restored your previous Blur my Shell settings"
}

# ----------------------------------------------- window opacity: KDE
KWIN_GROUP=spotify-translucency

kde_tools() {
  KW=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
  KR=$(command -v kreadconfig6 || command -v kreadconfig5 || true)
  [ -n "$KW" ] && [ -n "$KR" ]
}

kwin_reload() {
  local q
  q=$(command -v qdbus6 || command -v qdbus || true)
  if [ -n "$q" ]; then "$q" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 && return; fi
  dbus-send --session --dest=org.kde.KWin --type=method_call /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
}

kwin_set_rules() {
  local list=$1 count=0
  [ -n "$list" ] && count=$(echo "$list" | tr ',' '\n' | grep -c .)
  "$KW" --file kwinrulesrc --group General --key rules "$list"
  "$KW" --file kwinrulesrc --group General --key count "$count"
}

kde_apply() {
  kde_tools || { warn "kwriteconfig not found; set a KWin window rule for Spotify manually (see README)."; return; }
  local g=(--file kwinrulesrc --group "$KWIN_GROUP") rules
  "$KW" "${g[@]}" --key Description "Spotify translucency"
  "$KW" "${g[@]}" --key wmclass spotify
  "$KW" "${g[@]}" --key wmclasscomplete false
  "$KW" "${g[@]}" --key wmclassmatch 2
  "$KW" "${g[@]}" --key opacityactive "$OPACITY"
  "$KW" "${g[@]}" --key opacityactiverule 2
  "$KW" "${g[@]}" --key opacityinactive "$OPACITY"
  "$KW" "${g[@]}" --key opacityinactiverule 2
  rules=$("$KR" --file kwinrulesrc --group General --key rules)
  case ",$rules," in
    *",$KWIN_GROUP,"*) ;;
    *) kwin_set_rules "${rules:+$rules,}$KWIN_GROUP" ;;
  esac
  kwin_reload
  info "KDE: Spotify window opacity set to $OPACITY% via a KWin rule"
}

kde_revert() {
  kde_tools || return 0
  local rules k
  rules=$("$KR" --file kwinrulesrc --group General --key rules)
  case ",$rules," in *",$KWIN_GROUP,"*) ;; *) return 0 ;; esac
  for k in Description wmclass wmclasscomplete wmclassmatch opacityactive opacityactiverule opacityinactive opacityinactiverule; do
    "$KW" --file kwinrulesrc --group "$KWIN_GROUP" --key "$k" --delete
  done
  rules=$(echo "$rules" | tr ',' '\n' | grep -vx "$KWIN_GROUP" | paste -sd, -)
  kwin_set_rules "$rules"
  kwin_reload
  info "KDE: removed the Spotify KWin rule"
}

other_instructions() {
  local a; a=$(awk "BEGIN{printf \"%.2f\", $OPACITY/100}")
  warn "Could not set window opacity automatically for desktop '${XDG_CURRENT_DESKTOP:-unknown}'."
  cat <<EOF
    Add one of these to your compositor config:
      Hyprland:  windowrulev2 = opacity $a $a, class:^(Spotify|spotify)\$
      Sway/i3:   for_window [class="Spotify"] opacity $a
      picom:     opacity-rule = [ "$OPACITY:class_g = 'Spotify'" ];
EOF
}

window_apply() {
  if [ "$OS" = Darwin ]; then
    warn "macOS has no built-in per-app window opacity; only the flat-colour patch was applied (see README)."
    return
  fi
  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*gnome*|*Unity*|*Budgie*) gnome_apply ;;
    *KDE*|*kde*|*Plasma*)             kde_apply ;;
    *)                                other_instructions ;;
  esac
}

window_revert() {
  [ "$OS" = Darwin ] && return 0
  gnome_revert
  kde_revert
}

# -------------------------------------------------------------- main
[ -f "$CSS_SRC" ] || die "missing $CSS_SRC (keep install.sh next to the .css file)"
SPA=$(find_spa) || die "could not find Spotify. Set SPOTIFY_XPUI=/path/to/Apps/xpui.spa and rerun."
info "Found Spotify UI bundle: $SPA"

if [ "$ACTION" = uninstall ]; then
  unpatch_spotify
  window_revert
  rm -f "$CONFIG" "$CONFIG_DIR"/custom-font.*
  start_spotify
  info "Uninstalled."
  exit 0
fi

patch_spotify
window_apply
mkdir -p "$CONFIG_DIR"
printf 'OPACITY=%s\nFONT=%s\n' "$OPACITY" "$FONT" > "$CONFIG"
info "Saved opacity $OPACITY%${FONT:+ and font '$FONT'} to $CONFIG"
start_spotify
info "Done. Re-run this script after Spotify updates to re-apply the patch."
