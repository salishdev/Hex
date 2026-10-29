#!/bin/bash
# Use an exact installed version, or bootstrap the official, checksummed binary.
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the release metadata for local builds too, without requiring Bun in Xcode CI.
marketing_version=$(/usr/bin/plutil -extract version raw -o - package.json)
[[ $marketing_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'package.json must contain a stable x.y.z version.' >&2; exit 1;
}
version=$(cat .xcodegen-version)
checksum=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
tool="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -n ${XCODEGEN_BIN:-} ]]; then
  [[ $("$tool" --version) == "Version: $version" ]] || {
    echo "XCODEGEN_BIN must point to XcodeGen $version." >&2; exit 1;
  }
elif [[ -z $tool || $("$tool" --version) != "Version: $version" ]]; then
  tool="$PWD/build/tools/xcodegen-$version/xcodegen/bin/xcodegen"
  if [[ ! -x $tool ]]; then
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    curl -fL --retry 3 "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip" \
      -o "$temporary/xcodegen.zip"
    echo "$checksum  $temporary/xcodegen.zip" | shasum -a 256 --check
    unzip -q "$temporary/xcodegen.zip" -d "$temporary/unpacked"
    mkdir -p "$(dirname "$(dirname "$tool")")"
    cp -R "$temporary/unpacked/xcodegen/." "$(dirname "$(dirname "$tool")")/"
  fi
fi
[[ $("$tool" --version) == "Version: $version" ]] || {
  echo "Expected XcodeGen $version; remove build/tools and retry." >&2; exit 1;
}

# This is the sole committed file inside the generated project. Never delete it.
lockfile=Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
before=$(shasum -a 256 "$lockfile")
HEX_MARKETING_VERSION="$marketing_version" "$tool" generate --spec project.yml
[[ $(shasum -a 256 "$lockfile") == "$before" ]] || {
  echo 'Project generation changed Package.resolved; review before building.' >&2; exit 1;
}
