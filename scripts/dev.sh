#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  build "$@"
