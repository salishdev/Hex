# Release runbook for a local agent

Use this procedure when the user asks you to prepare and publish a Hex release. Run it on the signing Mac, from this repository. Signing setup and lower-level commands are documented in [release-process.md](release-process.md).

## Task scope

An explicit instruction to make and publish a release authorizes acting as the release maintainer: review changesets, run the release tool to process them, commit release metadata, sign/notarize, push the intended branch, create the draft, review it, and publish. The development rule to create fragments without processing them applies to ordinary coding tasks. Do not ask for the same authorization again at each script prompt; those prompts are review checkpoints for the agent too. If the user requested a draft only, stop at the draft.

Keep the user informed during long builds and notarization. Ask for help only for a real blocker, missing release scope, or a check you cannot perform. macOS Keychain/password prompts may require the user to act on the Mac. Never ask them to send passwords in chat, export the signing keys, or weaken Keychain permissions to bypass a prompt.

## 1. Establish the release inputs

```bash
git status --short
git branch --show-current
git remote -v
gh auth status
gh release list --repo salishdev/Hex --limit 20
git fetch origin --tags
bun install --frozen-lockfile
```

Use the branch/commit requested by the user; normally this is `main`, with `origin` pointing to `salishdev/Hex`. The checkout must be clean before starting the release tool. Review and commit release-related work when authorized; preserve unrelated user edits. Do not hide unrelated work in a release commit or discard it to make the tree clean.

Determine the last **published stable** release and its tag. The preparation helper defaults to the nearest reachable stable `vX.Y.Z` tag. If that is not the last shipped release, pass `--since <published-tag>` explicitly. Fetch full history before using a shallow checkout. An existing draft for the intended version is a resume case, not a reason to create another release or advance the version again.

Choose a build number greater than previously shipped builds and unused for a different artifact. Inspect published appcasts and local `build/releases/*/release-source.json`, archive metadata, and output directories. Historical baseline: 0.9.0 shipped as build 93; build 94 was reserved for integration testing. **95 is an example below, not an automatically selected next number.** Preserve both Swift package lockfiles and do not upgrade dependencies as part of a release.

This Mac's existing signing inputs are:

```bash
export TEAM_ID=WW59U84Z7X
export BUILD_NUMBER=95 # Replace after checking published and local artifacts.
export NOTARY_PROFILE=apple-developer-store-credentials
```

The Developer ID private key and Sparkle key must be available in login Keychain. Sparkle uses account `com.salishdev.Hex`; its public key must match `Hex/Info.plist`. Use existing credentials. On a different Mac, complete the one-time setup in the release guide before continuing.

## 2. Start the guided command in a persistent terminal

```bash
bun run release:run
```

For an agent using `exec_command`, set `tty: true`, keep the returned session ID, and use `write_stdin` to respond at each checkpoint. Keep long-running commands alive across tool calls. Do not pipe `yes` into the script: the reviews and tests must actually happen. `--since`, `--initial`, and `--bump` are available; see `bun run release:run --help`. The bump option affects only newly drafted changesets, not the existing release plan.

Respond to checkpoints as follows:

| Checkpoint | Work to finish before answering `y` |
| --- | --- |
| Review changesets | Read `build/release-preparation.md`, commit diffs/PR context, and `.changeset/*.md`. Rewrite draft subjects into user-facing notes, deduplicate, remove internal maintenance, and check issue references and bump types. Keep provenance comments for commits reviewed or intentionally omitted. Association is a heuristic, not proof of coverage. |
| Approve version plan | Read `changeset:status`; confirm its version is appropriate and not already released. Patch is the normal fallback; existing feature/breaking-change fragments may require minor/major. |
| Commit release metadata | Inspect `package.json`, `CHANGELOG.md`, and `Hex/Resources/changelog.md`. Verify changelogs match and only expected release files changed. The script commits these files and consumed fragments. |
| Test and notes review | Complete the checks below, read the release-specific notes in the printed artifact directory, and edit them for users. If the user has explicitly marked this packaged build ready, record that readiness instead of asking them to repeat it. Do not claim unperformed checks passed. |
| Push and draft upload | Confirm the target repository, intended source commit, version/build, and final artifact paths. The script signs the DMG for Sparkle, generates `appcast.xml`, pushes the branch, and uploads a draft with ZIP, DMG, checksums, and appcast. |

The script already runs tooling/core tests and verifies signing, notarization, version metadata, and checksums. At the test checkpoint, also run the app tests while leaving the release terminal open:

```bash
bun run project:generate
xcodebuild test -project Hex.xcodeproj -scheme Hex -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "build/release-app-tests-${BUILD_NUMBER}.xcresult" \
  > "build/release-app-tests-${BUILD_NUMBER}.log" 2>&1
```

Use a fresh result-bundle path if that output already exists. Stale DerivedData can cause missing-symbol linker errors after toolchain/project changes; if that occurs, inspect the error and rerun with `xcodebuild clean test`. Never delete the whole `Hex.xcodeproj` directory: its app dependency lockfile is tracked.

