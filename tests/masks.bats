#!/usr/bin/env bats
# The repo and the sandbox home re-bound read-only under a writable project,
# and dev mode. A copy of the repo stands in so its location can be chosen.

load helpers
bats_require_minimum_version 1.5.0

setup_file() {
    systemd_shim
    export HOME1="$BATS_FILE_TMPDIR/home" TREE="$BATS_FILE_TMPDIR/tree" PROJ="$BATS_FILE_TMPDIR/proj"
    export COPY="$TREE/bubbleclaude"
    host_home "$HOME1"
    mkdir -p "$COPY/claude-home" "$PROJ/sh"
    cp "$REPO/bclaude.sh" "$REPO/managed-settings.json" "$COPY/"
    probe tree "$COPY/bclaude.sh" "$HOME1" - "$TREE" \
        "$TREE/smoke" "$COPY/bclaude.sh" "$COPY/managed-settings.json" "$COPY/claude-home/smoke"
    probe dev "$COPY/bclaude.sh" "$HOME1" - "$COPY" \
        "$COPY/bclaude.sh" "$COPY/managed-settings.json" "$COPY/claude-home/smoke"
    probe repointed "$REPO/bclaude.sh" "$HOME1" "$PROJ/sh" "$PROJ" "$PROJ/smoke" "$PROJ/sh/smoke"
}

@test "repo under project: project writable" { is tree "w_$TREE/smoke" yes; }
@test "repo under project: script masked" { is tree "w_$COPY/bclaude.sh" no; }
@test "repo under project: policy masked" { is tree "w_$COPY/managed-settings.json" no; }
@test "repo under project: sandbox home masked" { is tree "w_$COPY/claude-home/smoke" no; }
@test "repo under project: no dev-mode warning" {
    run ! grep -q WARNING "$BATS_FILE_TMPDIR/tree.err"
}

@test "dev mode: script writable" { is dev "w_$COPY/bclaude.sh" yes; }
@test "dev mode: policy writable" { is dev "w_$COPY/managed-settings.json" yes; }
@test "dev mode: sandbox home still masked" { is dev "w_$COPY/claude-home/smoke" no; }
@test "dev mode: warning printed" {
    grep -q WARNING "$BATS_FILE_TMPDIR/dev.err"
}

@test "sandbox home under project: project writable" { is repointed "w_$PROJ/smoke" yes; }
@test "sandbox home under project: sandbox home masked" { is repointed "w_$PROJ/sh/smoke" no; }
