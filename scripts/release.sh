#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
EXPORT_OPTIONS="$ROOT_DIR/scripts/ExportOptions.plist"
UPDATE_CONFIG="$ROOT_DIR/scripts/UpdateFeed.plist"
TEAM_ID="AKDDZQLVBL"
BUNDLE_ID="com.yanlongchen.folderbeacon"
SPARKLE_KEY_ACCOUNT="com.yanlongchen.folderbeacon"
NOTARY_PROFILE="FolderBeaconNotary"
APP_INPUT=""
SIGNING_IDENTITY=""
WORK_DIR=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/release.sh [--app /path/to/Notarized.app] [--notary-profile NAME] [--identity "Developer ID Application: ..."]

Without --app: archive Release with the feed URL in UpdateFeed.plist, export
with Developer ID, create and notarize a DMG, then sign an appcast.xml feed.
With --app: package an already exported Developer ID-signed app using the
same DMG signing and notarization steps. If update URLs are configured, the
exported app must already contain the same Sparkle feed URL.

Prerequisites: Xcode signing is configured, a local Developer ID Application
identity is in Keychain, and notarytool credentials are saved under the
specified profile (default: FolderBeaconNotary).
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || fail "--app needs a path"
            APP_INPUT="$2"
            shift 2
            ;;
        --notary-profile)
            [[ $# -ge 2 ]] || fail "--notary-profile needs a name"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || fail "--identity needs a certificate name"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done

for command_name in xcodebuild codesign security plutil ditto hdiutil shasum xcrun; do
    command -v "$command_name" >/dev/null || fail "missing command: $command_name"
done

if [[ -n "$APP_INPUT" ]]; then
    [[ -d "$APP_INPUT" && "$APP_INPUT" == *.app ]] || fail "--app must point to an exported .app bundle"
    APP_PATH="$(cd "$(dirname "$APP_INPUT")" && pwd)/$(basename "$APP_INPUT")"
else
    [[ -f "$ROOT_DIR/FolderBeacon-Mac.xcodeproj/project.pbxproj" ]] || fail "Xcode project not found"
fi

[[ -f "$UPDATE_CONFIG" ]] || fail "missing $UPDATE_CONFIG"
FEED_URL="$(plutil -extract feedURL raw -o - "$UPDATE_CONFIG")"
DOWNLOAD_URL_PREFIX="$(plutil -extract downloadURLPrefix raw -o - "$UPDATE_CONFIG")"
if [[ -n "$FEED_URL" || -n "$DOWNLOAD_URL_PREFIX" ]]; then
    [[ "$FEED_URL" == https://* && "$DOWNLOAD_URL_PREFIX" == https://*/ ]] || \
        fail "UpdateFeed.plist needs an HTTPS feedURL and downloadURLPrefix ending in /"
elif [[ -z "$APP_INPUT" ]]; then
    fail "set feedURL and downloadURLPrefix in UpdateFeed.plist before releasing an updater-enabled build"
fi

IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    MATCHES="$(printf '%s\n' "$IDENTITIES" | sed -nE '/Developer ID Application:.*\(AKDDZQLVBL\)/s/^[^"]*"([^"]+)".*$/\1/p')"
    [[ -n "$MATCHES" ]] || fail "no local Developer ID Application identity for $TEAM_ID; install the certificate and private key"
    [[ "$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')" == 1 ]] || fail "multiple Developer ID identities found; pass --identity"
    SIGNING_IDENTITY="$MATCHES"
fi
[[ "$IDENTITIES" == *"\"$SIGNING_IDENTITY\""* ]] || fail "signing identity is not valid in Keychain: $SIGNING_IDENTITY"

mkdir -p "$DIST_DIR"
WORK_DIR="$(mktemp -d "$DIST_DIR/.release.XXXXXX")"

if [[ -z "$APP_INPUT" ]]; then
    printf 'Archiving Release build...\n'
    xcodebuild -project "$ROOT_DIR/FolderBeacon-Mac.xcodeproj" \
        -scheme FolderBeacon-Mac -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$WORK_DIR/DerivedData" \
        -clonedSourcePackagesDirPath "$DIST_DIR/SourcePackages" \
        -archivePath "$WORK_DIR/FolderBeacon-Mac.xcarchive" \
        "FOLDERBEACON_APPCAST_URL=$FEED_URL" \
        archive

    printf 'Exporting Developer ID app...\n'
    xcodebuild -exportArchive \
        -archivePath "$WORK_DIR/FolderBeacon-Mac.xcarchive" \
        -exportPath "$WORK_DIR/export" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates

    shopt -s nullglob
    EXPORTED_APPS=("$WORK_DIR/export/"*.app)
    shopt -u nullglob
    [[ ${#EXPORTED_APPS[@]} -eq 1 ]] || fail "expected one .app in Xcode export; found ${#EXPORTED_APPS[@]}"
    APP_PATH="${EXPORTED_APPS[0]}"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "app has no Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
[[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "unexpected bundle ID: $ACTUAL_BUNDLE_ID"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ && "$BUILD" =~ ^[A-Za-z0-9._-]+$ ]] || fail "version/build contains unsupported filename characters"
if [[ -n "$FEED_URL" ]]; then
    APP_FEED_URL="$(plutil -extract SUFeedURL raw -o - "$INFO_PLIST")"
    [[ "$APP_FEED_URL" == "$FEED_URL" ]] || fail "app update feed does not match UpdateFeed.plist"
    APP_SPARKLE_KEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
    SPARKLE_BIN="$DIST_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [[ -x "$SPARKLE_BIN/generate_keys" && -x "$SPARKLE_BIN/generate_appcast" ]] || \
        fail "Sparkle tools missing; resolve Xcode package dependencies first"
    KEYCHAIN_SPARKLE_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
    [[ "$APP_SPARKLE_KEY" == "$KEYCHAIN_SPARKLE_KEY" ]] || \
        fail "app's Sparkle public key does not match this Mac's signing key"
fi

RELEASE_NAME="FolderBeacon-${VERSION}-${BUILD}"
FINAL_DIR="$DIST_DIR/$RELEASE_NAME"
[[ ! -e "$FINAL_DIR" ]] || fail "$FINAL_DIR already exists; increase the app version/build number"

printf 'Checking app signature...\n'
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_TEAM="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$APP_TEAM" == "$TEAM_ID" ]] || fail "app was not signed by team $TEAM_ID"
APP_AUTHORITY="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p')"
printf '%s\n' "$APP_AUTHORITY" | grep -Fq 'Developer ID Application:' || fail "app is not Developer ID signed"

STAGING="$WORK_DIR/dmg-content"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/FolderBeacon.app"
codesign --verify --deep --strict "$STAGING/FolderBeacon.app"
ln -s /Applications "$STAGING/Applications"
DMG_PATH="$WORK_DIR/$RELEASE_NAME.dmg"

printf 'Creating disk image...\n'
hdiutil create -volname FolderBeacon -srcfolder "$STAGING" -format UDZO "$DMG_PATH"
printf 'Signing disk image...\n'
codesign --sign "$SIGNING_IDENTITY" --timestamp \
    --identifier "$BUNDLE_ID.dmg" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

printf 'Submitting disk image for notarization...\n'
NOTARY_RESULT="$WORK_DIR/notarization.json"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$NOTARY_RESULT"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT")"
NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT")"
if [[ "$NOTARY_STATUS" != Accepted ]]; then
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization status: $NOTARY_STATUS (submission $NOTARY_ID)"
fi

printf 'Stapling and validating ticket...\n'
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ -n "$FEED_URL" ]]; then
    printf 'Generating signed Sparkle appcast...\n'
    FEED_STAGING="$WORK_DIR/feed"
    mkdir "$FEED_STAGING"
    ditto "$DMG_PATH" "$FEED_STAGING/$RELEASE_NAME.dmg"
    "$SPARKLE_BIN/generate_appcast" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        --maximum-deltas 0 \
        -o "$FEED_STAGING/appcast.xml" "$FEED_STAGING"
    [[ -s "$FEED_STAGING/appcast.xml" ]] || fail "Sparkle appcast was not generated"
fi

mkdir "$FINAL_DIR"
ditto "$DMG_PATH" "$FINAL_DIR/$RELEASE_NAME.dmg"
ditto "$NOTARY_RESULT" "$FINAL_DIR/notarization.json"
if [[ -n "$FEED_URL" ]]; then
    ditto "$FEED_STAGING/appcast.xml" "$FINAL_DIR/appcast.xml"
fi
(
    cd "$FINAL_DIR"
    if [[ -n "$FEED_URL" ]]; then
        shasum -a 256 "$RELEASE_NAME.dmg" appcast.xml > SHA256SUMS
    else
        shasum -a 256 "$RELEASE_NAME.dmg" > SHA256SUMS
    fi
)
printf 'Release ready: %s\n' "$FINAL_DIR/$RELEASE_NAME.dmg"
