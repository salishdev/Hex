# Distribution through GitHub Releases

This fork packages locally using Apple Developer ID signing and notarization. Artifacts are reviewed and published on GitHub separately. There is no tag-triggered publishing workflow and no S3 dependency.

The product name remains Hex while branding is being decided. Before the first public release, finalize the name and bundle ID (`Config/Fork.xcconfig`); changing a published bundle ID creates a separate application with new permissions and storage.

## One-time setup

1. Install full Xcode, Bun, and GitHub CLI. Run `bun install --frozen-lockfile` at the repository root.
2. Install your Developer ID Application certificate and private key in Keychain. Inspect available identities with `security find-identity -v -p codesigning`.
3. This machine already has the working profile `apple-developer-store-credentials`. On another machine, configure credentials locally (choose a new profile name):

   ```bash
   xcrun notarytool store-credentials hex-notary --team-id WW59U84Z7X
   ```

   Enter your Apple ID and an app-specific password in the secure prompts. Alternatively use the API-key options supported by `notarytool store-credentials --help`. Never add credentials or exported signing keys to the repo.

This development machine has Astere Software LLC certificates for team `WW59U84Z7X`. The packaging command requires an explicit team and keychain profile so other developers can use their own accounts.

## Prepare a version

The release maintainer reviews pending changesets, then runs:

```bash
bun run changeset:status
bun run changeset:version
bun run sync-changelog
```

Review `package.json`, `CHANGELOG.md`, and `Hex/Resources/changelog.md`, then commit the release changes. Agents should only create changeset fragments, not process them.

The archive takes its marketing version from `package.json` and its build number from `BUILD_NUMBER`. It does not edit source metadata. Choose an unused integer greater than the last shipped build; upstream ended at 92. Never reuse a build number for a different artifact.

## Package

Check prerequisites first (replace the sample build number):

```bash
TEAM_ID=WW59U84Z7X BUILD_NUMBER=93 NOTARY_PROFILE=apple-developer-store-credentials \
  bun run release --check
```

Then, from a clean committed checkout:

```bash
TEAM_ID=WW59U84Z7X BUILD_NUMBER=93 NOTARY_PROFILE=apple-developer-store-credentials \
  bun run release
```

If multiple distribution identities are installed, set `SIGNING_IDENTITY` to the exact certificate name. The script archives for Apple Silicon, exports using Xcode’s Developer ID export, verifies signatures and metadata, submits the app to Apple, staples its ticket, builds a ZIP and DMG, signs/notarizes/staples the DMG, and writes SHA-256 checksums.

Outputs are in `build/releases/<version>-<build>/`. A failed run retains intermediate artifacts and logs; inspect the error before removing that output folder and retrying. If Apple rejects an upload, use the submission ID with `xcrun notarytool log <id> --keychain-profile apple-developer-store-credentials` to inspect the reason.

Test the packaged app from `/Applications` on a clean account or another Mac: first launch, permissions, model download, transcription, paste, and the releases link. Confirm microphone access and hotkeys after relaunch.

## Publish after review

Create a draft release and upload the reviewed files. For example, after replacing the version and build:

```bash
gh release create v0.8.6 \
  build/releases/0.8.6-93/Hex-0.8.6.zip \
  build/releases/0.8.6-93/Hex-0.8.6.dmg \
  build/releases/0.8.6-93/SHA256SUMS \
  --repo salishdev/Hex --target "$(git rev-parse HEAD)" \
  --draft --title 'Hex 0.8.6' --notes-file /path/to/release-notes.md
```

Use release-specific notes from the changelog, including any known limitations. Verify the draft’s target commit and attachments before publishing in GitHub. Packaging alone never creates a tag or release.

## Updates and Homebrew

The upstream Sparkle feed and public key have been removed. “Check for Updates” opens `https://github.com/salishdev/Hex/releases`. For automatic installation later, generate a new Sparkle key pair, add the fork-owned `SUFeedURL` and `SUPublicEDKey`, sign update archives, and publish an appcast. Keep the private key in Keychain. Test a real update between two signed fork builds before shipping it.

Homebrew distribution can follow the first public release; create a fork-owned cask with an exact version and SHA-256. The old upstream cask has been removed to avoid installing upstream builds.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Sparkle setup and signing](https://sparkle-project.org/documentation/).
