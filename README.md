<p align="center">
  <img src="docs/banner.png" alt="Robbie's Gif Capture" width="720">
</p>
 
# Robbie's GifCapture

A tiny macOS menu bar app: drag-select a region of your screen, record it, and it's
automatically converted to a GIF — like QuickTime Player's screen recording, but the
output is a shareable GIF instead of a .mov.

## How it works

- **Capture**: [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  records the selected region to a temporary H.264 `.mov` via `AVAssetWriter`.
- **Conversion**: [gifski](https://gif.ski) (a high-quality Rust GIF encoder) converts
  that video straight to GIF.
- Output GIFs land in `~/Desktop/GifCaptures/`.

## Requirements

- macOS 13+
- [gifski](https://gif.ski) is bundled inside the app. The optional ffmpeg
  encoder (selectable in Settings) uses a Homebrew ffmpeg if present:
  `brew install ffmpeg`

## Install (any Mac) — one command

Paste this in Terminal:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/RobbieCase/GifCapture/main/install.sh)"
```

It downloads the latest release, installs to `/Applications`, clears the
Gatekeeper quarantine (the build is ad-hoc signed, not notarized), and launches
the app. gifski is bundled inside the app, so there's nothing else to install —
just grant Screen Recording permission when prompted on the first recording.

Manual alternative: grab `GifCapture.zip` from the
[latest release](https://github.com/RobbieCase/GifCapture/releases/latest),
unzip, move to `/Applications`, then right-click → Open on first launch.

## Build

```
./scripts/build_app.sh
```

This produces `.build/release/GifCapture.app`, ad-hoc signed with a stable bundle
identifier (`com.robbiecase.gifcapture`) so macOS remembers your Screen Recording
permission grant across rebuilds, and installs it to `/Applications/GifCapture.app`
so you can launch it from Launchpad, Spotlight, or Finder.

> The build script compiles directly with `swiftc` rather than `swift build`, because
> this machine's Command Line Tools install is missing `BuildServerProtocol.framework`
> (a dependency of SwiftPM's newer Swift Build backend). If you have a full Xcode
> install, `swift build -c release` should also work — the `Package.swift` is there
> for that case / for opening in Xcode.

## Run

Launch **GifCapture** from Launchpad, Spotlight (⌘Space), or Finder's Applications
folder — or: `open -a GifCapture`.

A record-circle icon appears in the menu bar. On first use, macOS will prompt for
**Screen Recording** permission (System Settings → Privacy & Security → Screen
Recording) — you may need to quit and relaunch the app after granting it.

## Use

1. Click the menu bar icon → **Record New GIF…**
2. Drag to select the region you want to capture. The selection stays adjustable:
   drag the corner/edge handles to resize, drag inside it to move, click outside
   to start over (Esc cancels). Your last selection is remembered and restored
   the next time you record.
3. Click **Record** (or press Return) to start recording.
4. While recording, everything outside the box is dimmed (red border marks the
   capture area) and a timer + **Stop** button sits at the top of the box — click
   **Stop** when done. The dimming and button are excluded from the capture, so
   they never appear in the GIF.
5. The recording is converted to a GIF and revealed in Finder.

Encoder, quality, frame rate, and output size are configurable via the menu bar
icon → **Settings…**.

## Project layout

```
Sources/GifCapture/
  main.swift                    entry point (menu-bar-only app, no Dock icon)
  AppDelegate.swift             status item, menu, recording lifecycle
  SelectionOverlayController.swift  full-screen overlay windows for drag-select
  SelectionOverlayView.swift    draws the dimmed overlay + selection rectangle
  ScreenRecorder.swift          ScreenCaptureKit capture -> AVAssetWriter (.mov)
  GifConverter.swift            shells out to gifski/ffmpeg to produce the .gif
  RecordingOverlayController.swift  recording dim overlay + anchored Stop control
scripts/build_app.sh            compiles + assembles + ad-hoc signs the .app
```

## Known limits

- Only single-display selection is supported (the drag must start and end on the same screen).
- No audio capture (GIFs don't support audio anyway).
- Ad-hoc signed, not notarized — fine for local personal use, not for distribution.
