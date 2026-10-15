# The beads relay

How a cloud session's beads writes reach the tracker. Use the `rig-relay`
skill in a session; this page is for adopting and changing the relay.

## Why it is needed

Beads keeps its issues in a Dolt database and shares it through the
repository's own git remote, on the ref `refs/dolt/data` — not on a branch.
Reading the tracker means fetching that ref (`bd bootstrap`); writing it
means pushing that ref (`bd dolt push`).

A cloud session cannot push that ref. Its git access goes through a relay
that forwards only branch creates and fast-forwards under `refs/heads/*`.
Measured from a session against a member repository:

| Push                              | Result |
|-----------------------------------|--------|
| a branch, created or fast-forward | ok     |
| a branch deletion                 | 403    |
| a tag                             | 403    |
| `refs/notes/*`                    | 403    |
| `refs/dolt/data`, any other ref   | 403    |

Tags and deletions failing too shows this is the relay's rule, not a
repository permission: no grant to the session changes it.

What makes this dangerous rather than merely inconvenient is that bd does
not fail. `bd create`, `bd update`, `bd close`, `bd comments add` and
`bd remember` all report success: they write the local store and stop
there. The container is reclaimed when the session ends, and the writes go
with it. A session that claims an issue, records a design and closes it has
changed nothing, and nobody is told.

Two easier-looking fixes do not work:

- **Commit `.beads/issues.jsonl`** and let readers import it. The export is
  a snapshot; a store hydrated from it looks healthy and is silently stale,
  and two sessions' exports overwrite each other. rig never seeds a store
  from it.
- **Push from the session another way.** Every route out of the session to
  `github.com` goes through the same relay.

CI can do what the session cannot: an Actions `GITHUB_TOKEN` with
`contents: write` pushes any ref. So the relay moves the *write* from the
session to CI, and uses the one thing a session can push — a branch — to
carry it there.

## How it works

```
session                     git                       CI (member's workflow)
-------                     ---                       ----------------------
bd create / update / …
rig-relay stage        →    .beads/inbox/<t>-<l>.jsonl
                            branch → PR → review → default branch
                                                  →   rig-relay bootstrap
                                                      rig-relay apply:
                                                        staleness gate
                                                        bd import
                                                        bd dolt push
                                                      clear applied deltas
```

1. **The session works normally.** Its `bd` writes land in the local store,
   which was bootstrapped from `refs/dolt/data` when the session started.
2. **It stages once, at the end.** `rig-relay stage <label>` works out
   which issues and memories the session changed, exports exactly those
   records from bd, and writes them to `.beads/inbox/<time>-<label>.jsonl`
   (see *Staging*).
3. **The file travels as code.** The session commits it on its branch and
   opens a PR, alone or with the session's other changes. The PR is
   reviewed like any other: a beads write reaches the tracker only when a
   reviewer would let the same change reach the default branch.
4. **The merge triggers the member's workflow.** It calls rig's reusable
   workflow, which runs only on the default branch. That checks out the
   member and rig (at a pinned commit), installs rig's pinned bd and dolt,
   and bootstraps a fresh store from `refs/dolt/data`.
5. **It applies the inbox.** The staleness gate refuses the run if the
   tracker has changed any staged issue since it was staged (see
   *Applying*); otherwise each file is imported, in time order, and the
   store is pushed back to `refs/dolt/data`.
6. **It clears what it applied.** It removes the applied files from the
   default branch in one commit, so the inbox holds only what is still
   waiting.

The next session to start bootstraps from the updated ref and sees the
changes.

## Parts

- `bin/rig-relay` with `lib/relay.sh`. `stage` runs in the session; it is
  linked into `~/.local/bin` by `bin/rig-install`. `bootstrap` and `apply`
  run in CI and refuse to run elsewhere unless `RIG_RELAY_ALLOW_CI=1`.
- `.github/workflows/beads-relay.yml`, a reusable workflow
  (`workflow_call`) that a member calls.
- The `rig-relay` skill: when and how a session stages.

## Staging

`rig-relay stage <label>` fetches the store's Dolt remote and compares the
local working set with its **merge base** with the remote. Comparing with the
remote tip instead would stage rows that changed remotely, carrying this
store's stale values.

Rows are compared by content, not by row identity: bd's schema migrations
rewrite every row of a table or re-key comments, and a raw `dolt_diff` would
report the whole tracker as changed. An issue is staged when its own row's
`updated_at` moved, or when one of its comments, labels or dependencies was
added or removed (those export inside its record). A memory is staged when
its value changed. Deleted issues and forgotten memories cannot be carried;
the command warns about them.

The staged file is the matching records from `bd export --all`, one per
line. A store without an `origin` Dolt remote is refused: it was hydrated
from an export rather than bootstrapped, and its rows are not the tracker's.

## Applying

`rig-relay apply` reads every `*.jsonl` in the inbox and:

1. **Gates on staleness.** `bd import` is an upsert, so a record older than
   the store would silently reinstate old values. If any issue's
   `updated_at` in the store is newer than in the delta, the whole run is
   refused, naming the issues, and nothing is imported. Memories carry no
   timestamp and are not gated.
2. Imports each file in name (time) order. Re-importing an applied file is
   a no-op.
3. Pushes `refs/dolt/data`, with the tracked `.beads/config.yaml` pointed
   at https for the push and restored afterwards.

The workflow then resets to the branch tip and removes only the files it
applied, so the clearing commit carries nothing bd changed in the tree and
never drops a delta merged while it ran. Its push uses `GITHUB_TOKEN`, which
raises no workflow events, so the relay does not re-trigger itself.

**Schema migrations.** The workflow runs rig's pinned bd. If that bd is newer
than the store's schema, bootstrapping migrates it and the push publishes the
migration, so every clone then needs a bd at least that new. Bump the pin in
`lib/pins.sh` deliberately.

## When it is stuck

- **Refused as stale.** Someone changed an issue after the delta was staged.
  Remove the file from the inbox in a PR, re-bootstrap a session's store,
  redo the writes and stage again.
- **Inbox not cleared** (branch protection refused the workflow's push). The
  deltas stay queued; the next run's gate refuses them once the store has
  moved on. Remove the applied files by hand in a PR. Branch protection
  must let `GITHUB_TOKEN` push to the default branch for clearing to work.
- **A merge resurrected an applied file** on a long-lived branch. See the
  skill's "After merging main".

## Adopting it in a member

1. Add a workflow, pinned to a reviewed commit of rig (both SHAs the same):

   ```yaml
   name: beads relay
   on:
     push:
       branches: [main]
       paths: [".beads/inbox/*.jsonl"]
     workflow_dispatch:
   jobs:
     relay:
       uses: curvelogic/curve-rig/.github/workflows/beads-relay.yml@<sha>
       with:
         rig-ref: <sha>
       permissions:
         contents: write
   ```

   While rig is private, the member also needs rig's Actions access set to
   allow repositories in the organisation, and must pass a token that can
   read rig: `secrets: { rig-token: ${{ secrets.<name> }} }`.
2. Remove the member's own relay scripts and workflow, if it had them, once
   its inbox is empty.
3. Point the member's `CLAUDE.md` at the `rig-relay` skill
   (`templates/CLAUDE.md` does).
