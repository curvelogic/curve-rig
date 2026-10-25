# Plan

What exists, and what to do next, in order. This is the generic roadmap;
work items, and anything naming a member, are tracked in the owner's
org-level tracker. rig has no beads store of its own (see `CLAUDE.md`).

## Exists

- Two-stage delivery: `bin/rig-install` (stage 1) and
  `hooks/session-start.sh` (stage 2), with `lib/common.sh` and
  `lib/beads.sh`.
- Stage 2 run by hand (`RIG_FORCE=1`) in a multi-repo cloud session with
  four beads-using members: all discovered (including one nested under an
  owner directory), stores bootstrapped over https in about two minutes,
  member trees left clean, re-run a no-op in two seconds. Single-repo
  discovery checked too. `rig-install` checked for idempotence and for
  merging into an existing `settings.json`.
- Stage 1 then stage 2 inside one cloud session: `bin/rig-hook-test`
  installs rig into a throwaway config directory and starts a headless
  `claude -p`, whose user-level SessionStart hook fires and whose rig skills
  load. With the real owner trusted it installed bd and dolt and
  bootstrapped a member's store in under half a minute, leaving trees clean.
  The setup-script path is proven with a stand-in (`design.md`,
  constraints 8 and 9); rig's own is proven once it is public (step 5). bd ≥ 1.3 appends patterns to a member's tracked
  `.beads/.gitignore` on bootstrap; rig restores the file, but members should
  commit those additions so the tree stays clean under plain `bd`.
- Beads relay (`docs/relay.md`): `rig-relay stage` in a session pushes the
  delta alone on a `beads-inbox/…` branch; a push-triggered workflow with
  no secrets dispatches the reusable relay on the default branch, which
  reads the branch as data, applies it behind a staleness gate, pushes
  `refs/dolt/data` and deletes the branch. Staging, the gate, import
  (idempotent on re-apply) and the CI bootstrap were exercised on copies
  of a member's store; `bin/rig-relay-test` covers the branch push,
  validation, applying from refs and deletion against a local origin. The
  GitHub side (dispatch, permissions, pushes) has not yet run — that
  happens when the pilot adopts it (`relay.md` → *Checking it end to end*).
- Reviewer agent `rig-review`: fresh context, adversarial; takes its rules
  from the member's `REVIEW.md` on the base branch; requires green CI and
  runs the member's check; merges, sends back, or escalates to a decision
  bead; second-independent-review and re-review modes; sends back on
  blocking findings only, with a two-round limit; runs at the session's
  model except for non-sensitive re-reviews. Loads in a headless session;
  not yet run against a real PR.
- Plugin and marketplace manifests; skills `rig-provision` and `rig-relay`;
  agent `rig-review`.
- Templates for a member repo's `CLAUDE.md` and `REVIEW.md`.
- CI: `bin/rig-check` on every PR; a separate `pull_request_target`
  workflow runs the base branch's `bin/rig-denylist-check` over history,
  paths, metadata and refs, with the secret held in a `denylist`
  environment restricted to `main`. A tag ruleset forbids updating or
  deleting tags, so a release tag cannot be moved under a member that pins
  it.
- First independent security review done; its findings fixed (trusted
  owners, `startup` matcher, pinned and digest-checked downloads, deadline
  and restore-on-kill, stdin isolation, safe exclude patterns, stricter
  denylist).
- Second independent security review done, of `main` at `065cc39`; its
  fixes are in one PR for the owner.

## Next

1. **Pilot on one private member**: add `.rig/setup.sh`, adopt the
   templates and the relay workflow, enable the plugin for local sessions,
   and have `rig-review` review and merge its PRs in place of its own
   reviewer. Prove the relay end to end (`relay.md` → *Checking it end to
   end*). While rig is private, install it by hand in the session (the
   `rig-provision` skill) rather than from the setup script, and give the
   relay workflow its private-rig access (`docs/relay.md` → *Adopting
   it*).
2. **Second member**, replacing its own copies of setup, relay and reviewer.
3. **Merge the second review's fixes.**
4. **Guard Dependabot branches in the hook**: skip a member's
   `.rig/setup.sh` when its checkout is on a `dependabot/` branch, so a
   session never installs a bump's packages with its credentials.
5. **Go public**: squash history to a single commit, confirm the denylist
   scan is clean, make the repository public, and tag a release. Squashing
   clears `main`'s history only: every PR's commits stay reachable from
   its `refs/pull/<n>/head`, and its title, description and comments stay
   on its page, so those must be clean too.
6. **Prove hands-off delivery**: point a fresh cloud environment's setup
   script at the release with `--trusted-owners` (README → *Using rig in a
   cloud environment*), start a session, and confirm the hook provisioned
   every member with nothing run by hand. Then move the other environments
   over, and drop each member's private-rig access for the relay.
