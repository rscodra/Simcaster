#!/bin/bash
set -e

INSTALL_DIR="${SIMCASTER_HOME:-$HOME/.simcaster}"
REPO="rscodra/Simcaster"
REPO_URL="https://github.com/$REPO.git"

generate_token() {
    LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24
}

echo "Installing Simcaster to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Try downloading pre-built binaries first
install_prebuilt() {
    echo "Checking for pre-built binaries..."
    LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$LATEST" ]; then
        return 1
    fi

    ASSET_URL="https://github.com/$REPO/releases/download/$LATEST/simcaster-$LATEST-macos-universal.tar.gz"
    echo "Downloading $LATEST..."

    CHECKSUM_URL="https://github.com/$REPO/releases/download/$LATEST/checksums.txt"

    if curl -fsSL "$ASSET_URL" -o "/tmp/simcaster-release.tar.gz" 2>/dev/null; then
        # Verify checksum if available
        if curl -fsSL "$CHECKSUM_URL" -o "/tmp/simcaster-checksums.txt" 2>/dev/null; then
            EXPECTED=$(grep "simcaster-$LATEST-macos-universal.tar.gz" /tmp/simcaster-checksums.txt | awk '{print $1}')
            ACTUAL=$(shasum -a 256 /tmp/simcaster-release.tar.gz | awk '{print $1}')
            rm /tmp/simcaster-checksums.txt
            if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ]; then
                echo "Checksum verification failed!"
                echo "  Expected: $EXPECTED"
                echo "  Got:      $ACTUAL"
                rm /tmp/simcaster-release.tar.gz
                return 1
            fi
            echo "Checksum verified."
        fi

        tar -xzf /tmp/simcaster-release.tar.gz -C "$INSTALL_DIR"
        rm /tmp/simcaster-release.tar.gz
        # Remove macOS quarantine flag so Gatekeeper doesn't block the binaries
        xattr -cr "$INSTALL_DIR" 2>/dev/null
        echo "Downloaded pre-built binaries ($LATEST)"
        return 0
    fi

    return 1
}

# Build from source as fallback
install_from_source() {
    echo "Building from source (this takes 2-3 minutes on first run)..."

    if [ -d "$INSTALL_DIR/.git" ]; then
        cd "$INSTALL_DIR" && git pull --ff-only
    else
        # Clone into temp and move, in case INSTALL_DIR already has pre-built files
        if [ ! -d "$INSTALL_DIR/.git" ]; then
            git clone "$REPO_URL" "/tmp/simcaster-clone"
            cp -r /tmp/simcaster-clone/.git "$INSTALL_DIR/"
            cp -rn /tmp/simcaster-clone/* "$INSTALL_DIR/" 2>/dev/null || true
            rm -rf /tmp/simcaster-clone
        fi
        cd "$INSTALL_DIR"
    fi

    swift build

    # Build capture helper
    echo "Compiling capture helper..."
    mkdir -p Spike/CaptureSpike.app/Contents/MacOS
    swiftc -o Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike \
        CaptureHelper/SimcasterCapture.swift \
        -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

    # Point symlinks to debug build
    SIMCASTERD="$INSTALL_DIR/.build/debug/simcasterd"
    SIMCASTERCTL="$INSTALL_DIR/.build/debug/simcasterctl"
}

# Try pre-built first, fall back to source
if install_prebuilt; then
    SIMCASTERD="$INSTALL_DIR/simcasterd"
    SIMCASTERCTL="$INSTALL_DIR/simcasterctl"
else
    echo "No pre-built release found, building from source..."
    install_from_source
fi

# Symlink binaries
echo "Symlinking binaries to /usr/local/bin..."
mkdir -p /usr/local/bin
ln -sf "$SIMCASTERD" /usr/local/bin/simcasterd
ln -sf "$SIMCASTERCTL" /usr/local/bin/simcasterctl

# Also clone the repo if we only downloaded binaries (needed for the .app bundle structure)
if [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "Cloning repo for capture helper bundle..."
    git clone "$REPO_URL" "/tmp/simcaster-clone" 2>/dev/null
    cp -r /tmp/simcaster-clone/Spike "$INSTALL_DIR/Spike" 2>/dev/null || true
    cp -r /tmp/simcaster-clone/CaptureHelper "$INSTALL_DIR/CaptureHelper" 2>/dev/null || true
    cp /tmp/simcaster-clone/com.simcaster.daemon.plist "$INSTALL_DIR/" 2>/dev/null || true
    rm -rf /tmp/simcaster-clone
fi

# Generate and store token in ~/.simcaster/token (used by daemon + CLI directly)
TOKEN_FILE="$INSTALL_DIR/token"
if [ ! -f "$TOKEN_FILE" ]; then
    GENERATED_TOKEN=$(generate_token)
    echo "$GENERATED_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "Generated auth token in $TOKEN_FILE"
else
    echo "Auth token already exists in $TOKEN_FILE"
fi

# Also export in shell profile so $SIMCASTER_TOKEN is available for curl/scripts
case "$SHELL" in
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    *)      SHELL_RC="$HOME/.zshrc" ;;
esac

if ! grep -q "SIMCASTER_TOKEN" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Simcaster" >> "$SHELL_RC"
    echo "export SIMCASTER_TOKEN=$(cat "$TOKEN_FILE")" >> "$SHELL_RC"
fi

echo ""
echo "Done! Simcaster installed. Run this next:"
echo ""
echo "  simcasterctl setup"
echo ""
