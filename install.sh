#!/usr/bin/env bash
# Spotify translucency installer for Linux and macOS.
#
#   ./install.sh                 install / repair (uses saved opacity, default 79)
#   ./install.sh --opacity 70    set window opacity in percent (saved for next time)
#   ./install.sh --uninstall     restore the original Spotify files and settings
#
# Two parts:
#   1. Patches Spotify's UI bundle (Apps/xpui.spa) with spotify-translucency.css,
#      which removes the album-art tint/gradients so the window is one flat colour.
#   2. Makes the window itself translucent. Spotify's CEF window cannot be
#      transparent from CSS, so this uses the desktop's compositor:
#      GNOME -> Blur My Shell extension, KDE Plasma -> KWin window rule,
#      others -> printed instructions. macOS has no supported way (see README).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CSS_SRC="$HERE/spotify-translucency.css"
CSS_NAME="spotify-translucency.css"
LINK="<link href=\"/$CSS_NAME\" rel=\"stylesheet\">"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spotify-translucency"
CONFIG="$CONFIG_DIR/config"
DEFAULT_OPACITY=79
OS=$(uname -s)

info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------- arguments
ACTION=install
OPACITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--opacity)  [ $# -ge 2 ] || die "$1 needs a value"; OPACITY=$2; shift 2 ;;
    --opacity=*)   OPACITY=${1#*=}; shift ;;
    -u|--uninstall) ACTION=uninstall; shift ;;
    -h|--help)     usage 0 ;;
    *)             warn "unknown option: $1"; usage 1 ;;
  esac
done

saved_opacity() {
  [ -f "$CONFIG" ] && sed -n 's/^OPACITY=\([0-9][0-9]*\)$/\1/p' "$CONFIG" | head -n1
}

if [ -z "$OPACITY" ]; then
  OPACITY=$(saved_opacity || true)
  OPACITY=${OPACITY:-$DEFAULT_OPACITY}
fi
case "$OPACITY" in ''|*[!0-9]*) die "opacity must be a whole number from 10 to 100" ;; esac
[ "$OPACITY" -ge 10 ] && [ "$OPACITY" -le 100 ] || die "opacity must be from 10 to 100 (got $OPACITY)"

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

# build_patched SRC DST: write a copy of SRC with our CSS added and linked.
build_patched() {
  local src=$1 dst=$2
  if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    local w; w=$(mktemp -d)
    cp "$src" "$w/xpui.spa"
    unzip -q -o "$w/xpui.spa" index.html -d "$w"
    grep -q '</head>' "$w/index.html" || { rm -rf "$w"; die "unexpected Spotify layout (index.html has no </head>)"; }
    if ! grep -q "$CSS_NAME" "$w/index.html"; then
      sed "s#</head>#$LINK</head>#" "$w/index.html" > "$w/index.new" && mv "$w/index.new" "$w/index.html"
    fi
    cp "$CSS_SRC" "$w/$CSS_NAME"
    (cd "$w" && zip -q xpui.spa index.html "$CSS_NAME")
    cp "$w/xpui.spa" "$dst"
    rm -rf "$w"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I - "$src" "$dst" "$CSS_SRC" "$CSS_NAME" "$LINK" <<'PY'
import sys, zipfile
src, dst, css_path, css_name, link = sys.argv[1:6]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename == css_name:
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
  local bak="$SPA.translucency-backup" src="$SPA" tmp
  if is_patched "$SPA" && spa_cat "$SPA" "$CSS_NAME" | cmp -s - "$CSS_SRC"; then
    info "Spotify UI already patched with the current stylesheet"
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
  build_patched "$src" "$tmp"
  stop_spotify
  as_root cp "$tmp" "$SPA"
  rm -f "$tmp"
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

gnome_apply() {
  if ! bms_available; then
    warn "GNOME needs the 'Blur my Shell' extension to make windows translucent."
    echo "    Install it from https://extensions.gnome.org/extension/3193/blur-my-shell/"
    echo "    (or: sudo apt install gnome-shell-extension-blur-my-shell), log out and"
    echo "    back in, then run this script again."
    return
  fi
  mkdir -p "$CONFIG_DIR"
  [ -f "$CONFIG_DIR/gnome-before.txt" ] || bms list-recursively "$BMS_KEY" > "$CONFIG_DIR/gnome-before.txt"

  local wl
  wl=$(bms get "$BMS_KEY" whitelist)
  if [[ "$wl" != *"'Spotify'"* ]]; then
    case "$wl" in
      "@as []"|"[]") wl="['Spotify', 'spotify']" ;;
      *)             wl="${wl%]}, 'Spotify', 'spotify']" ;;
    esac
    bms set "$BMS_KEY" whitelist "$wl"
  fi
  bms set "$BMS_KEY" opacity $(( (OPACITY * 255 + 50) / 100 ))
  bms set "$BMS_KEY" dynamic-opacity false
  bms set "$BMS_KEY" customize true
  bms set "$BMS_KEY" sigma 0
  bms set "$BMS_KEY" blur true
  gnome-extensions enable "$BMS_UUID" >/dev/null 2>&1 || true
  if [ "$(bms get "$BMS_KEY" enable-all)" = true ]; then
    warn "Blur my Shell 'blur all applications' is on, so this opacity applies to every window."
  fi
  info "GNOME: Spotify window opacity set to $OPACITY% via Blur my Shell"
}

gnome_revert() {
  local before="$CONFIG_DIR/gnome-before.txt" schema key value
  [ -f "$before" ] || return 0
  bms_available || return 0
  while read -r schema key value; do
    bms set "$schema" "$key" "$value" || true
  done < "$before"
  rm -f "$before"
  info "GNOME: restored previous Blur my Shell settings"
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
  rm -f "$CONFIG"
  start_spotify
  info "Uninstalled."
  exit 0
fi

patch_spotify
window_apply
mkdir -p "$CONFIG_DIR"
printf 'OPACITY=%s\n' "$OPACITY" > "$CONFIG"
info "Saved opacity $OPACITY% to $CONFIG"
start_spotify
info "Done. Re-run this script after Spotify updates to re-apply the patch."
