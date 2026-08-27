#!/bin/bash
# Release build → Developer ID signing → notarization → staple → zip
# (docs/15 step 39, the credential-free scaffold).
#
# Everything here that CAN exist without the $99 Apple Developer enrollment
# does; the two inputs only the owner can create are read from the
# environment and checked up front:
#
#   VOCAL_SIGN_IDENTITY   Developer ID Application identity, e.g.
#                         "Developer ID Application: Jane Doe (TEAMID1234)"
#                         (after enrollment: Xcode → Settings → Accounts →
#                         Manage Certificates → Developer ID Application)
#   VOCAL_NOTARY_PROFILE  notarytool keychain profile name, created once:
#                         xcrun notarytool store-credentials vocal-notary \
#                           --apple-id you@example.com --team-id TEAMID1234 \
#                           --password <app-specific password>
#
# Usage: scripts/release.sh [output-dir]     (default: build/release)
#
# Sparkle auto-updates remain deliberately unwired: the framework, the
# appcast feed, and the EdDSA signing keys are one integration that should
# land together, signed, once distribution actually begins — half of it
# would only pretend the app updates itself.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null; then
    echo "error: xcodebuild not found — run on a Mac with Xcode installed" >&2
    exit 1
fi
if [[ -z "${VOCAL_SIGN_IDENTITY:-}" ]]; then
    echo "error: VOCAL_SIGN_IDENTITY is not set (see the header of this script)." >&2
    echo "Signing requires the Apple Developer enrollment — docs/15 open decision 4." >&2
    exit 1
fi
if [[ -z "${VOCAL_NOTARY_PROFILE:-}" ]]; then
    echo "error: VOCAL_NOTARY_PROFILE is not set (see the header of this script)." >&2
    exit 1
fi

OUT="${1:-build/release}"
ARCHIVE="$OUT/Vocal.xcarchive"
APP="$OUT/Vocal.app"
ZIP="$OUT/Vocal.zip"
mkdir -p "$OUT"

echo "==> Generating the Xcode project"
command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

echo "==> Archiving VocalMac (Release)"
xcodebuild -project Vocal.xcodeproj \
    -scheme VocalMac \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive \
    CODE_SIGN_IDENTITY="$VOCAL_SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

rm -rf "$APP"
cp -R "$ARCHIVE/Products/Applications/Vocal.app" "$APP"

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing (waits for Apple)"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$VOCAL_NOTARY_PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the distributed archive contains the stapled app.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Done: $ZIP"
echo "    Gatekeeper check on another Mac: spctl -a -vv \"$APP\""
