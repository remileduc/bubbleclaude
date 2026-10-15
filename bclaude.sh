#!/usr/bin/env bash

# MIT License
#
# bubbleclaude: Run Claude Code inside a bubblewrap (bwrap) sandbox.
# Copyright (c) 2026 Rémi Ducceschi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# Launch Claude Code inside a bubblewrap sandbox.
#
# Allowlist model: nothing exists inside the sandbox unless bound in below.
# Paths not listed are ABSENT, not merely denied
#
# Usage:  cd /path/to/project && bclaude.sh [claude args...]
# The launch directory is the project, and the only writable place inside.
# CLAUDE_BIN=/path/to/claude overrides the PATH lookup; bclaude-vscode.sh uses
# that to run the VS Code extension's bundled binary in the same cage.
#
# Verify it is actually working, from your normal shell:
#     readlink /proc/self/ns/mnt
# then ask Claude to run the same command. Different inode = sandboxed.
# A *matching* inode means the sandbox is not applying, whatever you configured.

set -eufo pipefail

# readlink -f: $0 may be a symlink (e.g. ~/.local/bin/bclaude), and the binds
# below must resolve relative to the real repo, not the symlink's directory.
BCLAUDE_PATH="$(realpath "$(dirname "$(readlink -f "$0")")")"
REAL_HOME="$(realpath "$HOME")"

# This is the folder that will be mounted as the new home in the sandbox
SANDBOX_HOME="$(realpath -m "${SANDBOX_HOME:-$BCLAUDE_PATH/claude-home}")"
# Path to the claude's settings.json and CLAUDE.md files to use in the sandbox (~/.claude/settings.json)
CLAUDE_SETTINGS_PATH="$(realpath "$BCLAUDE_PATH/claude-settings")"

# Resolved on the HOST. An explicit CLAUDE_BIN wins over the PATH lookup: that
# is how bclaude-vscode.sh hands over the extension's bundled binary.
export PATH="$HOME/.local/bin:$PATH"
if [ -n "${CLAUDE_BIN:-}" ]; then
    EXPLICIT_BIN=1
else
    CLAUDE_BIN="$(command -v claude)" || { echo "claude not found in PATH" >&2; exit 1; }
    EXPLICIT_BIN=0
fi
# The directory of the path as found, not of its target: an nvm `claude` is a
# symlink into node_modules, and the `node` its shebang needs sits beside it.
CLAUDE_BIN_DIR="$(realpath "$(dirname "$CLAUDE_BIN")")"
# The file itself resolved: only this one file is bound in, so it has to be
# the real one, and -f keeps a directory from passing as "executable".
CLAUDE_BIN_REAL="$(realpath "$CLAUDE_BIN")"
if [ ! -f "$CLAUDE_BIN_REAL" ] || [ ! -x "$CLAUDE_BIN_REAL" ]; then
    echo "not an executable file: $CLAUDE_BIN_REAL" >&2
    exit 1
fi

# Canonical throughout: a symlinked launch path would not exist inside the
# sandbox, and --chdir must land on the directory that was actually bound.
PROJECT="$(realpath "$PWD")"

