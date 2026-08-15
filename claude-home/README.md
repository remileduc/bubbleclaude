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
`.claude/settings.json` is bound read-only from `../claude-settings/`, and
`.claude/{agents,commands,hooks,skills}` are masked with throwaway tmpfs so a
session cannot plant anything that auto-loads into future sessions.

Wipe this folder to factory-reset the sandboxed Claude (you will have to log in
again).
