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

Still to verify in the pilot (see `plan.md`):

- That a **public** repository can be cloned anonymously during the setup
  phase (constraint 3 concerns credentials, not network).
- That a SessionStart hook added to `~/.claude/settings.json` during the
  setup phase fires, and is not overwritten when the session launches.

## Delivery: two stages

**Stage 1 — `bin/rig-install`**, run by the environment setup script. No
GitHub credentials needed (rig is public by then). It:

- installs rig at `$RIG_HOME` (default `~/.local/share/curve-rig`);
- links the plugin's skills and agents into `~/.claude/skills` and
  `~/.claude/agents`;
- registers `hooks/session-start.sh` as a user-level SessionStart hook in
  `~/.claude/settings.json`, merging rather than overwriting.

**Stage 2 — `hooks/session-start.sh`**, a user-level SessionStart hook, so it
fires in single- and multi-repo sessions alike. Cloud only
(`CLAUDE_CODE_REMOTE=true`); on a dev machine it exits at once. It finds every
git repository in the session and, for each:

- runs the repo's `.rig/setup.sh`, if any, with `RIG_HOME` exported;
- if the repo has `.beads/`, installs `bd` and `dolt` and materialises the
  beads store from `refs/dolt/data` over https.

It always exits 0, and reports per step.

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
- **Never seed from `.beads/issues.jsonl`.** bd will hydrate an empty store
  from an export lying beside it, and the result looks healthy while being
  stale. A real store has a Dolt remote; that is the check.
- **Write:** the relay (to come). A session stages its changes to an outbox
  in the working tree, they reach the default branch through an ordinary PR,
  and a workflow applies them and pushes `refs/dolt/data`.

## Naming

- Repository: `curve-rig`. Marketplace: `curvelogic`. Plugin: `rig`, so
  skills appear as `rig:<skill>` in local sessions.
- Skills installed into `~/.claude` for cloud sessions are not namespaced,
  so their directory names carry a `rig-` prefix to avoid collisions.
