#!/bin/bash
# Create a release: build, notarize, create DMG, optionally sign for Sparkle, upload to GitHub, update website
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${TRAE_FLOW_BUILD_DIR:-$PROJECT_DIR/build/release}"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="${TRAE_FLOW_RELEASE_DIR:-$PROJECT_DIR/releases/signed}"

# Website repo for auto-updating appcast
WEBSITE_DIR="${TRAE_FLOW_WEBSITE:-$PROJECT_DIR/../TraeFlow-website}"
WEBSITE_PUBLIC="$WEBSITE_DIR/public"

APP_PATH="$EXPORT_PATH/TRAE FLOW.app"
APP_NAME="TraeFlow"
NOTARY_PROFILE="${TRAE_FLOW_NOTARY_KEYCHAIN_PROFILE:-TraeFlow}"

infer_github_repo() {
    if [ -n "${TRAE_FLOW_GITHUB_REPO:-}" ]; then
        echo "$TRAE_FLOW_GITHUB_REPO"
        return 0
    fi

    local remote_url
    remote_url=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)

    if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

GITHUB_REPO="$(infer_github_repo || true)"

echo "=== Creating Release ==="
echo ""

export TRAE_FLOW_BUILD_DIR="$BUILD_DIR"
export TRAE_FLOW_RELEASE_DIR="$RELEASE_DIR"
export TRAE_FLOW_GENERATE_APPCAST=1
export TRAE_FLOW_NOTARY_KEYCHAIN_PROFILE="$NOTARY_PROFILE"

"$SCRIPT_DIR/package-release.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG not found at $DMG_PATH"
    exit 1
fi

echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Create GitHub Release
# ============================================
echo "=== Step 1: Creating GitHub Release ==="

GITHUB_DOWNLOAD_URL=""

if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release."
elif [ -z "$GITHUB_REPO" ]; then
    echo "WARNING: Could not infer GitHub repository. Set TRAE_FLOW_GITHUB_REPO=owner/repo to enable release upload."
    echo "Skipping GitHub release."
else
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" \
            --repo "$GITHUB_REPO" \
            --title "TRAE FLOW v$VERSION" \
            --notes "## Highlights

- Download \`$(basename "$DMG_PATH")\` and install the latest TRAE FLOW release.

## Notes

- Open the DMG, drag TRAE FLOW to Applications, and launch it normally.
- After installation, TRAE FLOW will automatically check for updates."
    fi

    GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$(basename "$DMG_PATH")"
    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
fi

echo ""

# ============================================
# Step 2: Update website appcast and deploy
# ============================================
echo "=== Step 2: Updating Website ==="

if [ -d "$WEBSITE_PUBLIC" ] && [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    cp "$RELEASE_DIR/appcast/appcast.xml" "$WEBSITE_PUBLIC/appcast.xml"

    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$(basename "$DMG_PATH")\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$WEBSITE_PUBLIC/appcast.xml"
        echo "Updated appcast.xml with GitHub download URL"
    fi

    CONFIG_FILE="$WEBSITE_DIR/src/config.ts"
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        cat > "$CONFIG_FILE" << EOF
// Auto-updated by create-release.sh
export const LATEST_VERSION = "$VERSION";
export const DOWNLOAD_URL = "$GITHUB_DOWNLOAD_URL";
EOF
        echo "Updated src/config.ts with version $VERSION"
    fi

    cd "$WEBSITE_DIR"
    if [ -d ".git" ]; then
        git add public/appcast.xml src/config.ts
        if ! git diff --cached --quiet; then
            git commit -m "Update appcast for v$VERSION"
            echo "Committed appcast update"

            read -p "Push website changes to deploy? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                git push
                echo "Website deployed!"
            else
                echo "Changes committed but not pushed. Run 'git push' in $WEBSITE_DIR to deploy."
            fi
        else
            echo "No changes to commit"
        fi
    else
        echo "Copied appcast.xml to $WEBSITE_PUBLIC/"
        echo "Note: Website directory is not a git repo"
    fi
    cd "$PROJECT_DIR"
else
    echo "Website directory not found or appcast not generated"
    echo "Skipping website update."
fi

echo ""
echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "  - Appcast: $RELEASE_DIR/appcast/appcast.xml"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$WEBSITE_PUBLIC/appcast.xml" ]; then
    echo "  - Website: $WEBSITE_PUBLIC/appcast.xml"
fi
