#!/usr/bin/env bats
# The claude binary found under the real home: its directory is a writable
# mount point in the persistent sandbox home and must stay off PATH.

load helpers

setup_file() {
    systemd_shim
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    export BINDIR="$HOME1/.vscode-server/extensions/ext/resources/native-binary"
    export NVMDIR="$HOME1/.nvm/versions/node/v1/bin"
    host_home "$HOME1"
    mkdir -p "$SH" "$PROJ" "$BINDIR" "$NVMDIR" "$HOME1/.local/bin"
    cp /bin/bash "$BINDIR/claude"
    cp /bin/bash "$NVMDIR/claude"
    touch "$HOME1/.local/bin/host-tool"
    TEST_CLAUDE_BIN="$BINDIR/claude" probe home "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ" \
        "$HOME1/.local/bin/smoke"
    TEST_CLAUDE_BIN="$NVMDIR/claude" probe nvm "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ" \
        "$NVMDIR/smoke"
}

@test "binary dir under the home is not on PATH" {
    [[ "$(rv home env_PATH)" != *"$BINDIR"* ]]
}
@test "binary dir shows only the binary" {
    # A sibling planted on the host beside the binary must not be visible inside.
    touch "$BINDIR/sibling"
    # shellcheck disable=SC2016 # expanded inside the sandbox, not here
    TEST_CLAUDE_BIN="$BINDIR/claude" run launch "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ" \
        -c 'ls -- "$1"' probe "$BINDIR"
    [ "$output" = claude ]
}
@test "nvm binary dir is first on PATH" {
    [[ "$(rv nvm env_PATH)" == "$NVMDIR:"* ]]
}
@test "nvm binary dir is read-only" { is nvm "w_$NVMDIR/smoke" no; }
@test "~/.local/bin first on PATH when the host has one" {
    [[ "$(rv home env_PATH)" == "$HOME1/.local/bin:"* ]]
}
@test "~/.local/bin bound read-only from the host" { is home "w_$HOME1/.local/bin/smoke" no; }
@test "host: sandbox home holds only the mount-point stub" {
    local stub="$SH/.vscode-server/extensions/ext/resources/native-binary"
    [ "$(ls -A "$stub")" = claude ]
}
