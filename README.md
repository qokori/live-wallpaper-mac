# Live Wallpaper for macOS

Live wallpapers for the Mac desktop: a looping video, an animated GIF, a web page (HTML/CSS/JS, WebGL shaders) or a Wallpaper Engine project under the
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

The bundle is ad-hoc signed and not notarized. The logo (black wavy stripes) is drawn by code (`Sources/LiveWallpaper/Logo.swift`, used by `scripts/make-icon.swift` for the app icon and as a template image for the menu bar and the window) and the icon is rebuilt with every `build-app.sh`: `AppIcon.icns` (older systems, the .dmg volume icon) and `Assets.car` with the Icon Composer icon (`scripts/make-assets.sh`: `make-icon.swift --icon` writes `icon.json` and the waves layer, `actool` compiles it), so the Dock recolours the icon with the macOS theme (Tinted, Clear, Dark). Outside an .app (`swift run`) the logo is set as the Dock icon at run time.

### Installer disk image

```sh
SKIP_INSTALL=1 ./scripts/build-app.sh
./scripts/make-dmg.sh build/LiveWallpaper.app build/LiveWallpaper.dmg
./scripts/make-zip.sh build/LiveWallpaper.app build/LiveWallpaper.zip   # zip and .sha256, without AppleDouble files
```

