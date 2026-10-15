#!/usr/bin/env bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Rémi Ducceschi
#
# bubbleclaude: run Claude Code inside a bubblewrap sandbox.
# Allowlist model: nothing exists inside unless bound below. Unlisted paths are
# absent, not merely denied.
#
# Usage: cd /path/to/project && bclaude.sh [claude args...]
# The launch directory is the project, and the only writable place inside.
# CLAUDE_BIN=/path/to/claude overrides the PATH lookup (bclaude-vscode.sh).
# SANDBOX_HOME=/path overrides the fake home (default: claude-home/ in the repo).
#
# Check it applies: `readlink /proc/self/ns/mnt` from your shell and from inside
# must differ. Same inode = no sandbox, whatever you configured.

set -eufo pipefail

die() { echo "$*" >&2; exit 1; }

# readlink -f: $0 may be a symlink, and binds must resolve against the real repo.
BCLAUDE_PATH="$(dirname "$(readlink -f "$0")")"
REAL_HOME="$(realpath "$HOME")"
SANDBOX_HOME="$(realpath -m "${SANDBOX_HOME:-$BCLAUDE_PATH/claude-home}")"
# Policy only, bound as managed settings: no user or project file outranks it.
MANAGED_SETTINGS="$BCLAUDE_PATH/managed-settings.json"
# The user's layer, as outside the sandbox. Resolved: symlinked into a dotfiles
# repo, these must still fail the project checks below.
USER_CLAUDE_DIR="$(realpath -m "$REAL_HOME/.claude")"
USER_SETTINGS="$(realpath -m "$USER_CLAUDE_DIR/settings.json")"
USER_CLAUDE_MD="$(realpath -m "$USER_CLAUDE_DIR/CLAUDE.md")"

# Resolved on the HOST. An explicit CLAUDE_BIN (the VS Code wrapper) is not
# updated: the extension ships its own copy. DISABLE_AUTOUPDATER is Claude's
# own switch, honoured here too so `-p` one-shots skip the network round trip.
export PATH="$HOME/.local/bin:$PATH"
UPDATE=1
[ -z "${CLAUDE_BIN:-}" ] || UPDATE=0
case "${DISABLE_AUTOUPDATER:-}" in 1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) UPDATE=0 ;; esac
if [ -z "${CLAUDE_BIN:-}" ]; then
    CLAUDE_BIN="$(command -v claude)" || die "claude not found in PATH"
fi
# Dir as found, not resolved: an nvm symlink's node sits beside it. File
# resolved: only that one file is bound, so it has to be the real one.
CLAUDE_BIN_DIR="$(realpath "$(dirname "$CLAUDE_BIN")")"
CLAUDE_BIN_REAL="$(realpath "$CLAUDE_BIN")"
if [ ! -f "$CLAUDE_BIN_REAL" ] || [ ! -x "$CLAUDE_BIN_REAL" ]; then
    die "not an executable file: $CLAUDE_BIN_REAL"
fi

