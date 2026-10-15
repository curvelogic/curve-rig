# CLAUDE.md — curve-rig

Shared agent scaffolding for a family of repositories. Read `README.md` for
what rig is and `docs/design.md` before changing how it is delivered.
`docs/plan.md` says what to do next.

## The rule that overrides everything: generic only

This repository is private while it is built and **will be made public**,
with its full history. From the first commit:

- Never name a private project, private repository, internal hostname,
  account ID or person other than "the owner". Examples use made-up names
  (`example-app`, `acme`).
- That covers commit messages, branch names and PR text as well as files.
- Describe a need generically ("a hosted app that wraps a CLI in a
  container"), never the project that has it.
- If a fix needs project-specific knowledge, the knowledge belongs in that
  project's `.rig/setup.sh` or `REVIEW.md`, not here.

CI enforces a private denylist (see `bin/rig-denylist-check`); passing it is
necessary, not sufficient.

## Layout

```
bin/rig-install           stage 1: install into ~/.claude (setup script)
bin/rig-check             the check command — run before every commit
bin/rig-denylist-check    CI-only private-name check
bin/rig-ci-tools          install the pinned linters rig-check runs
bin/rig-hook-test         prove the hook fires, in a headless session
bin/rig-relay             beads relay: stage (session), bootstrap/apply (CI)
hooks/session-start.sh    stage 2: provision trusted repos in the session
lib/common.sh             logging, deadline, restores, discovery, trust
lib/pins.sh               pinned versions and digests of every download
lib/beads.sh              bd + dolt install, beads store bootstrap
lib/relay.sh              relay staging, staleness gate, apply
.github/workflows/        CI, denylist, reusable beads relay
plugins/rig/              the Claude Code plugin (skills, agents)
.claude-plugin/           marketplace manifest
templates/                member-repo CLAUDE.md / REVIEW.md skeletons
docs/                     design and plan
```

## Check

```bash
bin/rig-check
```

Runs `bash -n` and shellcheck on every script, actionlint on the workflows,
and validates every JSON file and the plugin/marketplace manifests. Without
shellcheck or actionlint installed it skips them locally and fails in CI;
`bin/rig-ci-tools` installs the pinned versions CI uses. CI runs the same;
a separate workflow runs the denylist from the base branch
(`.github/workflows/denylist.yml`).

## Workflow

- Branch, commit, push, open a PR. Never commit to `main`.
- The owner merges every PR except docs-only ones (see `REVIEW.md` for
  why). rig's reviewer agent (`rig-review`) reviews every PR and may merge
  docs-only ones.
- Roadmap: `docs/plan.md`, kept generic. Work items, including anything
  that names a member, live in the owner's org-level tracker, not here.
- rig has no beads store, and must not get one: the store lives on
  `refs/dolt/data` in this repository, would be published with it, and is
  not covered by the denylist scan or by squashing history.

## Shell conventions

- `bash`, `set -euo pipefail`, shellcheck-clean.
- Idempotent: every script is safe to re-run.
- Provisioning never aborts as a whole for one failed step. Each step reports
  its own failure, so a half-provisioned session says which half.
- The SessionStart hook always exits 0 — a failing hook must not stop the
  session from starting.
- Every download is an exact release asset pinned in `lib/pins.sh` with
  its SHA-256, fetched with `rig_fetch` and checked with `rig_sha256_ok`.
  Never `latest`, a moving branch, or an upstream install script. Never
  `api.github.com` (in a cloud session it is scoped to the session's
  repositories).
- Run code from a member repository only after `rig_repo_trusted`.
- Give everything the hook runs `</dev/null` and a timeout from
  `rig_step_timeout`; send its output to `$RIG_LOG`.
- Leave a member repo's working tree as you found it, even if killed:
  `rig_restore_register` a backup before rewriting a tracked file.
- Delete only what this run created.

## Prose

UK English. Prose wraps at 80 columns. Documents say what is true now and
what happens next; history belongs in commits and PRs.