The image opens as a window with its own background (`scripts/dmg-background.swift`: white page, the logo's black wavy stripes, an arrow from the app to
Applications, a first-launch hint), a fixed window size and large icons in place; the volume has the app icon.
The window layout is written by [dmgbuild](https://github.com/dmgbuild/dmgbuild) (`scripts/dmg-settings.py`), so Finder
is not opened and no AppleScript runs. The first run installs dmgbuild (pinned) into `build/dmg-venv`, which needs the
network once; nothing is installed system-wide. A preview of the window without mounting anything:
(`dmg-background.swift` is compiled with `Sources/LiveWallpaper/Logo.swift` by `swiftc`, as `scripts/make-dmg.sh` does; command `preview <AppIcon.icns> preview.png [dark]`).

### First launch

Gatekeeper shows "Apple could not verify…" on first launch. Move the app to Applications first (don't run it from
the disk image), then once:

1. In the warning dialog click **Done** (not "Move to Trash").
2. System Settings → Privacy & Security → scroll down to "LiveWallpaper was blocked" → **Open Anyway** → password
   or Touch ID.

Or in Terminal: `xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app`, then launch normally.

On macOS 14, right-click → **Open** → **Open** also works; on macOS 15 and later it no longer bypasses the check.

## Install in one command

```sh
curl -fsSL https://raw.githubusercontent.com/qokori/live-wallpaper-mac/main/scripts/install.sh | bash
```

Downloads the latest release (`bash -s -- --version 0.4.0` for a given one), checks its SHA-256 against the `.sha256` file of the
release, unpacks it with `ditto` and puts `LiveWallpaper.app` into `/Applications` (into `~/Applications` if that is not writable).
No sudo. A file fetched by `curl` gets no quarantine mark, so Gatekeeper shows no "Apple could not verify" warning; the script
never touches the quarantine attribute. If the app is running, the script asks you to quit it and changes nothing. The app is
still ad-hoc signed and not notarized. Read the script first if you like: [scripts/install.sh](scripts/install.sh).

## Updates

Inside an `.app` the program updates itself with [Sparkle 2](https://sparkle-project.org) (pinned to 2.10.0 in `Package.swift`)
from the GitHub releases of this repository. The feed is `appcast.xml`, a file attached to each release
(`SUFeedURL` = `https://github.com/qokori/live-wallpaper-mac/releases/latest/download/appcast.xml`). It checks on launch and
every 24 hours. Every update is verified with an EdDSA signature against the public key in `Info.plist` (`SUPublicEDKey`) before
it is installed, then the app replaces itself and starts again.

- **Menu bar and window:** «Проверить обновления…» and the toggle «Обновлять автоматически» (on by default: it maps to Sparkle's
  `automaticallyDownloadsUpdates`; when off, Sparkle asks before it installs). Under `swift run` (not an `.app`) the updater is off.
- A running GIF conversion starts again after the restart.
- `scripts/build-app.sh` embeds `Sparkle.framework` into `Contents/Frameworks`, adds the rpath `@executable_path/../Frameworks`
  and signs ad-hoc from the inside out (Sparkle's XPC services, `Updater.app` and `Autoupdate`, then the framework, then the app;
  no `--deep` signing). `codesign --verify --deep --strict` passes.
- **Publishing a release** (the maintainer): build the zip with `scripts/make-zip.sh`, then
  `scripts/make-appcast.sh <version> --zip LiveWallpaper-<version>.zip --notes release-notes.md` writes `appcast.xml` next to the
  zip: it signs the zip with `sign_update --ed-key-file`, checks that the app inside has that version and points the enclosure at
  the versioned zip of the same release. Upload `appcast.xml` together with the zip, `.dmg` and the `.sha256` files.
  `scripts/test-updates.sh` checks the built app and the signing chain (a throwaway key, no network).
- **The signing key** is a plain Ed25519 seed in `~/.config/live-wallpaper/sparkle_ed25519.key` (folder mode 700, file 600), made
  by `scripts/make-sparkle-key.swift` without the keychain. It is never committed; only the public half is in the repo
  (`SPARKLE_PUBLIC_KEY` in `scripts/build-app.sh`). **Back it up** (a password manager or an encrypted volume): whoever holds it
  can publish updates, and if it is lost the installed copies accept updates signed only by a new key, so they must be
  reinstalled by hand once (`scripts/install.sh`).
- The app is ad-hoc signed and not notarized, as before; Sparkle's EdDSA signature is what protects the update channel.

## Features

- Video (mp4/mov, H.264, HEVC): `AVQueuePlayer` + `AVPlayerLooper` over the video track only, muted, no gap at
  the loop point; the display can still sleep.
- Animated GIF (and APNG): ImageIO, each frame for its own delay (a delay of 0.01 s or less is read as 0.1 s, as in
  browsers), endless loop, fill / fit / stretch like a video. Frames are decoded one at a time on a background
  queue: a picture that fits in 64 MB of decoded frames stays decoded (no decoding while it plays), a bigger one
  keeps only the frame on screen and the next one, and one bigger than the screen is decoded at screen size. No sound.
  Add it like a video: Library → Add → GIF…, drag the file into the window, or `--video clip.gif` on the command line
  (`--video` and `--video-for` take a `.gif` / `.apng` / `.png` (an APNG usually keeps the .png name; a still .png is refused) as well as a video). A GIF needs more than one frame.
  A GIF whose frames do not fit that budget is turned into an H.264 video when it is added (Library button or drag and
  drop; `--video` and `--video-for` convert the same way), kept in `~/Library/Application Support/LiveWallpaper/Converted` and removed
  once neither the library nor a screen uses it; the original file is never touched, and a failed conversion leaves the GIF as it was.
  Several at once are made one after another; the frame is scaled (not cropped) to the biggest screen, at most 4096 on the long side and 8,847,360 pixels in all (the H.264 limit). Measured: the app spent 23.7 % / 38.8 % of a core on 1280x720 / 1920x1080 GIFs
  and 0.4 % on the video made from them (reading it with `AVAssetReader` in the app's process; the system decoder that plays it is not counted).
- Web page from an http(s) address, a folder with `index.html` or an `.html` file; 15, 30 or 60 fps cap (also for Wallpaper Engine scenes, which have a quality setting too: economy, to the screen, maximum); optional
  interactive mode that forwards pointer moves and clicks on the bare desktop to the page while the Finder icons
  keep working.
- Wallpaper Engine projects (a Workshop folder copied to the Mac, a scene `.pkg` or a `project.json`): `video` projects play
  their mp4/m4v/mov, `web` projects run in the web view with the `wallpaperPropertyListener` host they expect (default settings,
  frame rate, pause); a `scene` project is drawn live: picture layers with position, rotation, scale, colour and
  transparency, video layers (muted), the blend modes "multiply" and "screen", and parallax that follows the pointer
  on every screen with a scene. Effects, particles, layer animation, text, sound and SceneScript are not drawn yet: such
  a scene looks plainer than in Wallpaper Engine, and a scene that cannot be drawn at all shows its preview ("scene: preview only"
  on its card). Library → Add → Wallpaper Engine…, drag a folder, `.pkg` or `project.json` into the window, or
  `--we <path>` / `--we-for <display UUID> <path>`; `--we-inspect <path>` prints what a project holds. Nothing is copied or unpacked.
  The library file is read entry by entry: an entry of a kind this version does not know is kept and written back unchanged.
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
- Scene quality: pictures are limited once, by the canvas size when the page loads (a later resolution change or a
  bigger screen keeps them small); the app still holds full-size pictures and the reduction happens in the page, so
  the economy level saves page memory but not app memory. Videos inside scenes are decoded whole and ignore the
  quality level; ordinary videos and GIFs are not affected by the scene settings.
- Scenes: a scene card is cached by its package and `project.json`, not by loose files in the project folder (read when there is no package); an edit to such a file shows after the app restarts.
