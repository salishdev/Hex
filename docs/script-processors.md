# Transcription modes and script processors

Open **Modes** in the Hex window. The left column lists modes and tools. Click the circle beside a mode to use it when dictating; click its name to edit it. Edits save automatically shortly after you stop typing.

A mode has a name, a tool to **Rewrite with**, and instructions. Empty instructions offer starters (Notes, Message, Email, Clean up). Add a tool once and reuse it with different instructions; new modes start with the tool your other modes use most. A mode without a tool pastes dictation as-is, and a mode whose tool is missing is marked with a warning and can't be selected. Dictation starts with no tool and works without installing anything. In code and configuration files, a tool is called a *processor*.

**Add Tool…** offers Codex and Claude Code presets, a starter script, or any existing program. A preset writes a small wrapper into Hex's `scripts/` folder (an existing file with that name is kept) and relies on that CLI being installed and signed in already. Because apps opened from Finder don't load your shell's PATH, preset wrappers also look in `~/.local/bin`, `~/.npm-global/bin`, and `~/.bun/bin`, and print a clear message on stderr if the command still can't be found. For an existing program, enter one **Command** line: the absolute path, then options. Quotes and backslashes work as in Terminal, but Hex only splits the line into literal arguments; nothing is expanded or run in a shell.

A processor is a trusted executable running as your user. It can read files, access the network, and use its normal credentials. Hex does not install agents, supply credentials, answer approval/authentication prompts, require a terminal, or add permission-bypass flags. Prepare and authenticate tools independently before configuring them. Use **Try It** in a mode to check it before dictating.

## Command contract

- stdin is UTF-8 dictation after global word removals and replacements. Hex closes stdin after writing it.
- stdout must contain only the final UTF-8 text. Exit with status zero to accept it. Whitespace-only output is an error. Other whitespace, including trailing newlines, is preserved before optional final formatting.
- stderr contains diagnostics, displayed separately in tests and recovery. It may contain private text. Hex does not automatically write stderr to history or normal logs.
- `HEX_PROMPT_FILE` is an absolute path to a private temporary UTF-8 file containing the mode instructions. It is supplied even for an empty prompt. Scripts may ignore it. The instructions editor appears for every mode that has a tool. The legacy `usesModeInstructions` field is still read and written but no longer changes the editor.

Hex launches an absolute executable path and a literal argument array directly. There is no shell expansion, text interpolation, or argument template syntax. Use an executable wrapper script for a pipeline, or explicitly select a shell and provide its arguments.

The default timeout is 30 seconds (configurable from 1 to 300). Each run permits up to 4 MiB of stdout and 256 KiB of stderr. Exceeding either terminates the run and reports the corresponding stream. A failure never pastes partial output or silently falls back to the original dictation.

### Example wrapper

**Add Tool… → Write My Own Script** creates a starter like this in `scripts/` and opens it in TextEdit. Otherwise, save this as an executable script, choose it as the tool's command, and adapt the final command to your installed tool's documented noninteractive interface:

```sh
#!/bin/sh
set -eu
# This harmless example returns the input unchanged. Replace it with your tool.
# Your tool can read instructions from "$HEX_PROMPT_FILE" and dictation from stdin.
exec /bin/cat
```

Use `chmod +x /absolute/path/to/filter.sh`. Scripts may live in Hex's `scripts/` directory or any other chosen location. Keep progress messages on stderr; progress on stdout becomes part of the returned text. Try It runs the real tool with the mode's current instructions, saving pending edits first. Editing during a run does not change that run; older results are labeled when edits or sample input change. Tests do not paste or create history/audio entries.

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

A file changed in another app reloads silently unless Hex is about to save an edit to it. In that case a banner offers **Use Their Version** or **Keep Mine**. Keep Mine acknowledges the latest disk revision and saves; a later external change will cause another conflict. A mode's **Advanced** section has Open Instructions File and Show in Finder, and the sidebar's ⋯ menu shows the configuration folder. A warning icon at the bottom of the sidebar lists files that couldn't be loaded. A tool can't be deleted while modes use it; its detail page lists them.

## Recording, delivery, history, and recovery

A recording captures its mode, instructions, processor, cleanup/formatting settings, language/model, and source application when recording starts. Later edits affect the next recording. The order is raw speech, global cleanup/replacements, optional processor, final lowercase/punctuation formatting, history (if enabled), then delivery. Formatting fields can inherit global settings or override them. The remapping scratchpad receives raw speech and bypasses all modifications and processors. Force-quit speech commands are recognized before processing.

The indicator shows the captured mode and current phase; Escape and the menu's Cancel action cover processing and delivery as well as recording. If the foreground application's bundle ID changes, Hex keeps a ready result and offers Copy Result and explicit Paste Result in the menu. This checks applications only; switching fields or windows within the same app is not detected.

Failures retain the original dictation and offer Retry Processing, Copy Original, and Paste Original in the menu without opening a window. Retry reuses the captured processor input, instructions, processor configuration, and formatting; it does not retranscribe the audio. History shows original dictation, processor input when different, and final output separately. Failed entries are excluded from Paste Last Transcript. Old history remains readable and playable, with its existing text as the only known output.

When history is enabled, request snapshots and recoverable audio/text are private history data in Application Support. Failed entries persist their status and captured request, but not stderr. With history disabled, recovery stays in memory and audio stays temporary; dismissal, cancellation, a newer recording, or normal app termination cleans it up. Disabling history continues to remove existing history/audio through the existing Settings behavior.

## Codex CLI example

Plain `codex` starts an interactive terminal interface and fails with “stdin is not a terminal” when launched with Hex's pipes. Use `codex exec` for noninteractive processing. Its progress goes to stderr and its final response goes to stdout. A prompt argument supplies instructions while piped stdin supplies the dictation.

An example wrapper is included at [`examples/processors/codex.sh`](../examples/processors/codex.sh). **Add Tool… → Codex** installs the same wrapper into your Hex `scripts/` directory. To set it up by hand, copy it there, make it executable, and choose that copy as the tool's command. The wrapper reads `HEX_PROMPT_FILE`, forwards literal argument rows, and runs a read-only, ephemeral Codex session outside a Git repository. It reuses your existing CLI authentication and model configuration unless you provide model arguments.

To select a model, add it after the script path in the Command field, for example `/path/to/codex.sh --model some-model`. Leave options out to use your configured model.

The Claude Code preset runs `claude -p` in print mode with tools disabled, no saved session, no MCP servers, and the mode's instructions as the system prompt (`--system-prompt-file`). Extra options such as `--model NAME` are passed through the same way. It was verified against the installed CLI with piped dictation and existing authentication.

Verified against the installed CLI and the [official Codex noninteractive documentation](https://developers.openai.com/codex/noninteractive/). The wrapper does not provide approval or sandbox bypass flags, install Codex, or configure authentication. Run Codex's normal login flow independently if required.
