#!/usr/bin/env bats
# No ~/.claude on the host: the two files are shadowed, not left creatable.

load helpers

setup_file() {
    systemd_shim
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    mkdir -p "$HOME1" "$SH" "$PROJ"
    probe bare "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ"
}

@test "settings.json shadowed with {}" { is bare settings '{}'; }
@test "settings.json shadow read-only" { is bare w_settings no; }
@test "CLAUDE.md shadowed empty" { is bare claude_md ''; }
@test "CLAUDE.md shadow read-only" { is bare w_claude_md no; }
@test "host: sandbox home copy of settings.json is {}" {
    [ "$(cat "$SH/.claude/settings.json")" = '{}' ]
}
