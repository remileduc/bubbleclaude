bubbleclaude
============

Run [Claude Code](https://claude.com/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`) sandbox. Nothing exists inside unless `bclaude.sh` binds it in: your
home, keys, credentials and environment are absent, not denied. The only writable
location is the directory you launch from.

- [Requirements](#requirements)
- [Usage](#usage)
  - [First launch](#first-launch)
  - [VS Code (Linux and WSL)](#vs-code-linux-and-wsl)
  - [Working on bubbleclaude itself](#working-on-bubbleclaude-itself)
  - [Tests](#tests)
- [What it protects against](#what-it-protects-against)
- [Layout](#layout)
- [Constraints and limits](#constraints-and-limits)
- [Security audit](#security-audit)

Requirements
------------

- Linux with `bwrap` (`apt install bubblewrap`) and a systemd user session (for
  the resource limits).
- A usr-merged layout (`/bin`, `/lib`... symlinked into `/usr`), standard on
  current Debian and derivatives.
- Claude Code on the host, on `PATH` under a bound path: `/usr/...`,
  `~/.local/bin` or `~/.nvm`. Not needed for VS Code, whose extension brings its
  own binary.

Usage
-----

The launch directory is the project: bound writable at its real path, and the
only writable place inside.

```sh
ln -s ~/projects/bubbleclaude/bclaude.sh ~/.local/bin/bclaude   # once
cd ~/work/myproject && bclaude [claude args...]
```

Arguments go straight to `claude` (`bclaude -p "..."`, `bclaude --resume`).
Environment overrides:

```sh
SANDBOX_HOME=/path/home bclaude     # fake home (default: <repo>/claude-home)
CLAUDE_BIN=/path/to/claude bclaude  # this binary instead of the one on PATH
```

Refused launch directories: `/`, your home or any parent of it, `claude-home/` or
anything under it, and anything holding or inside your real `~/.claude` (symlinks
resolved, `settings.json` and `CLAUDE.md` included). Bound as the project, they
would stack over the sandbox home and hand the session your real files, or its
own state.

The script runs `claude update` on the host first, since the sandbox is read-only
wherever the updater writes; a failed update warns and launches the current
version. `DISABLE_AUTOUPDATER=1` skips it, useful for `-p` one-shots.

### First launch

The sandbox home starts empty: log in and answer the onboarding questions again,
even if Claude is configured on the host. The result lives in `claude-home/` and
persists across runs (OAuth session, preferences, per-project trust, history).

### VS Code (Linux and WSL)

The [extension](https://code.claude.com/docs/en/vs-code) runs on the Linux side
and starts its bundled `claude` with the workspace folder as working directory.
Point it at `bclaude-vscode.sh`, which turns that binary into `CLAUDE_BIN`,
sets `DISABLE_AUTOUPDATER=1` so the extension's own copy is never touched, and
calls `bclaude.sh`. Two host-side settings, both with full paths (no `~`):

**1. `claudeCode.claudeProcessWrapper`**, in machine scope so the project's
`.vscode/settings.json` cannot repoint it. WSL or any remote: **Preferences: Open
Remote Settings**, which writes `~/.vscode-server/data/Machine/settings.json`.
Local Linux: user settings, `~/.config/Code/User/settings.json`.

```json
{
  "claudeCode.claudeProcessWrapper": "/home/you/projects/bubbleclaude/bclaude-vscode.sh",
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "/home/you/projects/bubbleclaude/claude-home/.claude" }
  ]
}
```

**2. `CLAUDE_CONFIG_DIR` in the extension host's environment.** The extension
runs outside the sandbox and reads Claude's config directory on the host:
sessions, settings, credentials, and its IDE server's lock file under `ide/`. The
sandbox sees the same state at `~/.claude`, which is `claude-home/.claude` on the
host. The `environmentVariables` entry above is not enough on its own: tested,
the extension host kept reading the real `~/.claude`.

- WSL: `~/.vscode-server/server-env-setup`, the one hook the VS Code server
  sources (it runs no shell rc files). It must be valid Bourne shell: a syntax
  error stops the server from starting, and the fix is to delete or rename the
  file from a plain WSL shell. Restart the server afterwards (close the remote
  connection, or `wsl --shutdown`); a window reload is not enough.

  ```sh
  export CLAUDE_CONFIG_DIR=/home/you/projects/bubbleclaude/claude-home/.claude
  ```

- Local Linux: export it where VS Code is launched from (`~/.profile`, or
  `code .` from a shell that has it).

Side effect: a host `claude` run from VS Code's integrated terminal then uses
`claude-home/.claude` too, unsandboxed.

From there it behaves as in a terminal: sign in from the panel once, the
directory refusals and the dev-mode warning apply. The script's own output goes
to **Claude Code: View output logs**, not a terminal; a refused workspace shows up
there as the process exiting at startup.

Two details of the plumbing:

- `bclaude.sh` refreshes `claude-home/.claude/settings.json` from your
  `~/.claude/settings.json` at every launch (`{}` when you have none) so the
  extension host reads the same preferences as the sandbox. Inside, the read-only
  bind still wins. The file is rewritten in place and only when its content
  changed: a fresh inode would detach the bind in sessions already running, and
  the extension never catches it half-written.
- Only the host variables named in the script's `ENV_ALLOW` list cross into the
  sandbox: what the extension sets per launch, plus harmless knobs (token and
  timeout limits, telemetry and UI switches). It is a positive list because VS
  Code or a parent session can set anything, so every name on it has to stay
  harmless under a hostile value, a degraded session at worst. Everything else is
  dropped,
  `ANTHROPIC_*` and credentials included, and `CLAUDE_CONFIG_DIR` is rewritten to
  the sandbox's `~/.claude`. Static preferences go in the `env` block of
  `~/.claude/settings.json` instead. Check with `CLAUDE_BIN=/usr/bin/env bclaude`.

### Working on bubbleclaude itself

Launching from inside this repo is allowed. The repo is then the project, hence
writable, and the sandbox no longer protects itself: a session can edit the
mount layout or widen `sandbox.network.allowedDomains` in `managed-settings.json`,
and the change applies to every later sandbox. The script prints an uppercase
warning and continues. Read every diff before you relaunch.

`claude-home/` is re-bound read-only on top of the writable repo even here, so a
session cannot plant state that auto-loads into later runs. It stays writable at
`$HOME`, where it belongs.

Launching from a directory that merely contains the repo (`~/projects`, with the
repo at `~/projects/bubbleclaude`) is safe: the repo is remounted read-only
inside the writable project.

### Tests

What CI runs, reproducible locally with the same two commands. Needs
[bats](https://github.com/bats-core/bats-core), `shellcheck`, `jq`, `bwrap` and
unprivileged user namespaces.

```sh
tests/lint.sh                        # bash -n, shellcheck, jq on every script and JSON file
BCLAUDE_TEST_NO_SYSTEMD=1 bats tests # policy invariants, refusals, the mount layout
```

The layout files launch `bclaude.sh` for real with `CLAUDE_BIN=/bin/bash` and
the updater disabled, against throwaway homes and projects, once per scenario
in `setup_file`, and check what the sections above promise: remapped home,
absent secrets, cleared environment, read-only masks, refused directories.
Omit the variable where a systemd user session exists and `systemd-run` runs
for real; the CI runners have none, so it swaps in a passthrough shim and the
resource limits go untested.

What it protects against
------------------------

- Reading or exfiltrating anything outside the launch directory: `~/.ssh`,
  `~/.aws`, browser profiles, your other repos.
- Environment leaks: `--clearenv`, so `SSH_AUTH_SOCK`, `GITHUB_TOKEN`, `AWS_*`,
  `DISPLAY` never get in.
- Claude rewriting its own settings: `managed-settings.json` is bound read-only
  at `/etc/claude-code/managed-settings.json`, the top of the precedence, so
  neither your `~/.claude/settings.json` nor a project `.claude/settings.json`
  can override it. Your own `settings.json` and `CLAUDE.md` are bound read-only
  too, as a permissions and prompt-injection persistence channel otherwise. If
  the repo sits inside the project it is remounted read-only.
- Git hooks planted for the host: the project's `.git` is re-bound read-only
  over the project, since `git commit` on the host runs `.git/hooks`, whatever
  `core.hooksPath`, `core.fsmonitor` or `core.pager` point at in `.git/config`,
  and the same under `.git/modules/*` for submodules, all unsandboxed. Inside,
  git reads fine and every write (`add`, `commit`, `stash`, `checkout -b`,
  `remote add`...) fails loudly. Only the top-level repository; see
  "Constraints and limits".
- Cross-session persistence in the sandbox home: `~/.claude/agents`, `commands`,
  `hooks`, `skills`, `plugins`, `rules`, `output-styles`, `workflows` and
  `themes` are 1 MiB tmpfs (nothing legitimate writes there, so a planted file
  fails instead of silently vanishing at exit), and `settings.local.json` and
  the shell rc files are shadowed by an empty read-only file. A deny-list, so a
  name Claude Code starts auto-loading in a future release is open until added
  here. The project directory and auto memory are not covered, see "Constraints
  and limits".
- Runaway resources: a systemd scope with `MemoryMax=8G` and `TasksMax=1024`,
  and `/tmp` and `/var/tmp` as tmpfs capped at 2 GiB each. CPU is weighted
  (`CPUWeight=25`: full speed when idle, yields to your other work under
  contention) but not capped; disk is neither.
- Defence in depth: Claude Code's inner sandbox with `failIfUnavailable: true`
  and a strict network allowlist. `strictAllowlist` denies unlisted domains with
  no prompt, `allowManagedDomainsOnly` ignores domains added from project
  settings, and `allowManagedHooksOnly` / `disableSideloadFlags` block hooks and
  sideloaded plugins or agents from any scope a session can write to.

Layout
------

| Path                                | Role                                                                         |
|-------------------------------------|------------------------------------------------------------------------------|
| `bclaude.sh`                        | The whole tool: resolves `claude` on the host, updates it, `exec bwrap`      |
| `bclaude-vscode.sh`                 | VS Code entry point: argv[1] becomes `CLAUDE_BIN`, no update, rest passes on |
| `claude-home/`                      | Bound over `$HOME`; the only persistent state (OAuth, prefs, history)        |
| `claude-home/.claude/settings.json` | Copy of `~/.claude/settings.json`, `{}` if absent, for the VS Code extension |
| `managed-settings.json`             | Policy only, bound read-only as top-precedence managed settings              |
| `examples/settings.json`            | Example preferences for `~/.claude/settings.json`; never bound               |
| `examples/CLAUDE.md`                | Example global instructions for `~/.claude/CLAUDE.md`; never bound           |

Also bound read-only from your real home: `~/.claude/settings.json` and
`~/.claude/CLAUDE.md` (your preferences and global instructions, the same as
outside the sandbox; absent files are shadowed by an empty one so a session
cannot create them; `~/.claude/settings.local.json` is never bound and always
shadowed), `~/.gitconfig`, `~/.local/bin`, `~/.local/share/claude` and
`~/.nvm` (so a host `claude` and its runtime resolve; not all of `~/.local`,
which holds keyrings and app data), plus the `claude` binary in use.

Network: edit `managed-settings.json` on the host. The list is strict, so
`npm install` or `pip install` against an unlisted registry fails until you add
it and relaunch. Preference keys do not belong there: anything in the managed
file silently overrides the same key in your `~/.claude/settings.json`.

Constraints and limits
----------------------

- **Network isolation comes from the inner sandbox, not bwrap.** `bclaude.sh`
  re-shares the host network namespace, and with it abstract-namespace Unix
  sockets; under X11 that includes the X server, which means keylogging reach.
  The inner sandbox closes it: each command gets a private netns with loopback
  only and `AF_UNIX` refused. Disable the inner sandbox and the vector is back.
  Wayland's socket is a file in `XDG_RUNTIME_DIR`, which is not bound; check
  with `echo $XDG_SESSION_TYPE`.
- **No SSH agent.** `SSH_AUTH_SOCK` is not passed; use HTTPS remotes (github.com
  is allowlisted). Nothing authenticates you anyway: commit and push from the
  host.
- **One writable directory, one project per session.** Anything Claude must read
  lives under the launch directory or a bound path. Two projects, two sandboxes.
- **Project memory files are writable.** `CLAUDE.md`, `CLAUDE.local.md`,
  `AGENTS.md` and `.claude/` auto-load into later sessions of that project and
  nothing masks them, so a prompt-injected session can leave instructions for
  the next. Deliberate: masking them would stop Claude keeping project notes.
  The same goes for auto memory under `~/.claude/projects/<project>/memory/`,
  which is per project and writable by design. Read those diffs, don't skim
  them.
- **What you run on the host runs sandbox-written files.** The sandbox ends at
  the project mount: a `Makefile`, `package.json` scripts, `.vscode/tasks.json`,
  a `.envrc`, a nested repository's `.git` are all writable inside and execute
  with your privileges the moment you invoke them outside. Only the top-level
  `.git` is pinned read-only, because git runs hooks and config from it
  implicitly. Inside, that also means anything that writes git state (`add`,
  `commit`, `stash`, branches, `remote add`, `config`) fails on the top-level
  repo: do that from the host. Review the rest before you build, test or
  `direnv allow` on the host.
- **File-writing tools may not be confined by the mounts.** The Write tool
  created its temp file inside `~/.claude/` before the rename failed on the
  read-only bind. Names under `~/.claude` that are neither bound, shadowed nor
  tmpfs-masked (`keybindings.json`, `projects/`...) may be writable through
  those tools and persist. Observed, endpoint not tested; see the audit.
- **The session token is readable inside.** `~/.claude/.credentials.json` and
  `~/.claude.json` are readable by any command, and the allowlist includes hosts
  that accept data. The token is scoped to the sandbox session, not your host
  account; treat it as compromised if the session is.
- **The VS Code bridge lives on the host.** The extension's IDE server runs in
  the unsandboxed extension host; the CLI reaches it through a localhost port and
  token read from `claude-home/.claude/ide/`. The model sees two of its tools,
  diagnostics and Jupyter cell execution (which always asks first); the rest is
  RPC the CLI drives for its own UI, diffs and selections included. Still a
  channel into the editor that bwrap does not cover.
- **Workspace extension settings are writable by the session.** The wrapper
  setting is machine-scoped, but other `claudeCode.*` keys planted in
  `.vscode/settings.json` take effect on the next launch. The environment filter
  in `bclaude.sh` bounds that. Read `.vscode/` diffs like memory files.
- **Mount points materialise in `claude-home/`.** A project under your real home
  leaves its empty directory chain in the sandbox home (`~/work/myproject` →
  `claude-home/work/myproject`); the VS Code binary bind leaves one per extension
  version under `claude-home/.vscode-server/`. Harmless, shadowed at runtime.
  Neither is on `PATH`: the binary's directory is added only under `~/.nvm`
  (read-only, and `node` must be found beside it), and `~/.local/bin` only
  when bound from your real home.
- **`--new-session` drops the controlling terminal** (TIOCSTI defence); the
  process reports "not a tty". If it ever breaks the TUI, revisit that flag.
- **Minimal `/etc`.** DNS, TLS certificates, passwd/group, timezone, the
  alternatives links and the `ld.so` cache only. Anything else a tool reads
  from `/etc` is absent: Debian's OpenJDK, for one, expects `/etc/java-*`.
- **This repo is read-only inside** unless it is the project itself (see
  "Working on bubbleclaude itself"). Your global `CLAUDE.md` and `settings.json`
  are edited from outside. `claude-home/` is read-only from the project side in
  every configuration.
- **Fixed limits, with gaps.** 8 GiB memory, 1024 tasks, 2 GiB `/tmp` and
  `/var/tmp`; raise them in the script if needed. No CPU or disk quota: a
  runaway session can still pin every core on an idle host (`CPUWeight=25`
  only makes it lose to your foreground work) and fill the filesystem. The caps
  cannot be checked from inside (no cgroupfs); use `systemctl --user show` on
  the scope. The hostname inside is `bubbleclaude`.
- **Same user, same kernel.** A namespace sandbox, not a VM: kernel exploits are
  out of scope.

Security audit
--------------

Audited from inside a live session on 2026-08-16, eleven boundaries probed with
non-destructive checks: [`pentest-prompt.md`](pentest-prompt.md) drove it,
[`pentest-report.md`](pentest-report.md) records evidence, classification and
severity per boundary.

Nine boundaries came out contained. The one violation is partial: the project
memory files above. That, the unconfined file-writing tools, the readable token
and the missing CPU and disk quotas are listed under "Constraints and limits";
the proposed fixes were reviewed and declined, with each trade-off recorded in
the report. The audit also corrected this README on two points: the network
namespace is private in practice, and egress is blocked by an empty routing table
before the proxy allowlist applies, so there is no IP-literal or raw-socket
bypass.
