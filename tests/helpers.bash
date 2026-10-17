# Shared by the .bats files: fixtures, the in-sandbox probe and the launcher.
# Loaded with `load helpers`; functions meant for setup_file export their paths
# because tests run in subshells of it.

export REPO
REPO="$(dirname "$BATS_TEST_DIRNAME")"

# The script execs through systemd-run; without a user manager that is the
# first thing to break, so decide loudly before any launch.
systemd_shim() {
    export BIN="$BATS_FILE_TMPDIR/bin"
    mkdir -p "$BIN"
    if [ "${BCLAUDE_TEST_NO_SYSTEMD:-0}" = 1 ]; then
        # The shim drops the options, so it pins the one that is a security
        # control: without it the ${VAR} expansion of systemd >= 258 returns.
        cat > "$BIN/systemd-run" <<'SHIM'
#!/bin/sh
case " $* " in *" --expand-environment=no "*) ;;
    *) echo "systemd-run shim: --expand-environment=no missing" >&2; exit 1;; esac
while [ $# -gt 0 ] && [ "$1" != bwrap ]; do shift; done
exec "$@"
SHIM
        chmod +x "$BIN/systemd-run"
        echo "# systemd-run shimmed, resource limits not exercised" >&3
    elif ! systemd-run --user --scope -q true 2>/dev/null; then
        echo "systemd-run --user does not work here; set BCLAUDE_TEST_NO_SYSTEMD=1" >&2
        return 1
    fi
}

# A real home as the script sees it: a secret that must stay outside, the two
# files it binds read-only, a .gitconfig it binds through.
host_home() {
    mkdir -p "$1/.claude"
    echo secret > "$1/secret"
    echo '{"host":true}' > "$1/.claude/settings.json"
    echo 'host md' > "$1/.claude/CLAUDE.md"
    echo '[user]' > "$1/.gitconfig"
}

# Runs inside as `bash -c "$PROBE" probe <paths...>`: one key=value per line.
# Writability is probed with touch: it fails with EROFS on a read-only mount
# and never alters content on a writable one, unlike a redirection.
# shellcheck disable=SC2016 # expanded inside the sandbox, not here
PROBE='
r() { printf "%s=%s\n" "$1" "$2"; }
w() { if touch "$1" 2>/dev/null; then echo yes; else echo no; fi; }
e() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
r ns "$(readlink /proc/self/ns/mnt)"
r home "$HOME"
r pwd "$PWD"
r hostname "$(cat /proc/sys/kernel/hostname)"
for v in SSH_AUTH_SOCK GITHUB_TOKEN ANTHROPIC_API_KEY DISPLAY XDG_RUNTIME_DIR \
         DBUS_SESSION_BUS_ADDRESS DISABLE_TELEMETRY CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER PATH; do
    r "env_$v" "${!v-unset}"
done
r capbnd "$(awk "/^CapBnd:/ {print \$2}" /proc/self/status)"
r host_secret "$(e "$HOME/secret")"
r sandbox_canary "$(e "$HOME/sandbox-canary")"
r etc_shadow "$(e /etc/shadow)"
r gitconfig "$(cat "$HOME/.gitconfig" 2>/dev/null)"
r w_gitconfig "$(w "$HOME/.gitconfig")"
r w_usr "$(w /usr/smoke)"
r w_tmp "$(w /tmp/smoke)"
r w_home "$(w "$HOME/smoke")"
r w_settings "$(w "$HOME/.claude/settings.json")"
r w_claude_md "$(w "$HOME/.claude/CLAUDE.md")"
r w_settings_local "$(w "$HOME/.claude/settings.local.json")"
r w_skills "$(w "$HOME/.claude/skills/smoke")"
r w_bashrc "$(w "$HOME/.bashrc")"
r rm_bashrc "$(if rm -f "$HOME/.bashrc" 2>/dev/null; then echo yes; else echo no; fi)"
r w_managed "$(w /etc/claude-code/managed-settings.json)"
r settings "$(cat "$HOME/.claude/settings.json")"
r claude_md "$(cat "$HOME/.claude/CLAUDE.md")"
r settings_local "$(cat "$HOME/.claude/settings.local.json")"
r managed_sha "$(sha256sum /etc/claude-code/managed-settings.json | cut -d" " -f1)"
for p in "$@"; do r "w_$p" "$(w "$p")"; done
'

# launch <script> <home> <sandbox-home|-> <project> [bash args...]
# Canary variables stand in for the host secrets that --clearenv must drop;
# DISABLE_TELEMETRY and CLAUDE_CONFIG_DIR are the two forwarding paths.
# TEST_CLAUDE_BIN stands in for the binary; it must behave like bash, and
# DISABLE_AUTOUPDATER keeps the script from running `bash update` on it: `yes`
# rather than `1`, so the forced value inside is told apart from forwarding.
# systemd-run --user finds the bus through XDG_RUNTIME_DIR or
# DBUS_SESSION_BUS_ADDRESS: the host's values go through, canaries otherwise.
launch() {
    local script="$1" home="$2" sandbox="$3" project="$4"
    shift 4
    local -a vars=(HOME="$home" PATH="$BIN:$PATH" CLAUDE_BIN="${TEST_CLAUDE_BIN:-/bin/bash}"
        DISABLE_AUTOUPDATER=yes
        USER="${USER:-$(id -un)}" SSH_AUTH_SOCK=/leak GITHUB_TOKEN=leak
        ANTHROPIC_API_KEY=leak DISPLAY=:0 DISABLE_TELEMETRY=1
        CLAUDE_CONFIG_DIR=/elsewhere
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/leak}"
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/leak}")
    [ "$sandbox" = - ] || vars+=(SANDBOX_HOME="$sandbox")
    (cd "$project" && env -i "${vars[@]}" "$script" "$@")
}

# probe <name> <script> <home> <sandbox-home|-> <project> [paths...]
# One launch per scenario from setup_file; the tests read <name>.out via rv.
probe() {
    local name="$1"
    shift
    launch "$1" "$2" "$3" "$4" -c "$PROBE" probe "${@:5}" \
        > "$BATS_FILE_TMPDIR/$name.out" 2> "$BATS_FILE_TMPDIR/$name.err" \
        || { cat "$BATS_FILE_TMPDIR/$name.err" >&2; return 1; }
}

# rv <name> <key>: the probed value, or <missing> so a bad launch reads as such.
rv() {
    local k v
    while IFS='=' read -r k v; do
        if [ "$k" = "$2" ]; then printf '%s' "$v"; return; fi
    done < "$BATS_FILE_TMPDIR/$1.out"
    printf '<missing>'
}

# is <name> <key> <expected>
is() {
    local got
    got="$(rv "$1" "$2")"
    [ "$got" = "$3" ] || { echo "$2: got '$got', want '$3'"; return 1; }
}

exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
