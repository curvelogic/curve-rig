# REVIEW.md — curve-rig

Criteria a reviewer applies to every PR here, on top of green CI.

## Who merges

rig runs as root at the start of every session in every environment that
installs it, and its skills and templates are instructions agents follow.
So **the owner merges every PR**, except one confined to `docs/` — that the
reviewer agent (`rig-review`) may merge — unless it changes a fenced code
block (the workflows, settings and commands members copy from the docs),
the steps of `docs/relay.md`'s *Adopting it*, or the *Security model*
section of `docs/design.md`. Those are the owner's too.

(CODEOWNERS cannot enforce this: agents push and open PRs as the owner's
account, and GitHub does not let an account approve its own PR. The rule
is enforced by this file and the reviewer.)

## Blocking

- **Generic only.** Any private project name, private repository, internal
  hostname, account ID or person other than the owner — in files, commit
  messages, branch name or PR text — blocks the PR. So does a description
  specific enough to identify a private project.
- **No secrets**, including in examples and test fixtures.
- **Nothing untrusted is executed.** Provisioning runs code only from
  repositories whose origin owner is trusted; CI never runs code from the
  PR with access to a secret.
- **Every download is pinned** to an exact version with a SHA-256 digest
  in `lib/pins.sh`. No `latest`, no moving branches, no install scripts.
- **The hook cannot fail or hang the session.** `hooks/session-start.sh`
  exits 0 on every path; every step has a timeout drawn from the deadline;
  stdin is `/dev/null` for anything it runs.
- **Member trees are left clean**, including when the hook is killed: any
  rewrite of a tracked file is registered with `rig_restore_register`
  first.
- **Nothing is deleted that rig did not create.**
- **Tool output goes to the log**, not stdout (stdout becomes agent
  context).
- **Idempotent.** Running any script twice gives the same result as once.

## Worth flagging, not blocking

- A new external host (name it; check it is reachable from a cloud
  session).
- Behaviour that differs between single- and multi-repo sessions.
- Anything that changes what a member's `.rig/setup.sh` can rely on.
