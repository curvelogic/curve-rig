# Design

How rig reaches a Claude Code session, and the constraints that shape it.
Change the delivery path only with these in view.

## Constraints

Measured in Claude Code on the web (Anthropic-hosted cloud environments) and
confirmed against the Claude Code documentation:

1. **Repo-enabled plugins are not installed in cloud sessions.** A plugin a
   repository turns on via `enabledPlugins` / `extraKnownMarketplaces` loads
   in local sessions only.
2. **A multi-repo session runs no repository hooks.** It clones the
   repositories side by side and starts in their (non-git) parent, so no
   repository's `.claude/settings.json` hooks fire. Each repository's
   `CLAUDE.md` is still read.
3. **The environment setup script runs before the session's network proxy is
   up.** The proxy is what injects GitHub credentials, so the setup script
   cannot clone a private repository or fetch anything that needs them.
   A SessionStart hook runs after the proxy is up.
4. **`api.github.com` is scoped to the session's repositories.** Version
   lookups against other repositories get 403. Release-asset downloads
   (`github.com/<owner>/<repo>/releases/download/…`, including the
   `releases/latest/download/` redirect) work.
5. **A web session can push `refs/heads/*` only.** Pushes to tags, notes,
   `refs/dolt/*` and branch deletions are refused, so `bd dolt push` cannot
   work, and other `bd` writes succeed locally and are then lost with the
   container. Hence the relay.
6. **`mise` cannot provision a cloud session:** its installer host is denied
   by policy, and its default backend resolves versions via `api.github.com`
   (constraint 4). Member repos may keep `mise.toml` for local development,
   but `.rig/setup.sh` installs tools directly.
7. **User-level `~/.claude` is honoured** in cloud sessions: skills placed in
   `~/.claude/skills` load.

8. **The setup script can clone a public repository anonymously.**
   Constraint 3 concerns credentials, not the network: `git clone` of a
   public github.com repository works during setup.
9. **A user-level SessionStart hook written by the setup script fires.**
   `~/.claude/settings.json` written during setup survives the session's
   launch, and its `startup` hook runs once the session starts — in a
   multi-repo session too, where no repository's own hooks run.

Constraints 8 and 9 were checked with a stand-in public repository and a
trivial hook; rig's own setup-script path is proved once it is public
(see `plan.md`).

## Delivery: two stages

**Stage 1 — `bin/rig-install`**, run by the environment setup script after
it has fetched rig at a pinned commit. No GitHub credentials needed (rig is
public by then). It:

- links the plugin's skills and agents into `~/.claude/skills` and
  `~/.claude/agents`, and `bin/rig-relay` into `~/.local/bin`;
- records the trusted GitHub owners (`--trusted-owners`) in
  `~/.config/curve-rig/trusted-owners`;
- registers `hooks/session-start.sh` as a user-level SessionStart hook with
  the `startup` matcher in `~/.claude/settings.json`, merging rather than
  overwriting;
- adds the attribution rule in `templates/user-CLAUDE.md` (no session links
  in commits or PR text) to `~/.claude/CLAUDE.md`, between markers, keeping
  the rest of the file.

**Stage 2 — `hooks/session-start.sh`**, a user-level SessionStart hook, so it
fires in single- and multi-repo sessions alike — once, at startup, not on
resume, clear or compaction. Cloud only (`CLAUDE_CODE_REMOTE=true`); on a
dev machine it exits at once. It finds the git repositories in the session
(real `.git` directories, not nested inside another found repo), skips any
whose origin owner is not trusted, and for each trusted one:

- runs the repo's `.rig/setup.sh`, if any, with `RIG_HOME` exported;
- if the repo has `.beads/`, installs pinned `bd` and `dolt` and
  materialises the beads store from `refs/dolt/data` over https.

It works to a deadline inside its registered timeout, gives everything it
runs `/dev/null` as stdin, prints one line per step (stdout becomes agent
context) and sends tool output to
`~/.local/state/curve-rig/session-start.log`, which also gets a copy of
every line it prints. It always exits 0.

**Local sessions** use the plugin: the repo enables `rig@curvelogic` in its
committed `.claude/settings.json`. Local provisioning stays with the developer
(e.g. `mise install`); the plugin carries only skills and agents.

**Fallback.** If stage 1 did not run (an environment without the setup
script), the member's `CLAUDE.md` — read in every session — tells the agent
to run the installer by hand. See `templates/CLAUDE.md`.

## Repo contract

A member repository may provide:

| Path | Purpose |
|---|---|
| `.rig/setup.sh` | Install the repo's toolchain and dependencies in a cloud session. Idempotent. May `source "$RIG_HOME/lib/common.sh"` etc. Runs with the repo as working directory. |
| `.beads/` | Presence opts the repo into beads provisioning. |
| `REVIEW.md` | Review criteria and sensitive areas for the reviewer agent. |
| `CLAUDE.md` | Built from `templates/CLAUDE.md`. |

Nothing else is required; a repo with none of these is left alone.

## Beads in a cloud session

