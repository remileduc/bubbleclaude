bubbleclaude
============

Run [Claude Code](https://claude.com/claude-code) inside a [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`) sandbox. Nothing exists inside unless `bclaude.sh` binds it in: your
home, keys, credentials and environment are absent, not denied. The only
writable location is the directory you launch from.

- [Requirements](#requirements)
- [Usage](#usage)
- [VS Code (Linux and WSL)](#vs-code-linux-and-wsl)
- [How it works](#how-it-works)
- [Known gaps](#known-gaps)
- [Tests and audit](#tests-and-audit)

Requirements
------------

- Linux with `bwrap` (`apt install bubblewrap`) and a systemd user session (for
  the resource limits), systemd 254 or later for `--expand-environment=no`.
- A usr-merged layout (`/bin`, `/lib`... symlinked into `/usr`), standard on
  current Debian and derivatives.
- Claude Code on the host, on `PATH` under a bound path: `/usr/...`,
  `~/.local/bin` or `~/.nvm`. Not needed for VS Code, whose extension brings its
  own binary.

Usage
-----

```sh
ln -s ~/projects/bubbleclaude/bclaude.sh ~/.local/bin/bclaude   # once
cd ~/work/myproject && bclaude [claude args...]
```

The launch directory is the project: bound writable at its real path, the only
writable place inside, one project per session. Arguments go straight to
`claude`. Two overrides:

```sh
SANDBOX_HOME=/path/home bclaude     # fake home (default: <repo>/claude-home)
CLAUDE_BIN=/path/to/claude bclaude  # this binary instead of the one on PATH
```

Refused as launch directory: `/`, your home or a parent of it, the sandbox home
or anything under it, and anything holding your real `~/.claude` (symlinks
resolved). Bound as the project, they would hand the session your real files or
its own state.

`claude update` runs on the host before each launch, the sandbox being
read-only where the updater writes. `DISABLE_AUTOUPDATER=1` skips it.

**First launch.** The sandbox home starts empty: log in and answer the
onboarding again. The result lives in `claude-home/` and persists (OAuth
session, preferences, per-project trust, history).

**Working on bubbleclaude itself.** Launching from this repo is allowed, but
the repo is then writable: a session can change the mount layout or widen the
network allowlist for every later run. The script prints an uppercase warning;
read every diff before you relaunch. `claude-home/` stays read-only from the
project side even then. Launching from a parent of the repo is safe: the repo
is remounted read-only.

VS Code (Linux and WSL)
-----------------------

The [extension](https://code.claude.com/docs/en/vs-code) runs on the Linux side
and starts its bundled `claude` with the workspace folder as working directory.
Point it at `bclaude-vscode.sh`, which passes that binary as `CLAUDE_BIN`,
disables the updater and calls `bclaude.sh`. Two host-side settings, full
paths, no `~`:

**1. `claudeCode.claudeProcessWrapper`**, in machine scope so a project's
`.vscode/settings.json` cannot repoint it. WSL or any remote: **Preferences:
Open Remote Settings** (`~/.vscode-server/data/Machine/settings.json`). Local
Linux: `~/.config/Code/User/settings.json`.

```json
{
  "claudeCode.claudeProcessWrapper": "/home/you/projects/bubbleclaude/bclaude-vscode.sh",
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "/home/you/projects/bubbleclaude/claude-home/.claude" }
  ]
}
```

**2. `CLAUDE_CONFIG_DIR` in the extension host's environment.** The extension
runs outside the sandbox and reads Claude's config directory on the host
(sessions, settings, credentials, the IDE server's lock file). It must read
`claude-home/.claude`, which is `~/.claude` inside. The `environmentVariables`
entry above is not enough on its own: tested, the extension host kept reading
the real `~/.claude`.

- WSL: `~/.vscode-server/server-env-setup`, the one file the VS Code server
  sources. Plain Bourne shell: a syntax error stops the server from starting,
  and the fix is to delete the file from a WSL shell. Then restart the server
  (close the remote connection, or `wsl --shutdown`); a window reload is not
  enough.

  ```sh
  export CLAUDE_CONFIG_DIR=/home/you/projects/bubbleclaude/claude-home/.claude
  ```

- Local Linux: export it where VS Code is launched from (`~/.profile`, or
  `code .` from a shell that has it).

Side effect: a host `claude` run from VS Code's integrated terminal then uses
`claude-home/.claude` too, unsandboxed.

From there it behaves as in a terminal: sign in once from the panel, refusals
and the dev-mode warning apply. The script's output goes to **Claude Code: View
output logs**; a refused workspace shows there as the process exiting at
startup.

Two details. `bclaude.sh` copies your `~/.claude/settings.json` to
`claude-home/.claude/settings.json` at each launch (`{}` when you have none),
so the extension host sees the same preferences as the sandbox. And only the
host variables named in the script's `ENV_ALLOW` list cross into the sandbox,
each harmless under a hostile value: never `ANTHROPIC_*` or credentials, and
`CLAUDE_CONFIG_DIR` is rewritten to the sandbox's `~/.claude`. Static
preferences go in the `env` block of `~/.claude/settings.json`. Check with
`CLAUDE_BIN=/usr/bin/env bclaude`.

**Turn off automatic port forwarding.** The inner sandbox routes its network
allowlist through a proxy on a random `127.0.0.1` port, one per session, on
the host side of bwrap. VS Code treats it as an application port. In `process`
mode it forwards every one of them, and a port still open when the window
closes is restored at the next open and never released. After twenty, VS Code
switches itself to `hybrid`, which instead forwards any `localhost:port`
printed in a terminal, including by Claude. Set this in the **user** settings
of the VS Code client (the Windows side under WSL), then clear the leftovers
once from the Ports view (select all, **Stop Forwarding Port**):

```json
{ "remote.autoForwardPorts": false }
```

Manual forwarding and clicking a link in the terminal still forward on demand.
Under WSL nothing is lost: `wslrelay.exe` already mirrors every WSL listener,
the proxy included, onto Windows loopback, so the proxy is reachable by any
process on the Windows machine for as long as the session runs.

How it works
------------

| Path                    | Role                                                            |
|-------------------------|-----------------------------------------------------------------|
| `bclaude.sh`            | The whole tool: resolves `claude`, updates it, `exec bwrap`     |
| `bclaude-vscode.sh`     | VS Code entry point: argv[1] becomes `CLAUDE_BIN`, no update    |
| `claude-home/`          | Bound over `$HOME`; the only persistent state                   |
| `managed-settings.json` | Policy only, bound read-only as top-precedence managed settings |
| `examples/`             | Hints for your own `~/.claude/settings.json` and `CLAUDE.md`    |

Inside the sandbox:

- **Writable:** the project, `claude-home/` at `$HOME`, and `/tmp` and
  `/var/tmp` as 2 GiB tmpfs.
- **Read-only from your real home:** `~/.claude/settings.json` and `CLAUDE.md`
  (the same preferences and instructions as outside; shadowed by an empty file
  when absent, so a session cannot create them), `~/.gitconfig`, `~/.local/bin`,
  `~/.local/share/claude`, `~/.nvm` and the `claude` binary. Not the rest of
  `~/.local`, which holds keyrings and app data.
- **Read-only system:** `/usr` and a minimal `/etc` (DNS, TLS certificates,
  passwd/group, timezone, alternatives, `ld.so` cache). Anything else a tool
  expects under `/etc` is absent; Debian's OpenJDK, for one, wants
  `/etc/java-*`.
- **Environment cleared** (`--clearenv`): no `SSH_AUTH_SOCK`, `GITHUB_TOKEN`,
  `AWS_*`, `DISPLAY`.
- **Policy:** `managed-settings.json` is the top of the precedence chain, so
  neither your `settings.json` nor a project `.claude/settings.json` can
  override it. It turns on Claude Code's inner sandbox (`failIfUnavailable`,
  no unsandboxed commands) and a strict network allowlist: unlisted domains
  denied without a prompt, domains from project settings ignored, hooks and
  sideloaded plugins or agents blocked from any scope a session can write to.
  Edit the allowlist on the host and relaunch; `npm install` against an
  unlisted registry fails until then. Preference keys do not belong in that
  file: a managed key silently overrides the same key in your `settings.json`.
- **Anti-persistence in the sandbox home:** `~/.claude/agents`, `commands`,
  `hooks`, `skills`, `plugins`, `rules`, `output-styles`, `workflows` and
  `themes` are 1 MiB tmpfs; `settings.local.json` and the shell rc files are
  shadowed read-only. A deny-list: a name Claude Code starts auto-loading in a
  future release is open until added here.
- **The project's top-level `.git` is read-only:** `git` on the host runs
  hooks, `core.hooksPath`, `core.fsmonitor`, `core.pager` and submodule hooks
  unsandboxed. Inside, git reads fine and every write (`add`, `commit`,
  `stash`, branches, `remote add`) fails loudly: do that from the host.
- **Resources:** a systemd scope with `MemoryMax=8G`, `TasksMax=1024` and
  `CPUWeight=25`. Raise them in the script if needed. The scope is started
  with `--expand-environment=no`: since systemd 258 `systemd-run` otherwise
  fills `${VAR}` in its arguments, a prompt or a path, from the host
  environment before `--clearenv` runs.

Known gaps
----------

- **Project memory files are writable.** `CLAUDE.md`, `CLAUDE.local.md`,
  `AGENTS.md`, `.claude/` and auto memory under
  `~/.claude/projects/<project>/memory/` auto-load into later sessions of that
  project, so a prompt-injected session can leave instructions for the next.
  Deliberate: masking them would stop Claude keeping project notes. Read those
  diffs, don't skim them.
- **Write and Edit are not confined by the mounts.** Bash runs in the inner
  sandbox, where all of `$HOME` is read-only; Write and Edit run in the CLI
  process, where `claude-home/` is writable. Names under `~/.claude` that are
  neither bound, shadowed nor masked (`routines/`, `keybindings.json`...)
  persist into every later session, confirmed in the audit. Nothing there is
  executable or on `PATH`. After a suspicious session, check from the host:
  `find claude-home -newer claude-home/README.md -not -path '*/.claude/*'`.
- **The session token is readable inside.** `~/.claude/.credentials.json` and
  `~/.claude.json`, by any command, and the allowlist includes hosts that
  accept uploads. It is the sandbox's token, not your host account's; treat it
  as compromised if the session is.
- **What you run on the host runs sandbox-written files.** A `Makefile`,
  `package.json` scripts, `.vscode/tasks.json`, a `.envrc` execute with your
  privileges the moment you invoke them outside. A nested repository's `.git`
  is writable except `config` and a non-empty `hooks/`, pinned by the inner
  sandbox (which also makes the clone undeletable from inside; `rm` it from
  the host). Review before you build, test or `direnv allow`.
- **VS Code: the bridge and workspace settings live on the host.** The IDE
  server runs in the unsandboxed extension host; the CLI reaches it through a
  localhost port and token in `claude-home/.claude/ide/`, for diagnostics,
  Jupyter cell execution (always asks first), diffs and selections. And
  `claudeCode.*` keys planted in `.vscode/settings.json` take effect on the
  next launch, bounded by the environment filter. Read `.vscode/` diffs like
  memory files.
- **Network isolation comes from the inner sandbox, not bwrap.** `bclaude.sh`
  re-shares the host network namespace, and with it abstract Unix sockets:
  under X11, the X server (keylogging reach). The inner sandbox gives each
  command a private netns with `AF_UNIX` refused; disable it and the vector is
  back. Wayland's socket is a file that is not bound.
- **No CPU or disk quota.** A runaway session can pin every idle core
  (`CPUWeight` only makes it lose to your foreground work) and fill the
  filesystem. The memory and task caps cannot be checked from inside; use
  `systemctl --user show` on the scope.
- **No SSH agent.** Use HTTPS remotes. Nothing authenticates you anyway: push
  from the host.
- **Mount points materialise in `claude-home/`.** A project under your home
  leaves its empty directory chain there; the VS Code binary leaves one under
  `claude-home/.vscode-server/`, pruned of removed versions at launch.
  Harmless, shadowed at runtime, not on `PATH`.
- **Same user, same kernel.** A namespace sandbox, not a VM: kernel exploits
  are out of scope.

Tests and audit
---------------

```sh
tests/lint.sh                        # bash -n, shellcheck, jq
BCLAUDE_TEST_NO_SYSTEMD=1 bats tests # policy invariants, refusals, mount layout
```

What CI runs. Needs [bats](https://github.com/bats-core/bats-core),
`shellcheck`, `jq`, `bwrap` and unprivileged user namespaces. The layout tests
launch `bclaude.sh` for real against throwaway homes and projects and check
what this file promises. Omit the variable where a systemd user session
exists; with it, `systemd-run` is shimmed and the resource limits go untested.

Audited from inside live sessions on 2026-08-16 and 2026-10-16: eleven
boundaries driven by [`pentest-prompt.md`](pentest-prompt.md), evidence in
[`pentest-report.md`](pentest-report.md). Ten boundaries contained, resource
limits mixed, one partial violation: persistence, through the writable tools
and project memory files above. The proposed fixes were reviewed and declined,
each trade-off recorded in the report.