# Binding the project over a parent of the real home would undo the sandbox
# home: later mounts stack over earlier ones, so $HOME would resolve back to
# your real files. Matched separately because "/" never matches "$PROJECT"/*.
case "$PROJECT" in
    /)  echo "refusing: / is not a project directory" >&2
        exit 1 ;;
    "$SANDBOX_HOME"|"$SANDBOX_HOME"/*)
        echo "refusing: $PROJECT is inside the sandbox home ($SANDBOX_HOME)" >&2
        echo "that is the session's own state, not a project." >&2
        exit 1 ;;
    "$REAL_HOME/.claude"|"$REAL_HOME/.claude"/*)
        echo "refusing: you're running bclaude from $PROJECT" >&2
        echo "Bro... WTF" >&2
        exit 1 ;;
esac
case "$REAL_HOME" in
    "$PROJECT"|"$PROJECT"/*)
        echo "refusing: $PROJECT holds your real home directory" >&2
        echo "cd into an actual project; the launch directory is bound writable." >&2
        exit 1 ;;
esac

mkdir -p "$SANDBOX_HOME/.claude"
# Host-side copy for the unsandboxed VS Code extension (CLAUDE_CONFIG_DIR);
# inside, the ro-bind shadows it. cp, never a rename: a new inode would detach
# that ro-bind in running sessions. cmp skips the truncate-rewrite window.
if ! cmp -s "$CLAUDE_SETTINGS_PATH/settings.json" "$SANDBOX_HOME/.claude/settings.json"; then
    cp "$CLAUDE_SETTINGS_PATH/settings.json" "$SANDBOX_HOME/.claude/settings.json"
fi

# Remount this repo read-only when it sits inside the project: otherwise the
# agent edits bclaude.sh or settings.json through the project mount and widens
# its own next launch. All three sources are checked: the ro-binds at
# ~/.claude protect the view, not a repointed source.
MASK_ARGS=()
DEV_MODE=0
case "$PROJECT" in
    "$BCLAUDE_PATH"|"$BCLAUDE_PATH"/*) DEV_MODE=1 ;;
esac
# Dev mode keeps the repo writable so the session is useful, but never the
# sandbox home: anything planted there auto-loads into every later session,
# which is the one thing no warning can make safe.
if [ "$DEV_MODE" -eq 1 ]; then
    MASK_SOURCES=("$SANDBOX_HOME")
else
    MASK_SOURCES=("$BCLAUDE_PATH" "$CLAUDE_SETTINGS_PATH" "$SANDBOX_HOME")
fi
for real in "${MASK_SOURCES[@]}"; do
    case "$real" in
        "$PROJECT"/*) MASK_ARGS+=(--ro-bind "$real" "$real") ;;
    esac
done

if [ "$DEV_MODE" -eq 1 ]; then
    cat >&2 <<'EOF'

***    WARNING: THIS SESSION RUNS INSIDE THE BUBBLECLAUDE REPOSITORY.     ***
***   THE REPO IS WRITABLE, SO CLAUDE CAN EDIT ITS OWN CAGE: CHANGES TO   ***
***    bclaude.sh OR claude-settings/ TAKE EFFECT ON THE NEXT LAUNCH.     ***
***   READ EVERY DIFF BEFORE YOU RELAUNCH. claude-home/ STAYS READ-ONLY.  ***

EOF
fi

# Update claude as it can't update itself in the sandbox. Not for an explicit
# binary: the VS Code extension ships and updates its own copy, and `update`
# on it would target whatever host install exists, or none.
if [ "$EXPLICIT_BIN" -eq 0 ]; then
    "$CLAUDE_BIN" update || echo "warning: update failed, launching current version" >&2
fi

# Host variables that cross --clearenv. A positive list, because the host env
# is not fully trusted: VS Code's environmentVariables setting (its scope is
# undocumented) or a parent session can set anything. Each name here is
# harmless even if hostile:
# the worst case is a degraded session, never new file access, code loading
# (CLAUDE_CODE_PLUGIN_DIRS), another settings file (..._MANAGED_SETTINGS_PATH),
# credentials or a provider/endpoint switch (ANTHROPIC_*, CLAUDE_CODE_USE_*).
# Static preferences do not belong here at all: put them in the read-only
# claude-settings/settings.json "env" block, which the CLI applies to itself.
ENV_ALLOW=(
    # What the VS Code extension and the Agent SDK set per launch.
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
# Rewritten, not forwarded: the host points it at claude-home/.claude for the
# extension, and inside the sandbox that same directory is simply ~/.claude.
if [ "${CLAUDE_CONFIG_DIR+set}" ]; then
    ENV_ARGS+=(--setenv CLAUDE_CONFIG_DIR "$HOME/.claude")
fi

exec systemd-run --user --scope -q \
    -p MemoryMax=8G -p TasksMax=1024 \
    bwrap \
        `# ---- namespaces -------------------------------------------------` \
        `# --unshare-all covers user, pid, ipc, uts, cgroup and net.` \
        `# --share-net must come after it, and re-shares ONLY the network.` \
        `# CAVEAT: sharing the network namespace also shares abstract-namespace` \
        `# Unix sockets. Under X11 that includes the X server, and anything that` \
        `# can reach X11 can keylog the session. Check: echo $XDG_SESSION_TYPE` \
        `# On Wayland the compositor socket is a file in XDG_RUNTIME_DIR, which` \
        `# is not bound here, so this matters much less.` \
        --unshare-all \
        --share-net \
        `# Neutral hostname: don't leak the host's name into prompts/logs.` \
        --hostname bubbleclaude \
        --die-with-parent \
        `# --new-session drops the controlling terminal (TIOCSTI defence).` \
        `# It makes the process report "not a tty". That is fine for one-shot` \
        `# non-interactive runs; if it breaks the interactive TUI, drop it and` \
        `# accept the (small, on modern kernels) TIOCSTI risk instead.` \
        --new-session \
        \
        `# ---- environment: start empty, add back only what is needed -----` \
        `# Without this you inherit SSH_AUTH_SOCK, GITHUB_TOKEN, AWS_*, DISPLAY...` \
        --clearenv \
        --setenv HOME "$HOME" \
        `# CLAUDE_BIN's own dir first: with an nvm install, node sits next to` \
        `# claude and the env-node shebang needs it on PATH.` \
        --setenv PATH "$CLAUDE_BIN_DIR":"$HOME/.local/bin":/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        --setenv TERM "${TERM:-xterm-256color}" \
        --setenv LANG "${LANG:-C.UTF-8}" \
        --setenv USER "${USER:-$(id -un)}" \
        `# Host variables from the ENV_ALLOW list above.` \
        "${ENV_ARGS[@]}" \
        \
        `# ---- system, read-only ------------------------------------------` \
        --ro-bind /usr /usr \
        `# Debian is usr-merged: /bin /sbin /lib /lib64 are symlinks into /usr.` \
        `# Recreate them as symlinks rather than --ro-bind, which would replace` \
        `# a symlink with a real directory and can confuse path comparisons.` \
        --symlink usr/bin   /bin \
        --symlink usr/sbin  /sbin \
        --symlink usr/lib   /lib \
        --symlink usr/lib64 /lib64 \
        \
        `# ---- minimal /etc; note nsswitch.conf, which glibc needs for DNS -` \
        --ro-bind /etc/resolv.conf   /etc/resolv.conf \
        --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf \
        --ro-bind /etc/hosts         /etc/hosts \
        --ro-bind /etc/ssl           /etc/ssl \
        --ro-bind /etc/passwd        /etc/passwd \
        --ro-bind /etc/group         /etc/group \
        --ro-bind-try /etc/localtime /etc/localtime \
        --ro-bind-try /etc/ca-certificates.conf /etc/ca-certificates.conf \
        \
        `# ---- fresh pseudo-filesystems -----------------------------------` \
        --proc /proc \
        --dev /dev \
        `# tmpfs is RAM; cap /tmp (2 GiB, --size wants bytes) so it can't eat it all` \
        --size 2147483648 --tmpfs /tmp \
        \
        `# The sandbox gets its own real home directory. Persists across runs, so` \
        `# ~/.claude.json (OAuth session, preferences, per-project trust) survives.` \
        --bind "$SANDBOX_HOME" "$HOME" \
        `# Read-only: CLAUDE.md auto-loads into every session, so writable it would` \
        `# be a persistent prompt-injection channel. Edit it from the host instead.` \
        --ro-bind "$CLAUDE_SETTINGS_PATH/CLAUDE.md" "$HOME/.claude/CLAUDE.md" \
        \
        `# Sources resolve on the HOST, so these read from your real home while` \
        `# landing inside the sandbox home.` \
        --ro-bind-try "$REAL_HOME/.gitconfig" "$HOME/.gitconfig" \
        --ro-bind-try "$REAL_HOME/.config/git/config" "$HOME/.config/git/config" \
        --ro-bind-try "$REAL_HOME/.local/bin"     "$HOME/.local/bin" \
        --ro-bind-try "$REAL_HOME/.local/share/claude"     "$HOME/.local/share/claude" \
        --ro-bind-try "$REAL_HOME/.nvm"       "$HOME/.nvm" \
        `# The claude binary alone, never its directory: a CLAUDE_BIN under /tmp` \
        `# or ~/.config must not drag the siblings in. A no-op inside /usr or` \
        `# ~/.local; the only bind of ~/.vscode-server/... for the bundled copy.` \
        --ro-bind "$CLAUDE_BIN_REAL" "$CLAUDE_BIN_REAL" \
        \
        `# Still pin settings.json read-only from the host copy: otherwise Claude` \
        `# could rewrite its own sandbox.network.allowedDomains for the next run.` \
        --ro-bind "$CLAUDE_SETTINGS_PATH/settings.json" "$HOME/.claude/settings.json" \
        `# Same file again as managed settings, the TOP of the precedence chain:` \
        `# a writable project .claude/settings.json can outrank user settings, but` \
        `# nothing outranks managed.` \
        --ro-bind "$CLAUDE_SETTINGS_PATH/settings.json" /etc/claude-code/managed-settings.json \
        `# Mask as empty tmpfs so a session can't plant agents/commands/hooks/` \
        `# skills/plugins that auto-load into every future run (anti-persistence).` \
        --tmpfs "$HOME/.claude/agents" \
        --tmpfs "$HOME/.claude/commands" \
        --tmpfs "$HOME/.claude/hooks" \
        --tmpfs "$HOME/.claude/skills" \
        --tmpfs "$HOME/.claude/plugins" \
        `# Same attack via shell rc files, sourced by future sessions' shell` \
        `# snapshots: shadow them with a read-only empty file, and rm-and-replace` \
        `# fails too (mount point). Content comes from fds opened on /dev/null at` \
        `# the exec line, one per file since bwrap closes each after reading. Not` \
        `# a bind of /dev/null itself: bwrap mounts binds nodev, so a device node` \
        `# there is unopenable and breaks sourcing.` \
        --ro-bind-data 7 "$HOME/.bashrc" \
        --ro-bind-data 8 "$HOME/.bash_profile" \
        --ro-bind-data 9 "$HOME/.profile" \
        \
        `# ---- the project: the only genuinely writable place -------------` \
        --bind "$PROJECT" "$PROJECT" \
        `# Later mounts stack over earlier ones: mask the repo read-only (see top).` \
        "${MASK_ARGS[@]}" \
        --chdir "$PROJECT" \
        \
        "$CLAUDE_BIN_REAL" "$@" 7</dev/null 8</dev/null 9</dev/null
