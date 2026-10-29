# Live Wallpaper for macOS

Live wallpapers for the Mac desktop: a looping video, an animated GIF or a web page (HTML/CSS/JS, WebGL shaders) under the
desktop icons. A menu bar app with a main window (library, screens, settings); the Dock icon shows only while the window is
open. AppKit, AVFoundation and WebKit; SwiftUI for the window and the menu; no third-party dependencies. MIT license.

Full documentation (in Russian): [README-RU.md](README-RU.md).

## Build

Requires Xcode with Swift 6 and macOS 14 or later.

```sh
swift test                              # logic tests and the app model / main window / GIF layer tests
./scripts/build-app.sh                  # build/LiveWallpaper.app, also copied to ~/Applications
SKIP_INSTALL=1 ./scripts/build-app.sh   # build only
```

The bundle is ad-hoc signed and not notarized. The app icon is drawn by code (`scripts/make-icon.swift`) and rebuilt with every `build-app.sh`.

### Installer disk image

```sh
SKIP_INSTALL=1 ./scripts/build-app.sh
./scripts/make-dmg.sh build/LiveWallpaper.app build/LiveWallpaper.dmg
```

The image opens as a window with its own background (`scripts/dmg-background.swift`: theme gradient, an arrow from the app to
Applications, a one-line first-launch hint), a fixed window size and large icons in place; the volume has the app icon.
The window layout is written by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (`scripts/dmg-settings.py`), so Finder
is not opened and no AppleScript runs. The first run installs dmgbuild (pinned) into `build/dmg-venv`, which needs the
network once; nothing is installed system-wide. A preview of the window without mounting anything:
`swift scripts/dmg-background.swift preview <AppIcon.icns> preview.png`.

### First launch

Gatekeeper shows "Apple could not verify…" on first launch. Move the app to Applications first (don't run it from
the disk image), then once:

1. In the warning dialog click **Done** (not "Move to Trash").
2. System Settings → Privacy & Security → scroll down to "LiveWallpaper was blocked" → **Open Anyway** → password
   or Touch ID.

Or in Terminal: `xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app`, then launch normally.

On macOS 14, right-click → **Open** → **Open** also works; on macOS 15 and later it no longer bypasses the check.

## Features

- Video (mp4/mov, H.264, HEVC): `AVQueuePlayer` + `AVPlayerLooper` over the video track only, muted, no gap at
  the loop point; the display can still sleep.
- Animated GIF (and APNG): ImageIO, each frame for its own delay (a delay of 0.01 s or less is read as 0.1 s, as in
  browsers), endless loop, fill / fit / stretch like a video. Frames are decoded one at a time on a background
  queue: a picture that fits in 64 MB of decoded frames stays decoded (no decoding while it plays), a bigger one
  keeps only the frame on screen and the next one, and one bigger than the screen is decoded at screen size. No sound.
  Add it like a video: Library → Add → GIF…, drag the file into the window, or `--video clip.gif` on the command line
  (`--video` and `--video-for` take a `.gif` / `.apng` / `.png` (an APNG usually keeps the .png name; a still .png is refused) as well as a video). A GIF needs more than one frame.
- Web page from an http(s) address, a folder with `index.html` or an `.html` file; 30 or 60 fps cap; optional
  interactive mode that forwards pointer moves and clicks on the bare desktop to the page while the Finder icons
  keep working.
- One source for all screens or one per screen; survives monitors being plugged in or out and resolution changes.
- Pauses when the wallpaper is covered (fullscreen app, another Space), the screen is locked or asleep, in Low
  Power Mode, and optionally on battery.
- Optionally sets the first frame of a video or GIF as the system desktop picture, so Mission Control and login match.
- Launch at login (SMAppService), off by default.

## Scaling

Main window → Settings → **Масштаб** (Scaling; per screen: the Screens tab) sets how a video fits a screen whose proportions differ from the video's:

| Mode | Video (`AVPlayerLayer.videoGravity`) | Desktop picture (`setDesktopImageURL`) |
| --- | --- | --- |
| Fill (default) | `resizeAspectFill`: covers the screen, crops the edges | `scaleProportionallyUpOrDown`, clipping allowed |
| Fit | `resizeAspect`: whole frame, black bars | `scaleProportionallyUpOrDown`, no clipping |
| Stretch | `resize`: covers the screen, proportions not kept | `scaleAxesIndependently`, no clipping |

It works like the source: one choice for all screens, or in per-screen mode each screen's own choice, with
«Как общий» (as shared) to follow the shared one. The choice is remembered apart from the sources, so a new video
or «Убрать обои» keeps it. A change applies at once without reloading the video, and the desktop picture is set
again with the same mode when frame sync is on. The item is greyed out for web wallpapers: a page lays itself out
in the window.

## Examples

- `examples/aurora-shader/` — WebGL aurora that follows the pointer.
- `examples/soft-lights/` — CSS-only drifting lights.

## Limitations

- macOS sets the desktop picture on the current Space only; restoring the previous picture works per screen, not
  per Space.
- Forwarded pointer events are synthetic (`isTrusted` is false); a desktop click reaches both Finder and the page.
- The same source on several screens decodes or renders once per screen.
