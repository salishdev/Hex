# XcodeGen migration validation

Validated locally on 2026-10-21 with Xcode 27.1 / Swift 6.4 and XcodeGen 2.45.4, against the project at `1f6e2bb`.

`project.yml` and shared `.xcconfig` inputs now define the project. Development builds, CI, and release packaging invoke `scripts/generate-project.sh`; direct Xcode use starts with `bun run project:generate`. Generated configuration and schemes are removed from tracking. Both Swift package lockfiles remain tracked and unchanged. No dependency revisions, app behavior, source version defaults (0.8.5 / 92), local signing configuration, or release publication behavior changed. This build-system migration does not require a user-facing changeset.

## Checks

- `bun install --frozen-lockfile`, project generation, and `bun run dev` passed.
- Created an isolated git checkout of the migration snapshot with only the committed lockfile inside `Hex.xcodeproj`. Hid the globally installed XcodeGen from `PATH`: the script downloaded the pinned official release, verified its SHA-256, and generated successfully. Repeated generation preserved every tracked file's hash and left git status clean. Confirmed the app lockfile is the only tracked file inside the project.
- Compared all explicit project/app/test Debug and Release build settings with the baseline. They match except for the added `TEST_TARGET_NAME = Hex`, which makes XcodeGen emit the existing `TestTargetID` host association. Both configuration-specific test host paths are preserved.
- Compared effective Debug and Release app settings via `xcodebuild -showBuildSettings -json`. Identity, signing, entitlements, deployment target, version expansion, product/module names, and Debug-only Inject linker flags match. The generated scheme omits two baseline coverage metadata values (`CLANG_COVERAGE_MAPPING` and `CLANG_PROFILE_DATA_DIRECTORY`); coverage was not enabled in the baseline scheme. Scheme action configurations and Inject environment variables are preserved.
- Debug app passes `codesign --verify --deep --strict`; Apple Development authority, team `WW59U84Z7X`, hardened runtime, arm64 architecture, bundle ID `com.salishdev.Hex.debug`, and version 0.8.5 / 92 verified.
- Core tests: 7 XCTest plus 67 Swift Testing tests passed (74 total).
- App tests with normal development signing and with the CI ad hoc signing flags: 19 passed, one expected failure, zero unexpected failures. The expected failure remains `ModelDownloadFeatureTests.testDeletingAnotherModelDoesNotChangeSelection`.
- Developer ID Release archive succeeded with explicit version/build overrides (0.8.5 / 93) and `ARCHS=arm64`, without editing source version values. This is a validation archive, not a published build.
- Developer ID export succeeded. `codesign --verify --deep --strict` passed for the exported app. Verified Developer ID authority and team for the app, Sparkle framework, Updater, Autoupdate, Installer, and Downloader helpers; checked the Release bundle ID, version overrides, hardened runtime, and sandbox/network/microphone/file-selection/automation entitlements. Exported resource membership exactly matches the pre-migration export, including the compiled Icon Composer assets, localization, JSON data, audio, and changelog.
- Release preflight passed with the existing `apple-developer-store-credentials` profile.

## Local observations and scope

The first app-test attempt reused old `build/DerivedData` package artifacts and failed to link `IssueReporting` symbols into HexCore. Tests passed in a fresh DerivedData directory, including repeated development and CI signing runs. Clean existing DerivedData when switching projects if this occurs; package or source changes were unnecessary.

Xcode logs an installed CoreSimulator version mismatch. These macOS builds and tests passed despite that diagnostic. No simulator updates were made.

Full notarization, ZIP/DMG packaging, publishing, and a manual transcription/permissions smoke test are outside this migration's validation. No versions were bumped, changesets processed, or releases published.

Ignored local logs, effective-setting snapshots, test result bundles, and archive/export artifacts are under `build/verification/xcodegen/`. They are diagnostic outputs and are not required for fresh-checkout generation.
