# Live Wallpaper for macOS

Live wallpapers for the Mac desktop: a looping video or a web page (HTML/CSS/JS, WebGL shaders) under the
desktop icons. Menu bar app, no Dock icon. AppKit, AVFoundation and WebKit; SwiftUI for the menu only; no
third-party dependencies. MIT license.

Full documentation (in Russian): [README-RU.md](README-RU.md).

## Build

Requires Xcode with Swift 6 and macOS 14 or later.

```sh
swift test                              # 48 logic tests
./scripts/build-app.sh                  # build/LiveWallpaper.app, also copied to ~/Applications
SKIP_INSTALL=1 ./scripts/build-app.sh   # build only
```

The bundle is ad-hoc signed and not notarized.

## Features

- Video (mp4/mov, H.264, HEVC): `AVQueuePlayer` + `AVPlayerLooper` over the video track only, muted, no gap at
  the loop point; the display can still sleep.
- Web page from an http(s) address, a folder with `index.html` or an `.html` file; 30 or 60 fps cap; optional
  interactive mode that forwards pointer moves and clicks on the bare desktop to the page while the Finder icons
  keep working.
- One source for all screens or one per screen; survives monitors being plugged in or out and resolution changes.
- Pauses when the wallpaper is covered (fullscreen app, another Space), the screen is locked or asleep, in Low
  Power Mode, and optionally on battery.
- Optionally sets the video's first frame as the system desktop picture, so Mission Control and login match.
- Launch at login (SMAppService), off by default.

## Scaling

Menu → **Масштаб** (Scaling) sets how a video fits a screen whose proportions differ from the video's:

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