Check CI for the intended source commit. Hosted macOS runner capacity failures can be covered by equivalent successful local core/app tests; record the substitution. An actual test failure must be resolved before release. Do not report a queued or cancelled CI job as passing.

Exercise the packaged app's launch, permissions, model download/availability, transcription, hotkeys, paste, and relaunch. Use a clean account or an isolated test identity where practical; preserve the user's installed app, settings, and recordings. Use user-provided readiness for checks requiring their microphone/input. For changes to the updater, test a real signed install-and-relaunch between builds; [the initial validation](sparkle-validation.md) documents an isolated approach. Do not sign off on a manual check you could not perform and the user has not marked ready.

## 3. Review and publish the exact draft

After the guided command finishes, set `VERSION` from the packaged version (not from a later checkout) and inspect the draft:

```bash
VERSION=0.9.1 # Replace with the version actually packaged.
gh release view "v${VERSION}" --repo salishdev/Hex \
  --json url,isDraft,isPrerelease,targetCommitish,assets,body
```

Match `targetCommitish` to `build/releases/<version>-<build>/release-source.json`. Confirm all four expected assets are uploaded and their GitHub `digest` values match the local SHA-256 hashes. Check the appcast's version, build, DMG URL, length, and signature. Read the notes as a user would; remove drafting instructions and stale pending-test wording. Do not replace published artifacts or move an existing release tag.

When publication is within the user's requested scope and readiness checks are satisfied:

```bash
gh release edit "v${VERSION}" --repo salishdev/Hex --draft=false --latest
```

Use `--latest` for the normal newest stable release; use `--latest=false` for a deliberately older maintenance release. The user does not need to approve publication a second time if they already requested it. If publication was not authorized, deliver the reviewed draft and identify that final step.

## 4. Verify publication and the Sparkle feed

```bash
gh release view "v${VERSION}" --repo salishdev/Hex \
  --json url,isDraft,isPrerelease,targetCommitish,assets
git fetch origin --tags
gh run list --repo salishdev/Hex --workflow sparkle-feed.yml --limit 5
```

Find the **release-triggered** feed run for this publication; do not confuse it with an older successful dispatch. Watch that run to completion (`gh run watch <run-id> --repo salishdev/Hex --exit-status`), then fetch `https://salishdev.github.io/Hex/appcast.xml`. Confirm it contains the expected highest published Sparkle build and the exact release DMG URL. A late older release must not roll back the feed. If the workflow fails, inspect its failed logs, fix the deployment, and dispatch the feed workflow again; do not rebuild or re-sign unchanged published archives.

0.9.0 is the intentional exception: its source predates both Sparkle and the feed workflow and it has three assets, no appcast. If publishing an older release whose tag has no feed workflow, dispatch `gh workflow run sparkle-feed.yml --repo salishdev/Hex --ref main` and verify that run instead. Publishing 0.9.0 leaves the bootstrap feed empty. The first Sparkle-enabled release must be downloaded manually by 0.9.0 users; later updates are installed in-app.

Finish by reporting the public release URL, version/build, validation performed, Pages result, any remaining limitations, and git status. Leave source changes committed and pushed when that is within the release task. Do not leave a release described as published if it is still a draft.

## Resume after an interruption

| Last completed point | Resume action |
| --- | --- |
| Draft changesets edited, version unchanged | Review/commit the drafts so the tree is clean, then run `bun run release:run --from version`. |
| Version/changelog already prepared | Review and commit release metadata, then run `bun run release:run --from package`. Never process changesets again for that version. |
| Packaging succeeded; no GitHub draft yet | With the same source commit and environment, run `bun run release:run --from draft`. It checks the saved version/build/commit and artifact checksums. |
| Packaging failed | Inspect retained logs and Apple's rejection details if applicable. Move the failed output aside before retrying. Use a new build number if the source/artifact changes. |
| GitHub draft already exists | Inspect its target, notes, assets, and digests directly. Finish missing uploads without overwriting valid artifacts, then publish that draft when ready. Do not rerun draft creation or bump the version. |
| Release published; feed deployment incomplete | Inspect or rerun `sparkle-feed.yml` and verify the public feed. Do not create another release. |

`--from draft` requires the manifest written by `release:run`. Raw `bun run release` packaging does not create that manifest or a signed appcast. For a Sparkle release, package from the intended source through `release:run --from package` using a fresh build number; do not invent provenance afterward. The manual four-asset upload example assumes completed guided-command outputs. If HEAD changed after packaging, return to the recorded source in an isolated worktree or rebuild with a fresh build number; do not edit provenance to make mismatched artifacts appear current.

## Example instruction for a future local agent

> Read AGENTS.md and docs/agent-release.md. Prepare and publish the next stable Hex release from main, including the Sparkle feed. Review changes since the last published release and choose the Changesets version bump and an unused build number. You are authorized to process release changesets through the release tool, commit release metadata, sign/notarize, push, create the draft, and publish after the required checks. Continue through routine script checkpoints yourself; ask me only for a real blocker, Keychain interaction, or a manual smoke check you cannot perform. Report the release URL and verify the live feed before finishing.
