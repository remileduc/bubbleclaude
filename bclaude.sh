#!/usr/bin/env bash
# Launch Claude Code inside a bubblewrap sandbox.
#
# Allowlist model: nothing exists inside the sandbox unless bound in below.
# Paths not listed are ABSENT, not merely denied
#
# Usage:  ./bclaude.sh [claude args...]
#
# Verify it is actually working, from your normal shell:
#     readlink /proc/self/ns/mnt
# then ask Claude to run the same command. Different inode = sandboxed.
# A *matching* inode means the sandbox is not applying, whatever you configured.

set -eufo pipefail

# readlink -f: $0 may be a symlink (e.g. ~/.local/bin/bclaude), and the binds
# below must resolve relative to the real repo, not the symlink's directory.
BCLAUDE_PATH="$(dirname "$(readlink -f "$0")")"
REAL_HOME="$HOME"

# Directory where your projects belong, this is the directory where Claude can read and write
PROJECT_DIR="${PROJECT_DIR:-$HOME/projects}"
# This is the folder that will be mounted as the new home in the sandbox
SANDBOX_HOME="${SANDBOX_HOME:-$BCLAUDE_PATH/claude-home}"
# Path to the claude's settings.json and CLAUDE.md files to use in the sandbox (~/.claude/settings.json)
CLAUDE_SETTINGS_PATH="$BCLAUDE_PATH/claude-settings/"

mkdir -p "$SANDBOX_HOME/.claude"

# Resolved on the HOST. The result must live under a path bound in below
# (/usr/... or ~/.nvm/...), or the sandbox will start and then fail to exec
export PATH="$HOME/.local/bin:$PATH"
CLAUDE_BIN="$(command -v claude)" || { echo "claude not found in PATH" >&2; exit 1; }

[ -d "$PROJECT_DIR" ] || { echo "no such project dir: $PROJECT_DIR" >&2; exit 1; }

# Remount the repo/settings read-only when they sit inside PROJECT_DIR: otherwise
# the agent could edit bclaude.sh or settings.json and widen its own next launch.
MASK_ARGS=()
PROJECT_REAL="$(realpath "$PROJECT_DIR")"
for dir in "$BCLAUDE_PATH" "$CLAUDE_SETTINGS_PATH"; do
    real="$(realpath "$dir")"
    case "$real" in
        "$PROJECT_REAL"/*) MASK_ARGS+=(--ro-bind "$real" "$PROJECT_DIR/${real#"$PROJECT_REAL"/}") ;;
    esac
done

# bwrap silently falls back to / when the launch cwd is not bound inside the
# sandbox; pin the start directory to the project instead.
case "$(realpath "$PWD")" in
    "$PROJECT_REAL"|"$PROJECT_REAL"/*) SANDBOX_CWD="$PWD" ;;
    *)  SANDBOX_CWD="$PROJECT_DIR"
        echo "cwd is outside PROJECT_DIR, starting in $PROJECT_DIR" >&2 ;;
esac

# update claude as it can't update itself in the sandbox
"$CLAUDE_BIN" update || echo "warning: update failed, launching current version" >&2

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
        --setenv PATH "$(dirname "$CLAUDE_BIN")":"$HOME/.local/bin":/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        --setenv TERM "${TERM:-xterm-256color}" \
        --setenv LANG "${LANG:-C.UTF-8}" \
        --setenv USER "${USER:-$(id -un)}" \
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
        --ro-bind-try "$REAL_HOME/.local/bin"     "$HOME/.local/bin" \
        --ro-bind-try "$REAL_HOME/.local/share/claude"     "$HOME/.local/share/claude" \
        --ro-bind-try "$REAL_HOME/.nvm"       "$HOME/.nvm" \
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
        `# snapshots: shadow them with /dev/null so they can't be created either.` \
        --ro-bind /dev/null "$HOME/.bashrc" \
        --ro-bind /dev/null "$HOME/.bash_profile" \
        --ro-bind /dev/null "$HOME/.profile" \
        \
        `# ---- the project: the only genuinely writable place -------------` \
        --bind "$PROJECT_DIR" "$PROJECT_DIR" \
        `# Later mounts stack over earlier ones: mask the repo read-only (see top).` \
        "${MASK_ARGS[@]}" \
        --chdir "$SANDBOX_CWD" \
        \
        "$CLAUDE_BIN" "$@"
