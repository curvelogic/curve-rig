# Plan

What exists, and what to do next, in order. Replace this file with beads
once the relay works (step 3).

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
  Not yet proven: the hook surviving from an environment setup script into
  a fresh session (step 5). bd ≥ 1.3 appends patterns to a member's tracked
  `.beads/.gitignore` on bootstrap; rig restores the file, but members should
  commit those additions so the tree stays clean under plain `bd`.
- Plugin and marketplace manifests; one skill, `rig-provision`.
- Templates for a member repo's `CLAUDE.md` and `REVIEW.md`.
- CI: `bin/rig-check` on every PR; a separate `pull_request_target`
  workflow runs the base branch's `bin/rig-denylist-check` over history,
  paths, metadata and refs, with the secret held in a `denylist`
  environment restricted to `main`.
- First independent security review done; its findings fixed (trusted
  owners, `startup` matcher, pinned and digest-checked downloads, deadline
  and restore-on-kill, stdin isolation, safe exclude patterns, stricter
  denylist).

## Next

1. **Owner: create the `denylist` environment** (Settings → Environments):
   deployment branches restricted to `main`, with an environment secret
   `RIG_DENYLIST` — one distinctive private name per line. Do not add it as
   a repository secret. Until it exists the denylist workflow fails.
2. **Owner: protect tags** with a tag ruleset (no updates, no deletion)
   before the first release tag.
3. **Beads relay.** A script that stages a session's beads changes to an
   outbox in the member's working tree (`.beads/inbox/`), and a reusable
   workflow (`workflow_call`) that, on merge to the default branch, imports
   the outbox into the store behind a staleness check and pushes
   `refs/dolt/data`. Members call it from a three-line workflow. Ship as a
   skill (`rig-relay`) plus `lib/relay.sh` and
   `.github/workflows/beads-relay.yml`. Then initialise beads for rig itself
   (from a desktop session) and move this plan into it.
4. **Reviewer agent** (`plugins/rig/agents/rig-review.md`): fresh context,
   adversarial; reads the member's `REVIEW.md`; requires green CI; merges or
   escalates to a decision bead; supports a second-independent-review mode
   for sensitive areas; never merges what `REVIEW.md` reserves for the owner.
   Inherit the session's model — never pin a cheaper one.
5. **Pilot on one private member**: add `.rig/setup.sh`, adopt the
   templates, enable the plugin for local sessions. Verify both delivery
   stages in a fresh cloud environment whose setup script runs
   `bin/rig-install --trusted-owners …`. Resolve the open questions in
   `design.md`.
6. **Second member**, replacing its own copies of setup, relay and reviewer.
7. **Second independent security review** of everything since the first
   one, with the findings fixed.
8. **Go public**: squash history to a single commit (removes session links
   and stale branches), confirm the denylist scan is clean, make the
   repository public, tag a release, and point environments' setup
   scripts at a pinned commit with `--trusted-owners`.
