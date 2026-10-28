# Distribution through GitHub Releases

This fork packages locally using Apple Developer ID signing and notarization. App Sandbox is disabled; hardened runtime, audio input and automation entitlements, privacy descriptions, Developer ID signing, and notarization remain required. See [storage and migration](storage.md). Artifacts are reviewed and published on GitHub separately. There is no tag-triggered publishing workflow and no S3 dependency.

The product name remains Hex while branding is being decided. Before the first public release, finalize the name and bundle ID (`Config/Fork.xcconfig`); changing a published bundle ID creates a separate application with new permissions and storage.

## One-time setup

1. Install full Xcode, Bun, and GitHub CLI. Run `bun install --frozen-lockfile` at the repository root. The packaging entry point generates `Hex.xcodeproj` with the pinned XcodeGen version automatically, including during `--check`; the generation script bootstraps the checksummed tool under `build/tools/` if needed. See [development setup](../README.md#development).
2. Install your Developer ID Application certificate and private key in Keychain. Inspect available identities with `security find-identity -v -p codesigning`.
3. This machine already has the working profile `apple-developer-store-credentials`. On another machine, configure credentials locally (choose a new profile name):

   ```bash
   xcrun notarytool store-credentials hex-notary --team-id WW59U84Z7X
   ```

   Enter your Apple ID and an app-specific password in the secure prompts. Alternatively use the API-key options supported by `notarytool store-credentials --help`. Never add credentials or exported signing keys to the repo.

This development machine has Astere Software LLC certificates for team `WW59U84Z7X`. The packaging command requires an explicit team and keychain profile so other developers can use their own accounts.

## Guided release command

From a clean committed checkout, run the full process in an interactive terminal:

```bash
TEAM_ID=WW59U84Z7X BUILD_NUMBER=93 NOTARY_PROFILE=apple-developer-store-credentials \
  bun run release:run
```

Replace `93` with an unused build number greater than the last shipped build. The command checks signing prerequisites, fetches tags, drafts missing changesets, pauses for editing, shows the Changesets plan, and asks before applying the version/changelog updates and creating a release commit. It then runs the release-tooling and core tests, packages the app, and generates release-specific notes. It pauses for you to confirm CI passed and test the packaged app. After a final prompt it pushes the current branch to `origin` and uploads a **draft** release to `salishdev/Hex`. It does not publish the release or deploy a Sparkle feed. The existing `bun run release` command remains packaging-only.

Keep this terminal open while reviewing files at each prompt; answer `y` to continue or anything else to stop. To edit notes before upload, use the printed `build/releases/<version>-<build>/release-notes.md` path. Check both the package output and GitHub draft before publishing.

Resume using the same environment variables and one of these options:

- `--from version`: review and process existing changesets without redrafting them. Commit reviewed drafts first so the checkout is clean.
- `--from package`: skip versioning when the release version/changelog are already committed. This is the appropriate starting point for a manually prepared release.
- `--from draft`: reuse artifacts from a successful `release:run` packaging stage. The command verifies their recorded commit, version, build number, and checksums. It still asks for test confirmation and upload approval. For artifacts built directly with `bun run release`, create the draft manually using the command below.

For example, after committing an already prepared version:

```bash
TEAM_ID=WW59U84Z7X BUILD_NUMBER=93 NOTARY_PROFILE=apple-developer-store-credentials \
  bun run release:run --from package
```

`--since <ref>`, `--initial`, and `--bump patch|minor|major` can be passed when starting from preparation. A stopped run retains its changes and artifacts. After a versioning stop, review and commit prepared release metadata before using `--from package`. After a packaging failure, inspect the logs and remove the failed output directory before retrying. An existing draft is never overwritten; review it in GitHub if an upload was interrupted.

## Prepare a version manually

Start by fetching tags and gathering the committed changes since the nearest reachable stable release tag (`vX.Y.Z`):

```bash
git fetch origin --tags
bun run release:prepare
```

Read `build/release-preparation.md` for the commit list and existing changeset summaries. The default command only writes this ignored report. It uses local git history, needs no GitHub API credentials, and preserves issue/PR references already in commit subjects. It does not fetch PR descriptions. Merge commits and prerelease tags are excluded; inspect merge resolutions separately if needed. Uncommitted code is outside the report.

To draft a changeset for commits without an associated pending changeset:

```bash
bun run release:prepare --write
# Override the draft's default patch bump when appropriate:
# bun run release:prepare --write --bump minor
```

Review the generated `.changeset/release-draft-*.md` before versioning. Rewrite commit subjects into user-facing notes, combine related changes, remove internal maintenance, and check bump types and issue/PR references. Association means that a commit touched a currently pending changeset; it is a heuristic, not proof of coverage. Separately authored changesets can cause duplicate draft bullets, so compare against the existing summaries. All non-merge commits remain visible in the report for review.

Provenance comments in generated drafts prevent repeated runs from drafting the same commits. Keep those comments when editing or combining summaries (including for commits intentionally omitted from notes). To change an existing draft's bump, edit its frontmatter; `--bump` only affects newly created drafts. No version, changelog, commit, tag, release, or feed is changed by preparation.

Use `--since <tag-or-commit>` to choose a different ancestor as the baseline, particularly if the nearest tag is not the last published release. If no release tag exists, fetch tags or explicitly use `--initial` to review all history. Shallow checkouts must fetch full history first. The same range options apply to `--write`.

The release maintainer then reviews pending changesets and runs:

```bash
bun run changeset:status
bun run changeset:version
bun run sync-changelog
```

Review `package.json`, `CHANGELOG.md`, and `Hex/Resources/changelog.md`, then commit the release changes. Agents should only create changeset fragments, not process them.

The archive takes its marketing version from `package.json` and its build number from `BUILD_NUMBER`. It does not edit source metadata. Choose an unused integer greater than the last shipped build; upstream ended at 92. Never reuse a build number for a different artifact.

Project settings belong in `project.yml` or the shared `.xcconfig` inputs. Generated project files are ignored and generation leaves the committed Swift package lockfile unchanged, so packaging can retain its clean-checkout requirement. Commit the specification and both app/core lockfiles when deliberately updating dependencies.

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
