# Transcription modes and script processors

Status: implemented with automated verification. Live microphone and visual UI review remain manual acceptance checks. The v1 defaults below are the implemented behavior.

## Goal and agreed direction

Let users select a named mode that turns dictation into useful output, such as notes or a chat message. Hex edits the instructions; a user-selected script or process performs the transformation. Users can reuse one installed CLI agent across multiple modes with different instructions.

Keep the first release small: each mode has no processor or one processor. Scripts can implement their own pipelines. Hex does not manage LLM providers, credentials, or models for text processing.

Agreed interface:

- stdin: UTF-8 dictated text, closed after writing so readers receive EOF.
- stdout: UTF-8 final text, used only after successful completion.
- stderr: diagnostics, separate from output.
- `HEX_PROMPT_FILE`: absolute path to a temporary UTF-8 file containing the mode's instructions. Scripts may ignore it.
- Modes reference reusable processor configurations.
- A processor declares whether it uses mode instructions; this controls prompt editor visibility, not enforcement.
- The editor and external tools use the same `prompt.md` file.
- Testing runs the real processor against sample text and current unsaved edits, without pasting or adding history.

## Dependency: unsandboxing and storage

The separate agent is implementing branch `feat/unsandbox-storage` in `/Users/jjones/Developer/salishdev/Hex-unsandbox`. Integrate and review that work before implementing this plan; branch names are handoff context, not a permanent dependency.

Use its final storage APIs rather than creating another path resolver or migration. Expected configuration root is `${XDG_CONFIG_HOME:-~/.config}/hex`, with isolated Debug configuration. Persistent history/audio/models remain in macOS Application Support and disposable caches in Library/Caches.

Verify that the integrated app can launch installed tools, retains hardened runtime/signing, preserves existing user data, and no longer passes a Hex-private `XDG_CACHE_HOME` override into child processes. Resolve any differences from these expectations before starting.

## Proposed v1 defaults

1. Keep microphone, speech model, language, hotkey semantics, and output transport global. Modes own name, instructions, optional processor, and final formatting overrides.
2. Keep existing word removals/replacements global initially. Apply them before processing; apply lowercase/punctuation formatting after processing. Mode formatting fields inherit global settings unless explicitly overridden. No generic step editor.
3. Start with a working Dictation mode, with no processor, selected by default. Offer Notes and Message as creation templates with example instructions. Require users to choose/configure a processor before enabling those templates; no automatic CLI detection or installation.
4. Select the active mode in the menu bar and show it in the recording indicator. No per-mode recording hotkeys or automatic app selection in v1.
5. Preserve existing automatic paste behavior on success. If the foreground application changed, retain the result and offer Copy/Paste explicitly rather than automatically changing focus.
6. On failure, preserve the original transcript and offer Retry, Copy original, and Paste original. Never silently substitute raw text or paste partial output. Empty/whitespace-only successful output is an error in v1, not a discard command.
7. Use a 30-second default timeout, configurable from 1 to 300 seconds. Permit at most 4 MiB of stdout and 256 KiB of stderr per run; terminate on exceeding either limit and identify the cause. These are implementation defaults, not a new user-facing quota system.
8. Commands are user-trusted automation. Hex provides no agent permission bypass flags and does not claim that stdin-only input limits a script's filesystem/network access.

These defaults can be adjusted before implementation without changing the basic text-filter contract.

## Configuration model and files

Proposed layout under the resolved configuration root:

```text
settings.json                 # includes selectedModeID
modes/
  <stable-mode-id>/
    mode.json
    prompt.md
processors/
  <stable-processor-id>.json
scripts/
  my-agent.sh
```

Use stable IDs for references and directory names; renaming a mode must not move its directory. Display names can contain ordinary user text. File names must not be derived from untrusted display names.

`TranscriptionMode` fields: schema version, stable ID, display name, optional processor ID, optional final formatting overrides. Instructions live in `prompt.md`, not a duplicate JSON field.

`ProcessorConfiguration` fields: schema version, stable ID, display name, absolute executable path, argument array, optional absolute working directory, uses-mode-instructions flag, and timeout. Do not persist credentials or duplicate the tool's authentication configuration.

