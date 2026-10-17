#!/usr/bin/env bats
# A normal launch with host config present: what is inside, what is not, and
# what persisted on the host afterwards.

load helpers

setup_file() {
    systemd_shim
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    host_home "$HOME1"
    mkdir -p "$SH" "$PROJ/.git/hooks"
    touch "$SH/sandbox-canary"
    echo '[core]' > "$PROJ/.git/config"
    export HOST_NS
    HOST_NS="$(readlink /proc/self/ns/mnt)"
    probe main "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ" \
        "$PROJ/smoke" "$PROJ/.git/smoke" "$PROJ/.git/hooks/smoke" "$PROJ/.git/config"
    # Own fixtures: a second launch on $SH/$PROJ would rewrite the host state
    # the tests above read. stderr kept apart so a warning cannot fail the match.
    mkdir -p "$BATS_FILE_TMPDIR/sh2" "$BATS_FILE_TMPDIR/proj2"
    # shellcheck disable=SC2016 # the literal is the point
    launch "$REPO/bclaude.sh" "$HOME1" "$BATS_FILE_TMPDIR/sh2" "$BATS_FILE_TMPDIR/proj2" \
        -c 'printf %s "$1"' x '${GITHUB_TOKEN}' \
        > "$BATS_FILE_TMPDIR/verbatim.out" 2> "$BATS_FILE_TMPDIR/verbatim.err" \
        || { cat "$BATS_FILE_TMPDIR/verbatim.err" >&2; return 1; }
}

@test "mount namespace differs from the host" {
    [ "$(rv main ns)" != "$HOST_NS" ]
}
@test "HOME keeps its path" { is main home "$HOME1"; }
@test "cwd is the project" { is main pwd "$PROJ"; }
@test "hostname is bubbleclaude" { is main hostname bubbleclaude; }
@test "SSH_AUTH_SOCK dropped" { is main env_SSH_AUTH_SOCK unset; }
@test "GITHUB_TOKEN dropped" { is main env_GITHUB_TOKEN unset; }
@test "ANTHROPIC_API_KEY dropped" { is main env_ANTHROPIC_API_KEY unset; }
@test "DISPLAY dropped" { is main env_DISPLAY unset; }
@test "XDG_RUNTIME_DIR dropped" { is main env_XDG_RUNTIME_DIR unset; }
@test "DBUS_SESSION_BUS_ADDRESS dropped" { is main env_DBUS_SESSION_BUS_ADDRESS unset; }
@test "DISABLE_TELEMETRY forwarded" { is main env_DISABLE_TELEMETRY 1; }
@test "CLAUDE_CONFIG_DIR rewritten to the sandbox ~/.claude" {
    is main env_CLAUDE_CONFIG_DIR "$HOME1/.claude"
}
@test "DISABLE_AUTOUPDATER forced to 1, not forwarded" { is main env_DISABLE_AUTOUPDATER 1; }
# Unprivileged bwrap empties the bounding set itself; --cap-drop ALL would be a no-op.
@test "capability bounding set empty" { is main capbnd 0000000000000000; }
@test "PATH omits ~/.local/bin when the host has none" {
    [[ "$(rv main env_PATH)" != *"/.local/bin"* ]]
}
@test "real home absent" { is main host_secret no; }
@test "sandbox home mounted at HOME" { is main sandbox_canary yes; }
@test "/etc/shadow absent" { is main etc_shadow no; }
@test ".gitconfig comes from the real home" { is main gitconfig '[user]'; }
@test ".gitconfig read-only" { is main w_gitconfig no; }
@test "/usr read-only" { is main w_usr no; }
@test "/tmp writable" { is main w_tmp yes; }
@test "sandbox home writable" { is main w_home yes; }
@test "settings.json read-only" { is main w_settings no; }
@test "CLAUDE.md read-only" { is main w_claude_md no; }
@test "settings.local.json shadowed with {}" { is main settings_local '{}'; }
@test "settings.local.json shadow read-only" { is main w_settings_local no; }
@test "skills/ is a tmpfs" { is main w_skills yes; }
@test ".bashrc read-only" { is main w_bashrc no; }
@test ".bashrc not removable" { is main rm_bashrc no; }
@test "managed settings read-only" { is main w_managed no; }
@test "settings.json is the host file" { is main settings '{"host":true}'; }
@test "CLAUDE.md is the host file" { is main claude_md 'host md'; }
@test "managed settings is the repo file" {
    is main managed_sha "$(sha256sum "$REPO/managed-settings.json" | cut -d' ' -f1)"
}
@test "project writable" { is main "w_$PROJ/smoke" yes; }
@test ".git read-only" { is main "w_$PROJ/.git/smoke" no; }
@test ".git/hooks read-only" { is main "w_$PROJ/.git/hooks/smoke" no; }
@test ".git/config read-only" { is main "w_$PROJ/.git/config" no; }
@test "host: project write persisted" { [ "$(exists "$PROJ/smoke")" = yes ]; }
@test "host: sandbox home write persisted" { [ "$(exists "$SH/smoke")" = yes ]; }
@test "host: real home untouched" { [ "$(exists "$HOME1/smoke")" = no ]; }
@test "host: tmpfs skills not persisted" { [ "$(exists "$SH/.claude/skills/smoke")" = no ]; }
# bwrap leaves 0-byte mount-point files behind; content is what must not persist.
@test "host: settings.local.json mount point stays empty" {
    [ ! -s "$SH/.claude/settings.local.json" ]
}
# systemd-run >= 258 expands ${VAR} in the payload from the host environment
# unless told not to. Shimmed, the shim refuses a launch without the flag.
@test "arguments reach claude verbatim, no host expansion" {
    # shellcheck disable=SC2016 # the literal is the point
    [ "$(cat "$BATS_FILE_TMPDIR/verbatim.out")" = '${GITHUB_TOKEN}' ]
}
@test "host: settings.json copied into the sandbox home" {
    [ "$(cat "$SH/.claude/settings.json")" = '{"host":true}' ]
}
