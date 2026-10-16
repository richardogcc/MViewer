# MViewer

Blazing-fast native image & video viewer for macOS. Open anything instantly.

Pure Swift + AppKit with zero dependencies — a ~200 KB binary that decodes with
the system's own ImageIO and AVFoundation, so it launches in a blink and
supports every format macOS knows:

- **Images**: JPG, PNG, GIF, WebP, TIFF, HEIC/HEIF, AVIF, BMP, PSD, EXR, JPEG 2000…
- **Camera RAW**: NEF, ARW, CR2/CR3, RAF, ORF, RW2, DNG, PEF, SRW, and more
- **Animated**: GIF, animated WebP, APNG
- **Video**: MP4, MOV, M4V, 3GP, MTS/M2TS

## Why it opens fast

- Minimal AppKit binary — no storyboards, no third-party frameworks.
- Shows the file's embedded preview **immediately** (for RAW it extracts the
  in-file JPEG in milliseconds) or a downsampled decode, then swaps in the
  full-resolution image in the background without touching your zoom.
- Prefetches neighboring files while you browse a folder with the arrow keys,
  backed by an in-memory cache.

## Install

Download `MViewer-x.y.z.dmg` from [Releases](../../releases), open it and drag
**MViewer** to **Applications**.

> **First launch**: the app is not notarized (no Apple Developer account), so
> macOS will warn you. Right-click `MViewer.app` → **Open** → **Open**, or run:
>
> ```sh
> xattr -d com.apple.quarantine /Applications/MViewer.app
> ```

To make it the default viewer for a format: select a file in Finder →
**Get Info** → *Open with* → MViewer → **Change All…**

## Shortcuts

| Key | Action |
|---|---|
| `←` `→` (or `↑` `↓`) | Previous / next file in folder |
| `Space` | Next file (video: play/pause) |
| `F` / `⌃⌘F` | Full screen |
| `0` / `⌘0` | Zoom to fit |
| `1` / `⌘1` | Actual size (pixel-perfect) |
| `⌘+` (or `⌘=`) / `⌘−` | Zoom in / out |
| `⌘` + scroll, or pinch | Continuous zoom |
| Double click | Toggle fit ↔ actual size |
| `⌘O` | Open… |
| `⌘C` | Copy image (bitmap + file) |
| `⌘I` | Info sidebar (metadata, EXIF, GPS) |
| `⌘⌫` | Move to Trash |
| `3` | Toggle 360° video view |
| `H` / `?` / `⌘/` | Keyboard shortcuts overlay |
| `A` | About / version overlay |
| `Esc` | Exit full screen / close |
| `⌘,` | Settings |

The keyboard shortcuts above (all but `⌘,`) can be changed in
**Settings → Shortcuts** (`⌘,`); mouse gestures can't. Click a shortcut to
record a new one, `+` to add another (up to four per action), `×` to remove
it, the reset arrow to restore an action's defaults, or **Restore Defaults**
to reset them all. **Show in Finder** has
no default shortcut but can be given one. Almost any key can be recorded, Esc
included; click elsewhere or press `⌘.` to cancel. The pane
also works from the keyboard: Tab to a shortcut, Space or Return to record,
Delete to remove it. Assigning a shortcut that another action uses moves it
over. `⌘Q`, `⌘W`, `⌘H`, `⌥⌘H`, `⌘M` and `⌘,` stay reserved for the system.

The help overlay lists all your current shortcuts. Menu bar items show one
shortcut each, preferring one with `⌘`, `⌃` or `⌥`; **Open…** only ever shows
one with `⌘`, `⌃` or `⌥`, since it works in every window. Globe (fn) plus a
letter, number or symbol key can't be recorded and is left to the system.

Right-click the image for **Show in Finder**, **Copy Image**, **Get Info** and
**Move to Trash**. Drag & drop files or folders onto the window, or open from
the command line: `MViewer.app/Contents/MacOS/MViewer photo.nef`.

The info sidebar (⌘I) shows file details, image properties, camera EXIF
(exposure, aperture, ISO, lens…), GPS position, and a full raw metadata dump;
it follows along as you browse, and you can drag its left edge to resize it
(the width is remembered). Photos with GPS coordinates get a mini map of
where they were taken — click it to open the spot in Maps.

360° videos (Spherical Video metadata — YouTube/GoPro/Insta360 style) are
detected automatically and rendered inside a sphere: drag to look around,
scroll to zoom. Press `3` to toggle the mode manually on any video.

The window opens maximized, and images are always scaled to fill the view —
small images are stretched up, large ones fitted down. A pill at the bottom
shows your position among the viewable files in the folder.

## Build from source

Requires Xcode (or the Command Line Tools) on macOS 14+.

```sh
scripts/build_app.sh    # builds build/MViewer.app
scripts/release.sh      # additionally packages dist/MViewer-<version>.dmg
                        # and publishes the GitHub release
```

The app icon is generated programmatically:

```sh
swift scripts/make_icon.swift . && \
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns && \
rm -rf AppIcon.iconset
```

## License

[MIT](LICENSE)