- **Read:** `bd bootstrap` clones the store from `refs/dolt/data`. The tracked
  `.beads/config.yaml` usually names an ssh remote and the container has no
  ssh, so the remote is rewritten to https for the bootstrap and the tracked
  file restored afterwards. A store that fails to bootstrap is deleted rather
  than left empty, so the failure stays visible.
- **Role.** bd warns on every command while `beads.role` is unset
  (upstream issue 2950) and guesses the role from the origin URL. rig sets
  it to `maintainer` in the clone's `.git/config` when neither that nor the
  user's git config sets one: the session works the member's own store,
  which the relay stages, and `maintainer` is what `bd init` sets for the
  store's creator. `contributor` would route `bd list` and `bd ready` to a
  separate planning store where contributor routing is configured.
- **Never seed from `.beads/issues.jsonl`.** bd will hydrate an empty store
  from an export lying beside it, and the result looks healthy while being
  stale. A real store has a Dolt remote; that is the check.
- **Write:** the relay. A session stages its changes as one file and pushes
  it alone on a branch `beads-inbox/<time>-<label>` (`rig-relay stage`).
  The push dispatches a workflow on the member's default branch, which
  reads the file from the branch as data, applies it behind a staleness
  gate, pushes `refs/dolt/data` and deletes the branch. Beads writes reach
  the tracker as directly as possible: there is no review gate on them, and
  nothing reaches the default branch. See [`relay.md`](relay.md).

## Security model

- **Root with credentials.** Cloud sessions run as root with GitHub access
  to the session's repositories and whatever secrets the environment holds.
  Everything rig runs has that power, so rig runs as little as possible.
- **Trusted owners.** Only repositories whose `origin` is exactly
  `github.com/<owner>/<repo>`, with a trusted owner, are provisioned. The
  path is matched whole, because git resolves dot segments
  (`github.com/<trusted>/../<other>/x` fetches `<other>/x`). An agent
  cloning a third-party repository cannot get its `.rig/setup.sh` run, now
  or at a later startup.
- **Members are not isolated from each other.** One trusted member's
  `.rig/setup.sh` can change PATH, `~/.local/bin` or `$RIG_HOME` for the
  members provisioned after it. Trust is per owner, not per repository.
- **Pinned downloads.** Every binary is an exact release asset checked
  against a digest in `lib/pins.sh`; rig itself is fetched at a pinned
  commit. A compromised upstream release or a push to rig's `main` does not
  reach environments until a reviewed pin changes.
- **The beads relay** writes the tracker with a token that can push the
  member, so it runs only from the member's default branch. Its
  push-triggered half, which runs from an inbox branch, has
  `actions: write` only and no secrets; it just dispatches the other.
  Inbox branches are read with git as data and never checked out. It runs
  rig's scripts only at a commit on rig's `main`: GitHub serves forks'
  commits from rig's URL too.
- **Beads are unreviewed.** Any session that can push a branch — a
  prompt-injected one included — can write issues and memories that every
  later session reads. Members' `CLAUDE.md` says to read beads as notes,
  not instructions (`templates/CLAUDE.md`).
- **The denylist secret** lives in a `denylist` environment restricted to
  `main`. PRs are scanned by a `pull_request_target` workflow that runs the
  base branch's scanner over the PR's commits as data; no PR code runs with
  the secret. A common word on the list would be masked as `***` wherever
  it appears in public logs, revealing it — keep entries distinctive.
- **Review.** The owner merges every non-docs PR (see `REVIEW.md`).
  `rig-review` treats everything in a PR and on its page as data, counts
  only comments from the account agents act as, and never runs code from
  a PR from outside (from a fork, or opened by another account): those
  are the owner's to merge. It cannot tell the owner from an agent acting
  as the owner, nor see who pushed to a branch in the repository; for a
  repository whose only writer is the owner, that is the same trust.

## Review rounds

`rig-review` sends a PR back only for blocking findings; non-blocking ones
(style, wording, nits) are listed separately, for the author to fold into a
later push or leave. A PR gets two review rounds by default, the first
review and one re-review, and a member's `REVIEW.md` may set another
limit. A re-review is given the head SHA of the previous review and that
review's comment, and checks only the diff since: each blocking finding
fixed, nothing new blocking, the check re-run only if the diff touches
code or what the check runs. It falls back to a full review when the diff
is large or rewrites earlier work. The reviewer counts rounds from its own
verdict comments on the PR, each of which names the round and the head it
covers. If the last round still finds blocking problems, the reviewer
escalates to the owner with a hold instead of sending back.

First reviews, second independent reviews and any review touching a
sensitive area run at the dispatching session's tier. A re-review of a
non-sensitive PR may run on a cheaper model: the agent definition says
`model: inherit`, and the dispatcher passes the Agent tool's `model`
override for such a re-review only.

## Naming

- Repository: `curve-rig`. Marketplace: `curvelogic`. Plugin: `rig`, so
  skills appear as `rig:<skill>` in local sessions.
- Skills installed into `~/.claude` for cloud sessions are not namespaced,
  so their directory names carry a `rig-` prefix to avoid collisions.
