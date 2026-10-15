# REVIEW.md — curve-rig

Criteria a reviewer applies to every PR here, on top of a green `bin/rig-check`.

## Blocking

- **Generic only.** Any private project name, private repository, internal
  hostname, account ID or person — in files, commit messages, branch name or
  PR text — blocks the PR. So does a description specific enough to identify
  a private project.
- **No secrets**, including in examples and test fixtures.
- **The hook cannot fail the session.** `hooks/session-start.sh` must exit 0
  on every path, and must not hang (bounded downloads, no prompts).
- **Member trees are left clean.** Any step that may rewrite a tracked file
  in a member repo restores it.
- **No `api.github.com`** in provisioning paths.
- **Idempotent.** Running any script twice gives the same result as once.

## Sensitive areas — the owner merges

- The delivery path: `bin/rig-install`, `hooks/session-start.sh`, the
  marketplace and plugin manifests.
- The reviewer agent's own definition, and this file.
- Anything that widens what agents are permitted to do in member repos.

## Worth flagging, not blocking

- New external downloads (name the host; check it is reachable from a cloud
  session).
- Behaviour that differs between single- and multi-repo sessions.
