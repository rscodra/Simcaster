#!/bin/bash
set -e

INSTALL_DIR="${SIMCASTER_HOME:-$HOME/.simcaster}"
REPO="https://github.com/rscodra/Simcaster.git"

echo "Installing Simcaster to $INSTALL_DIR..."

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing install..."
    cd "$INSTALL_DIR" && git pull --ff-only
else
    if [ -d "$INSTALL_DIR" ]; then
        echo "Error: $INSTALL_DIR exists but is not a git repo. Remove it first."
        exit 1
    fi
    git clone "$REPO" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Build daemon and CLI
echo "Building (this takes a minute on first run)..."
swift build 2>&1 | tail -3

# Build capture helper
echo "Compiling capture helper..."
swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
    CaptureHelper/SimcasterCapture.swift \
    -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

# Symlink binaries
echo "Symlinking binaries to /usr/local/bin..."
mkdir -p /usr/local/bin
ln -sf "$INSTALL_DIR/.build/debug/simcasterd" /usr/local/bin/simcasterd
ln -sf "$INSTALL_DIR/.build/debug/simcasterctl" /usr/local/bin/simcasterctl

# Check shell profile for SIMCASTER_TOKEN
SHELL_RC="$HOME/.zshrc"
if [ -n "$BASH_VERSION" ]; then SHELL_RC="$HOME/.bashrc"; fi

if ! grep -q "SIMCASTER_TOKEN" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Simcaster" >> "$SHELL_RC"
    echo "export SIMCASTER_TOKEN=dev" >> "$SHELL_RC"
    echo "Added SIMCASTER_TOKEN=dev to $SHELL_RC"
else
    echo "SIMCASTER_TOKEN already set in $SHELL_RC"
fi

echo ""
echo "Done! Simcaster installed."
echo ""
echo "  Start the daemon:   simcasterd &"
echo "  List simulators:    simcasterctl devices"
echo "  Init a project:     cd ~/YourApp && simcasterctl init"
echo ""
echo "Run 'source $SHELL_RC' or open a new terminal to pick up the token."
