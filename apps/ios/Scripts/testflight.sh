#!/bin/sh
# Archives the Vellum app, signs it and uploads it to App Store Connect for TestFlight, then waits until App Store
# Connect has processed the build. Run by .github/workflows/testflight.yml on a macOS runner.
# Needs KEY_ID, ISSUER_ID, TEAM_ID and DROPBOX_APP_KEY in the environment, the App Store Connect key (.p8) at
# KEY_PATH, and a BUILD_NUMBER that rises with every upload. The team reaches the build only as a build setting here; no committed
# file names it, and the Dropbox app key reaches the app the same way (ADR-0013).
# Signing is Xcode's automatic signing with Apple's cloud-managed distribution certificate, so no certificate or
# profile is kept anywhere; the key needs the Admin role for that.
set -eu
cd "$(dirname "$0")/.."
: "${KEY_ID:?}" "${ISSUER_ID:?}" "${TEAM_ID:?}" "${KEY_PATH:?}" "${BUILD_NUMBER:?}" "${DROPBOX_APP_KEY:?}"
# A TestFlight build always reaches Dropbox: refuse a key not shaped like a Dropbox app key rather than ship a build
# that says Dropbox isn't set up. The key is never printed.
if ! printf '%s' "$DROPBOX_APP_KEY" | grep -Eq '^[a-z0-9]{10,24}$'; then
  echo "DROPBOX_APP_KEY is not shaped like a Dropbox app key (10 to 24 lowercase letters and digits)" >&2
  exit 1
fi
out=.build-native
archive="$out/Vellum.xcarchive"

# Before the long archive: the key signs a token App Store Connect accepts, and the app record exists.
swift Scripts/asc-build-status.swift com.millzach.vellum --app-only

sh Scripts/generate-project.sh

# The archive is left unsigned and only the export signs it, as Sotto learned: signing the archive makes a new Apple
# Development certificate on every fresh runner until the account reaches Apple's limit; the export's cloud-managed
# distribution certificate is one per team and is reused.
xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DROPBOX_APP_KEY="$DROPBOX_APP_KEY" \
  archive

plist="$archive/Products/Applications/Vellum.app/Info.plist"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName \
  ITSAppUsesNonExemptEncryption; do
  printf '%s = %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
done
# The app's Dropbox key and callback scheme came from the secret, checked without printing them.
if [ "$(/usr/libexec/PlistBuddy -c 'Print :DropboxAppKey' "$plist")" = "$DROPBOX_APP_KEY" ] &&
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$plist")" = "db-$DROPBOX_APP_KEY" ]; then
  echo "DropboxAppKey and its db- callback scheme match the DROPBOX_APP_KEY secret"
else
  echo "The archived Info.plist does not carry the DROPBOX_APP_KEY secret" >&2
  exit 1
fi

# destination "upload" sends the signed build straight to App Store Connect; nothing is kept on the runner.
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key><string>upload</string>
	<key>method</key><string>app-store-connect</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID"
rm -f "$out/ExportOptions.plist"

# The upload is only half the journey: App Store Connect still has to process the build before TestFlight offers it.
swift Scripts/asc-build-status.swift com.millzach.vellum "$BUILD_NUMBER"
