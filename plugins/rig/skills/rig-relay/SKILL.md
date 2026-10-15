---
name: rig-relay
description: Save this cloud session's beads changes (bd create, update, close, comments, labels, dependencies, remember) so they reach the tracker. Use before ending any cloud session that ran a bd write, or when asked to relay, sync or push beads from a web session.
---

# Relaying beads changes from a cloud session

A cloud session cannot push `refs/dolt/data`. `bd dolt push` fails there, and
every other `bd` write reports success, lands in the local store and is lost
with the container. The relay carries the writes instead: you stage them as a
file in the repository, it reaches the default branch through an ordinary PR,
and the member's `beads relay` workflow applies it and pushes the store.

Locally, none of this applies: use `bd dolt push`.

## Stage, once, as the session's last beads act

After the session's final `bd` write, from inside the member repository:

```bash
rig-relay stage <short-label>
git add .beads/inbox && git commit -m "beads: relay session changes"
```

(If `rig-relay` is not on PATH:
`"${RIG_HOME:-$HOME/.local/share/curve-rig}/bin/rig-relay" stage <label>`.)

Then push and open a PR as usual — on its own, or as the last commit of the
session's final PR. On merge the workflow applies it.

- Stage **once**, after the last write. A staged file is a point-in-time
  export: writes after it are not in it, and a second file touching the same
  issues is refused by the next one's staleness check.
- "No beads changes to relay" means the store matches the tracker; nothing to
  commit.
- It refuses a store with no `origin` Dolt remote: that store was not
  bootstrapped from the tracker, so its rows are not the tracker's. Use the
  `rig-provision` skill to bootstrap it, then redo the writes.

## Limits

- Deleted issues and forgotten memories are not carried; the command warns.
- Memories are applied without a staleness check: the latest relay wins.
- If the repository has no `beads relay` workflow, staged files sit in the
  inbox unapplied. Tell the user rather than leaving it silent.

## After merging main into a long-lived branch

Merging can resurrect a staged file the relay has already applied and
cleared. Before staging again, reset the inbox to the default branch's state
(`git checkout <ref> -- <dir>` is not enough: it keeps files the ref lacks):

```bash
git fetch origin main
git restore --source=origin/main --staged --worktree -- .beads/inbox
```

(Use the repository's default branch if it is not `main`.)

## Never

- Edit or hand-write files in `.beads/inbox/`.
- `bd import` in a session, or seed a store from `.beads/issues.jsonl`.
- `bd dolt pull` after your own delta is relayed: the store holds its own
  commits for those rows and the pull conflicts. Re-bootstrap, or let the
  container go.