Use direct executable/argument launching. Support arbitrary shell pipelines through a wrapper script or an explicitly selected shell with explicit arguments. Do not introduce implicit shell parsing, transcript interpolation, prompt substitution, or an argument-template language. Scripts outside Hex's scripts directory may also be selected.

Configuration writes must be atomic. Validate schema, IDs, references, paths, and limits before activating a configuration. Never execute imported/externally edited configuration merely because it was loaded. Missing/broken configuration should be visible and recoverable, without silently replacing the user's files.

Handle external edits on app activation and via file observation. An open editor tracks its loaded revision: if an external edit conflicts with unsaved edits, offer Reload or Keep my edits before overwriting. Ignore own-write notifications and incomplete/invalid intermediate saves. A deleted selected mode falls back to Dictation; a deleted referenced processor leaves its mode visibly unavailable. In the UI, prevent processor deletion until its modes are reassigned or detached.

## Processing client and execution

Introduce a TCA dependency `TextProcessorClient` with a value-type request and result. Share it between transcription and the test editor. Keep Foundation process orchestration in the live implementation and data models in HexCore where practical.

Request contains an immutable snapshot of input text, prompt, processor configuration, and a run ID. A recording snapshots its selected mode, processor, instructions, cleanup/formatting settings, and source application at recording start. Changes in Settings cannot alter an in-flight recording.

For each run:

1. Validate the request. Resolve a documented executable environment without assuming interactive shell startup files are loaded. Prefer explicit executable paths; provide conventional Homebrew/system search paths for script subprocesses, with a documented inherited-PATH policy. Use the real user home, and default working directory to the user's home unless configured otherwise.
2. Create a private per-run temporary directory and prompt file with restrictive permissions. Set `HEX_PROMPT_FILE` only in this child's environment; never mutate global environment variables for a run. Supply an empty prompt file even when instructions are unused so the contract stays consistent.
3. Launch with separate stdin/stdout/stderr pipes, concurrently write input and drain both output streams, and enforce bounded buffering. Preserve output text except for the agreed empty-output validation; do not arbitrarily strip formatting/newlines.
4. Await exit and pipe completion. Require successful exit and valid UTF-8 output. Report launch, input/output, exit, timeout, invalid encoding, and output-limit failures distinctly. A CLI printing progress to stdout is a script configuration problem; show that clearly in the test view.
5. Remove temporary input/prompt files and release handles on every exit path. Keep content out of normal logs. Diagnostics displayed in the UI may contain private text; do not automatically persist stderr in history.

Prototype cancellation before committing to a low-level launch API: a wrapper can spawn descendants. Validate a process-group/session strategy that terminates the run's descendants without signaling Hex or unrelated processes. Use graceful termination followed by bounded escalation where supported. Cancelling must prevent all subsequent paste/history mutation from the cancelled run even when a descendant cannot be killed. Do not ship a claim of full cancellation based only on terminating the immediate shell.

The app must not require a TTY or answer authentication/approval prompts for tools. The test UI should explain that processors must run noninteractively and emit only final text on stdout. Initial built-in guidance can be tool-neutral; any later CLI-specific examples must verify current official CLI syntax and avoid assuming subscription/authentication compatibility.

## Recording lifecycle and delivery

Refactor `TranscriptionFeature` around an explicit session ID and phases such as recording, transcribing, processing, and delivering. Busy/cancel handling must cover processing and final delivery; current booleans clear before final persistence/paste, so do not simply append a new effect to that path.

Flow:

```text
record -> raw transcript -> global cleanup/replacements
       -> optional processor -> final formatting
       -> save result (if enabled) -> deliver
```

Preserve existing force-quit voice command handling on raw speech results, before external processing. Preserve scratchpad behavior: when the remapping scratchpad is focused, bypass processing and text modifications so it receives raw transcription.

Guard every async result with the run ID. Escape, a superseding recording, and explicit cancellation invalidate the session; late results must never paste, overwrite another result, or append a successful history entry. Recheck cancellation and foreground destination immediately before delivery. Holding saved results and audio must have explicit ownership/cleanup paths so cancellation/failure cannot orphan temporary recordings.

