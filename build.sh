#!/bin/bash
# Builds build/Unghost.app as a universal (Apple Silicon + Intel) app.
# Needs Xcode or the Command Line Tools (run: xcode-select --install).
#
# Options (environment variables):
#   VERSION=1.0.0        version string written into Info.plist (default 1.0.0)
#   ARCHS="arm64"        build only for these architectures (default "arm64 x86_64")
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="13.0"
BUILD="build"
APP="$BUILD/Unghost.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"

slices=()
for arch in $ARCHS; do
    out="$BUILD/Unghost-$arch"
    xcrun --sdk macosx swiftc -O -swift-version 5 \
        -target "$arch-apple-macos$MIN_MACOS" \
        Sources/Unghost.swift \
        -framework AppKit -framework ApplicationServices -framework ServiceManagement \
        -o "$out"
    slices+=("$out")
done
lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/Unghost"
rm -f "${slices[@]}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Unghost</string>
    <key>CFBundleDisplayName</key><string>Unghost</string>
    <key>CFBundleIdentifier</key><string>io.github.andrecamm.claudedockclean</string>
    <key>CFBundleExecutable</key><string>Unghost</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSAccessibilityUsageDescription</key><string>Counts agent app icons in the Dock so the menu bar item can show how many extras are stuck.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP ($VERSION, $ARCHS)"
