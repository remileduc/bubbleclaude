Examples
========

Nothing in this directory is used by `bclaude.sh`. These files show what your
own `~/.claude/` can hold; the script binds your real files from there,
read-only, into the sandbox.

| File            | Copy to                   | What it is                                |
|-----------------|---------------------------|-------------------------------------------|
| `settings.json` | `~/.claude/settings.json` | Preferences: model, effort, theme, TUI    |
| `CLAUDE.md`     | `~/.claude/CLAUDE.md`     | Global instructions, loaded every session |

Copy whichever you want, then edit to taste. A missing file is fine: the sandbox
shadows the path with an empty one so a session cannot create it.

Why two settings files
----------------------

Claude Code reads settings in layers, and the managed layer wins over all the
others. bubbleclaude uses that split on purpose:

- `../managed-settings.json` is policy: the inner sandbox, the network
  allowlist, the managed-only switches. It is bound at the managed layer so no
  user or project file can override it. Keep preference keys out of it, or they
  silently override the same key in your own file.
- `~/.claude/settings.json` is yours: everything that is a matter of taste and
  the same as you would use outside the sandbox.

Both are read-only inside the sandbox. Edit them on the host and relaunch.