If the foreground application's bundle ID differs from the captured source, show a ready result with Copy and explicit Paste actions. Do not claim window-level destination protection: switching fields/windows within the same app is not detected in v1. Transcription/processing errors should not force focus away from the user's work.

## History and recovery

Extend the existing Transcript model compatibly with optional original text, processor-input text (after cleanup), mode ID/name snapshot, and processing outcome. Keep `text` as the final delivered output for successful entries so existing paste-last behavior stays useful. Store enough mode/processor/prompt snapshot information with enabled history to make Retry reproducible without relying on mutable mode files; keep private artifacts in history storage, never configuration. Clearly distinguish stored original, processor input, and final output.

For old entries, treat existing text as the only available output; do not invent a raw transcript. Preserve existing audio playback and retention behavior.

For failed processing with history enabled, preserve recoverable text/audio and failure status, and make paste-last select the latest successful usable output rather than a failed entry. With history disabled, recovery exists only in memory and audio is cleaned up when the result is dismissed, cancelled, superseded, or the app exits normally. Do not secretly enable persistence for recovery. Reprocessing historical entries with a different mode is deferred; Retry reruns the captured processing request without retranscribing audio.

## UI work

- Settings: a compact Modes list with create-from-template, duplicate, rename, and delete; mode editor with processor picker, conditional instructions editor, formatting overrides, and Test area.
- Processor configuration: reusable list/editor with executable picker, argument rows, working directory, timeout, uses-instructions flag, and Show/Edit script actions. New modes can create a processor without leaving their workflow.
- Test area: sample input, Run/Cancel, output, errors/stderr, elapsed time, and dirty-state handling. Editing while a test runs does not change that run. Stale test results must not be presented as matching newer edits.
- Menu bar: active-mode selection and clear unavailable state. No focus-stealing mode picker during recording.
- Indicator: active mode plus processing state and cancellation support.
- History/recovery: original/output comparison and explicit recovery actions. Never paste directly from a test.

## Implementation sequence

1. Integrate unsandboxing, inspect final storage APIs, and record any deviations from the assumptions above.
2. Implement versioned mode/processor models, validated file persistence, Dictation bootstrap, external-edit handling, and backwards-compatible history fields. Ensure old users retain current dictation behavior.
3. Build the processing dependency and validate stdin/stdout/stderr handling, prompt files, environment, bounded output, timeout, and process-tree cancellation with small local fixture programs/scripts.
4. Refactor recording sessions and integrate processing, immutable snapshots, original/output history, recovery, and guarded delivery. Keep scratchpad and hotkey semantics intact.
5. Build mode/processor editors, shared Test UI, menu selection, processing indicator, and history/recovery presentation. Add Notes/Message creation templates.
6. Document script contract, noninteractive requirements, environment/path rules, example wrapper structure, privacy implications, file layout, and recovery behavior. Add a user-facing changeset via the required noninteractive script. Do not process changesets or publish releases.

## Verification and acceptance

Use targeted tests for behavior that crosses async, persistence, and process boundaries:

- Configuration: old-settings defaults, stable references after rename, missing processor, invalid external saves, conflict detection, isolated Debug paths, and no automatic execution on load.
- Process integration: Unicode and multiline stdin/prompt/output, EOF, noisy stderr, nonzero exit, launch failure, empty output, invalid UTF-8, input broken pipe, concurrent pipe draining, output limits, timeout, cancellation, descendant cleanup, and temporary-file cleanup.
- Reducer lifecycle: mode/prompt changes during recording, processing cancellation and new-recording races, stale responses, destination app changes, scratchpad bypass, failure recovery, save-history-disabled behavior, failed-entry paste-last filtering, and unchanged no-processor dictation.
- Test editor: current unsaved prompt is used; cancellation works; no paste, recording history, or audio retention side effects.
- Compatibility: old history still decodes and plays audio; cleanup and final formatting preserve their documented order.

Run `bun run test:core`, appropriate app tests, and a generated-project app build. Preserve lockfiles and avoid unrelated dependency upgrades. Manually exercise a real installed CLI configured by the developer, including its normal credentials and a wrapper that spawns a child. Validate cancellation with harmless fixture processes rather than arbitrary user workloads. Record results and any environment limitations.

