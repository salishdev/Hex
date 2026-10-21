# Handoff: migrate Hex to XcodeGen

## Objective

Replace the hand-maintained Xcode project with a committed XcodeGen specification and ignored generated project files. The owner normally uses this workflow for iOS/macOS projects and agreed it makes sense for this fork. Implement the migration while preserving the current application behavior, dependency versions, signing, and test setup.

The migration is implemented. See [validation results and local observations](xcodegen-validation.md). The remainder of this document preserves the original implementation brief and baseline.

## Starting point

- Repository: `/Users/jjones/Developer/salishdev/Hex`
- GitHub: `salishdev/Hex`
- Baseline commit: `1f6e2bb` — `Set up independent fork development and GitHub distribution`
- Working tree was clean before this handoff was added.
- Read `AGENTS.md` (a symlink to `CLAUDE.md`) before implementation.
- Hex is a macOS menu bar dictation app using TCA, WhisperKit, FluidAudio, and Sparkle.
- Product name remains **Hex**, provisionally. Naming is a separate decision; do not rename the app as part of this migration.

The previous work separated the fork from upstream identity, storage, updates, and promotional links, and established local development and GitHub distribution tooling. Preserve that work.

## Current configuration to inspect

- `Hex.xcodeproj/project.pbxproj`: authoritative baseline for targets, settings, resources, and package dependencies.
- `Hex.xcodeproj/xcshareddata/xcschemes/Hex.xcscheme`: shared build/run/test/archive behavior and Inject environment variables.
- `Hex.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: app dependency lockfile; must remain version controlled.
- `HexCore/Package.swift` and `HexCore/Package.resolved`: local package and independent core-test dependency graph.
- `Config/Fork.xcconfig`: shared fork identity and optional local signing include.
- `Config/Local.xcconfig.example`: committed example for ignored local signing settings.
- `Hex/Info.plist`, `Hex/Hex.entitlements`.
- `Hex/AppIcon.icon`, asset catalogs, bundled resources, and root-level `Localizable.xcstrings`.
- `scripts/dev.sh`, `scripts/package-release.sh`, `package.json`.
- `.github/workflows/ci.yml`, `.github/workflows/README.md`.
- `README.md`, `docs/release-process.md`, `CLAUDE.md`.

The project currently uses synchronized source folders, has two Xcode targets (`Hex`, `HexTests`), and references the local `HexCore` package. It also has several direct remote Swift package references. Inventory the actual project rather than reconstructing the package list from memory.

## Preserve these behaviors

### Identity and signing

- Base bundle identifier: `com.salishdev.Hex`, supplied by `HEX_BUNDLE_ID` in `Config/Fork.xcconfig`.
- Debug bundle identifier: `$(HEX_BUNDLE_ID).debug`; product name: `Hex Debug`; Swift module: `Hex`.
- Release bundle identifier: `$(HEX_BUNDLE_ID)`; product name: `Hex`.
- Test bundle identifier: `$(HEX_BUNDLE_ID).tests`.
- Keep the configuration-specific test host paths correct for `Hex Debug.app` and `Hex.app`.
- Development signing uses Apple Development and `HEX_DEVELOPMENT_TEAM`, with local overrides in ignored `Config/Local.xcconfig`.
- This Mac's ignored local configuration uses Astere Software LLC team `WW59U84Z7X`. Do not commit that local file or replace it during generation.
- Distribution overrides signing through command-line settings and Xcode Developer ID export. Preserve hardened runtime, sandbox, entitlements, and embedded Sparkle helper signing.
- Keep `Info.plist` version values driven by `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Existing source defaults are `0.8.5` and `92`; do not bump them for the migration.

### Build, resources, and tests

- Preserve the macOS deployment target and Apple Silicon distribution architecture.
- Preserve Debug-only Inject linker settings and scheme environment variables.
- Ensure all existing resources, including the Icon Composer icon and root localization catalog, retain the correct target membership.
- Preserve package requirements and resolved revisions. Do not combine this migration with dependency upgrades.
- Keep the `Hex` shared scheme available after generation with the same run, test, and archive configurations.
- **Keep `IssueReportingTestSupport` linked to both the HexCore test target and the Xcode app test target.** Without the public Testing bridge, the current toolchain crashes in IssueReporting's runtime-layout fallback. The Xcode test product is currently referenced without a direct remote package declaration; encode it explicitly as needed without changing its resolved version.
- Keep HexCore independently testable using `swift test` from `HexCore`.
- Automatic Sparkle updates are inactive; update checks open this fork's GitHub Releases. Do not restore upstream feed URLs or signing keys.