# Canonical: a symlinked launch path would not exist inside the sandbox.
PROJECT="$(realpath "$PWD")"
# The project is bound writable on top of everything else, so a parent of the
# real home would resolve $HOME back to your real files, and the sandbox home
# would become a writable persistence channel. "/" never matches "$PROJECT"/*.
case "$PROJECT" in
    /)  die "refusing: / is not a project directory" ;;
    "$SANDBOX_HOME"|"$SANDBOX_HOME"/*)
        die "refusing: $PROJECT is inside the sandbox home ($SANDBOX_HOME)" ;;
    "$USER_CLAUDE_DIR"|"$USER_CLAUDE_DIR"/*)
        die "refusing: $PROJECT is your Claude config directory. Bro... WTF" ;;
esac
case "$REAL_HOME" in
    "$PROJECT"|"$PROJECT"/*)
        die "refusing: $PROJECT holds your real home directory" ;;
esac
# Your real config resolved under the project would be writable from inside,
# even as a dangling symlink a session could then target: refused, not masked.
for path in "$USER_CLAUDE_DIR" "$USER_SETTINGS" "$USER_CLAUDE_MD"; do
    case "$path" in
        "$PROJECT"|"$PROJECT"/*)
            die "refusing: $PROJECT holds your Claude config ($path)" ;;
    esac
done

# Host copy for the unsandboxed VS Code extension; inside, the ro-bind shadows
# it. Written in place, never unlinked: a new inode detaches live sessions' bind.
HOST_SETTINGS="$SANDBOX_HOME/.claude/settings.json"
mkdir -p "$SANDBOX_HOME/.claude"
if [ -e "$HOST_SETTINGS" ] || [ -L "$HOST_SETTINGS" ]; then
    # Anything but a plain file means a session got write access: never write
    # through it. 0444 is the mount point an older launch let bwrap create.
    { [ ! -L "$HOST_SETTINGS" ] && [ -f "$HOST_SETTINGS" ] \
        && [ "$(stat -c %h "$HOST_SETTINGS")" -eq 1 ]; } \
        || die "refusing: $HOST_SETTINGS is not a plain file"
    chmod u+w "$HOST_SETTINGS"
else
    : > "$HOST_SETTINGS"
fi
if [ -f "$USER_SETTINGS" ]; then
    cmp -s "$USER_SETTINGS" "$HOST_SETTINGS" || cp "$USER_SETTINGS" "$HOST_SETTINGS"
else
    [ "$(cat "$HOST_SETTINGS")" = '{}' ] || echo '{}' > "$HOST_SETTINGS"
fi

# The repo and the sandbox home are re-bound read-only when they sit under the
# project: otherwise a session edits its own next launch through the project
# mount. Launched from the repo itself (dev mode) the repo is the project and
# stays writable, with a warning; the sandbox home never does.
MASK_ARGS=()
for dir in "$BCLAUDE_PATH" "$SANDBOX_HOME"; do
    case "$dir" in "$PROJECT"/*) MASK_ARGS+=(--ro-bind "$dir" "$dir") ;; esac
done
# Host git runs hooks, core.hooksPath/fsmonitor/pager and submodule hooks
# unsandboxed; the whole gitdir is read-only so none can be planted. Inside,
# git reads fine and every write fails loudly. Nested repos are not covered.
if [ -e "$PROJECT/.git" ]; then MASK_ARGS+=(--ro-bind "$PROJECT/.git" "$PROJECT/.git"); fi
case "$PROJECT" in
    "$BCLAUDE_PATH"|"$BCLAUDE_PATH"/*) cat >&2 <<'EOF'

***    WARNING: THIS SESSION RUNS INSIDE THE BUBBLECLAUDE REPOSITORY.     ***
***   THE REPO IS WRITABLE, SO CLAUDE CAN EDIT ITS OWN CAGE: CHANGES TO   ***
***  bclaude.sh OR managed-settings.json TAKE EFFECT ON THE NEXT LAUNCH.  ***
***   READ EVERY DIFF BEFORE YOU RELAUNCH. claude-home/ STAYS READ-ONLY.  ***

EOF
    ;;
esac

# Updated on the host: the sandbox is read-only where npm writes.
if [ "$UPDATE" -eq 1 ]; then
    "$CLAUDE_BIN" update || echo "warning: update failed, launching current version" >&2
fi

# The only host variables that cross --clearenv: each must stay harmless under
# a hostile value. Never ANTHROPIC_*, credentials, plugin dirs or settings paths.
ENV_ALLOW=(
    # Set per launch by the VS Code extension and the Agent SDK.
    CLAUDE_CODE_ENTRYPOINT CLAUDE_AGENT_SDK_VERSION
    CLAUDE_CODE_EMIT_STARTUP_TIMING CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS
    CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING
    CLAUDE_CODE_ENABLE_TASKS CLAUDE_CODE_QUESTION_PREVIEW_FORMAT
    CLAUDE_CODE_SESSION_ATTENDED MCP_CONNECTION_NONBLOCKING
    # IDE integration: a localhost port and two auto-install switches.
    CLAUDE_CODE_SSE_PORT CLAUDE_CODE_AUTO_CONNECT_IDE CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL
    # Model, context and tool limits.
    CLAUDE_CODE_MAX_OUTPUT_TOKENS MAX_THINKING_TOKENS CLAUDE_CODE_EFFORT_LEVEL
    CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_DISABLE_1M_CONTEXT
    CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING DISABLE_INTERLEAVED_THINKING
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS BASH_MAX_OUTPUT_LENGTH
    CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR USE_BUILTIN_RIPGREP
    MCP_TIMEOUT MCP_TOOL_TIMEOUT MAX_MCP_OUTPUT_TOKENS MCP_OAUTH_CALLBACK_PORT
    # Telemetry, update and UI switches.
    DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DO_NOT_TRACK DISABLE_AUTOUPDATER
    DISABLE_COST_WARNINGS DISABLE_BUG_COMMAND DISABLE_FEEDBACK_COMMAND
    DISABLE_INSTALLATION_CHECKS CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    CLAUDE_CODE_DISABLE_AUTO_MEMORY CLAUDE_CODE_DISABLE_TERMINAL_TITLE
    CLAUDE_CODE_NO_FLICKER CLAUDE_CODE_SIMPLE CLAUDE_CODE_HIDE_CWD
    CLAUDE_CODE_SKIP_PROMPT_HISTORY CLAUDE_CODE_ATTRIBUTION_HEADER
)
ENV_ARGS=()
for name in "${ENV_ALLOW[@]}"; do
    if [ "${!name+set}" ]; then
        ENV_ARGS+=(--setenv "$name" "${!name}")
    fi
done
# Rewritten, not forwarded: on the host it points the extension at
# claude-home/.claude, which inside the sandbox is simply ~/.claude.
if [ "${CLAUDE_CONFIG_DIR+set}" ]; then
    ENV_ARGS+=(--setenv CLAUDE_CONFIG_DIR "$HOME/.claude")
fi

# Mount order matters: later binds stack over earlier ones, which is why the
# project and the masks come last.
BWRAP_ARGS=(
    # --share-net must follow --unshare-all and re-shares ONLY the network.
    # Caveat: that includes abstract-namespace Unix sockets, i.e. the X server
    # under X11 (keylogging reach). Wayland's socket is a file and is not bound.
    --unshare-all --share-net
    # Don't leak the host's name into prompts and logs.
    --hostname bubbleclaude
    --die-with-parent
    # Drops the controlling terminal (TIOCSTI defence) at the cost of "not a
    # tty". If it ever breaks the interactive TUI, drop it and accept the risk.
    --new-session

    # Start empty, else SSH_AUTH_SOCK, GITHUB_TOKEN, AWS_*, DISPLAY leak in.
    --clearenv
    --setenv HOME "$HOME"
    # CLAUDE_BIN's dir first: with nvm, the node its shebang needs sits beside it.
    --setenv PATH "$CLAUDE_BIN_DIR:$HOME/.local/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin"
    --setenv TERM "${TERM:-xterm-256color}"
    --setenv LANG "${LANG:-C.UTF-8}"
    --setenv USER "${USER:-$(id -un)}"
    "${ENV_ARGS[@]}"

    --ro-bind /usr /usr
    # Debian is usr-merged: symlinks, not binds, which would turn them into real
    # directories and confuse path comparisons.
    --symlink usr/bin   /bin
    --symlink usr/sbin  /sbin
    --symlink usr/lib   /lib
    --symlink usr/lib64 /lib64
    # Minimal /etc; nsswitch.conf is what glibc needs for DNS.
    --ro-bind /etc/resolv.conf   /etc/resolv.conf
    --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf
    --ro-bind /etc/hosts         /etc/hosts
    --ro-bind /etc/ssl           /etc/ssl
    --ro-bind /etc/passwd        /etc/passwd
    --ro-bind /etc/group         /etc/group
    --ro-bind-try /etc/localtime /etc/localtime
    --ro-bind-try /etc/ca-certificates.conf /etc/ca-certificates.conf
    # Debian/Fedora alternatives: without it awk, vi, pager... are dangling
    # symlinks. -try because Arch, Alpine and NixOS have no such directory.
    --ro-bind-try /etc/alternatives /etc/alternatives
    # Without the cache ld.so only searches its built-in paths (/usr/local/lib
    # and ld.so.conf.d entries vanish).
    --ro-bind-try /etc/ld.so.cache /etc/ld.so.cache
    --proc /proc
    --dev /dev
    # tmpfs is RAM: cap /tmp at 2 GiB (--size takes bytes).
    --size 2147483648 --tmpfs /tmp
    --size 2147483648 --tmpfs /var/tmp

    # The sandbox's own persistent home: ~/.claude.json (OAuth, trust) survives.
    --bind "$SANDBOX_HOME" "$HOME"
    # Sources resolve on the HOST: these read your real home and land inside.
    --ro-bind-try "$REAL_HOME/.gitconfig" "$HOME/.gitconfig"
    --ro-bind-try "$REAL_HOME/.config/git/config" "$HOME/.config/git/config"
    --ro-bind-try "$REAL_HOME/.local/bin" "$HOME/.local/bin"
    --ro-bind-try "$REAL_HOME/.local/share/claude" "$HOME/.local/share/claude"
    --ro-bind-try "$REAL_HOME/.nvm" "$HOME/.nvm"
    # The binary alone, never its directory: a CLAUDE_BIN under ~/.vscode-server
    # or /tmp must not drag its siblings in.
    --ro-bind "$CLAUDE_BIN_REAL" "$CLAUDE_BIN_REAL"
    # Managed settings are the TOP of the precedence chain: a writable project
    # .claude/settings.json can outrank user settings, nothing outranks these.
    # Hard bind: without it there is no inner sandbox and no network allowlist.
    --ro-bind "$MANAGED_SETTINGS" /etc/claude-code/managed-settings.json
)

# Shadowed present or not: left unbound, a session could create settings.json
# (permissions, env) or CLAUDE.md (prompt injection) in the persistent home.
if [ -f "$USER_SETTINGS" ]; then
    BWRAP_ARGS+=(--ro-bind "$USER_SETTINGS" "$HOME/.claude/settings.json")
else
    exec 5<<<'{}'
    BWRAP_ARGS+=(--ro-bind-data 5 "$HOME/.claude/settings.json")
fi
if [ -f "$USER_CLAUDE_MD" ]; then
    BWRAP_ARGS+=(--ro-bind "$USER_CLAUDE_MD" "$HOME/.claude/CLAUDE.md")
else
    exec 6</dev/null
    BWRAP_ARGS+=(--ro-bind-data 6 "$HOME/.claude/CLAUDE.md")
fi
# Never bound from the host: a local override of settings.json is the same
# persistence channel, so it is always the empty object.
exec 4<<<'{}'
BWRAP_ARGS+=(--ro-bind-data 4 "$HOME/.claude/settings.local.json")

BWRAP_ARGS+=(
    # Anti-persistence: empty tmpfs so a session can't plant anything that
    # auto-loads into every later run, witth 1 MiB caps.
    --size 1048576 --tmpfs "$HOME/.claude/agents"
    --size 1048576 --tmpfs "$HOME/.claude/commands"
    --size 1048576 --tmpfs "$HOME/.claude/hooks"
    --size 1048576 --tmpfs "$HOME/.claude/skills"
    --size 1048576 --tmpfs "$HOME/.claude/plugins"
    --size 1048576 --tmpfs "$HOME/.claude/rules"
    --size 1048576 --tmpfs "$HOME/.claude/output-styles"
    --size 1048576 --tmpfs "$HOME/.claude/workflows"
    --size 1048576 --tmpfs "$HOME/.claude/themes"
    # Same attack via shell rc files sourced by later shell snapshots: a
    # read-only empty mount point, so rm-and-replace fails too. One fd each,
    # bwrap closes it after reading. Not a bind of /dev/null: binds are nodev,
    # so a device node there is unopenable and breaks sourcing.
    --ro-bind-data 7 "$HOME/.bashrc"
    --ro-bind-data 8 "$HOME/.bash_profile"
    --ro-bind-data 9 "$HOME/.profile"

    # The project: the only genuinely writable place. Then the masks (see top).
    --bind "$PROJECT" "$PROJECT"
    "${MASK_ARGS[@]}"
    --chdir "$PROJECT"
)

exec systemd-run --user --scope -q -p MemoryMax=8G -p TasksMax=1024 \
    bwrap "${BWRAP_ARGS[@]}" "$CLAUDE_BIN_REAL" "$@" \
    7</dev/null 8</dev/null 9</dev/null
