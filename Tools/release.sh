#!/bin/bash
# Builds a Developer ID-signed, notarized Biscotti DMG for internal
# distribution to Synderys employees (not the App Store). Run it through
# `make release`; the DMG lands in build/release/.
#
# One-time setup on the Mac that cuts releases:
#   1. Import the "Developer ID Application: DigitalMonks LLC (9Y6C5MKG87)"
#      certificate and its private key (.p12, from the vault) into the login
#      keychain. Check: security find-identity -v -p codesigning
#   2. Store notarization credentials under a keychain profile, e.g. with an
#      App Store Connect API key:
#        xcrun notarytool store-credentials biscotti-notary \
#          --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer UUID>
#      or with an Apple ID and an app-specific password:
#        xcrun notarytool store-credentials biscotti-notary \
#          --apple-id <id> --team-id 9Y6C5MKG87 --password <app-specific>
#      NOTARY_PROFILE (in Makefile.local) overrides the profile name.
#   3. Put the Microsoft 365 app registration's IDs in Makefile.local
#      (docs/entra_app_registration.md); they fill the Info.plist placeholders:
#        MICROSOFT_GRAPH_CLIENT_ID := <Application (client) ID>
#        MICROSOFT_GRAPH_TENANT_ID := <Directory (tenant) ID>
set -euo pipefail

TEAM_ID="${TEAM_ID:-9Y6C5MKG87}"
NOTARY_PROFILE="${NOTARY_PROFILE:-biscotti-notary}"
GRAPH_CLIENT_ID="${MICROSOFT_GRAPH_CLIENT_ID:-}"
GRAPH_TENANT_ID="${MICROSOFT_GRAPH_TENANT_ID:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Biscotti.xcarchive"
EXPORT="$OUT/export"

die() {
    echo "release: $*" >&2
    exit 1
}

# --- Preflight: fail before a long build if signing or notarizing can't work.

# Without the IDs the app falls back to Apple Calendar, which is not what
# Synderys employees should get.
[ -n "$GRAPH_CLIENT_ID" ] && [ -n "$GRAPH_TENANT_ID" ] \
    || die "set MICROSOFT_GRAPH_CLIENT_ID and MICROSOFT_GRAPH_TENANT_ID in Makefile.local (see Tools/release.sh)"
IDENTITY=$(security find-identity -v -p codesigning \
    | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\".*/\1/p" | head -1)
[ -n "$IDENTITY" ] \
    || die "no \"Developer ID Application\" certificate for team $TEAM_ID in the keychain; import the .p12 (see Tools/release.sh)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || die "no notarytool credentials under the keychain profile \"$NOTARY_PROFILE\" (see Tools/release.sh)"

rm -rf "$OUT"
mkdir -p "$OUT"

# --- Archive and export. Apple silicon only, so arm64 only.

echo "release: archiving (Release, signed as $IDENTITY)"
xcodebuild -quiet -project "$ROOT/App/Biscotti.xcodeproj" -scheme Biscotti \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    ARCHS=arm64 CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    MICROSOFT_GRAPH_CLIENT_ID="$GRAPH_CLIENT_ID" MICROSOFT_GRAPH_TENANT_ID="$GRAPH_TENANT_ID" \
    archive

cat > "$OUT/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "release: exporting with Developer ID"
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$OUT/ExportOptions.plist"
APP="$EXPORT/Biscotti.app"
codesign --verify --deep --strict "$APP"
for key in MicrosoftGraphClientID MicrosoftGraphTenantID; do
    [ -n "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" 2> /dev/null)" ] \
        || die "$key is missing from the built Info.plist"
done

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
DMG="$OUT/Biscotti-$VERSION.dmg"

# --- DMG: the app plus an Applications link to drag it onto.

echo "release: packaging $(basename "$DMG")"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Biscotti.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Biscotti -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

# --- Notarize and staple, so Gatekeeper opens it without a warning.

echo "release: notarizing (usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$OUT/notary.json" || true
STATUS=$(plutil -extract status raw -o - "$OUT/notary.json" 2> /dev/null || echo "unknown")
if [ "$STATUS" != "Accepted" ]; then
    SUBMISSION=$(plutil -extract id raw -o - "$OUT/notary.json" 2> /dev/null || true)
    if [ -n "$SUBMISSION" ]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-log.json" || true
    fi
    die "notarization status: $STATUS (see $OUT/notary.json and notary-log.json)"
fi

xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" \
    || die "Gatekeeper rejected the stapled DMG"

echo "release: done: $DMG (version $VERSION, build $BUILD)"