## Implementation expectations

1. Add a readable `project.yml` describing the current targets, packages, settings, resources, and shared scheme. Keep useful shared `.xcconfig` files as source inputs.
2. Pin the XcodeGen tool version using an appropriate lightweight repository convention and document installation. Do not rely silently on whichever version happens to be installed. Current official documentation: <https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md>.
3. Add a generation command and make project generation part of the supported development, CI, and release-packaging entry points. A fresh clone should not require an undocumented manual generation step. Document generation before opening the project directly in Xcode.
4. Stop tracking generated project configuration and schemes, and update `.gitignore` appropriately. **Keep the app's `Package.resolved` tracked**, even though it lives inside `.xcodeproj`. Avoid removing the entire directory from the index and accidentally losing the lockfile. Preserve its contents across repeated generation and fresh-checkout workflows.
5. Keep local credentials, local signing overrides, and build products ignored. Generation must not introduce tracked changes during release packaging, which requires a clean working tree.
6. Update the development/release docs, CI docs, and agent instructions to describe the new source of truth. Subsequent project-setting changes belong in the specification or shared configuration inputs.
7. Follow the repository's changeset policy if the implementation changes user-facing behavior. This should otherwise be a build-system migration. Do not process existing changesets, bump versions, publish a release, or mix in unrelated cleanup.

Use the committed baseline project to compare effective settings and behavior. Generated project UUIDs and textual ordering do not need to match. The generated project itself should not become an additional maintained source of truth.

## Validation and acceptance criteria

- Generate from a fresh checkout/worktree where generated project files do not exist, while retaining the committed lockfile.
- Generate twice and confirm source files and lockfiles remain unchanged.
- Compare effective Debug and Release build settings against the baseline, especially identity, signing, entitlements, version expansion, product names, resource membership, and test host paths.
- Run `bun install --frozen-lockfile`, the generation command, and `bun run dev`.
- Verify Debug signing and identity with `codesign` and the built `Info.plist`.
- Run `bun run test:core`.
- Run the app tests with normal development signing, and verify the CI command with ad hoc signing.
- Validate a Developer ID Release archive and export. Preserve the existing packaging script's version/build overrides and signature checks.
- Run release preflight using the existing notarization profile. Full notarization or publication is not required for a project-generation migration.
- Confirm a clean checkout remains clean after generation, excluding ignored outputs, and that both app and core lockfiles are still tracked.
- Summarize any intentional setting differences and any validation limitations in the final handoff.

### Established baseline results

On this Mac, using Xcode 27.1 / Swift 6.4:

- HexCore: 7 XCTest tests plus 67 Swift Testing tests pass (74 total).
- Xcode app suite: 19 passed, one expected failure, zero unexpected failures. The expected failure is in `ModelDownloadFeatureTests.testDeletingAnotherModelDoesNotChangeSelection`, reporting skipped assertions for an in-flight effect.
- Both development signing and the CI ad hoc signing configuration pass the app tests.
- Signed Debug build, Developer ID Release archive, and Developer ID export succeed.
- Exported app and embedded Sparkle signatures pass `codesign --verify --deep --strict`.
- Full notarization and ZIP/DMG packaging have not yet been exercised end-to-end.

Existing ignored verification outputs are under `build/verification/`; test bundles are under `build/`. These may be useful locally but must not be required by the migration.

### Existing notarization profile

The working Keychain profile is **`apple-developer-store-credentials`**. It was located through the owner's camera-project release script and successfully authenticated with a read-only `notarytool history` request. No credentials need to be recreated or displayed.

```bash
TEAM_ID=WW59U84Z7X BUILD_NUMBER=93 \
  NOTARY_PROFILE=apple-developer-store-credentials bun run release --check
```

This is a preflight example, not an instruction to create or publish build 93. Keep the product name provisional until the owner chooses final branding.
