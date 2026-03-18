# Simcaster — Claude Code Setup

Add these instructions to your iOS project's `CLAUDE.md` so Claude Code can build and preview your app remotely via Simcaster.

## Step 1: Install Simcaster (one-time)

```bash
git clone https://github.com/rscodra/Simcaster.git ~/.simcaster
cd ~/.simcaster
swift build
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics
```

Add to your shell profile (`~/.zshrc`):
```bash
TOKEN=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24)
printf '\nexport SIMCASTER_HOME="$HOME/.simcaster"\nexport SIMCASTER_TOKEN=%s\n' "$TOKEN" >> ~/.zshrc
source ~/.zshrc
```

## Step 2: Start the daemon

```bash
$SIMCASTER_HOME/.build/debug/simcasterd &
```

Or install as a launchd service for auto-start:
```bash
cp ~/.simcaster/com.simcaster.daemon.plist ~/Library/LaunchAgents/
plutil -replace ProgramArguments.0 -string "$HOME/.simcaster/.build/debug/simcasterd" ~/Library/LaunchAgents/com.simcaster.daemon.plist
plutil -insert EnvironmentVariables -xml "<dict><key>SIMCASTER_TOKEN</key><string>$SIMCASTER_TOKEN</string></dict>" ~/Library/LaunchAgents/com.simcaster.daemon.plist
launchctl load ~/Library/LaunchAgents/com.simcaster.daemon.plist
```

## Step 3: Add to your project's CLAUDE.md

Copy everything below the line into your iOS project's `CLAUDE.md`. Replace the placeholder values.

---

## iOS Simulator Preview

This project uses Simcaster for remote Simulator preview. The binaries are at `~/.simcaster/.build/debug/` (`simcasterd` and `simcasterctl`). If `SIMCASTER_HOME` is set, use `$SIMCASTER_HOME/.build/debug/`; otherwise default to `~/.simcaster/.build/debug/`.

### Check Simcaster is running

```bash
curl -s "http://127.0.0.1:4821/api/health?token=$SIMCASTER_TOKEN"
```

If the daemon isn't running, start it:
```bash
~/.simcaster/.build/debug/simcasterd &
```

If Simcaster isn't installed, install it first:
```bash
git clone https://github.com/rscodra/Simcaster.git ~/.simcaster
cd ~/.simcaster && swift build
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
  CaptureHelper/SimcasterCapture.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics
export SIMCASTER_TOKEN="${SIMCASTER_TOKEN:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24)}"
~/.simcaster/.build/debug/simcasterd &
```

### Build & Preview

```bash
# Boot a simulator (pick latest iPhone unless specified)
~/.simcaster/.build/debug/simcasterctl devices
~/.simcaster/.build/debug/simcasterctl boot --udid <UDID>
open -a Simulator

# Build the app
xcodebuild -scheme <YOUR_SCHEME> -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20

# Install and launch
xcrun simctl install <UDID> <PATH_TO_BUILD_APP>
xcrun simctl launch <UDID> <YOUR_BUNDLE_ID>

# Create a viewer session — give the user the URL it prints
~/.simcaster/.build/debug/simcasterctl watch --udid <UDID>
```

### Rebuild After Changes

```bash
xcodebuild -scheme <YOUR_SCHEME> -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20
xcrun simctl install <UDID> <PATH_TO_BUILD_APP>
xcrun simctl terminate <UDID> <YOUR_BUNDLE_ID> && xcrun simctl launch <UDID> <YOUR_BUNDLE_ID>
```

The viewer auto-reconnects — no need to create a new session.

### Troubleshooting

```bash
# Restart a stuck session
curl -X POST "http://127.0.0.1:4821/api/sessions/<session-id>/stop?token=$SIMCASTER_TOKEN"
~/.simcaster/.build/debug/simcasterctl watch --udid <UDID>

# Full restart
pkill simcasterd; pkill CaptureSpike
~/.simcaster/.build/debug/simcasterd &
```
