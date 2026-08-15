bubbleclaude
============

Run [Claude Code](https://claude.com/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`) sandbox, so the agent can only see and touch what you explicitly give it.

The sandbox uses an **allowlist model**: nothing exists inside the namespace unless
it is bound in by `bclaude.sh`. Your real home directory, SSH keys, cloud
credentials, and environment variables are not "denied" — they are simply *absent*.
The only writable location is your projects directory.

What it protects against
-------------------------

- Claude reading or exfiltrating anything outside the project directory
  (`~/.ssh`, `~/.aws`, browser profiles, other repos...).
- Leaked secrets from the environment: the sandbox starts with `--clearenv`, so
  `SSH_AUTH_SOCK`, `GITHUB_TOKEN`, `AWS_*`, `DISPLAY` etc. never make it inside.
- Claude rewriting its own security settings: `settings.json` is bound
  **read-only**, twice — at `~/.claude/settings.json` and at
  `/etc/claude-code/managed-settings.json`, the top of the settings precedence.
  A project-level `.claude/settings.json` (which outranks user settings) can
  therefore not override the sandbox config either. And if this repo sits inside
  `PROJECT_DIR`, it is remounted read-only, so the agent cannot reach the source
  of `bclaude.sh` or `settings.json` through the writable project mount.
- Cross-session persistence: `~/.claude/agents`, `commands`, `hooks`, `skills`
  and `plugins` inside the sandbox are tmpfs, and the shell rc files (`.bashrc`,
  `.bash_profile`, `.profile`) are shadowed by `/dev/null`, so a prompt-injected
  session cannot plant code or instructions that auto-load into future sessions.
- Runaway resource use: the sandbox runs in a systemd scope with `MemoryMax=8G`
  and `TasksMax=1024` (bwrap itself has no cgroup support), and `/tmp` is a
  tmpfs capped at 2 GiB.
- On top of the bwrap layer, Claude Code's own inner sandbox is enabled with
  `failIfUnavailable: true` and a strict network domain allowlist — defence in
  depth. `strictAllowlist` means a non-listed domain is denied outright (no
  approval prompt a user could reflexively accept), `allowManagedDomainsOnly`
  means domain rules added from project settings are ignored, and
  `allowManagedHooksOnly` / `disableSideloadFlags` block hooks and sideloaded
  plugins/agents from any scope a session can write to.

Requirements
------------

- Linux with `bwrap` installed (`apt install bubblewrap` on Debian/Ubuntu) and a
  systemd user session (used for the resource limits).
- Claude Code installed on the host, reachable from `PATH` under a path the
  sandbox binds in: `/usr/...`, `~/.local/bin`, or `~/.nvm`.
- A usr-merged distribution layout (`/bin`, `/lib`... as symlinks into `/usr`),
  which is standard on current Debian and derivatives.

Usage
-----

```sh
./bclaude.sh [claude args...]          # launch sandboxed Claude Code
PROJECT_DIR=~/work ./bclaude.sh        # override the writable projects dir (default: ~/projects)
SANDBOX_HOME=/path/home ./bclaude.sh   # override the fake home (default: ./claude-home)
```

Any extra arguments are passed straight to `claude`, so `./bclaude.sh -p "..."`,
`./bclaude.sh --resume`, etc. all work.

Before launching, the script runs `claude update` **on the host**: the sandbox is
read-only everywhere the updater would write, so Claude cannot update itself from
inside. If the update fails (offline, outage), the script warns and launches the
current version anyway.

### First launch

Inside the sandbox, Claude Code sees a fresh, empty home directory — as if it had
never been run on this machine. On the **first launch you have to log in again and
answer the onboarding questions** (theme, trust prompts...), even if Claude is
already configured on the host. This is expected: your real `~/.claude.json` is
deliberately not exposed to the sandbox.

Everything you set up is stored in `claude-home/` and **persists across runs** —
OAuth session, preferences, per-project trust, history. You only go through
onboarding once.

### Verifying the sandbox actually applies

From a normal shell:

```sh
readlink /proc/self/ns/mnt
```

Then ask Claude to run the same command inside the session. A **different** inode
means the sandbox is in effect. A **matching** inode means it is not, regardless
of what the configuration says.

Layout
------

| Path                            | Role                                                                     |
|---------------------------------|--------------------------------------------------------------------------|
| `bclaude.sh`                    | The whole tool: resolves `claude` on the host, updates it, `exec bwrap`  |
| `claude-home/`                  | Bound over `$HOME`; the only persistent state (OAuth, prefs, history)    |
| `claude-settings/settings.json` | Bound read-only twice: user settings and top-precedence managed settings |
| `claude-settings/CLAUDE.md`     | Global instructions, bound read-only; edit from the host                 |
| `projects/`                     | Placeholder mount point; `PROJECT_DIR` is bound over it                  |

A few things are read-only bound *from your real home* for convenience:
`~/.gitconfig`, `~/.local/bin`, `~/.local/share/claude`, and `~/.nvm` (the latter
three so a host-installed `claude` binary and its runtime resolve inside the
sandbox — deliberately *not* all of `~/.local`, which would expose keyrings and
other app data under `~/.local/share`).

Network configuration: edit `claude-settings/settings.json` on the host to change
the allowed domains — by design this cannot be done from inside a session. The
list is strict: a domain that is not on it is denied with no runtime prompt, so
`npm install` / `pip install` against a registry you have not listed will simply
fail until you add it on the host and relaunch.

Constraints and limits
----------------------

- **Network is shared, not isolated.** The sandbox re-shares the host network
  namespace; the domain allowlist is enforced by Claude Code's inner sandbox, not
  by bwrap. Sharing the network namespace also shares abstract-namespace Unix
  sockets — **under X11 that includes the X server**, and anything that can reach
  X11 can keylog the session. On Wayland the compositor socket is a file in
  `XDG_RUNTIME_DIR`, which is not bound, so exposure is much smaller. Check with
  `echo $XDG_SESSION_TYPE`.
- **No SSH agent inside.** `SSH_AUTH_SOCK` is not passed through, so `git` over
  SSH won't work in the sandbox; use HTTPS remotes (github.com is in the network
  allowlist).
- **Only `PROJECT_DIR` is writable.** Anything Claude needs to read must live
  there or under one of the bound paths; everything else does not exist from its
  point of view.
- **`--new-session` drops the controlling terminal** (TIOCSTI defence), at the
  cost of the process reporting "not a tty". If it ever breaks the interactive
  TUI, that flag is the trade-off to revisit.
- **Minimal `/etc`.** Only DNS, TLS certificates, passwd/group and timezone are
  bound. Tools that expect other host config under `/etc` won't find it.
- **This repo is read-only inside the sandbox** (when it lives under
  `PROJECT_DIR`) — by design, so the agent cannot rewrite its own cage. That
  includes the global `CLAUDE.md`: instructions that auto-load into every
  session are policy, and policy is edited from outside the sandbox. Setting
  `PROJECT_DIR` to the repo itself is refused at launch for the same reason.
- **Fixed limits.** 8 GiB memory, 1024 tasks, 2 GiB `/tmp` — enough for normal
  agent work; raise them in the script if a big build needs more. The hostname
  inside reads `bubbleclaude`.
- **Same user, same kernel.** bwrap is a namespace sandbox, not a VM: a kernel
  exploit or a hole in the shared network namespace is out of scope.
