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
open Hex.xcodeproj
```

Run the Hex scheme in Xcode, or build from the terminal:

```bash
bun run dev
open 'build/DerivedData/Build/Products/Debug/Hex Debug.app'
bun run test:core
```

Debug uses `com.salishdev.Hex.debug`; Release uses `com.salishdev.Hex`. Change the shared base identifier in `Config/Fork.xcconfig`. Local signing settings are ignored by git. Apple Development signing gives stable macOS permission grants during development.

App tests:

```bash
xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
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
