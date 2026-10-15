#!/usr/bin/env bash
# hooks/session-start.sh — stage 2: provision every repository in the session.
#
# Registered as a USER-level SessionStart hook by bin/rig-install, so it
# fires in single- and multi-repo sessions alike (repository hooks do not
# fire in multi-repo sessions). Cloud only: on a dev machine it exits at once
# unless RIG_FORCE=1.
#
# Always exits 0: a failing hook must not stop the session starting. Each
# step reports its own outcome instead.

set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "${RIG_FORCE:-}" = 1 ] || exit 0

RIG_HOME="${RIG_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export RIG_HOME

# shellcheck source=../lib/common.sh
. "$RIG_HOME/lib/common.sh"
# shellcheck source=../lib/beads.sh
. "$RIG_HOME/lib/beads.sh"

rig_ensure_path

repos="$(rig_discover_repos "${CLAUDE_PROJECT_DIR:-$PWD}")"
if [ -z "$repos" ]; then
    rig_log "no repositories found under ${CLAUDE_PROJECT_DIR:-$PWD}"
    exit 0
fi

beads_ready=""
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    name="$(basename "$repo")"

    if [ -f "$repo/.rig/setup.sh" ]; then
        rig_log "$name: running .rig/setup.sh"
        if ! ( cd "$repo" && timeout 900 bash .rig/setup.sh ); then
            rig_warn "$name: .rig/setup.sh failed"
        fi
    fi

    if [ -d "$repo/.beads" ]; then
        if [ -z "$beads_ready" ]; then
            beads_ready=no
            rig_install_dolt && rig_install_bd && beads_ready=yes
        fi
        if [ "$beads_ready" = yes ]; then
            rig_bootstrap_beads "$repo" || true
        else
            rig_warn "$name: has beads, but bd/dolt are unavailable"
        fi
    fi
done <<< "$repos"

exit 0
