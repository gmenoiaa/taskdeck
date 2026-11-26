#!/bin/bash
# Builds and bundles TaskDeck.app. Usage: ./build.sh [--install] [--open]
set -euo pipefail
cd "$(dirname "$0")"

# An install from a branch that is behind main puts an older app on the real data.json. That app
# does not know the fields added since, and its first save drops them: the standup settings of
# every space were lost this way. Checked before building, so a refusal costs nothing.
# ALLOW_BEHIND_MAIN=1 installs anyway.
if [[ " $* " == *" --install "* ]] && [ "${ALLOW_BEHIND_MAIN:-}" != "1" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    if ! GIT_TERMINAL_PROMPT=0 git fetch -q origin main 2>/dev/null; then
        echo "Could not reach origin; checking against the last fetched main."
    fi
    if git rev-parse -q --verify origin/main >/dev/null && ! git merge-base --is-ancestor origin/main HEAD; then
        behind="$(git rev-list --count HEAD..origin/main)"
        echo "Not installing: $(git rev-parse --abbrev-ref HEAD) is $behind commit(s) behind origin/main." >&2
        echo "An older app would drop the settings it does not know from data.json on its first save." >&2
        echo "Merge or rebase on origin/main first, or run with ALLOW_BEHIND_MAIN=1 to install anyway." >&2
        exit 1
    fi
fi

swift build -c release

APP="build/TaskDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Notification Centre plays only sounds inside the app bundle, so the system's alert sounds are
# copied in for the sound picker in Settings → Notifications.
cp /System/Library/Sounds/*.aiff "$APP/Contents/Resources/" 2>/dev/null || true
cp "$(swift build -c release --show-bin-path)/TaskDeck" "$APP/Contents/MacOS/TaskDeck"

# SwiftPM stamps the binary with the deployment target (14.0) as its SDK version, which makes
# macOS run the app in compatibility mode, without the Liquid Glass design. Stamp the real SDK.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
    -output "$APP/Contents/MacOS/TaskDeck" "$APP/Contents/MacOS/TaskDeck" >/dev/null 2>&1

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TaskDeck</string>
    <key>CFBundleDisplayName</key><string>TaskDeck</string>
    <key>CFBundleIdentifier</key><string>local.taskdeck</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TaskDeck</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Sign with a stable certificate when one exists, so the Keychain's "Always Allow"
# keeps working after a rebuild. Without a certificate, fall back to ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "Signed with stable certificate"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "Signed ad-hoc (the Keychain will ask for the password after every rebuild)"
fi
echo "OK: $APP"

for arg in "$@"; do
    case "$arg" in
        --install)
            pkill -x TaskDeck 2>/dev/null || true
            rm -rf "/Applications/TaskDeck.app"
            cp -R "$APP" "/Applications/TaskDeck.app"
            APP="/Applications/TaskDeck.app"
            echo "Installed at $APP"
            ;;
        --open) open "$APP" ;;
    esac
done
