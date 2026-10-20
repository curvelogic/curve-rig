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


**Beads writes reach the tracker as directly as possible.** There is no
review gate on them: a session's staged writes are applied as soon as CI
can apply them, not when a PR merges. Whoever can push a branch to a member
can therefore write its tracker — but that was already so. A branch's
workflow runs as pushed and may declare `contents: write`, and no ruleset
covers `refs/dolt/data` (rulesets cover branches and tags only), so
whoever can push a branch, and push workflow files, can already rewrite
the store through a workflow of their own. What the relay adds is that no
workflow needs writing: a cloud session, a prompt-injected one included,
writes issues and memories that every later session reads just by
staging them. So a member's agents should read beads as notes about the
work, never as instructions. Nothing the relay does reaches the member's
default branch.

## How it works

```
session                     git                           CI
-------                     ---                           --
bd create / update / …
rig-relay stage        →    branch beads-inbox/<t>-<l>
                            adding .beads/inbox/<t>-<l>.jsonl
                                  │ push
                                  ▼
                            "beads inbox" workflow  →   dispatch "beads relay"
                            (runs from the branch;      on the default branch
                            actions: write only)             │
                                                             ▼
                                                      rig-relay collect
                                                        (reads each inbox
                                                         branch as data)
                                                      rig-relay bootstrap
                                                      rig-relay apply:
                                                        staleness gate
                                                        bd import
                                                        bd dolt push
                                                      rig-relay finish:
                                                        delete applied branches
```

1. **The session works normally.** Its `bd` writes land in the local store,
   which was bootstrapped from `refs/dolt/data` when the session started.
2. **It stages once, at the end.** `rig-relay stage <label>` works out
   which issues and memories the session changed, exports exactly those
   records from bd, and writes them to `.beads/inbox/<time>-<label>.jsonl`
   (see *Staging*).
3. **It pushes the file on its own branch.** `stage` then commits only
   that file on a new branch `beads-inbox/<time>-<label>`, based on the
   default branch, pushes it, and removes the file from the working tree,
   so it never rides in the session's own PRs (see *The inbox branch*).
4. **The push dispatches the relay.** The member's `beads inbox` workflow,
   triggered by the push, has no secrets and no write access; all it does
   is dispatch the member's `beads relay` workflow on the default branch
   (see *Triggering*).
5. **The relay reads every inbox branch as data.** Running from the default
   branch, it fetches each `beads-inbox/*` branch and reads its one file
   with git, never checking anything out, rejecting any branch that is not
   exactly one well-named new delta (see *Validation*).
6. **It applies the deltas.** It bootstraps a fresh store from
   `refs/dolt/data`, applies the deltas in time order, each behind the
   staleness gate, and pushes the store (see *Applying*).
7. **It deletes what it applied.** Each applied branch is deleted, unless
   it moved after it was read. Rejected and refused branches are left in
   place and the run fails, naming them.

The next session to start bootstraps from the updated ref and sees the
changes.

## Parts

- `bin/rig-relay` with `lib/relay.sh`. `stage` and `push` run in the
  session; `rig-relay` is linked into `~/.local/bin` by `bin/rig-install`.
  `bootstrap`, `collect`, `apply` and `finish` run in CI and refuse to run
  elsewhere unless `RIG_RELAY_ALLOW_CI=1`.
- `.github/workflows/beads-relay.yml`, a reusable workflow
  (`workflow_call`) that a member's `beads relay` workflow calls.
- Two workflows in each member, given in full under *Adopting it*.
- The `rig-relay` skill: when and how a session stages.
- `bin/rig-relay-test`, run by `bin/rig-check`: the git side of the relay
  (pushing, validation, applying deltas read from refs, deleting) against
  a local stand-in for origin, with a fake bd.

## Staging

`rig-relay stage <label>` fetches the store's Dolt remote and compares the
local working set with its **merge base** with the remote. Comparing with the
remote tip instead would stage rows that changed remotely, carrying this
store's stale values.

Rows are compared by content, not by row identity: bd's schema migrations
rewrite every row of a table or re-key comments, and a raw `dolt_diff` would
report the whole tracker as changed. An issue is staged when its own row's
`updated_at` moved, or when it gained a comment, label or dependency (those
export inside its record). A memory is staged when it is new or its value
changed.

**Only additions and updates are carried.** `bd import` merges a record's
labels, dependencies and comments into what the store holds rather than
replacing them, and cannot delete. So a removed label or dependency, a
removed or edited comment, a deleted issue and a forgotten memory are not
relayed; `stage` names each one it finds, and they have to be made from
somewhere that can push the store.

