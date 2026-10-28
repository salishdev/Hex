# Hex – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

## Project Overview

Hex is a macOS menu bar application for on‑device voice‑to‑text. It supports Whisper (Core ML via WhisperKit) and Parakeet TDT v3 (Core ML via FluidAudio). Users activate transcription with hotkeys; text can be auto‑pasted into the active app.

## Build & Development Commands

```bash
# Build the app
bun run dev

# Run tests (must be run from HexCore directory for unit tests)
cd HexCore && swift test

# Or run all tests via Xcode
xcodebuild test -scheme Hex

# Open in Xcode (recommended for development)
bun run project:generate
open Hex.xcodeproj
```

## Architecture

The app uses **The Composable Architecture (TCA)** for state management. Key architectural components:

### Features (TCA Reducers)
- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration
- `HistoryFeature`: Transcription history management

### Dependency Clients
- `TranscriptionClient`: WhisperKit integration for ML transcription
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework

### Key Dependencies
- **WhisperKit**: Core ML transcription (tracking main branch)
- **FluidAudio (Parakeet)**: Core ML ASR (multilingual) default model
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Release builds use the fork-owned signed update feed on GitHub Pages. Debug update checks open GitHub Releases. Published 0.9.0 predates this integration and needs a manual download of the first Sparkle-enabled release.
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HotKeyProcessor.swift`. See `docs/hotkey-semantics.md` for detailed behavior specifications including:
   - **Modifier-only hotkeys** (e.g., Option) use a **0.3s threshold** to prevent accidental triggers from OS shortcuts
   - **Regular hotkeys** (e.g., Cmd+A) use user's `minimumKeyTime` setting (default 0.2s)
   - Mouse clicks and extra modifiers are discarded within threshold, ignored after
   - Only ESC cancels recordings after the threshold

2. **Model Management**: Models are managed by `ModelDownloadFeature`. Curated defaults live in `Hex/Resources/Data/models.json`. The Settings UI shows a compact opinionated list (Parakeet + three Whisper sizes). No dropdowns.

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

6. **Logging**: All diagnostics should use the unified logging helper `HexLog` (`HexCore/Sources/HexCore/Logging.swift`). Pick an existing category (e.g., `.transcription`, `.recording`, `.settings`) or add a new case so Console predicates stay consistent. Avoid `print` and prefer privacy annotations (`, privacy: .private`) for anything potentially sensitive like transcript text or file paths.

## Models (2025‑11)

- Default: Parakeet TDT v3 (multilingual) via FluidAudio
- Additional curated: Whisper Small (Tiny), Whisper Medium (Base), Whisper Large v3
- Note: Distil‑Whisper is English‑only and not shown by default

### Storage Locations

See [docs/storage.md](docs/storage.md) for the full layout and copy-only migration.

- Settings: `${XDG_CONFIG_HOME:-~/.config}/hex/settings.json` (Debug: `hex-debug`). Only absolute XDG roots are honored. Other bundle IDs use their bundle ID as the config directory name.
- History and recordings: `~/Library/Application Support/<bundle-id>/history/` and `recordings/`.
- Installed models: `~/Library/Application Support/<bundle-id>/models/`, including FluidAudio models under `FluidAudio/`.
- Disposable caches: `~/Library/Caches/<bundle-id>/`. Temporary recordings use system temporary storage.
- Do not set `XDG_CACHE_HOME` globally. Pass explicit model/cache directories to libraries.

### Progress + Availability

- WhisperKit: native progress.
- Parakeet: best-effort progress by polling its explicit installed model directory.
- Availability, loading, deletion, and Show in Finder use the same identity-specific model root.

## Building & Running

- macOS 14+, Xcode 26+

### Packages

- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio.git` (link `FluidAudio` to Hex target)

### Signing and permissions

App Sandbox is disabled for direct distribution. Keep hardened runtime, Developer ID signing/notarization, audio input and automation entitlements, and macOS privacy usage descriptions. Debug retains Apple Development signing and a separate identity.

