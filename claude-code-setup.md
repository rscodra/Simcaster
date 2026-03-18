# Simcaster — Claude Code Setup Template

Copy the instructions below into your project's `CLAUDE.md` (or append them to an existing one). Update the paths and values in angle brackets to match your setup.

---

## iOS Simulator Preview

This project uses [Simcaster](https://github.com/<owner>/simcaster) for remote Simulator preview. When asked to build and preview the app, follow this workflow.

### Prerequisites

Simcaster must be running on the Mac. Verify with:
```bash
curl -s "http://127.0.0.1:4821/api/health?token=$SIMCASTER_TOKEN"
```

### Build & Preview

```bash
# Boot a simulator (pick latest iPhone unless specified)
simcasterctl devices
simcasterctl boot --udid <UDID>
open -a Simulator

# Build the app
xcodebuild -scheme <Scheme> -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20

# Install and launch
xcrun simctl install <UDID> <path-to-.app>
xcrun simctl launch <UDID> <bundle-id>

# Create a viewer session — give the user the printed URL
simcasterctl watch --udid <UDID>
```

### Rebuild After Changes

```bash
xcodebuild -scheme <Scheme> -destination 'platform=iOS Simulator,id=<UDID>' build 2>&1 | tail -20
xcrun simctl install <UDID> <path-to-.app>
xcrun simctl terminate <UDID> <bundle-id> && xcrun simctl launch <UDID> <bundle-id>
```

The viewer auto-reconnects — no need to create a new session.

### If Something Gets Stuck

```bash
# Restart the session
curl -X POST "http://127.0.0.1:4821/api/sessions/<session-id>/stop?token=$SIMCASTER_TOKEN"
simcasterctl watch --udid <UDID>
```
