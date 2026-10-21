#!/bin/bash
# Prepare distributable artifacts locally. Does not commit, tag, push, or publish.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${1:-} == --help ]]; then
  echo 'Usage: TEAM_ID=... BUILD_NUMBER=... NOTARY_PROFILE=hex-notary bun run release [--check]'
  echo 'Optional: SIGNING_IDENTITY="Developer ID Application: ... (...)"'
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && $1 == --check ) ]] || { echo 'Unknown argument; use --help.' >&2; exit 1; }
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to an unused integer greater than the last release (92 upstream)}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
[[ $TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || { echo 'Invalid TEAM_ID.' >&2; exit 1; }
[[ $BUILD_NUMBER =~ ^[1-9][0-9]{0,3}$ ]] && (( BUILD_NUMBER > 92 )) || { echo 'Invalid BUILD_NUMBER; use an unused integer > 92.' >&2; exit 1; }
version=$(bun -e 'console.log(require("./package.json").version)')
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'package.json must contain a stable x.y.z version.' >&2; exit 1; }
xcodebuild -version
# Check that a distribution certificate exists for the selected team.
identities=$(security find-identity -v -p codesigning)
default_identity=$(echo "$identities" | /usr/bin/awk -v team="$TEAM_ID" 'index($0, "Developer ID Application:") && index($0, "(" team ")") { print $2; exit }')
[[ -n $default_identity ]] || { echo 'No valid Developer ID Application certificate for TEAM_ID.' >&2; exit 1; }
identity=${SIGNING_IDENTITY:-$default_identity}
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null
if [[ ${1:-} == --check ]]; then
  echo "Release prerequisites available for Hex $version ($BUILD_NUMBER)."
  exit 0
fi
[[ -z $(git status --porcelain) ]] || { echo 'Commit changes before packaging a release.' >&2; exit 1; }
output="$PWD/build/releases/$version-$BUILD_NUMBER"
[[ ! -e $output ]] || { echo "Output already exists: $output" >&2; exit 1; }
mkdir -p "$output"

xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$output/Hex.xcarchive" \
  -derivedDataPath build/ReleaseDerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive

# Export through Xcode so embedded Sparkle helpers receive distribution signatures.
export_options="$output/ExportOptions.plist"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$export_options"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$export_options"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$export_options"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string $identity" "$export_options"
xcodebuild -exportArchive -archivePath "$output/Hex.xcarchive" \
  -exportPath "$output/export" -exportOptionsPlist "$export_options"
app="$output/export/Hex.app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2> "$output/signature.txt"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$BUILD_NUMBER" ]]
/usr/bin/grep -qx "TeamIdentifier=$TEAM_ID" "$output/signature.txt"

# Notarize the app, staple its ticket, then create the final ZIP from the stapled app.
ditto -c -k --keepParent "$app" "$output/notarization.zip"
xcrun notarytool submit "$output/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$output/notarization.zip"
ditto -c -k --keepParent "$app" "$output/Hex-$version.zip"

mkdir "$output/dmg"
ditto "$app" "$output/dmg/Hex.app"
ln -s /Applications "$output/dmg/Applications"
hdiutil create -volname Hex -srcfolder "$output/dmg" -ov -format UDZO "$output/Hex-$version.dmg"
codesign --force --sign "$identity" --timestamp "$output/Hex-$version.dmg"
xcrun notarytool submit "$output/Hex-$version.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$output/Hex-$version.dmg"
xcrun stapler validate "$output/Hex-$version.dmg"
(cd "$output" && shasum -a 256 "Hex-$version.zip" "Hex-$version.dmg" > SHA256SUMS)
echo "Artifacts ready for review: $output"
