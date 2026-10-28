# Sparkle integration validation

Validated on 2026-10-28 using Xcode 27.1 and macOS 26.7.1 (Apple Silicon).

- HexCore and release-tooling suites passed locally.
- App tests passed before and after integration: 34 passed, one expected failure, zero unexpected failures. An initial test attempt used stale DerivedData and failed to link; a clean rebuild passed.
- Eleven Bun tooling tests and five Python feed tests passed. The Ubuntu CI release-tooling job also passed independently of hosted macOS runner availability.
- GitHub Pages deployment succeeded and the HTTPS appcast endpoint returned the initial empty feed. Drafts are excluded from that feed.
- Built Developer ID signed, notarized app/DMG artifacts with the fork's feed and public key (test build 94). Generated the appcast with the local Keychain account, validated its version/URL/size metadata, and independently verified the DMG's EdDSA signature with Sparkle's `sign_update --verify`.

## Install-and-relaunch test

Used isolated copies of actual Hex release binaries with bundle ID `com.salishdev.Hex.sparkletest`, display name `Hex Sparkle Test`, and independent settings/storage. Both builds used the fork's Sparkle key and Developer ID signing. The baseline app and target DMG were notarized. The production app in `/Applications/Hex.app` was left running and was not replaced.

The test app's Info.plist contained the production HTTPS feed; a `SUFeedURL` user-default override selected a loopback HTTP test server. Only this isolated test identity used the local feed. No test update was published to GitHub.

1. Baseline build 93 checked an empty feed and displayed Sparkle's up-to-date dialog.
2. Generated a local signed appcast for build 94 and served its DMG from the loopback server.
3. The baseline displayed build 94 as available while identifying its installed build as 93.
4. Selected **Install Update**, then **Install and Relaunch**.
5. Hex relaunched from the original test installation path. Its on-disk `CFBundleVersion` was 94, strict recursive signature verification passed, and Gatekeeper reported `Notarized Developer ID`.

Artifacts, app-test result bundles, and logs are retained under ignored `build/` directories. The test app and local server were stopped after validation.

## Release boundary

Hex 0.9.0 build 93 was packaged before this integration and still links update checks to GitHub Releases. Users must manually download the first Sparkle-enabled release. Future release drafts include `appcast.xml`; publishing a stable release deploys the highest published Sparkle build to Pages. The build-94 integration artifacts are test-only and must not replace the build-93 assets for 0.9.0.

Live microphone dictation and paste were not part of this updater test. They remain separate packaged-app smoke checks.