The staged file is the matching records from `bd export --all`, one per
line. A store without an `origin` Dolt remote is refused: it was hydrated
from an export rather than bootstrapped, and its rows are not the tracker's.

## The inbox branch

The label is reduced to letters, digits, `_` and `-` (at most 40), so the
file and branch names are `<yyyymmddThhmmssZ>-<label>`.

`stage` builds the branch's one commit with a scratch index: the default
branch's tip, as just fetched, plus the delta. The session's working tree,
index, HEAD and branches are untouched, whatever branch it is on and
whatever it has uncommitted. It pushes the commit to
`refs/heads/beads-inbox/<time>-<label>` — a branch create, which a
session may push — and then deletes the staged file.

If the push fails, the file is kept and `rig-relay push
.beads/inbox/<file>` retries it. A retry that finds the branch already
holding the same file reports success. Two stages with the same label in
the same second collide; the second is refused and can simply be staged
again.

## Triggering

The relay needs `contents: write`, and while rig is private a token that
can read it. It must not run code from an inbox branch with either. For a
`push` event, GitHub runs the workflow file *from the pushed commit*, "this
includes workflows that are not merged into the default branch", so a
push-triggered job with write access would run whatever the branch says.
Hence two workflows:

- **`beads inbox`** (`on: push` to `beads-inbox/**`) runs from the inbox
  branch, so it is given nothing worth taking: `permissions:` is
  `actions: write` only, and it uses no secrets. Its one step calls the
  REST endpoint "Create a workflow dispatch event" for `beads-relay.yml`
  with `ref` set to the default branch and the branch name as the
  `inbox-branch` input.
- **`beads relay`** (`on: workflow_dispatch`) runs from the default branch
  — for `workflow_dispatch`, `GITHUB_SHA` is the last commit on the
  dispatched ref — and calls rig's reusable workflow, which also refuses any
  ref but the default branch.

