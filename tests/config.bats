#!/usr/bin/env bats
# The script's own options, from ~/.config/bclaude/config and the environment:
# what they change inside. The refusals are in config-refusals.bats.

load helpers
bats_require_minimum_version 1.5.0

setup_file() {
    systemd_shim
    export HOME1="$BATS_FILE_TMPDIR/home" SH="$BATS_FILE_TMPDIR/sh" PROJ="$BATS_FILE_TMPDIR/proj"
    export OTHER="$BATS_FILE_TMPDIR/other" CONF="$HOME1/.config/bclaude"
    export NVMDIR="$HOME1/.nvm/versions/node/v1/bin"
    host_home "$HOME1"
    mkdir -p "$SH" "$PROJ" "$OTHER" "$CONF" "$NVMDIR" "$HOME1/.local/bin" \
        "$HOME1/.local/share/pnpm/bin"
    cp /bin/bash "$NVMDIR/claude"
    touch "$HOME1/.local/bin/host-tool" "$HOME1/.local/share/pnpm/bin/pnpm"
    echo 'custom md' > "$CONF/CLAUDE.md"
    echo '{"custom":true}' > "$CONF/policy.json"
    # Options for one project only: $OTHER must get the defaults.
    cat > "$CONF/config" <<EOF
case "\$PROJECT" in
    "$PROJ")
        BCLAUDE_CLAUDE_MD="\$REAL_HOME/.config/bclaude/CLAUDE.md"
        BCLAUDE_MANAGED_SETTINGS="\$REAL_HOME/.config/bclaude/policy.json"
        BCLAUDE_TMP_SIZE=1048576
        BCLAUDE_GITCONFIG=0 BCLAUDE_LOCAL_BIN=0 BCLAUDE_PNPM=0 BCLAUDE_NVM=0 ;;
esac
EOF
    probe conf "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ"
    probe other "$REPO/bclaude.sh" "$HOME1" "$SH" "$OTHER"
    BCLAUDE_GITCONFIG=1 probe env "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ"
}

@test "config: CLAUDE.md is the configured file" { is conf claude_md 'custom md'; }
@test "config: CLAUDE.md read-only" { is conf w_claude_md no; }
@test "config: managed settings is the configured file" {
    is conf managed_sha "$(sha256sum "$CONF/policy.json" | cut -d' ' -f1)"
}
@test "config: managed settings read-only" { is conf w_managed no; }
@test "config: /tmp capped at the configured size" { is conf tmp_size 1048576; }
@test "config: .gitconfig not bound" { is conf gitconfig ''; }
@test "config: .gitconfig shadowed read-only" { is conf w_gitconfig no; }
@test "config: ~/.config/git/config shadowed read-only" { is conf w_gitconfig_xdg no; }
@test "config: PATH omits ~/.local/bin" { [[ "$(rv conf env_PATH)" != *"/.local/bin"* ]]; }
@test "config: PATH omits pnpm's bin dir" {
    [[ "$(rv conf env_PATH)" != *"/.local/share/pnpm"* ]]
}
@test "config: disabled binds show nothing from the host" {
    # shellcheck disable=SC2016 # expanded inside the sandbox, not here
    run -0 launch "$REPO/bclaude.sh" "$HOME1" "$SH" "$PROJ" \
        -c 'for p; do [ ! -e "$p" ] || { echo "visible: $p"; exit 1; }; done' probe \
        "$HOME1/.local/bin/host-tool" "$HOME1/.local/share/pnpm/bin/pnpm" "$NVMDIR/claude"
}

@test "another project: CLAUDE.md is the host file" { is other claude_md 'host md'; }
@test "another project: managed settings is the repo file" {
    is other managed_sha "$(sha256sum "$REPO/managed-settings.json" | cut -d' ' -f1)"
}
@test "another project: /tmp capped at 2 GiB" { is other tmp_size 2147483648; }
@test "another project: .gitconfig bound" { is other gitconfig '[user]'; }
@test "another project: ~/.local/bin first on PATH" {
    [[ "$(rv other env_PATH)" == "$HOME1/.local/bin:"* ]]
}

@test "environment wins over the config file" { is env gitconfig '[user]'; }
@test "environment leaves the other options to the config file" { is env claude_md 'custom md'; }
