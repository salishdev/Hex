# Transcription modes and script processors

Choose **Modes** in Settings to create a mode, or start with the Notes and Message templates. Configure a processor once and reuse it with different instructions. A template requires an explicitly selected processor before it can be saved. Dictation starts with no processor and works without installing another tool.

A processor is a trusted executable running as your user. It can read files, access the network, and use its normal credentials. Hex does not install agents, supply credentials, answer approval/authentication prompts, require a terminal, or add permission-bypass flags. Prepare and authenticate tools independently before configuring them. Use the Test area to check your command before dictating.

## Command contract

- stdin is UTF-8 dictation after global word removals and replacements. Hex closes stdin after writing it.
- stdout must contain only the final UTF-8 text. Exit with status zero to accept it. Whitespace-only output is an error. Other whitespace, including trailing newlines, is preserved before optional final formatting.
- stderr contains diagnostics, displayed separately in tests and recovery. It may contain private text. Hex does not automatically write stderr to history or normal logs.
- `HEX_PROMPT_FILE` is an absolute path to a private temporary UTF-8 file containing the mode instructions. It is supplied even for an empty prompt. Scripts may ignore it. The “Uses mode instructions” setting controls the editor's visibility.

Hex launches an absolute executable path and a literal argument array directly. There is no shell expansion, text interpolation, or argument template syntax. Use an executable wrapper script for a pipeline, or explicitly select a shell and provide its arguments.

The default timeout is 30 seconds (configurable from 1 to 300). Each run permits up to 4 MiB of stdout and 256 KiB of stderr. Exceeding either terminates the run and reports the corresponding stream. A failure never pastes partial output or silently falls back to the original dictation.

### Example wrapper

Save this as an executable script, choose it as the processor executable, and adapt the final command to your installed tool's documented noninteractive interface:

```sh
#!/bin/sh
set -eu
# This harmless example returns the input unchanged. Replace it with your tool.
# Your tool can read instructions from "$HEX_PROMPT_FILE" and dictation from stdin.
exec /bin/cat
```

Use `chmod +x /absolute/path/to/filter.sh`. Scripts may live in Hex's `scripts/` directory or any other chosen location. Keep progress messages on stderr; progress on stdout becomes part of the returned text. The Test area runs the real processor with the current unsaved prompt and processor editor values. Editing during a run does not change that run; older results are labeled when edits or sample input change. Tests do not paste or create history/audio entries.

### Environment and cancellation

Hex inherits the launching app's environment, sets HOME to the actual user home, and sets `HEX_PROMPT_FILE` only in the child environment. PATH retains inherited absolute directories in their original order, then appends missing `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `/usr/sbin`, and `/sbin`. Relative/empty PATH entries are excluded. Hex does not load interactive shell startup files and does not set a private XDG cache override. Working directory defaults to the real user home, or the processor's explicit absolute directory.

Each run starts in a new process group. Escape, Cancel in the menu, test cancellation, timeout, and output limits terminate the group with SIGTERM and escalate to SIGKILL after a short grace period. Ordinary wrapper descendants belong to that group. A process that deliberately detaches into another session/group can escape group termination. Cancelled sessions cannot deliver late results or append successful history entries. Temporary prompt files and handles are cleaned up on completion and cancellation.

## Files and external editing

Configuration uses the shared storage root described in [storage.md](storage.md): `${XDG_CONFIG_HOME:-~/.config}/hex`, or `hex-debug` for Debug. Other app identities remain isolated.

```text
settings.json                         # selectedModeID
modes/<stable-id>/mode.json            # schemaVersion, id, name, processorID, formatting
modes/<stable-id>/prompt.md            # one shared instructions file
processors/<stable-id>.json            # schemaVersion, id, name, executable, arguments,
                                      # workingDirectory, usesModeInstructions, timeout
scripts/                              # optional user wrappers
```

Rename display names freely; IDs and paths stay stable. Each configuration file is written atomically. External directory/file changes and app activation refresh configuration. Invalid files are reported and kept on disk for repair; incomplete invalid mode saves do not replace a loaded valid mode. A missing/broken processor makes its modes unavailable. Loading configuration never runs a command. Deleting the selected mode falls back to Dictation. The processor editor prevents deletion while any mode refers to it.

If external edits conflict with unsaved editor changes, choose **Reload** or **Keep my edits** before saving. “Keep my edits” acknowledges the latest disk revision; a later external change will cause another conflict. Show Files and Edit prompt.md Externally open the same files used by Hex. Save a new mode before opening its prompt file externally.

## Recording, delivery, history, and recovery

A recording captures its mode, instructions, processor, cleanup/formatting settings, language/model, and source application when recording starts. Later edits affect the next recording. The order is raw speech, global cleanup/replacements, optional processor, final lowercase/punctuation formatting, history (if enabled), then delivery. Formatting fields can inherit global settings or override them. The remapping scratchpad receives raw speech and bypasses all modifications and processors. Force-quit speech commands are recognized before processing.

The indicator shows the captured mode and current phase; Escape and the menu's Cancel action cover processing and delivery as well as recording. If the foreground application's bundle ID changes, Hex keeps a ready result and offers Copy Result and explicit Paste Result in the menu. This checks applications only; switching fields or windows within the same app is not detected.

Failures retain the original dictation and offer Retry Processing, Copy Original, and Paste Original in the menu without opening a window. Retry reuses the captured processor input, instructions, processor configuration, and formatting; it does not retranscribe the audio. History shows original dictation, processor input when different, and final output separately. Failed entries are excluded from Paste Last Transcript. Old history remains readable and playable, with its existing text as the only known output.

When history is enabled, request snapshots and recoverable audio/text are private history data in Application Support. Failed entries persist their status and captured request, but not stderr. With history disabled, recovery stays in memory and audio stays temporary; dismissal, cancellation, a newer recording, or normal app termination cleans it up. Disabling history continues to remove existing history/audio through the existing Settings behavior.

## Codex CLI example

Plain `codex` starts an interactive terminal interface and fails with “stdin is not a terminal” when launched with Hex's pipes. Use `codex exec` for noninteractive processing. Its progress goes to stderr and its final response goes to stdout. A prompt argument supplies instructions while piped stdin supplies the dictation.

An example wrapper is included at [`examples/processors/codex.sh`](../examples/processors/codex.sh). Copy it to your Hex `scripts/` directory, make it executable, and select that copy as the processor executable. Enable **Uses mode instructions**. The wrapper reads `HEX_PROMPT_FILE`, forwards literal argument rows, and runs a read-only, ephemeral Codex session outside a Git repository. It reuses your existing CLI authentication and model configuration unless you provide model arguments.

Each argument needs its own row. For example, to select a model, add `--model` in one row and your model's name in the next. A single row containing `--model some-model` is one literal argument and is not split by a shell. Leave arguments empty to use your configured model.

Verified against the installed CLI and the [official Codex noninteractive documentation](https://developers.openai.com/codex/noninteractive/). The wrapper does not provide approval or sandbox bypass flags, install Codex, or configure authentication. Run Codex's normal login flow independently if required.