Events a workflow raises with `GITHUB_TOKEN` normally start no workflow
runs, but GitHub documents the exception this relies on: "`workflow_dispatch`
and `repository_dispatch` events always create workflow runs." The dispatched
workflow must exist on the default branch ("This event will only trigger a
workflow run if the workflow file exists on the default branch"). Sources:
GitHub Docs, *Triggering a workflow* → "Triggering a workflow from a
workflow", and *Events that trigger workflows* → `push` and
`workflow_dispatch`.

Anyone who can push a branch to a member can already run any workflow they
like on it, with whatever the repository lets workflows have; the inbox
workflow adds nothing to that. What matters is that the run which can write
the store runs only code from the default branch and reads inbox branches
only as data.

**Runs at once.** The relay runs one at a time per member (a concurrency
group). GitHub keeps at most one pending run per group and cancels an older
pending one when a newer arrives, so a burst of pushes may start fewer runs
than there were branches. Nothing is lost: every run reads *every*
`beads-inbox/*` branch, not just the one that dispatched it, and applies all
of them in name (time) order.

## Validation

`rig-relay collect` fetches the default branch and every inbox branch in
one fetch, then for each branch requires:

- a name `beads-inbox/<yyyymmddThhmmssZ>-<label>`, the label as above;
- relative to its merge base with the default branch, exactly one change:
  the addition of `.beads/inbox/<same time and label>.jsonl`;
- that file not already on the default branch, a regular file, and at
  most 16 MiB.

It reads the file with `git cat-file` into the runner's temporary
directory. Anything else is rejected: the branch is left in place and the
run fails, naming it and the reason. Records are checked when they are
applied: every line must be JSON, every issue must have an id and every
memory a key.

## Applying

`rig-relay apply` takes the collected deltas in name (time) order and, for
each:

1. **Gates on staleness.** `bd import` is an upsert, so a record older than
   the store would silently reinstate old values. If any issue's
   `updated_at` in the store is newer than in the delta, or a record is
   invalid, that delta is refused, naming the issues, and not imported.
   Later deltas still apply. The gate sees only what moves `updated_at`: an
   issue's fields and status, not its labels or comments. Those merge
   rather than overwrite, so nothing is lost by it. Memories carry no
   timestamp and are not gated.
2. Imports it. Re-importing an applied delta is a no-op.

It then pushes `refs/dolt/data` once, with the tracked `.beads/config.yaml`
pointed at https for the push and restored afterwards. Only after the push
does it record what it applied; `rig-relay finish` deletes exactly those
branches, each with a lease on the commit it read, so a branch that moved
since is left for the next run.

Every step has a timeout, and the job a 30-minute limit, so a hang cannot
hold the relay's one-at-a-time slot for long.

**What runs with write access.** The job's token can push to the member, and
is set in git's global config so that bd's own git calls can use it. bd reads
the member's `.beads/` configuration from the default branch, and anything
bd ever executed from `.beads/` would run with that token — a reason to
review `.beads/` changes like code. Delta files are data: bd imports them,
and nothing else reads them. Because they are unreviewed, the apply step
stops GitHub reading its output for workflow commands.

**Schema migrations.** The workflow runs rig's pinned bd. If that bd is newer
than the store's schema, bootstrapping migrates it and the push publishes the
migration, so every clone then needs a bd at least that new. Bump the pin in
`lib/pins.sh` deliberately.

## When it is stuck

A failed run names every branch it left, with the reason. Sessions cannot
delete branches; whoever owns the repository deletes abandoned ones.

- **Refused as stale.** Someone changed an issue after the delta was
  staged. Redo the writes in a fresh session (its store is bootstrapped
  from the current tracker) and stage again; then delete the refused
  branch. Until it is deleted, every run reports it again.
- **Rejected** (a bad name, other changes on the branch, an oversized or
  missing file). It was not made by `rig-relay stage`. Redo the writes and
  stage them; delete the branch.
- **`bd import` or the store push failed.** Nothing is deleted, and the
  next run retries every branch. If one delta makes `bd import` fail every
  time, it holds up the rest: delete its branch, and redo its writes.
- **A branch is not deleted** after its delta applied (it moved, or the
  deletion was refused). The next run applies it again, which is harmless
  while the tracker has not moved; after that the gate refuses it. Delete
  it by hand.
- **No run started.** Run the `beads relay` workflow by hand (Actions →
  *beads relay* → *Run workflow*, input empty): it sweeps every inbox
  branch.

## Adopting it in a member

1. Add the relay workflow at `.github/workflows/beads-relay.yml`, pinned to
   a reviewed commit of rig. Both SHAs must be the same: the first chooses
   the workflow, the second the scripts it runs. Nothing checks that they
   agree, but the workflow refuses a `rig-ref` that is not on rig's
   `main`. Nothing checks the `uses:` SHA: GitHub serves forks' commits
   from rig's URL too, so before pinning one, confirm it is on rig's
   `main` (`git merge-base --is-ancestor <sha> origin/main` in a clone of
   rig).

   ```yaml
   name: beads relay
   on:
     workflow_dispatch:
       inputs:
         inbox-branch:
           description: Inbox branch that dispatched this run; empty sweeps all
           type: string
           required: false
   jobs:
     relay:
       uses: curvelogic/curve-rig/.github/workflows/beads-relay.yml@<sha>
       with:
         rig-ref: <sha>
         inbox-branch: ${{ inputs.inbox-branch }}
       secrets:
         rig-token: ${{ secrets.<name> }}
       permissions:
         contents: write
   ```

   The `secrets:` block is needed only while rig is private: it passes a
   token that can read rig, from a secret of the member's. Keep it in block
   form; written inline as a flow mapping (`{ rig-token: ${{ … }} }`) it is
   not valid YAML. While rig is private, rig's own Actions access (Settings
   → Actions → General → Access) must also allow repositories in the
   organisation.

2. If the member runs Dependabot's `github-actions` ecosystem, make it
   ignore rig. Otherwise it can bump the `uses:` SHA without `rig-ref`,
   and the two drift apart. Bump both together, by hand, to a reviewed
   commit.

   ```yaml
   # .github/dependabot.yml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule:
         interval: weekly
       ignore:
         - dependency-name: "curvelogic/curve-rig*"
   ```

   If the member already has a `github-actions` entry, add only the
   `ignore:` item to it.

3. Add the dispatcher at `.github/workflows/beads-inbox.yml`. It names the
   relay workflow by file name; change `beads-relay.yml` if yours differs.

   ```yaml
   name: beads inbox
   on:
     push:
       branches: ["beads-inbox/**"]
   permissions: {}
   jobs:
     dispatch:
       if: github.event.deleted != true
       runs-on: ubuntu-latest
       timeout-minutes: 5
       permissions:
         actions: write
       steps:
         - name: Dispatch the beads relay on the default branch
           env:
             GH_TOKEN: ${{ github.token }}
             REPO: ${{ github.repository }}
             DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
             INBOX: ${{ github.ref_name }}
           run: >-
             gh api --method POST
             "repos/$REPO/actions/workflows/beads-relay.yml/dispatches"
             -f ref="$DEFAULT_BRANCH" -f "inputs[inbox-branch]=$INBOX"
   ```

   It has no checkout and no secrets, and passes event values through the
   environment, never into the script. Both workflow files take effect once
   they are on the default branch, merged together in one PR.