## UI

- Settings → Transcription Model shows a compact list with radio selection, accuracy/speed dots, size on right, and trailing menu / download‑check icon.
- Context menu offers Show in Finder / Delete.

## Troubleshooting

- Repeated mic prompts during debug: ensure Debug signing uses "Apple Development" so TCC sticks
- Parakeet not detected: check the identity-specific installed model path in docs/storage.md; downloading from Hex places it correctly.

## Changelog Workflow Expectations

1. **Always add a changeset:** Any feature, UX change, or bug fix that ships to users must come with a `.changeset/*.md` fragment. The summary should mention the user-facing impact plus the GitHub issue/PR number (for example, "Improve Fn hotkey stability (#89)").
2. **Use non-interactive changeset creation:** AI agents should use the non-interactive script:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   bun run changeset:add-ai minor "Add new feature"
   bun run changeset:add-ai major "Breaking change"
   ```
3. **Ordinary development creates fragments only:** The release tool processes changesets and syncs the changelog. When the user explicitly asks an agent to make a release, the agent acts as release maintainer and may run that tool through versioning, review, commit, packaging, and authorized publication. Follow [the local-agent release runbook](docs/agent-release.md); do not treat routine script checkpoints as new user-approval requirements.
4. **Reference GitHub issues:** When a change addresses a filed issue, link it in code comments and the changeset entry (`(#123)`) so release notes and Sparkle updates point users back to the discussion. If the work should close an issue, include "Fixes #123" (or "Closes #123") in the commit or PR description so GitHub auto-closes it once merged.

## Git Commit Messages

- Use a concise, descriptive subject line that captures the user-facing impact (roughly 50–70 characters).
- Follow up with as much context as needed in the body. Include the rationale, notable tradeoffs, relevant logs, or reproduction steps—future debugging benefits from having the full story directly in git history.
- Reference any related GitHub issues in the body if the change tracks ongoing work.

## Fork Development and Distribution

- Source and releases: https://github.com/salishdev/Hex
- Product name is provisional. Default bundle ID is `com.salishdev.Hex`, with `.debug` for Debug.
- Shared identity: `Config/Fork.xcconfig`; ignored local signing override: `Config/Local.xcconfig`.
- Project source of truth: `project.yml` and shared `.xcconfig` inputs. Do not edit generated Xcode project settings or schemes. `bun run project:generate` uses `.xcodegen-version` (checksummed automatic install under ignored `build/tools/` if needed). When upgrading XcodeGen, update the pin, the script checksum, and the specification minimum together.
- Dev builds, CI, and release packaging generate automatically. Generate before opening Xcode or invoking raw `xcodebuild`. Generated project files are ignored, but the app lockfile inside `Hex.xcodeproj` stays tracked; never delete the whole directory. Preserve both app/core lockfiles and avoid dependency upgrades during unrelated work.
- `bun install --frozen-lockfile`, then `bun run dev` for a signed Debug build.
- `bun run test:core` runs the HexCore suite. Keep `IssueReportingTestSupport` linked to core tests; otherwise the runtime fallback can crash on newer Swift Testing versions.
- `.github/workflows/ci.yml` runs core and app tests. It does not publish releases.
- `TEAM_ID=... BUILD_NUMBER=... NOTARY_PROFILE=... bun run release --check` checks packaging prerequisites.
- `bun run release` with those variables packages signed/notarized ZIP and DMG files locally. It requires a clean committed tree and does not process changesets, tag, push, or publish.
- `bun run release:run` guides release preparation through a signed GitHub draft; authorized publication uses `gh release edit <tag> --draft=false` followed by feed verification. It needs a persistent interactive terminal.
- During ordinary development agents create fragments only. Explicitly authorized release tasks may run the full release-maintainer workflow, including processing changesets through the release tool.
- For a release task, read [docs/agent-release.md](docs/agent-release.md) first. See [docs/release-process.md](docs/release-process.md) for credential setup and manual commands.
