import Foundation

/// Ready-made tools. Hex never installs the CLI itself or touches its credentials;
/// a preset only writes a small wrapper script into Hex's `scripts/` folder.
public struct ToolPreset: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var scriptName: String
    public var script: String

    public static let all: [ToolPreset] = [codex, claude]

    // Verified against `codex exec`'s noninteractive interface.
    public static let codex = ToolPreset(
        id: "codex", name: "Codex", summary: "Uses your installed and signed-in Codex CLI.",
        scriptName: "codex.sh",
        script: #"""
        #!/bin/sh
        # Created by Hex. Dictation arrives on stdin; instructions are in HEX_PROMPT_FILE.
        # Extra arguments from Hex (for example --model NAME) are passed to codex.
        set -eu
        : "${HEX_PROMPT_FILE:?Hex must supply HEX_PROMPT_FILE}"
        # Apps opened from Finder don't load your shell's PATH, so add the usual install folders.
        PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
        command -v codex >/dev/null 2>&1 || { echo "Hex couldn't find the codex command. Run 'command -v codex' in Terminal and put that full path in this script." >&2; exit 127; }
        instructions=$(/bin/cat "$HEX_PROMPT_FILE")
        prompt="Transform the dictated text supplied on stdin according to the instructions below. Return only the final transformed text. Do not use tools, run commands, or read other files.

        $instructions"
        exec codex exec --skip-git-repo-check --sandbox read-only --ephemeral --color never "$@" -- "$prompt"
        """#
    )

    // Verified against `claude -p` (print mode) with tools disabled.
    public static let claude = ToolPreset(
        id: "claude", name: "Claude Code", summary: "Uses your installed and signed-in Claude Code CLI.",
        scriptName: "claude.sh",
        script: #"""
        #!/bin/sh
        # Created by Hex. Dictation arrives on stdin; instructions are in HEX_PROMPT_FILE.
        # Extra arguments from Hex (for example --model NAME) are passed to claude.
        set -eu
        : "${HEX_PROMPT_FILE:?Hex must supply HEX_PROMPT_FILE}"
        # Apps opened from Finder don't load your shell's PATH, so add the usual install folders.
        PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
        command -v claude >/dev/null 2>&1 || { echo "Hex couldn't find the claude command. Run 'command -v claude' in Terminal and put that full path in this script." >&2; exit 127; }
        exec claude -p --tools "" --no-session-persistence --strict-mcp-config --output-format text \
          --system-prompt-file "$HEX_PROMPT_FILE" "$@" \
          "Transform the dictated text supplied on stdin according to the system prompt. Return only the final transformed text."
        """#
    )

    /// Writes the wrapper (keeping an existing file with the same name) and returns a tool using it.
    public func install(in store: ModeConfigurationStore) throws -> ProcessorConfiguration {
        let url = store.scriptsDirectory.appendingPathComponent(scriptName)
        let fm = FileManager.default
        try fm.createDirectory(at: store.scriptsDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try Data(script.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return ProcessorConfiguration(name: name, executable: url.path)
    }
}

/// Starter instructions offered when a mode's instructions are empty.
public struct InstructionTemplate: Equatable, Identifiable, Sendable {
    public var name: String
    public var text: String
    public var id: String { name }

    public static let all: [InstructionTemplate] = [
        .init(name: "Notes", text: "Turn the dictation into concise notes with headings and action items. Preserve facts; do not invent details. Return only the notes."),
        .init(name: "Message", text: "Turn the dictation into a clear, natural chat message. Preserve meaning and tone. Return only the message."),
        .init(name: "Email", text: "Turn the dictation into a short, polite email body. Preserve meaning; do not add a subject line or signature. Return only the email."),
        .init(name: "Clean up", text: "Fix punctuation, capitalization, and obvious speech-recognition mistakes. Remove filler words. Do not change meaning or wording otherwise. Return only the text."),
    ]
}
