# Plan

What exists, and what to do next, in order. Replace this file with beads
once the relay works (step 4).

## Exists

- Two-stage delivery: `bin/rig-install` (stage 1) and
  `hooks/session-start.sh` (stage 2), with `lib/common.sh` and
  `lib/beads.sh`.
- Stage 2 run by hand (`RIG_FORCE=1`) in a multi-repo cloud session with
  four beads-using members: all discovered (including one nested under an
  owner directory), stores bootstrapped over https in about two minutes,
  member trees left clean, re-run a no-op in two seconds. Single-repo
  discovery checked too. `rig-install` checked for idempotence and for
  merging into an existing `settings.json`. **Not yet proven: either stage
  firing on its own** — see step 3.
- Plugin and marketplace manifests; one skill, `rig-provision`.
- Templates for a member repo's `CLAUDE.md` and `REVIEW.md`.
- CI: `bin/rig-check`, plus `bin/rig-denylist-check` once the
  `RIG_DENYLIST` secret is set.

## Next

1. **Owner: set the `RIG_DENYLIST` repository secret** — one private name per
   line. Until it exists the denylist check is skipped.
2. **Branch protection on `main`**: require the CI check; turn on automatic
   deletion of merged branches.
3. **Prove the hook fires.** Each cloud session is a fresh container, so an
   install from one session does not carry to the next, and a private rig
   cannot be cloned by the setup script (design.md, constraint 3). Before
   going public, test inside one session: run `bin/rig-install`, then start a
   headless `claude -p` in the same container and confirm the user-level
   SessionStart hook ran for it. The full path (setup script → hook) is proved
   at step 9. Note: bd ≥ 1.3 appends patterns to a member's tracked
   `.beads/.gitignore` on bootstrap; rig restores the file, but members should
   commit those additions so the tree stays clean under plain `bd`.
4. **Beads relay.** A script that stages a session's beads changes to an
   outbox in the member's working tree (`.beads/inbox/`), and a reusable
   workflow (`workflow_call`) that, on merge to the default branch, imports
   the outbox into the store behind a staleness check and pushes
   `refs/dolt/data`. Members call it from a three-line workflow. Ship as a
   skill (`rig-relay`) plus `lib/relay.sh` and
   `.github/workflows/beads-relay.yml`. Then initialise beads for rig itself
   (from a desktop session) and move this plan into it.
5. **Reviewer agent** (`plugins/rig/agents/rig-review.md`): fresh context,
   adversarial; reads the member's `REVIEW.md`; requires green CI; merges or
   escalates to a decision bead; supports a second-independent-review mode
   for sensitive areas; never merges what `REVIEW.md` reserves for the owner.
   Inherit the session's model — never pin a cheaper one.
6. **Pin bd** to a release asset in `rig_install_bd` instead of the upstream
   installer script.
7. **Pilot on one private member**: add `.rig/setup.sh`, adopt the
   templates, enable the plugin for local sessions. Verify both delivery
   stages in a fresh cloud environment whose setup script runs
   `bin/rig-install`. Resolve the open questions in `design.md`.
8. **Second member**, replacing its own copies of setup, relay and reviewer.
9. **Go public**: confirm the denylist check is clean across history, make
   the repository public, tag a release, point environments at it.
