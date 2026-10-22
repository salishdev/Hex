#!/bin/sh
# Hex supplies dictation on stdin and instructions through HEX_PROMPT_FILE.
# Additional arguments (for example --model and its value) are passed literally.
set -eu
: "${HEX_PROMPT_FILE:?Hex must supply HEX_PROMPT_FILE}"
instructions=$(/bin/cat "$HEX_PROMPT_FILE")
prompt="Transform the dictated text supplied on stdin according to the instructions below. Return only the final transformed text. Do not use tools, run commands, or read other files.

$instructions"
exec codex exec --skip-git-repo-check --sandbox read-only --ephemeral --color never "$@" -- "$prompt"
