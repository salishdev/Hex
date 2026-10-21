# Hex — Salish fork

An independently maintained fork of [Kit Langton’s original Swift Hex](https://github.com/kitlangton/Hex), an MIT-licensed macOS menu bar app for on-device voice-to-text. This fork is developed at [salishdev/Hex](https://github.com/salishdev/Hex). The product name is provisional.

Hold a hotkey to dictate and release to transcribe, or double-tap to lock recording and tap again to finish. Transcripts can be pasted into the active app. Speech recognition runs locally with Parakeet (FluidAudio) or Whisper (WhisperKit); initial model downloads require internet access.

Apple Silicon, macOS 14 or newer. Grant microphone, Accessibility, and Input Monitoring permissions when prompted. The fork has its own app identity and storage, so permissions and models must be configured separately from upstream Hex.

## Development

Install full Xcode (26 or newer), select it with `xcode-select`, finish its first-launch setup, and install [Bun](https://bun.sh).

```bash
bun install --frozen-lockfile
cp Config/Local.xcconfig.example Config/Local.xcconfig
# Set HEX_DEVELOPMENT_TEAM in Config/Local.xcconfig to your Apple Developer team.
bun run project:generate
open Hex.xcodeproj
```

Run the Hex scheme in Xcode, or build from the terminal:

```bash
bun run dev
open 'build/DerivedData/Build/Products/Debug/Hex Debug.app'
bun run test:core
```

Debug uses `com.salishdev.Hex.debug`; Release uses `com.salishdev.Hex`. Change the shared base identifier in `Config/Fork.xcconfig`. Local signing settings are ignored by git. Apple Development signing gives stable macOS permission grants during development.

To dogfood an optimized Release build from your working tree:

```bash
bun run install:local
# Install without launching:
bun run install:local --no-open
```

This builds incrementally, quits the installed Hex, replaces `/Applications/Hex.app`, and launches it. It uses Apple Development signing from your local configuration, without archiving or notarization. Build output is saved to `build/install-local.log`; cached build products live in `build/LocalReleaseDerivedData`. Run as your normal user with write access to `/Applications`.

Keep the bundle ID, signing team, and certificate type stable between installs so macOS can recognize permission grants. Models, preferences, and history remain in the app's existing storage. Switching from upstream Hex or Hex Debug uses a different identity: grant permissions and configure models once for the Release app. New settings default to Parakeet v2 for English; v3 remains available for multilingual transcription. Existing model selections are preserved. Switching later to Developer ID signing may also prompt for permissions again; see [Apple's code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

`project.yml` and the shared `Config/*.xcconfig` files are the project source of truth. Edit those inputs instead of changing generated project settings in Xcode. `bun run project:generate` uses the exact XcodeGen version in `.xcodegen-version` (currently 2.45.4). If that version is not installed, it downloads the official release, checks its SHA-256, and installs it locally under ignored `build/tools/`. No global installation is required. To use an existing binary explicitly, set `XCODEGEN_BIN`; its version must match. When updating the pin, also update the release checksum in `scripts/generate-project.sh` and the minimum version in `project.yml`.

Development builds, CI, and release packaging generate the project automatically. Generate before opening Xcode directly or running a raw `xcodebuild` command. The generated project and scheme are ignored; the app's `Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` remains committed and is preserved during generation. Do not delete the entire `.xcodeproj` directory when cleaning build outputs.

When first switching from the hand-maintained project, clean existing DerivedData if app tests report unresolved package symbols. A fresh DerivedData directory avoids stale package linkage from the old project.

App tests:

```bash
bun run project:generate
xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile
```

CI runs core and app tests on pull requests and pushes to `main`. Swift package lockfiles are checked in; review dependency updates deliberately.

## Distribution

Signed, notarized ZIP and DMG downloads will be distributed through this fork’s GitHub Releases. See [the release guide](docs/release-process.md) for signing setup, packaging, and publication. Until the first fork release, build from source.

“Check for Updates” opens this fork’s releases page. Automatic Sparkle updates remain inactive until a fork-owned feed and signing key are configured.

## Changes

Every user-facing change needs a fragment:

```bash
bun run changeset:add-ai patch "Describe the user-facing change (#issue)"
bun run changeset:status
```

Use `minor` for new features and `major` for breaking changes. The release maintainer processes fragments when preparing a version; agents create fragments only.

## License

[MIT](LICENSE). Original copyright and attribution are preserved.
