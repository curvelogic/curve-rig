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
| `hooks/session-start.sh` | Provisions every repo in the session: runs its `.rig/setup.sh`, installs `bd`/`dolt`, materialises the beads store. |
| `lib/` | Shell functions repos can source from their own `.rig/setup.sh`. |
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

Full account: [`docs/design.md`](docs/design.md).

## Using rig in a cloud environment

In the environment's setup script:

```bash
git clone --depth 1 https://github.com/curvelogic/curve-rig "$HOME/.local/share/curve-rig"
"$HOME/.local/share/curve-rig/bin/rig-install"
```

## Using rig locally

In the member repo's committed `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "curvelogic": {
      "source": { "source": "github", "repo": "curvelogic/curve-rig", "ref": "<tag>" }
    }
  },
  "enabledPlugins": { "rig@curvelogic": true }
}
```

## Making a repo a member

- Add `.rig/setup.sh` if the repo needs a toolchain beyond the base image.
  It may source `$RIG_HOME/lib/*.sh`. See `docs/design.md` → *Repo contract*.
- Start `CLAUDE.md` and `REVIEW.md` from `templates/`.
- If it uses beads, nothing else is needed: a `.beads/` directory is detected.

## Status

Scaffolding. What exists and what comes next: [`docs/plan.md`](docs/plan.md).
