# Storage and migration

Hex is distributed directly with App Sandbox disabled. Hardened runtime, Developer ID signing, notarization, microphone/automation entitlements, and macOS privacy permissions remain in place. Removing the sandbox does not grant microphone, Accessibility, Input Monitoring, or Automation permission automatically.

| Contents | Release location |
| --- | --- |
| Settings | `${XDG_CONFIG_HOME:-~/.config}/hex/settings.json` |
| Future user modes / scripts | Config root’s `hex/modes/` and `hex/scripts/` (reserved; no mode functionality yet) |
| History | `~/Library/Application Support/com.salishdev.Hex/history/transcription_history.json` |
| Saved audio | `~/Library/Application Support/com.salishdev.Hex/recordings/` |
| WhisperKit models | `~/Library/Application Support/com.salishdev.Hex/models/argmaxinc/whisperkit-coreml/<model>/` |
| Parakeet models | `~/Library/Application Support/com.salishdev.Hex/models/FluidAudio/<FluidAudio repo folder>/` |
| Disposable app caches | `~/Library/Caches/com.salishdev.Hex/` |
| Unsaved audio | System temporary directory |

Only absolute `XDG_CONFIG_HOME` values are honored; empty, relative, and literal tilde paths fall back to `~/.config`. Debug uses `hex-debug` and `com.salishdev.Hex.debug` data/cache/container roots. Overridden bundle IDs default to their bundle ID as the config directory name to avoid sharing another fork’s settings. An optional `HexConfigDirectoryName` Info.plist value can override the config subdirectory intentionally. Changing identity does not import another identity’s container.

## Migration behavior

Storage is prepared synchronously before file-backed settings or history can load. It checks this identity’s previous uncontainerized Application Support first, then its container Application Support and container Documents. Release additionally checks unscoped `~/Documents` for pre-container JSON. Debug and other fork identities deliberately do not import unscoped Documents or shared FluidAudio models.

Existing destination settings/history always win. Legacy JSON is validated before publication; settings and unknown JSON fields are preserved. History audio is copied before new history is atomically published with updated absolute references. Missing audio references remain unchanged. Orphaned recordings are retained too. Stable import namespaces prevent collisions among source directories; filesystem identity checks handle case-insensitive `Recordings`/`recordings` aliases. Symlinks are copied without traversing their targets; absolute symlinks may still depend on their original target.

WhisperKit models and FluidAudio’s container models (including legacy `-coreml` directory names) are copied into installed storage. Release also checks shared `~/Library/Application Support/FluidAudio/Models` and `~/.cache/fluidaudio/Models`. Old identity-local `cache/fluidaudio/Models`, `cache/FluidAudio/Models`, and container `.cache/fluidaudio/Models` are included. No dependency upgrades are required. FluidAudio 0.15.5’s `AsrModels.downloadAndLoad(to:version:)` supports an explicit path, but its implementation uses that path’s parent plus its own repository folder name. Hex preserves that folder convention. Availability, download polling, loading, Show in Finder, and deletion use this same installed root. Deletion touches only this identity’s installed copy.

WhisperKit downloads stage under the app cache root before installation. Models are persistent resources; clearing disposable caches does not remove installed models. Hex no longer changes `XDG_CACHE_HOME`, so future child commands inherit the user’s environment.

Every copied file is staged beside its destination before rename. Existing destination files are never overwritten; missing files in partially copied model trees are merged on retry. Originals and old containers are never removed. A `.unsandbox-migration-v1` marker in the data root is written only after all migration operations succeed. Later launches do not resurrect deleted data/models from old copies. If migration fails (for example, due to permissions or insufficient space), launch stops before file-backed defaults can overwrite anything; correct the filesystem problem and relaunch to retry. First launch can take time and require additional disk space for installed models. There is no automatic merging of multiple legacy histories: the highest-priority history wins, with the others preserved at their original paths.

## Verification

`StoragePathsTests` uses isolated temporary homes and synthetic content to cover path selection, container and Documents imports, recording references, original preservation, existing destinations, partial retries, model files, completion markers, missing audio, and Debug/fork isolation. Hosted app tests use a temporary storage home and ignore the user’s XDG config override, so they cannot migrate the developer’s real data. `ParakeetStorageTests` exercises FluidAudio’s availability checks for both model versions with synthetic filenames and checks deletion scope.

Manual release validation should still exercise a real first upgrade with a backed-up container, recording/playback/deletion, both model engines, and macOS privacy prompts. It should also verify the final exported Developer ID app’s signature and hardened runtime. No real user transcripts need to be inspected for this check.

Verification on 2026-10-21 (Xcode 27.1): core tests passed (85 total, including 10 storage tests); app tests passed (20, including both Parakeet variants). Signed Debug and Developer ID Release builds succeeded. Both dependency lockfiles stayed unchanged. On this toolchain, reusing normal-build artifacts for app tests produced transitive IssueReporting/PerceptionCore linker failures; a fresh `-derivedDataPath build/TestVerification` passed without dependency upgrades. Signing verification checks hardened runtime, retained audio/automation entitlements, and absence of App Sandbox; normal local Release builds need `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` for this inspection because build actions otherwise inject development entitlements. Distribution continues to use the existing archive/export/notarization workflow.

A zero-byte legacy history file is treated as empty history and migrated to valid empty JSON; the original file is retained. Nonempty malformed history still stops migration so recoverable entries cannot be silently discarded.
