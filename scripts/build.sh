#!/bin/bash
# Build TRAE FLOW for release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${TRAE_FLOW_BUILD_DIR:-$PROJECT_DIR/build}"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/TraeFlow.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
KEYCHAIN_PATH="${TRAE_FLOW_KEYCHAIN_PATH:-}"
TEAM_ID="${TRAE_FLOW_TEAM_ID:-}"
EXPORT_METHOD="${TRAE_FLOW_EXPORT_METHOD:-developer-id}"
SIGNING_CERTIFICATE="${TRAE_FLOW_SIGNING_CERTIFICATE:-Developer ID Application}"
ENABLE_HARDENED_RUNTIME="${TRAE_FLOW_ENABLE_HARDENED_RUNTIME:-YES}"
SCHEME="${TRAE_FLOW_SCHEME:-TraeFlow}"
PROJECT_FILE="${TRAE_FLOW_PROJECT_FILE:-TraeFlow.xcodeproj}"

echo "=== Building TRAE FLOW ==="
echo ""

# Clean previous builds
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$PROJECT_DIR"

archive_args=(
    xcodebuild archive
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -configuration Release
    -derivedDataPath "$DERIVED_DATA_PATH"
    -archivePath "$ARCHIVE_PATH"
    -destination "generic/platform=macOS"
    ENABLE_HARDENED_RUNTIME="$ENABLE_HARDENED_RUNTIME"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_CERTIFICATE"
)

if [ -n "$TEAM_ID" ]; then
    archive_args+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

if [ -n "$KEYCHAIN_PATH" ]; then
    archive_args+=(OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH")
fi

# Build and archive
echo "Archiving..."
if command -v xcpretty >/dev/null 2>&1; then
    "${archive_args[@]}" | xcpretty
else
    "${archive_args[@]}"
fi

# Create ExportOptions.plist if it doesn't exist
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$EXPORT_METHOD</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>$SIGNING_CERTIFICATE</string>
</dict>
</plist>
EOF

if [ -n "$TEAM_ID" ]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"
fi

export_args=(
    xcodebuild -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_PATH"
    -exportOptionsPlist "$EXPORT_OPTIONS"
)

if [ -n "$KEYCHAIN_PATH" ]; then
    export_args+=(OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN_PATH")
fi

# Export the archive
echo ""
echo "Exporting..."
if command -v xcpretty >/dev/null 2>&1; then
    "${export_args[@]}" | xcpretty
else
    "${export_args[@]}"
fi

echo ""
echo "=== Build Complete ==="
echo "App exported to: $EXPORT_PATH/TRAE FLOW.app"
echo ""
echo "Next: Run ./scripts/create-release.sh to notarize and create DMG"
