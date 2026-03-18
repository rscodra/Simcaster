# Simcaster

Preview your iOS Simulator on your phone. Tap, swipe, pinch, and type — all from a browser.

Built for developers who use [Claude Code](https://docs.anthropic.com/en/docs/claude-code) from a phone and need to see what they're building.

## Get started

```bash
# Install
curl -fsSL https://raw.githubusercontent.com/rscodra/Simcaster/main/install.sh | bash
simcasterctl setup

# Add to your iOS project
cd ~/YourApp
simcasterctl init
```

That's it. Open your project in Claude Code and ask it to **"build and preview the app"**. It boots the simulator, builds your project, starts a Cloudflare tunnel, and hands you a URL to open on your phone.

## Requirements

- macOS 14+ (Sonoma)
- Xcode 15+ with iOS Simulator

## How it works

```
Phone Browser ←—WebSocket—→ simcasterd ←—file IPC—→ CaptureHelper ←—CGEvent—→ Simulator
```

1. **simcasterd** — HTTP + WebSocket server that manages sessions and streams frames
2. **simcasterctl** — CLI for managing the daemon and creating sessions
3. **CaptureHelper** — macOS app that captures the Simulator window (ScreenCaptureKit) and injects touch/keyboard input (CGEvent)

## Manual usage

```bash
simcasterd &
simcasterctl devices
simcasterctl boot --udid <UDID>
open -a Simulator
simcasterctl watch --udid <UDID>
```

The `watch` command prints a URL. For remote access, use a Cloudflare tunnel:

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:4821
```

## CLI reference

| Command | Description |
|---------|-------------|
| `simcasterctl setup` | Set up macOS permissions and verify capture works |
| `simcasterctl init` | Generate a CLAUDE.md for the current project |
| `simcasterctl devices` | List available iOS simulators |
| `simcasterctl boot --udid <UDID>` | Boot a simulator device |
| `simcasterctl watch --udid <UDID>` | Create a viewer session and print the URL |
| `simcasterctl sessions` | List active viewer sessions |
| `simcasterctl health` | Check if the daemon is running |

## API

Base URL: `http://localhost:4821`

Authentication: `?token=<TOKEN>` or `Authorization: Bearer <TOKEN>`. Token is stored in `~/.simcaster/token`.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/devices` | List simulators |
| POST | `/api/boot` | Boot a simulator (`{"udid": "..."}`) |
| POST | `/api/sessions` | Create a session (`{"udid": "..."}`) |
| POST | `/api/sessions/:id/stop` | Stop a session |
| GET | `/sessions/:id` | Browser viewer page |
| WS | `/ws/sessions/:id/frames` | WebSocket frame stream (binary JPEG) |
| POST | `/api/sessions/:id/tap` | Tap (`{"x": 0.5, "y": 0.3}`) |
| POST | `/api/sessions/:id/swipe` | Swipe (`{"x1","y1","x2","y2","duration"}`) |
| POST | `/api/sessions/:id/pinch` | Pinch (`{"x","y","scale","duration"}`) |
| POST | `/api/sessions/:id/key` | Type (`{"chars": "abc"}`) |
| POST | `/api/sessions/:id/button` | Button (`{"button": "home"}`) |

Coordinates are normalized 0.0–1.0.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMCASTER_TOKEN` | `~/.simcaster/token` | Auth token |
| `SIMCASTER_HOST` | `0.0.0.0` | Bind address |
| `SIMCASTER_PORT` | `4821` | Listen port |
| `SIMCASTER_URL` | `http://127.0.0.1:4821` | Daemon URL (CLI only) |

## Building from source

```bash
git clone https://github.com/rscodra/Simcaster.git
cd Simcaster
swift build

swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

.build/debug/simcasterd &
```

## Architecture

The capture helper is a separate `.app` bundle because macOS ties Screen Recording and Accessibility permissions to the app's bundle identity. It communicates with the daemon via files in `/tmp` — JPEG frames and JSON command files. The daemon watches for new frames using kqueue and pushes them to browsers over WebSocket.

## Future improvements

- H.264/H.265 streaming instead of per-frame JPEG
- XPC or Unix socket IPC instead of file-based
- Multiple simultaneous simulator sessions
- Non-US keyboard layouts

## License

MIT