Acceptance: a user configures one processor, creates Notes and Message with different instructions, switches modes, dictates and receives the corresponding output, edits instructions inside or outside Hex, and tests changes without pasting. Dictation works unchanged without any CLI configured. Failures and cancellation never paste partial/stale results or lose the original text while recovery remains available.

## Deferred

Per-mode hotkeys, automatic app-based mode selection, application/clipboard/selection context, template variables, arbitrary environment-variable editors, multiple Hex-managed processing steps, streaming paste, automatic agent installation, provider APIs, prompt revision history, historical reprocessing with another mode, and external sync services.

## Implementation record (2026-10-21)

- Integrated `feat/unsandbox-storage` (`f4d8e00`) by fast-forward before implementation. The final APIs are `HexStoragePaths.live.config`, `.recordings`, `.history`, and identity-specific model/cache roots. No second migration/path resolver was introduced. Hardened runtime and Apple Development signing remain enabled; the app no longer exports a private XDG cache override.
- Implemented mode/processor JSON and shared prompt files, Dictation bootstrap, Notes/Message drafts, revision conflict checks, directory observation plus activation refresh, reusable processor editing, menu selection, indicator phases, and the shared real-process Test area.
- Implemented direct `posix_spawn` execution with separate concurrently serviced pipes, private per-run prompt files, a documented environment, output limits, timeout, process-group TERM/KILL escalation, and app-exit cleanup. The process-group leader remains unreaped until signaling finishes to avoid PID reuse while cleaning descendants. Deliberately detached descendants can escape the group; the UI/docs do not promise universal descendant termination.
- Added recording IDs and immutable snapshots, guarded foreground delivery, recoverable failures, captured-request Retry, compatible original/input/output history fields, failed-entry paste-last filtering, retention, and explicit temporary-audio ownership. Audio persistence copies from the owned temporary recording so disabling history during a save can retain only in-memory recovery and remove the persistent copy.
- Validation: `bun run test:core` passes (19 XCTest cases plus 77 Swift Testing tests). Generated-project app tests pass (31 passes and one existing expected failure, zero unexpected failures). Signed Debug build and strict signature verification pass. Both dependency lockfiles are unchanged. The first test attempt hit stale cached package-linker symbols; fresh derived output resolved it.
- Core fixtures cover UTF-8/multiline text and prompt, EOF, simultaneous streams, whitespace preservation, nonzero exit, missing executable, empty/invalid output, broken input pipe, both output limits, timeout, descendant cancellation, and prompt cleanup. Reducer tests cover snapshots/stale results, processing cancellation, destination changes, scratchpad bypass, unpublished-audio cleanup, history-disabled failure recovery, current unsaved test instructions, stale test output, and the existing recording races.
- The signed-app end-to-end fixture runs one real shell processor through Notes and Message, confirms distinct captured prompts, checks cleanup/replacements before processing, and verifies temporary-audio cleanup without saving history. Missing selected modes cannot silently start raw dictation; template Save/Duplicate require a processor. Edit Script explicitly opens TextEdit instead of executing a default file handler.
- Added [script-processors.md](script-processors.md) and a minor changeset; no changesets were processed and nothing was published.

Manual acceptance limitations: the computer-use service returned `cgWindowNotFound` for Hex, so visual UI inspection could not be completed in this session. Live speech recognition still needs a developer pass. The developer subsequently selected Codex: the noninteractive wrapper was verified with piped synthetic dictation and existing CLI authentication, returning only final transformed text on stdout in 3.7 seconds. The saved processor was corrected to use the wrapper and separate model flag/value arguments; credentials and local processor configuration are not part of this repository.

Local Release installation succeeded at `/Applications/Hex.app`. The first launch revealed a zero-byte legacy history file; migration now handles that as empty history while retaining the original and rejecting nonempty malformed data. The regression test and full core suite pass (19 XCTest cases plus 77 Swift Testing tests). The reinstalled signed Release app remains running, migration completed, and the legacy history file remains untouched.
