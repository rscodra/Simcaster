#!/bin/bash
set -e

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo "dev")}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release-dist"

echo "Building Simcaster $VERSION..."
cd "$PROJECT_DIR"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build for arm64 (Apple Silicon)
echo "Building for arm64..."
swift build -c release --arch arm64 2>&1 | tail -5

# Build for x86_64 (Intel)
echo "Building for x86_64..."
swift build -c release --arch x86_64 2>&1 | tail -5

# Create universal binaries
echo "Creating universal binaries..."
ARM_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
X86_DIR="$PROJECT_DIR/.build/x86_64-apple-macosx/release"

lipo -create "$ARM_DIR/simcasterd" "$X86_DIR/simcasterd" -output "$BUILD_DIR/simcasterd"
lipo -create "$ARM_DIR/simcasterctl" "$X86_DIR/simcasterctl" -output "$BUILD_DIR/simcasterctl"

# Build capture helper for both archs
echo "Compiling capture helper (universal)..."
swiftc -O -target arm64-apple-macosx14.0 \
    -o "$BUILD_DIR/CaptureSpike-arm64" \
    "$PROJECT_DIR/CaptureHelper/SimcasterCapture.swift" \
    -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

swiftc -O -target x86_64-apple-macosx14.0 \
    -o "$BUILD_DIR/CaptureSpike-x86_64" \
    "$PROJECT_DIR/CaptureHelper/SimcasterCapture.swift" \
    -framework AppKit -framework ScreenCaptureKit -framework CoreGraphics

lipo -create "$BUILD_DIR/CaptureSpike-arm64" "$BUILD_DIR/CaptureSpike-x86_64" \
    -output "$BUILD_DIR/CaptureSpike"
rm "$BUILD_DIR/CaptureSpike-arm64" "$BUILD_DIR/CaptureSpike-x86_64"

# Package
echo "Packaging..."
ARCHIVE="$BUILD_DIR/simcaster-$VERSION-macos-universal.tar.gz"

# Include the .app bundle structure
mkdir -p "$BUILD_DIR/Spike/CaptureSpike.app/Contents/MacOS"
cp "$BUILD_DIR/CaptureSpike" "$BUILD_DIR/Spike/CaptureSpike.app/Contents/MacOS/CaptureSpike"
cp "$PROJECT_DIR/Spike/CaptureSpike.app/Contents/Info.plist" "$BUILD_DIR/Spike/CaptureSpike.app/Contents/Info.plist"
rm "$BUILD_DIR/CaptureSpike"

# Include launchd plist
cp "$PROJECT_DIR/com.simcaster.daemon.plist" "$BUILD_DIR/"

tar -czf "$ARCHIVE" -C "$BUILD_DIR" simcasterd simcasterctl Spike com.simcaster.daemon.plist

echo ""
echo "Built: $ARCHIVE"
echo ""
ls -lh "$ARCHIVE"
echo ""
echo "Contents:"
tar -tzf "$ARCHIVE"
