#!/bin/bash
# Incremental, development-signed Release build for local dogfooding.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${1:-} == --help ]]; then
  echo 'Usage: bun run install:local [--no-open]'
  echo 'Build Release, replace /Applications/Hex.app, and launch it.'
  echo 'Signing uses Config/Local.xcconfig (Apple Development). No notarization.'
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && $1 == --no-open ) ]] || {
  echo 'Unknown argument; use --help.' >&2; exit 1;
}
[[ -w /Applications ]] || {
  echo '/Applications is not writable. Run from an account that can install apps there; do not run the build with sudo.' >&2
  exit 1
}

mkdir -p build
lock="$PWD/build/.install-local.lock"
mkdir "$lock" 2>/dev/null || {
  echo "Another local install is running. If it was interrupted, remove $lock and retry." >&2
  exit 1
}
staging=''
destination=/Applications/Hex.app
cleanup() {
  # Restore the previous bundle if replacing it failed after moving it aside.
  if [[ -n $staging ]]; then
    if [[ -d "$staging/Previous.app" && ! -e $destination ]]; then
      mv "$staging/Previous.app" "$destination" || {
        echo "Restore the previous app manually from $staging/Previous.app" >&2
        rmdir "$lock"
        return
      }
    fi
    rm -rf "$staging"
  fi
  rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash scripts/generate-project.sh
echo 'Building Release (incremental); log: build/install-local.log'
if ! xcodebuild -quiet -project Hex.xcodeproj -scheme Hex -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/LocalReleaseDerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build > build/install-local.log 2>&1; then
  tail -n 80 build/install-local.log >&2
  exit 1
fi
app="$PWD/build/LocalReleaseDerivedData/Build/Products/Release/Hex.app"
codesign --verify --deep --strict "$app"
signature=$(codesign -dvv "$app" 2>&1)
[[ $signature == *'Authority=Apple Development:'* && $signature == *'TeamIdentifier='* ]] || {
  echo 'Expected an Apple Development signature. Check Config/Local.xcconfig and your signing certificate.' >&2
  exit 1
}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ -d $destination ]]; then
  old_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  old_requirement=$(codesign -d -r- "$destination" 2>&1 | sed -n 's/^designated => //p')
  if [[ -z $old_requirement ]] || ! codesign --verify -R "=$old_requirement" "$app" 2>/dev/null; then
    echo "App identity is changing ($old_id -> $bundle_id); macOS permissions may need to be granted once."
    echo 'Existing data is retained, but different bundle IDs use separate model storage.'
  fi
fi

# Copy to new inodes before stopping the running app. Never overwrite a live
# signed executable in place, and never delete its sandbox, models, or defaults.
staging=$(mktemp -d /Applications/.Hex-install.XXXXXX)
ditto "$app" "$staging/Hex.app"
codesign --verify --deep --strict "$staging/Hex.app"
echo 'Quitting the installed Hex, replacing its bundle, and preserving its data…'
# AppKit termination avoids Apple Events automation permission prompts. Match
# the installed path so Hex Debug (and other copies) can continue running.
/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
ObjC.import('Foundation');
const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
for (let i = 0; i < apps.count; i++) {
  const app = apps.objectAtIndex(i);
  if (app.bundleURL.isNil() || ObjC.unwrap(app.bundleURL.path) !== '/Applications/Hex.app') continue;
  if (!app.terminate) throw new Error('Hex refused to quit; quit it manually and retry.');
  for (let attempt = 0; attempt < 100 && !app.terminated; attempt++) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
  }
  if (!app.terminated) throw new Error('Hex is still running; quit it manually and retry.');
}
JXA
if [[ -e $destination ]]; then
  mv "$destination" "$staging/Previous.app"
fi
mv "$staging/Hex.app" "$destination"
if [[ ${1:-} != --no-open ]]; then
  open "$destination"
fi
echo "Installed Hex $app_version at $destination ($bundle_id)."
