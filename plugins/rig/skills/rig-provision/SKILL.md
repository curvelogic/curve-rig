---
name: rig-provision
description: Check whether this cloud session is provisioned (toolchain, bd, beads store) and provision it by hand if not. Use at the start of work in a cloud session when a repo's tools or `bd ready` are missing, or when told the SessionStart hook did not run.
---

# Provisioning a session by hand

Normally a user-level SessionStart hook provisions every repository in a
cloud session. When it has not run — the environment lacks rig's setup
script, or the hook failed — do it by hand.

## Check

From each repository you will work in:

```bash
command -v bd >/dev/null && bd dolt remote list 2>/dev/null | grep -q origin \
    && echo provisioned || echo "not provisioned"
```

A store without a Dolt remote was hydrated from a stale export and is **not**
the tracker, even if `bd list` answers.

## Provision

If rig is installed (`$RIG_HOME`, default `~/.local/share/curve-rig`):

```bash
RIG_FORCE=1 "${RIG_HOME:-$HOME/.local/share/curve-rig}/hooks/session-start.sh"
```

Otherwise clone it first (needs the repository attached to the session while
it is private):

```bash
git clone --depth 1 https://github.com/curvelogic/curve-rig "$HOME/.local/share/curve-rig"
"$HOME/.local/share/curve-rig/bin/rig-install"
RIG_FORCE=1 "$HOME/.local/share/curve-rig/hooks/session-start.sh"
```

## Never

- Seed a beads store from `.beads/issues.jsonl`.
- Run `bd dolt push` from a web session: it cannot work, and other `bd`
  writes are lost with the container unless relayed.
