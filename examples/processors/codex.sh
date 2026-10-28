#!/bin/sh
# Hex supplies dictation on stdin and instructions through HEX_PROMPT_FILE.
# Additional arguments (for example --model and its value) are passed literally.
set -eu
: "${HEX_PROMPT_FILE:?Hex must supply HEX_PROMPT_FILE}"
# Apps opened from Finder don't load your shell's PATH, so add the usual install folders.
PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
command -v codex >/dev/null 2>&1 || { echo "Hex couldn't find the codex command. Run 'command -v codex' in Terminal and put that full path in this script." >&2; exit 127; }
instructions=$(/bin/cat "$HEX_PROMPT_FILE")
prompt="Transform the dictated text supplied on stdin according to the instructions below. Return only the final transformed text. Do not use tools, run commands, or read other files.

$instructions"
exec codex exec --skip-git-repo-check --sandbox read-only --ephemeral --color never "$@" -- "$prompt"
