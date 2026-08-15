projects/
=========

A **placeholder mount point**. At launch, `bclaude.sh` bind-mounts your real
projects directory (`PROJECT_DIR`, default `~/projects`) over this path inside
the sandbox — the **only genuinely writable location** Claude Code gets.

This folder itself is meant to stay empty: whatever you put here is shadowed by
the mount and invisible inside the sandbox. It exists in the repo (gitignored
except this README) only so the bind has a target when `PROJECT_DIR` defaults
elsewhere.

To work on a different tree:

```sh
PROJECT_DIR=~/work ./bclaude.sh
```

Remember the trust boundary: anything under `PROJECT_DIR` is readable *and
writable* by the agent — don't point it at a directory containing secrets.
