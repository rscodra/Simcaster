# Contributing to Simcaster

Contributions are welcome. This document covers the development setup and areas where help is most useful.

## Development setup

```bash
git clone <repo-url>
cd Simcaster
swift build

# Also compile the capture helper
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics
```

You'll need:
- macOS 14+ (Sonoma)
- Xcode 15+ with at least one iOS Simulator runtime installed
- Swift 5.10+

To test the full flow, you'll also need to grant the capture helper Screen Recording and Accessibility permissions in System Settings > Privacy & Security.

## Running locally

Terminal 1 — start the daemon:
```bash
SIMCASTER_TOKEN=dev .build/debug/simcasterd
```

Terminal 2 — interact via CLI:
```bash
SIMCASTER_TOKEN=dev .build/debug/simcasterctl health
SIMCASTER_TOKEN=dev .build/debug/simcasterctl devices
SIMCASTER_TOKEN=dev .build/debug/simcasterctl boot --udid <UDID>
open -a Simulator
SIMCASTER_TOKEN=dev .build/debug/simcasterctl watch --udid <UDID>
```

Open the printed URL in a browser to verify the viewer works.

## Project layout

| Directory | What it does |
|-----------|-------------|
| `Sources/SimcasterCore/` | Shared Codable types used by both daemon and CLI |
| `Sources/SimcasterDaemon/` | Hummingbird HTTP+WS server, split across multiple files |
| `Sources/SimcasterCLI/` | ArgumentParser CLI that talks to the daemon |
| `CaptureHelper/` | Standalone ScreenCaptureKit + CGEvent capture app |
| `Spike/CaptureSpike.app/` | Pre-built `.app` bundle for the capture helper |

Daemon source files:

| File | Responsibility |
|------|---------------|
| `main.swift` | Routes and server startup |
| `SessionStore.swift` | Thread-safe in-memory session storage |
| `CaptureManager.swift` | Capture helper process lifecycle, health monitoring, IPC |
| `AuthMiddleware.swift` | Token auth (master token + per-session viewer tokens) |
| `FrameWatcher.swift` | kqueue directory watcher for frame file changes |
| `Viewer.swift` | Mobile-first HTML/JS viewer template |
| `Helpers.swift` | simctl wrapper, JSON encoding, LAN IP detection, string escaping |

## Areas where help is needed

### Adaptive quality / video codec streaming

The biggest remaining performance opportunity. JPEG-per-frame works but doesn't compress well during motion. Adaptive JPEG quality (lower during fast changes, higher when static) would be a quick win. Longer term, streaming H.264 via WebSocket or WebRTC would be a step change.

### Multiple capture helper instances

Frame paths are per-session, but the capture helper is still a single process. Running multiple simulators simultaneously would need separate helper instances, each targeting a different window. The daemon would need to track which helper owns which session.

### Test coverage

There are currently no automated tests. Good starting points:
- Unit tests for `SessionStore` (add/get/update/remove, thread safety)
- Unit tests for command JSON serialization
- Unit tests for coordinate normalization and escaping functions
- Integration tests for the daemon HTTP API (these need a running Hummingbird instance but not a simulator)

### Non-US keyboard layouts

The keycode table in `SimcasterCapture.swift` maps US QWERTY only. Supporting other layouts would require either detecting the active input source or expanding the mapping table.

## Code style

- Swift 5.10, strict concurrency where possible (`@unchecked Sendable` with NSLock where needed)
- No SwiftFormat/SwiftLint configured — just keep it consistent with what's there
- Prefer explicit types over inference in public APIs
- Keep dependencies minimal

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Verify `swift build` compiles and the basic flow works (daemon start → create session → viewer loads)
4. Open a PR with a clear description of what changed and why
