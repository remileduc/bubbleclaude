#!/usr/bin/env bats
# The script's own options: what must stop the launch before bwrap ever runs,
# so that nothing they repoint is within a session's reach.

load helpers
bats_require_minimum_version 1.5.0

setup_file() {
    export BIN="$BATS_FILE_TMPDIR/bin"
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    export CONF="$HOME1/.config/bclaude" NVMDIR="$HOME1/.nvm/versions/node/v1/bin"
    host_home "$HOME1"
    mkdir -p "$SH" "$PROJ" "$CONF" "$NVMDIR"
    cp /bin/bash "$NVMDIR/claude"
}

# with_config <line>: a throwaway home whose config file is that one line.
with_config() {
    HOME2="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME2/.config/bclaude"
    echo "$1" > "$HOME2/.config/bclaude/config"
}

@test "environment wins over the config file, on a refusal" {
    with_config 'BCLAUDE_PNPM=1'
    BCLAUDE_PNPM=yes refused "$HOME2" "$SH" "$PROJ" "BCLAUDE_PNPM must be 0 or 1, not 'yes'"
}
@test "a toggle from the config file must be 0 or 1" {
    with_config 'BCLAUDE_PNPM=maybe'
    refused "$HOME2" "$SH" "$PROJ" "BCLAUDE_PNPM must be 0 or 1, not 'maybe'"
}
@test "a failing config file stops the launch, with its line" {
    with_config 'false'
    refused "$HOME2" "$SH" "$PROJ" "config error at $HOME2/.config/bclaude/config:1"
}
@test "a config file whose last line fails stops the launch, naming the file" {
    with_config '[ -d /nonexistent ] && SANDBOX_HOME=/nonexistent'
    refused "$HOME2" "$SH" "$PROJ" \
        "config error: $HOME2/.config/bclaude/config ended with a failing command"
}
@test "a mistyped toggle is refused before anything is written or run" {
    local sh="$BATS_TEST_TMPDIR/sh" bin="$BATS_TEST_TMPDIR/claude"
    printf '#!/bin/sh\necho RAN\n' > "$bin"
    chmod +x "$bin"
    run -1 env -i HOME="$HOME1" PATH="$PATH" CLAUDE_BIN="$bin" SANDBOX_HOME="$sh" \
        BCLAUDE_PNPM=yes "$REPO/bclaude.sh"
    [[ $output == *"BCLAUDE_PNPM must be 0 or 1"* && $output != *RAN* ]]
    [ ! -e "$sh" ]
}
@test "the config file cannot reassign PROJECT" {
    with_config 'PROJECT=/tmp'
    refused "$HOME2" "$SH" "$PROJ" "readonly"
}
@test "the config file cannot reassign its own path" {
    with_config 'CONFIG_DIR=/tmp'
    refused "$HOME2" "$SH" "$PROJ" "readonly"
}
@test "refuses the config directory as project" {
    with_config 'echo SOURCED'
    refused "$HOME2" "$SH" "$HOME2/.config/bclaude" "holds the bclaude config"
    [[ $output != *SOURCED* ]]
}
@test "refuses a parent of the config directory" {
    with_config 'echo SOURCED'
    refused "$HOME2" "$SH" "$HOME2/.config" "holds the bclaude config"
    [[ $output != *SOURCED* ]]
}
@test "refuses a config file symlinked into the project, unsourced" {
    local proj="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$BATS_TEST_TMPDIR/home/.config/bclaude" "$proj"
    echo 'echo SOURCED' > "$proj/config"
    ln -s "$proj/config" "$BATS_TEST_TMPDIR/home/.config/bclaude/config"
    refused "$BATS_TEST_TMPDIR/home" "$SH" "$proj" "holds the bclaude config"
    [[ $output != *SOURCED* ]]
}
@test "refuses a config directory inside the sandbox home" {
    local home="$BATS_TEST_TMPDIR/home" sh="$BATS_TEST_TMPDIR/sh"
    mkdir -p "$home" "$sh/cfg/bclaude"
    ln -s "$sh/cfg" "$home/.config"
    refused "$home" "$sh" "$PROJ" "is inside the sandbox home"
}
@test "refuses a config file inside the sandbox home, unsourced" {
    local home="$BATS_TEST_TMPDIR/home" sh="$BATS_TEST_TMPDIR/sh"
    mkdir -p "$home" "$sh/cfg/bclaude"
    ln -s "$sh/cfg" "$home/.config"
    echo 'echo SOURCED' > "$sh/cfg/bclaude/config"
    refused "$home" "$sh" "$PROJ" "is inside the sandbox home"
    [[ $output != *SOURCED* ]]
}
@test "refuses a config file inside the sandbox home it sets" {
    local home="$BATS_TEST_TMPDIR/home" sh="$BATS_TEST_TMPDIR/sh"
    mkdir -p "$home" "$sh/cfg/bclaude"
    ln -s "$sh/cfg" "$home/.config"
    echo "SANDBOX_HOME=$sh" > "$sh/cfg/bclaude/config"
    refused "$home" - "$PROJ" "is inside the sandbox home ($sh)"
    [ ! -e "$sh/.claude" ]
}
@test "refuses managed settings under the project" {
    mkdir -p "$PROJ/sub"
    echo '{}' > "$PROJ/sub/policy.json"
    BCLAUDE_MANAGED_SETTINGS="$PROJ/sub/policy.json" \
        refused "$HOME1" "$SH" "$PROJ" "holds the managed settings"
}
@test "refuses managed settings given relative to the project" {
    echo '{}' > "$PROJ/policy.json"
    BCLAUDE_MANAGED_SETTINGS=policy.json refused "$HOME1" "$SH" "$PROJ" "holds the managed settings"
}
@test "refuses managed settings inside the sandbox home" {
    echo '{}' > "$SH/policy.json"
    BCLAUDE_MANAGED_SETTINGS="$SH/policy.json" \
        refused "$HOME1" "$SH" "$PROJ" "is inside the sandbox home"
}
@test "refuses missing managed settings" {
    BCLAUDE_MANAGED_SETTINGS="$CONF/absent.json" \
        refused "$HOME1" "$SH" "$PROJ" "managed settings not found"
}
@test "refuses a CLAUDE.md override under the project" {
    echo injected > "$PROJ/CLAUDE.md"
    BCLAUDE_CLAUDE_MD="$PROJ/CLAUDE.md" \
        refused "$HOME1" "$SH" "$PROJ" "holds your Claude config"
}
@test "refuses a CLAUDE.md override inside the sandbox home" {
    echo injected > "$SH/CLAUDE.md"
    BCLAUDE_CLAUDE_MD="$SH/CLAUDE.md" \
        refused "$HOME1" "$SH" "$PROJ" "is inside the sandbox home"
}
@test "refuses a missing CLAUDE.md override" {
    BCLAUDE_CLAUDE_MD="$CONF/absent.md" \
        refused "$HOME1" "$SH" "$PROJ" "BCLAUDE_CLAUDE_MD not found"
}
@test "BCLAUDE_NVM=0 refuses a claude that lives under ~/.nvm, before touching the sandbox home" {
    local sh="$BATS_TEST_TMPDIR/sh"
    BCLAUDE_NVM=0 TEST_CLAUDE_BIN="$NVMDIR/claude" \
        refused "$HOME1" "$sh" "$PROJ" "leaves out ~/.nvm"
    [ ! -e "$sh" ]
}
