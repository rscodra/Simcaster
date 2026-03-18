# Simcaster Development

Swift 5.10, macOS 14+. Hummingbird 2.0 HTTP+WebSocket server.

## Build

```bash
swift build
```

## Compile the capture helper

Separate from SPM — needs to be inside a .app bundle for TCC permissions:
```bash
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics
```

## Run locally

```bash
SIMCASTER_TOKEN=dev .build/debug/simcasterd &
SIMCASTER_TOKEN=dev .build/debug/simcasterctl devices
```

## Project layout

- `Sources/SimcasterDaemon/` — HTTP+WS server, routes, auth, frame watcher
- `Sources/SimcasterCLI/` — CLI tool
- `Sources/SimcasterCore/` — Shared types (Contracts.swift)
- `CaptureHelper/SimcasterCapture.swift` — ScreenCaptureKit capture + CGEvent input
- `Spike/CaptureSpike.app/` — .app bundle structure (binary not committed, compile it)

## IPC

- Frames: `/tmp/simcaster_frames/<sessionId>.jpg` (atomic write, kqueue directory watch)
- Commands: `/tmp/simcaster_cmds/<sessionId>_<timestamp>.cmd`

## Key design decisions

- Capture helper is a separate .app because ScreenCaptureKit + Accessibility TCC are per-bundle
- kqueue watches the directory, not the file — atomic writes (rename) invalidate per-file descriptors
- AsyncStream with bufferingNewest(1) drops stale frames when WebSocket can't keep up
- Viewer tokens are scoped per-session so sharing a URL doesn't expose the master token
