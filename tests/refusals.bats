#!/usr/bin/env bats
# Launch directories the script must reject before bwrap ever runs.

load helpers
bats_require_minimum_version 1.5.0

setup_file() {
    export BIN="$BATS_FILE_TMPDIR/bin"
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    host_home "$HOME1"
    mkdir -p "$SH/sub" "$PROJ"
}

# refused <home> <sandbox-home> <project> <message>
refused() {
    run -1 launch "$REPO/bclaude.sh" "$1" "$2" "$3" -c 'echo ESCAPED'
    [[ $output == *"$4"* ]]
    [[ $output != *ESCAPED* ]]
}

@test "refuses /" { refused "$HOME1" "$SH" / refusing; }
@test "refuses the real home" { refused "$HOME1" "$SH" "$HOME1" "holds your real home"; }
@test "refuses a parent of the real home" {
    refused "$HOME1" "$SH" "$BATS_FILE_TMPDIR" "holds your real home"
}
@test "refuses the sandbox home" { refused "$HOME1" "$SH" "$SH" "inside the sandbox home"; }
@test "refuses a directory inside the sandbox home" {
    refused "$HOME1" "$SH" "$SH/sub" "inside the sandbox home"
}
@test "refuses the Claude config directory" {
    refused "$HOME1" "$SH" "$HOME1/.claude" "Claude config directory"
}
@test "refuses a project holding the config via symlink" {
    local home="$BATS_TEST_TMPDIR/home" proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$home" "$proj/cfg"
    ln -s "$proj/cfg" "$home/.claude"
    refused "$home" "$SH" "$proj" "holds your Claude config"
}
@test "refuses a symlinked host copy of settings.json" {
    local sh="$BATS_TEST_TMPDIR/sh"
    mkdir -p "$sh/.claude"
    ln -s /etc/passwd "$sh/.claude/settings.json"
    refused "$HOME1" "$sh" "$PROJ" "not a plain file"
}
