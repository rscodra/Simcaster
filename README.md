# Simcaster

Preview your iOS Simulator on a phone. Simcaster streams the Simulator screen over WebSocket and lets you interact with it through touch — tap, swipe, pinch, type — from any browser.

Built for developers who work remotely from a mobile device and need real-time visual feedback from Xcode builds running on a Mac elsewhere.

## How it works

Simcaster has three components:

1. **simcasterd** — a local HTTP + WebSocket server (Hummingbird 2) that manages simulator sessions and streams frames to connected viewers
2. **simcasterctl** — a CLI for managing the daemon, booting simulators, and creating viewer sessions
3. **CaptureHelper** — a background macOS app that uses ScreenCaptureKit to capture the Simulator window and CGEvent to inject touch/keyboard input

The capture helper writes JPEG frames to a per-session file in a temp directory. The daemon watches the file using macOS filesystem events (kqueue) and pushes new frames over WebSocket to any connected browser. Input flows the other way: the browser sends touch coordinates, the daemon writes command files, the capture helper reads them and injects the corresponding mouse/keyboard events into the Simulator.

```
Phone Browser ←—WebSocket—→ simcasterd ←—file IPC—→ CaptureHelper ←—CGEvent—→ Simulator
```

## Requirements

- macOS 14+ (Sonoma) — required for ScreenCaptureKit APIs
- Xcode 15+ with iOS Simulator
- Swift 5.10+

The capture helper needs two macOS permissions:
- **Screen Recording** — to capture the Simulator window
- **Accessibility** — to inject mouse and keyboard events

Both are prompted automatically on first run. You can grant them in System Settings > Privacy & Security.

## Quick start

```bash
# Build everything
swift build

# Compile the capture helper
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

# Start the daemon (set a token so the CLI can authenticate)
SIMCASTER_TOKEN=dev .build/debug/simcasterd &

# List available simulators
SIMCASTER_TOKEN=dev .build/debug/simcasterctl devices

# Boot one
SIMCASTER_TOKEN=dev .build/debug/simcasterctl boot --udid <UDID>

# Open Simulator.app (needed for window capture)
open -a Simulator

# Create a viewer session
SIMCASTER_TOKEN=dev .build/debug/simcasterctl watch --udid <UDID>
```

The `watch` command prints a URL. Open it on your phone to see the Simulator screen and interact with it.

## Remote access

Simcaster binds to `0.0.0.0` by default, so it's accessible on your local network. For access over the internet, use a tunnel:

```bash
# Using Cloudflare's free tunnel
brew install cloudflared
cloudflared tunnel --url http://localhost:4821
```

Replace the LAN IP in the viewer URL with the tunnel URL that cloudflared prints.

Expect 7–10 fps over a Cloudflare tunnel during active screen changes, and the full 15 fps on LAN.

## CLI reference

All commands support `--json` for machine-readable output. The CLI reads `SIMCASTER_TOKEN` from the environment to authenticate with the daemon.

| Command | Description |
|---------|-------------|
| `simcasterctl health` | Check if the daemon is running |
| `simcasterctl devices` | List available iOS simulators |
| `simcasterctl boot --udid <UDID>` | Boot a simulator device |
| `simcasterctl sessions` | List active viewer sessions |
| `simcasterctl watch --udid <UDID>` | Create a viewer session and print the URL |

## API

Base URL: `http://localhost:4821`

Authentication: pass the token as `?token=<TOKEN>` or `Authorization: Bearer <TOKEN>`. The token is set via the `SIMCASTER_TOKEN` environment variable (defaults to a random value on each launch). Viewer URLs use a session-scoped token that only grants access to that session's viewer, frame stream, and input endpoints.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Daemon health check |
| GET | `/api/devices` | List simulators (wraps `simctl list`) |
| POST | `/api/boot` | Boot a simulator (`{"udid": "..."}`) |
| GET | `/api/sessions` | List active sessions |
| POST | `/api/sessions` | Create a session (`{"udid": "..."}`) |
| POST | `/api/sessions/:id/stop` | Stop a session |
| GET | `/sessions/:id` | Browser viewer page |
| WS | `/ws/sessions/:id/frames` | WebSocket frame stream (binary JPEG) |

Input endpoints (all POST, all take session ID in path):

| Path | Body | Description |
|------|------|-------------|
| `/api/sessions/:id/tap` | `{"x": 0.5, "y": 0.3}` | Tap at normalized coordinates |
| `/api/sessions/:id/swipe` | `{"x1","y1","x2","y2","duration"}` | Swipe gesture |
| `/api/sessions/:id/pinch` | `{"x","y","scale","duration"}` | Pinch (scale >1 zooms in) |
| `/api/sessions/:id/key` | `{"chars": "abc"}` | Type characters |
| `/api/sessions/:id/button` | `{"button": "home"}` | Hardware button (home, lock, shake) |

Coordinates are normalized to 0.0–1.0 relative to the Simulator window.

## Configuration

