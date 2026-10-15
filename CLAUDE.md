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
hooks/session-start.sh    stage 2: provision repos in the session
lib/common.sh             logging, PATH, repo discovery
lib/beads.sh              bd + dolt install, beads store bootstrap
plugins/rig/              the Claude Code plugin (skills, agents)
.claude-plugin/           marketplace manifest
templates/                member-repo CLAUDE.md / REVIEW.md skeletons
docs/                     design and plan
```

## Check

```bash
bin/rig-check
```

Runs `bash -n` and shellcheck on every script, and validates every JSON file
and the plugin/marketplace manifests. CI runs the same, plus the denylist.

## Workflow

- Branch, commit, push, open a PR. Never commit to `main`.
- Until rig's own reviewer agent exists, the owner reviews and merges. Once
  it exists, rig uses it on itself, with the owner merging anything in
  `REVIEW.md`'s sensitive areas.
- Backlog: `docs/plan.md` for now. Beads arrives once the relay works —
  initialising it needs a push to `refs/dolt/data`, which a web session
  cannot make.

## Shell conventions

- `bash`, `set -euo pipefail`, shellcheck-clean.
- Idempotent: every script is safe to re-run.
- Provisioning never aborts as a whole for one failed step. Each step reports
  its own failure, so a half-provisioned session says which half.
- The SessionStart hook always exits 0 — a failing hook must not stop the
  session from starting.
- Never call `api.github.com` from provisioning: in a cloud session it is
  scoped to the session's repositories. Use release-asset URLs and the
  `releases/latest/download/` redirect instead.
- Leave a member repo's working tree as you found it. If a tool rewrites a
  tracked file (beads does), restore it.

## Prose

UK English. Prose wraps at 80 columns. Documents say what is true now and
what happens next; history belongs in commits and PRs.
