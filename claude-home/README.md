claude-home/
============

The sandbox's **fake home directory**: `bclaude.sh` bind-mounts this folder over
`$HOME` inside the bubblewrap namespace, so Claude Code never sees your real home.

This is the only state that persists across sessions:

| What           | Why it matters                                |
|----------------|-----------------------------------------------|
| `.claude.json` | OAuth session, preferences, per-project trust |
| `.claude/`     | History, credentials, todos, session data     |

Because of this, the **first launch behaves like a fresh install** — you log in
and answer the onboarding questions once, and they are saved here for every
later run.

Everything in this directory is **gitignored except this README**: the folder must
exist in the repo to serve as a mount point, but its contents are personal secrets
(OAuth tokens!) and must never be committed.

Note that some paths inside are overridden by the script at launch:
`.claude/settings.json` and `.claude/CLAUDE.md` are bound read-only from
`../claude-settings/`, and `.claude/{agents,commands,hooks,skills,plugins}` are
masked with throwaway tmpfs so a session cannot plant anything that auto-loads
into future sessions.

From the *project* side this folder is always read-only, including when you
launch a session from inside the bubbleclaude repo to work on the tool itself:
it is re-bound read-only over the writable project so a session cannot plant
state that auto-loads into every later run. Launching from inside it is refused
outright.

You will also see empty directory trees appear here that mirror your projects
(`work/myproject/`...). Those are mount points bwrap has to create when the launch
directory lives under your real home; they are shadowed by the real bind at
runtime and are safe to delete.

Wipe this folder to factory-reset the sandboxed Claude (you will have to log in
again).