| Environment variable | Default | Description |
|---------------------|---------|-------------|
| `SIMCASTER_TOKEN` | random | Auth token for API access (used by both daemon and CLI) |
| `SIMCASTER_HOST` | `0.0.0.0` | Bind address (daemon) |
| `SIMCASTER_PORT` | `4821` | Listen port (daemon) |
| `SIMCASTER_URL` | `http://127.0.0.1:4821` | Daemon base URL (CLI only) |

## Running as a service

A launchd plist is included for auto-starting the daemon:

```bash
cp com.simcaster.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.simcaster.daemon.plist
```

Edit the plist to update the binary path and token before loading.

## Architecture notes

**Why file-based IPC?** The capture helper runs as a separate `.app` bundle because ScreenCaptureKit and Accessibility TCC permissions are bound to the app's code signing identity and bundle. The daemon can't hold these permissions as a bare executable. File-based IPC keeps the boundary simple and debuggable — you can inspect `/tmp/simcaster_frames/<session>.jpg` to check if frames are flowing, or drop a `.cmd` file into `/tmp/simcaster_cmds/` to test input injection independently.

**Why not screen mirroring?** Tools like `simctl io recordVideo` or `xcrun simctl io screenshot` are too slow for interactive use. ScreenCaptureKit gives us 15 fps with low overhead, and capturing the window directly means we get exactly what's on screen with no extra encoding step.

**Why WebSocket?** The first version polled for frames over HTTP. Switching to server-push via WebSocket cut perceived latency by 30–40%, mostly by eliminating the round-trip overhead that compounds over tunneled connections.

**Why kqueue directory watching?** The daemon uses `DispatchSource` (backed by kqueue vnode events) to watch the frame directory for changes instead of polling. This reacts to new frames as soon as the capture helper writes them. The frame files are written atomically (write to temp file, then rename), so we watch the directory rather than the file — `rename()` replaces the inode, which would invalidate a per-file watcher after the first write.

## Project structure

```
Simcaster/
├── Package.swift
├── Sources/
│   ├── SimcasterCore/
│   │   └── Contracts.swift          # Shared request/response types
│   ├── SimcasterDaemon/
│   │   ├── main.swift               # Routes and server startup
│   │   ├── SessionStore.swift       # Thread-safe session storage
│   │   ├── CaptureManager.swift     # Capture helper lifecycle and IPC
│   │   ├── AuthMiddleware.swift     # Token auth (master + per-session viewer tokens)
│   │   ├── FrameWatcher.swift       # kqueue-based frame file watcher
│   │   ├── Viewer.swift             # Mobile-first HTML/JS viewer
│   │   └── Helpers.swift            # simctl, JSON encoding, LAN IP, escaping
│   └── SimcasterCLI/
│       └── main.swift               # CLI tool
├── CaptureHelper/
│   └── SimcasterCapture.swift         # ScreenCaptureKit capture + input injection
├── Spike/
│   └── CaptureSpike.app/            # Pre-built capture helper bundle
└── com.simcaster.daemon.plist         # launchd plist for daemon auto-start
```

## Using with Claude Code

Simcaster was built for developers who use [Claude Code](https://docs.anthropic.com/en/docs/claude-code) remotely from a phone. To let Claude build, install, and preview your iOS app autonomously:

1. Install and start Simcaster on your Mac (see [Quick start](#quick-start))
2. Copy the template from [`claude-code-setup.md`](claude-code-setup.md) into your iOS project's `CLAUDE.md`
3. Fill in your scheme name, bundle ID, and simulator UDID
4. Set `SIMCASTER_TOKEN` in your shell environment so both the daemon and Claude Code can authenticate

Now when you ask Claude to "build and preview the app", it knows how to boot the simulator, build your project, create a viewer session, and hand you the URL.

For remote access (phone not on the same network as your Mac), run a Cloudflare tunnel and set `SIMCASTER_URL` to the tunnel URL in your environment.

## Known limitations

- Keyboard input uses macOS virtual keycodes mapped to a US keyboard layout; non-ASCII characters fall back to clipboard paste
- The capture helper is a single process — running multiple simulators simultaneously would need multiple instances
- No rate limiting on input endpoints; this is fine for personal use but would need attention if exposed publicly
- Frame files and command files live in `/tmp` with default permissions; appropriate for a single-user dev tool

## Future improvements

These would meaningfully improve the experience but aren't blockers for daily use:

- **Adaptive JPEG quality** — lower quality during fast motion for higher fps, full quality when static
- **Video codec streaming** — H.264/H.265 over WebSocket would compress dramatically better than per-frame JPEG, especially during motion
- **Multiple simultaneous sessions** — frame paths are already per-session; the remaining work is launching separate capture helper instances per simulator window
- **Non-US keyboard layouts** — the keycode table currently maps US QWERTY only

## Building the capture helper

The capture helper is compiled separately from the SPM package because it needs to live inside an `.app` bundle:

```bash
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics
```

## License

MIT
