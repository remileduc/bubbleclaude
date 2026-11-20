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
# Every argument is claude's. The script's own options come from the
# environment, then from ~/.config/bclaude/config: see examples/bclaude.conf.
# CLAUDE_BIN=/path/to/claude overrides the PATH lookup (bclaude-vscode.sh).
# SANDBOX_HOME=/path overrides the fake home (default: claude-home/ in the repo).
#
# Check it applies: `readlink /proc/self/ns/mnt` from your shell and from inside
# must differ. Same inode = no sandbox, whatever you configured.

set -eufo pipefail

die() { echo "$*" >&2; exit 1; }

# config_error <source> <line>: a failing last line that set -e exempts (an &&
# list) fails `source` itself, so the trap then reports this script, not the file.
config_error() {
    [ "$1" = "$CONFIG" ] || die "config error: $CONFIG ended with a failing command"
    die "config error at $1:$2"
}

# readlink -f: $0 may be a symlink, and binds must resolve against the real repo.
BCLAUDE_PATH="$(dirname "$(readlink -f "$0")")"
REAL_HOME="$(realpath "$HOME")"
# Canonical: a symlinked launch path would not exist inside the sandbox.
PROJECT="$(realpath "$PWD")"
# Bound writable on top of everything else, a parent of the real home would
# resolve $HOME back to your real files. "/" never matches "$PROJECT"/*.
case "$REAL_HOME" in
    "$PROJECT"|"$PROJECT"/*) die "refusing: $PROJECT holds your real home directory" ;;
esac
[ "$PROJECT" != / ] || die "refusing: / is not a project directory"

# Sourced, so it is host code: checked before it runs, because under the
# project or a sandbox home a session would write its own next launch.
CONFIG_DIR="$(realpath -m "${XDG_CONFIG_HOME:-$REAL_HOME/.config}/bclaude")"
CONFIG="$(realpath -m "$CONFIG_DIR/config")"
# The config file can read these, and they are checked again after it ran:
# assigning one there must fail, not skip a refusal.
readonly BCLAUDE_PATH REAL_HOME PROJECT CONFIG_DIR CONFIG
for path in "$CONFIG_DIR" "$CONFIG"; do
    case "$path" in
        "$PROJECT"|"$PROJECT"/*)
            die "refusing: $PROJECT holds the bclaude config ($path)" ;;
    esac
done
# The default too: launches without the variable write there. A sandbox home
# the file itself sets is only known, and checked, once it has run.
for home in "$BCLAUDE_PATH/claude-home" ${SANDBOX_HOME:+"$SANDBOX_HOME"}; do
    home="$(realpath -m "$home")"
    case "$REAL_HOME" in
        # Named first: the config under your home would otherwise take the blame.
        "$home"|"$home"/*) die "refusing: sandbox home $home holds your real home" ;;
    esac
    for path in "$CONFIG_DIR" "$CONFIG"; do
        case "$path" in
            "$home"|"$home"/*)
                die "refusing: $path is inside the sandbox home ($home)" ;;
        esac
    done
done
# Every option the config file may set. The environment wins over the file.
OPTIONS=(
    SANDBOX_HOME CLAUDE_BIN DISABLE_AUTOUPDATER
    BCLAUDE_MANAGED_SETTINGS BCLAUDE_CLAUDE_MD
    BCLAUDE_MEMORY_MAX BCLAUDE_TASKS_MAX BCLAUDE_CPU_WEIGHT BCLAUDE_TMP_SIZE
    BCLAUDE_GITCONFIG BCLAUDE_LOCAL_BIN BCLAUDE_NVM BCLAUDE_PNPM
)
if [ -e "$CONFIG" ]; then
    FROM_ENV=()
    for name in "${OPTIONS[@]}"; do
        if [ "${!name+set}" ]; then FROM_ENV+=("$name" "${!name}"); fi
    done
    # set -e alone ends the launch without a word when the file's last line fails.
    trap 'config_error "${BASH_SOURCE[0]}" "$LINENO"' ERR
    # shellcheck source=/dev/null
    source "$CONFIG"
    trap - ERR
    for ((i = 0; i < ${#FROM_ENV[@]}; i += 2)); do
        printf -v "${FROM_ENV[i]}" %s "${FROM_ENV[i + 1]}"
    done
fi
# systemd scope limits. The tmpfs cap is in bytes: bwrap takes no suffix.
: "${BCLAUDE_MEMORY_MAX:=8G}" "${BCLAUDE_TASKS_MAX:=1024}" "${BCLAUDE_CPU_WEIGHT:=25}"
: "${BCLAUDE_TMP_SIZE:=2147483648}"
: "${BCLAUDE_GITCONFIG:=1}" "${BCLAUDE_LOCAL_BIN:=1}" "${BCLAUDE_NVM:=1}" "${BCLAUDE_PNPM:=1}"
# A typo must not pick a side, and must stop the launch before it acts on the host.
for name in BCLAUDE_GITCONFIG BCLAUDE_LOCAL_BIN BCLAUDE_NVM BCLAUDE_PNPM; do
    case "${!name}" in
        0|1) ;;
        *) die "$name must be 0 or 1, not '${!name}'" ;;
    esac
done

SANDBOX_HOME="$(realpath -m "${SANDBOX_HOME:-$BCLAUDE_PATH/claude-home}")"
# Policy only, bound as managed settings: no user or project file outranks it.
MANAGED_SETTINGS="$(realpath -m "${BCLAUDE_MANAGED_SETTINGS:-$BCLAUDE_PATH/managed-settings.json}")"
[ -f "$MANAGED_SETTINGS" ] || die "managed settings not found: $MANAGED_SETTINGS"
# The user's layer, as outside the sandbox. Resolved: symlinked into a dotfiles
# repo, these must still fail the project checks below.
USER_CLAUDE_DIR="$(realpath -m "$REAL_HOME/.claude")"
USER_SETTINGS="$(realpath -m "$USER_CLAUDE_DIR/settings.json")"
USER_CLAUDE_MD="$(realpath -m "${BCLAUDE_CLAUDE_MD:-$USER_CLAUDE_DIR/CLAUDE.md}")"
# Absent, the default is shadowed with an empty file: a mistyped override must not be.
if [ "${BCLAUDE_CLAUDE_MD:-}" ] && [ ! -f "$USER_CLAUDE_MD" ]; then
    die "BCLAUDE_CLAUDE_MD not found: $USER_CLAUDE_MD"
fi

# Resolved on the HOST.
export PATH="$HOME/.local/bin:$PATH"
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
if [ "$BCLAUDE_NVM" = 0 ]; then
    # Bound alone, the binary would have neither its node nor its modules.
    for path in "$CLAUDE_BIN_DIR" "$CLAUDE_BIN_REAL"; do
        case "$path" in
            "$REAL_HOME"/.nvm/*) die "BCLAUDE_NVM=0 leaves out ~/.nvm, where claude lives ($path)" ;;
        esac
    done
fi

# As the project, the sandbox home would be a writable persistence channel.
case "$PROJECT" in
    "$SANDBOX_HOME"|"$SANDBOX_HOME"/*)
        die "refusing: $PROJECT is inside the sandbox home ($SANDBOX_HOME)" ;;
    "$USER_CLAUDE_DIR"|"$USER_CLAUDE_DIR"/*)
        die "refusing: $PROJECT is your Claude config directory. Bro... WTF" ;;
esac
case "$REAL_HOME" in
    # Bound over $HOME: your real home would be its own writable fake home.
    "$SANDBOX_HOME"|"$SANDBOX_HOME"/*)
        die "refusing: sandbox home $SANDBOX_HOME holds your real home" ;;
esac
# Your real config resolved under the project would be writable from inside,
# even as a dangling symlink a session could then target: refused, not masked.
for path in "$USER_CLAUDE_DIR" "$USER_SETTINGS" "$USER_CLAUDE_MD"; do
    case "$path" in
        "$PROJECT"|"$PROJECT"/*)
            die "refusing: $PROJECT holds your Claude config ($path)" ;;
    esac
done
# What the options repoint must sit where no session writes. The sandbox home
# is writable at $HOME; the default CLAUDE.md is exempt, it may be its own bind.
for path in "$MANAGED_SETTINGS" "$CONFIG_DIR" "$CONFIG" ${BCLAUDE_CLAUDE_MD:+"$USER_CLAUDE_MD"}; do
    case "$path" in
        "$SANDBOX_HOME"|"$SANDBOX_HOME"/*)
            die "refusing: $path is inside the sandbox home ($SANDBOX_HOME)" ;;
    esac
done
# Under the repo it is masked below, or dev mode says so out loud.
case "$MANAGED_SETTINGS" in
    "$BCLAUDE_PATH"/*) ;;
    "$PROJECT"/*) die "refusing: $PROJECT holds the managed settings ($MANAGED_SETTINGS)" ;;
esac

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

# An editor's bundled binary leaves its mount-point chain in the sandbox home,
# one per extension version. Prune only the versions the editor has removed:
# unlinking a mount point on the host detaches the bind of a live session.
case "$CLAUDE_BIN_REAL" in
    "$REAL_HOME"/.*/extensions/*/*)
        HOST_EXT="${CLAUDE_BIN_REAL%%/extensions/*}/extensions"
        STUBS="$SANDBOX_HOME/${HOST_EXT#"$REAL_HOME"/}"
        KEEP=()
        while IFS= read -r -d '' name; do KEEP+=(! -name "$name"); done \
            < <(find "$HOST_EXT" -mindepth 1 -maxdepth 1 -printf '%f\0')
        # Empty means the host listing failed: pruning everything would be wrong.
        if [ ${#KEEP[@]} -gt 0 ]; then (
            cd "$STUBS" 2>/dev/null || exit 0
            # A session can swap any component under the sandbox home for a
            # symlink to your real files between a check and the rm: cd pins
            # the directory, and the physical path tells whether it is ours.
            [ "$(pwd -P)" = "$STUBS" ] || die "refusing: $STUBS resolves to $(pwd -P)"
            # Housekeeping, not policy: an undeletable stub must not block launches.
            find . -mindepth 1 -maxdepth 1 "${KEEP[@]}" -exec rm -rf -- {} + \
                || echo "warning: could not prune stale extension stubs in $STUBS" >&2
        ); fi ;;
esac

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

# Updated on the host: the sandbox is read-only where npm writes. Claude's own
# DISABLE_AUTOUPDATER switch covers this step too (`-p` one-shots, the VS Code
# wrapper whose bundled binary must not self-replace).
case "${DISABLE_AUTOUPDATER:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) ;;
    *) "$CLAUDE_BIN" update || echo "warning: update failed, launching current version" >&2 ;;
esac

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
    # Telemetry and UI switches. Not DISABLE_AUTOUPDATER: forced below.
    DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DO_NOT_TRACK
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

# Optional read-only binds from the real home. Sources resolve on the HOST.
HOST_ARGS=()
LOCAL_BIN=
PNPM_BIN=
BIN_PATH=
# Shadowed when not bound, like settings.json below: creatable in the persistent
# home, a planted core.fsmonitor, pager or alias would run in later sessions.
for file in .gitconfig .config/git/config; do
    if [ "$BCLAUDE_GITCONFIG" = 1 ] && [ -f "$REAL_HOME/$file" ]; then
        HOST_ARGS+=(--ro-bind "$REAL_HOME/$file" "$HOME/$file")
    else
        exec {fd}</dev/null
        HOST_ARGS+=(--ro-bind-data "$fd" "$HOME/$file")
    fi
done
if [ "$BCLAUDE_LOCAL_BIN" = 1 ]; then
    HOST_ARGS+=(--ro-bind-try "$REAL_HOME/.local/bin" "$HOME/.local/bin")
    # On PATH only when bound from the host: unbound, it is a writable directory
    # in the persistent home that later sessions resolve through.
    [ ! -d "$REAL_HOME/.local/bin" ] || LOCAL_BIN="$HOME/.local/bin:"
fi
if [ "$BCLAUDE_PNPM" = 1 ]; then
    # All of PNPM_HOME: bin/ only holds shims into global/. Never writable, it
    # holds the store every host project links from.
    HOST_ARGS+=(--ro-bind-try "$REAL_HOME/.local/share/pnpm" "$HOME/.local/share/pnpm")
    # Same rule as above. Last: its global-package shims must not shadow /usr.
    [ ! -d "$REAL_HOME/.local/share/pnpm/bin" ] || PNPM_BIN=":$HOME/.local/share/pnpm/bin"
fi
if [ "$BCLAUDE_NVM" = 1 ]; then
    HOST_ARGS+=(--ro-bind-try "$REAL_HOME/.nvm" "$HOME/.nvm")
    # The binary's dir on PATH only under nvm, where the node its shebang needs sits
    # beside it: elsewhere (~/.vscode-server) its mount point is a writable dir in $HOME.
    case "$CLAUDE_BIN_DIR" in
        "$REAL_HOME"/.nvm/*) BIN_PATH="$CLAUDE_BIN_DIR:" ;;
    esac
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
    --setenv PATH "$BIN_PATH$LOCAL_BIN/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin$PNPM_BIN"
    --setenv TERM "${TERM:-xterm-256color}"
    --setenv LANG "${LANG:-C.UTF-8}"
    --setenv USER "${USER:-$(id -un)}"
    # Updated on the host above; inside, the updater could only fail or litter
    # the sandbox home.
    --setenv DISABLE_AUTOUPDATER 1
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
    # tmpfs is RAM: capped, 2 GiB each by default.
    --size "$BCLAUDE_TMP_SIZE" --tmpfs /tmp
    --size "$BCLAUDE_TMP_SIZE" --tmpfs /var/tmp

    # The sandbox's own persistent home: ~/.claude.json (OAuth, trust) survives.
    --bind "$SANDBOX_HOME" "$HOME"
    "${HOST_ARGS[@]}"
    # Sources resolve on the HOST: this reads your real home and lands inside.
    --ro-bind-try "$REAL_HOME/.local/share/claude" "$HOME/.local/share/claude"
    # The binary alone, never its directory.
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
    exec {fd}<<<'{}'
    BWRAP_ARGS+=(--ro-bind-data "$fd" "$HOME/.claude/settings.json")
fi
if [ -f "$USER_CLAUDE_MD" ]; then
    BWRAP_ARGS+=(--ro-bind "$USER_CLAUDE_MD" "$HOME/.claude/CLAUDE.md")
else
    exec {fd}</dev/null
    BWRAP_ARGS+=(--ro-bind-data "$fd" "$HOME/.claude/CLAUDE.md")
fi
# Never bound from the host: a local override of settings.json is the same
# persistence channel, so it is always the empty object.
exec {fd}<<<'{}'
BWRAP_ARGS+=(--ro-bind-data "$fd" "$HOME/.claude/settings.local.json")

# Same attack via shell rc files sourced by later shell snapshots: a read-only
# empty mount point, so rm-and-replace fails too. One fd each, bwrap closes it
# after reading. Not a bind of /dev/null: binds are nodev, so a device node
# there is unopenable and breaks sourcing.
for file in .bashrc .bash_profile .profile; do
    exec {fd}</dev/null
    BWRAP_ARGS+=(--ro-bind-data "$fd" "$HOME/$file")
done

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

    # The project: the only genuinely writable place. Then the masks (see top).
    --bind "$PROJECT" "$PROJECT"
    "${MASK_ARGS[@]}"
    --chdir "$PROJECT"
)

# systemd-run >= 258 substitutes ${VAR} in its argv from the HOST environment,
# before --clearenv: a claude prompt quoting ${GITHUB_TOKEN} would leak it and a
# bind path containing `$` would reshape the mount layout. Needs systemd 254+.
exec systemd-run --user --scope -q --expand-environment=no \
    -p MemoryMax="$BCLAUDE_MEMORY_MAX" -p TasksMax="$BCLAUDE_TASKS_MAX" \
    -p CPUWeight="$BCLAUDE_CPU_WEIGHT" \
    bwrap "${BWRAP_ARGS[@]}" "$CLAUDE_BIN_REAL" "$@"
