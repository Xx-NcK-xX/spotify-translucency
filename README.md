# Spotify Translucency

**Version 2** · [Changelog](#changelog)

Makes the Spotify desktop app translucent, so your wallpaper shows through, and
removes the album-art colour tint so the whole window is one flat colour.

![Spotify with a translucent window and no album colour](assets/screenshot.png)

![Demo](assets/demo-v2.gif)

<sub>The screenshots use JetBrainsMono as the font. You can use any font with
`--font` (see [Custom font](#custom-font)).</sub>

It does three things:

1. **Flat colour**: patches Spotify's UI bundle (`Apps/xpui.spa`) with
   `spotify-translucency.css`. Spotify normally colours each page and panel
   from the album art; this resets that colour to the standard dark theme and
   removes the gradients and noise texture. A backup of the original is kept
   next to it (`xpui.spa.translucency-backup`).
2. **Translucent window**: Spotify's window can't be made see-through from
   inside the app, so this is done by the desktop:
   - **Windows**: a small hidden helper (starts at login) sets the window's opacity.
   - **Linux GNOME**: installs a small bundled GNOME extension (no other
     extensions needed). It keeps Spotify translucent on every monitor,
     including maximized and fullscreen.
   - **Linux KDE Plasma**: adds a KWin window rule.
   - **Other Linux desktops** (Hyprland, Sway, i3/picom…): the script prints the
     one line to add to your config.
   - **macOS**: no built-in way to do this, so you only get the flat colour.
3. **Custom font** (optional): use any installed font, or your own `.ttf`.

Opacity is in percent: `100` = solid, lower = more see-through. The default is
`79`. Whatever you pass is saved, so later re-runs keep your setting.

Keep all the files together in one folder.

## Custom font

Optional. Pass `--font` (Linux/macOS) or `-Font` (Windows):

| You pass | What happens |
|---|---|
| `--font "JetBrainsMono Nerd Font"` | Uses that font if it's installed on your system |
| `--font ~/Downloads/MyFont.ttf` | Embeds the file into Spotify, so it doesn't need to be installed (`.ttf`, `.otf`, `.woff`, `.woff2`) |
| `--font none` | Back to Spotify's own font |

The font is saved like the opacity, so you don't need to pass it again. A font
file is copied into the settings folder, so you can delete the original.

```bash
./install.sh --opacity 79 --font ~/Downloads/MyFont.ttf
```
```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -Opacity 79 -Font "C:\Users\me\Downloads\MyFont.ttf"
```

## Windows

Use the normal desktop Spotify from spotify.com. The Microsoft Store version
can't be modified.

- Double-click **`install-windows.cmd`**, or in PowerShell:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -Opacity 79
  ```

- Change opacity later: run it again with a new `-Opacity`. This takes effect
  within about 2 seconds, with no restart.
- Uninstall: double-click **`uninstall-windows.cmd`**, or run with `-Uninstall`.

Settings are saved in `%APPDATA%\SpotifyTranslucency\config.json`.

## Linux

```bash
chmod +x install.sh
./install.sh --opacity 79
```

- It will ask for your password (sudo) when Spotify is installed system-wide.
- **GNOME**: the first install asks you to **log out and back in once**. GNOME
  only loads new extensions at login. After that, `--opacity` changes apply
  instantly, with no restart. Upgrading from v1? Your *Blur my Shell* settings
  are put back automatically, so it's no longer used for Spotify.
- **KDE Plasma**: not tested for the fullscreen/second-monitor case fixed in v2.
  Please open an issue if Spotify turns solid when fullscreen.
- Works with the .deb/apt, AUR/`spotify-launcher` and Flatpak versions. The
  **Snap** version is read-only and can't be patched, so install the .deb or
  Flatpak instead.
- Spotify in a non-standard location:
  `SPOTIFY_XPUI=/path/to/spotify/Apps/xpui.spa ./install.sh`
- Uninstall: `./install.sh --uninstall`

Settings are saved in `~/.config/spotify-translucency/config`.

## macOS

```bash
chmod +x install.sh
./install.sh
```

- If you get "Operation not permitted": open System Settings → Privacy &
  Security → **App Management**, allow Terminal, and run it again.
- If macOS then says Spotify is "damaged", run
  `codesign --force --deep --sign - /Applications/Spotify.app` once.
- Uninstall: `./install.sh --uninstall`

## After a Spotify update

Spotify updates replace the patched file, so the album-art tint comes back.
Just run the installer again. Your saved opacity is reused.

The stylesheet was built against Spotify **1.2.95**. Spotify sometimes renames
its internal CSS classes, so on a much newer version some gradients may
reappear until `spotify-translucency.css` is updated.

## Changelog

### Version 2
- **BUG: didn't persist across other monitors.** On GNOME, Spotify turned solid
  when it covered a whole monitor (fullscreen, or maximized on a second monitor
  with no top bar). GNOME sends such windows straight to the display ("direct
  scanout"), which skips the compositor and with it the opacity. The new bundled
  GNOME extension turns that off only while a translucent Spotify window covers
  a monitor, and applies the opacity itself, so *Blur my Shell* is no longer
  needed.
- **New: custom fonts.** `--font "Name"` for an installed font, or
  `--font my.ttf` to embed your own font file. Requested in an issue.

### Version 1
- Translucent window (Windows, Linux GNOME/KDE), flat colour patch, saved
  opacity setting, backups and uninstall.

## Notes

- Opacity applies to the whole window, so text and album art become slightly
  translucent too, not only the background.
- The Windows helper was written against the Win32 API but hasn't been tested on
  a real Windows machine yet. If the window flickers or renders wrong, run the
  uninstaller.