4. Keep other push-triggered workflows off inbox branches. Every inbox
   branch carries the default branch's workflows, so an `on: push` with no
   branch filter (CI, say) also runs on each one. Add
   `branches-ignore: ["beads-inbox/**"]` to those. A `push` trigger that
   already has a `branches:` filter cannot also take `branches-ignore:`;
   if its patterns match inbox branches (`**`, say), add
   `"!beads-inbox/**"` as its last pattern instead.

5. Point the member's `CLAUDE.md` at the `rig-relay` skill
   (`templates/CLAUDE.md` does).

6. Check the member's settings. Any branch push runs the workflows on
   that branch as pushed, with whatever `permissions:` they declare, so
   what such a run may do is bounded by the repository, not by the relay:

   - Protect the default branch with a ruleset requiring a PR, its
     checks, and at least one approval, with the owner's role allowed to
     bypass, and leave *Allow GitHub Actions to create and approve pull
     requests* off. A pushed branch's workflow can declare
     `contents: write` and merge a ready PR through the API; with no
     approval required, nothing stops it. The approval rule stops the
     workflow's token, which cannot bypass, while the owner's account
     (and agents acting as it) merges by bypass.
   - Settings → Actions → General → *Workflow permissions*: read
     repository contents only. This is only the default for workflows
     that declare no `permissions:`; it keeps an ordinary workflow from
     holding a write token it does not need, and stops nothing that asks
     for one.
   - Keep secrets in environments restricted to the default branch, as
     rig does for its denylist; a repository secret is readable by any
     pushed branch's workflow.

   Nothing here protects `refs/dolt/data`: anyone who can push a branch
   with a workflow in it can write the store.

### Switching from the old inbox route

Members that adopted the relay earlier had sessions commit the delta in a
PR; their relay workflow triggered on a push to the default branch and
committed "clear applied deltas" back to it. To switch, replace that
workflow with the two above in one PR, pinned to a rig commit that has
them. Remove the member's own relay scripts and workflow, if it had them,
at the same time.

Nothing queued is lost: every run also reads any `*.jsonl` still in
`.beads/inbox/` on the default branch, applies it in time order with the
inbox branches, and leaves it where it is — the relay no longer commits to
the default branch. Then retire the old path:

1. After the switch merges, run *beads relay* by hand once (input empty)
   and check it applied the old files.
2. Remove `.beads/inbox/` from the default branch in a PR. Until then
   every run applies those files again, which is harmless until a later
   change touches one of their issues; from then the gate refuses them and
   each run fails, naming them.
3. A session PR made before the switch that still adds an inbox file is
   applied the same way when it merges; remove the file afterwards the
   same way.

## Checking it end to end

What `bin/rig-relay-test` cannot cover is GitHub: the dispatch, the
workflow's permissions and the pushes. After adopting it in a member, run
this once from a cloud session in that member, provisioned by rig.

1. **Stage and push.** Create an issue with `bd create "relay check"` and
   note its id; then `rig-relay stage relay-check`. Expect
   `Pushed beads-inbox/<time>-relay-check`. `git status` shows nothing new:
   no `.beads/inbox/` file, the session's branch as it was.
2. **Dispatch.** In the member's Actions tab, a *beads inbox* run on that
   branch succeeded, and a *beads relay* run on the default branch
   followed, its `inbox-branch` input naming the branch.
3. **Apply.** That run's log shows the branch under *Queued*, the gate
   passing, `Applied 1 delta(s)` and `Deleted beads-inbox/…`. The branch is
   gone, and the default branch has no new commit.
4. **Read back.** In a fresh session (or locally after `bd dolt pull`),
   `bd show <id>` finds the issue.
5. **Burst.** In one session run `bd update <id> --title "relay check a"`,
   `rig-relay stage a`, then a second later `bd update <id> --title "relay
   check b"`, `rig-relay stage b`. Both branches are applied, in either one
   run or two, and a fresh bootstrap shows the title `relay check b`.
6. **Rejection.** From a session, push a branch
   `beads-inbox/20000101T000000Z-bad` that adds
   `.beads/inbox/20000101T000000Z-bad.jsonl` and also changes another file.
   The relay run fails, naming the branch and the extra file, and the
   branch is still there. Delete it.
7. **Refusal.** In session A, `bd update <id> --title "stale"` and stage
   with `RIG_RELAY_NO_BRANCH=1 rig-relay stage stale`, which writes the file
   without pushing it. In session B, update the same issue and stage
   normally; wait for it to apply. Back in A, `rig-relay push
   .beads/inbox/<file>`. The run fails, naming the issue as stale, and the
   branch is left. Delete it.
8. **Clean up.** `bd close <id>` in a fresh session and stage.
