---
name: rig-relay
description: Save this cloud session's beads changes (bd create, update, close, new comments, labels and dependencies, remember) so they reach the tracker. Use before ending any cloud session that ran a bd write, or when asked to relay, sync or push beads from a web session.
---

# Relaying beads changes from a cloud session

A cloud session cannot push `refs/dolt/data`. `bd dolt push` fails there, and
every other `bd` write reports success, lands in the local store and is lost
with the container. The relay carries the writes instead: you stage them as a
file, `rig-relay` pushes it alone on a `beads-inbox/…` branch, and the
member's `beads relay` workflow applies it and pushes the store. Nothing goes
through a PR.

Locally, none of this applies: use `bd dolt push`.

## Stage, once, as the session's last beads act

After the session's final `bd` write, from inside the member repository:

```bash
rig-relay stage <short-label>
```

(If `rig-relay` is not on PATH:
`"${RIG_HOME:-$HOME/.local/share/curve-rig}/bin/rig-relay" stage <label>`.)

It writes `.beads/inbox/<time>-<label>.jsonl`, commits only that file on a
new branch `beads-inbox/<time>-<label>` based on the default branch, pushes
it and removes the file. Your own branch, index and working tree are not
touched. Expect `Pushed beads-inbox/…`; the relay applies it within minutes.

- **Never commit inbox files** in your own branches or PRs. If `stage`
  could not push, it keeps the file and says so: retry with
  `rig-relay push .beads/inbox/<file>`, and never `git add` it.
- Stage **once**, after the last write. A staged file is a point-in-time
  export: writes after it are not in it. Staging again pushes a second
  branch with the latest values; that is harmless, but if anyone changes
  those issues in between, the older one is refused.
- "No beads changes to relay" means the store matches the tracker; nothing to
  push.
- It refuses a store with no `origin` Dolt remote: that store was not
  bootstrapped from the tracker, so its rows are not the tracker's. Use the
  `rig-provision` skill to bootstrap it, then redo the writes.
- Do not push `beads-inbox/…` branches by hand: the relay rejects anything
  but exactly one well-named delta.

## Limits

- Only additions and updates are carried. Removed labels and dependencies,
  removed or edited comments, deleted issues and forgotten memories are
  not: `stage` names each one. Tell the user which, so they can be made
  from a session that can push the store.
- Memories are applied without a staleness check: the latest relay wins.
- If the repository has no `beads relay` workflows, inbox branches sit
  unapplied. Tell the user rather than leaving it silent.
- If the relay refuses or rejects your branch (its run fails naming it),
  the writes did not land. Tell the user: the fix is to redo the writes in
  a fresh session and stage again, and the owner deletes the old branch.

## Never

- Edit or hand-write files in `.beads/inbox/`, or commit them.
- `bd import` in a session, or seed a store from `.beads/issues.jsonl`.
- `bd dolt pull` after your own delta is relayed: the store holds its own
  commits for those rows and the pull conflicts. Re-bootstrap, or let the
  container go.
