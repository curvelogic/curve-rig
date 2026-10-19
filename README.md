# curve-rig

Shared agent scaffolding for a family of repositories developed largely by
Claude Code agents. It makes a cloud session in any member repo come up
provisioned, gives every repo the same reviewer and the same beads workflow,
and keeps the per-repo instruction files from drifting apart.

What it is **not**: application code. Shared libraries, auth modules and
deploy pipelines for the apps themselves live elsewhere.

## Contents

| Part | What it does |
|---|---|
| `bin/rig-install` | Installs rig into `~/.claude` — the user-level skills, agents and SessionStart hook. Run by a cloud environment's setup script. |
| `hooks/session-start.sh` | Provisions every trusted repo in the session: runs its `.rig/setup.sh`, installs pinned `bd`/`dolt`, materialises the beads store. |
| `bin/rig-relay` | The beads relay: a session stages its beads writes as a file and pushes it on an inbox branch; a member's workflow applies it. |
| `.github/workflows/beads-relay.yml` | The relay's reusable workflow, called by each beads-using member. |
| `lib/` | Shell functions repos can source from their own `.rig/setup.sh`; `lib/pins.sh` pins every download. |
| `plugins/rig/` | The Claude Code plugin: skills and agents, for local sessions. |
| `templates/` | Skeletons for a member repo's `CLAUDE.md` and `REVIEW.md`. |
| `docs/design.md` | Why it is shaped like this — read before changing delivery. |

## How it reaches a session

Cloud sessions do not install plugins that a repository enables, and a session
with several repositories runs none of their hooks. So rig is delivered in two
stages that do not depend on any repository's settings:

1. **Environment setup script** (before the session starts):
   `rig-install` puts rig's skills, agents and a user-level SessionStart hook
   into `~/.claude`.
2. **SessionStart hook** (once the session's network proxy is up): provisions
   each repository present.

Local sessions use the plugin instead: see *Using rig locally*.

A cloud session can read the beads tracker but cannot write it: it can push
branches only, and beads lives on another ref. Its beads writes reach the
tracker through the relay — staged as a file, pushed on an inbox branch,
applied by CI. Why, and how: [`docs/relay.md`](docs/relay.md).

Full account: [`docs/design.md`](docs/design.md).

## Using rig in a cloud environment

In the environment's setup script, pinned to a reviewed commit, naming the
GitHub owners whose repositories rig may provision:

```bash
RIG_REF=<full commit SHA>
RIG_HOME="$HOME/.local/share/curve-rig"
git init -q "$RIG_HOME"
git -C "$RIG_HOME" fetch -q --depth 1 https://github.com/curvelogic/curve-rig "$RIG_REF"
git -C "$RIG_HOME" checkout -q FETCH_HEAD
# GitHub serves forks' commits from this URL too: insist on one on main.
git -C "$RIG_HOME" fetch -q https://github.com/curvelogic/curve-rig main
git -C "$RIG_HOME" merge-base --is-ancestor "$RIG_REF" FETCH_HEAD || exit 1
"$RIG_HOME/bin/rig-install" --trusted-owners acme
```

Repositories owned by anyone else are never touched — including ones an
agent clones during the session.

## Using rig locally

In the member repo's committed `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "curvelogic": {
      "source": { "source": "github", "repo": "curvelogic/curve-rig", "ref": "<release tag>" }
    }
  },
  "enabledPlugins": { "rig@curvelogic": true }
}
```

Tags are protected by a ruleset (no updates, no deletion), so a release
tag cannot be moved under you.

## Making a repo a member

- Add `.rig/setup.sh` if the repo needs a toolchain beyond the base image.
  It may source `$RIG_HOME/lib/*.sh`. See `docs/design.md` → *Repo contract*.
- Start `CLAUDE.md` and `REVIEW.md` from `templates/`.
- If it uses beads, a `.beads/` directory is detected for provisioning; to
  keep writes from cloud sessions, add the relay workflows
  ([`docs/relay.md`](docs/relay.md) → *Adopting it*).

## Status

Scaffolding. What exists and what comes next: [`docs/plan.md`](docs/plan.md).
