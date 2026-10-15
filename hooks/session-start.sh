#!/usr/bin/env bash
# hooks/session-start.sh — stage 2: provision the trusted repositories in
# the session.
#
# Registered by bin/rig-install as a USER-level SessionStart hook with the
# "startup" matcher, so it fires once per session in single- and multi-repo
# sessions alike (repository hooks do not fire in multi-repo sessions), and
# not again on resume, clear or compaction. Cloud only: on a dev machine it
# exits at once unless RIG_FORCE=1.
#
# Trust: only repositories whose origin is owned by a trusted GitHub owner
# (bin/rig-install --trusted-owners) are touched. Anything else in the
# session — a repo an agent cloned to read, a vendored checkout — is never
# executed.
#
# Output: one line per step on stdout (it becomes agent context); tool
# output goes to the log file. Always exits 0: a failing hook must not stop
# the session starting. Tracked files it rewrites are restored even if it
# is killed.

set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "${RIG_FORCE:-}" = 1 ] || exit 0

RIG_HOME="${RIG_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export RIG_HOME

# shellcheck source=../lib/common.sh
. "$RIG_HOME/lib/common.sh"
# shellcheck source=../lib/pins.sh
. "$RIG_HOME/lib/pins.sh"
# shellcheck source=../lib/beads.sh
. "$RIG_HOME/lib/beads.sh"

RIG_LOG="$RIG_STATE_DIR/session-start.log"
export RIG_LOG
rig_open_log

trap 'rig_restore_all' EXIT
trap 'rig_on_signal' INT TERM

# Registered with a 900s timeout; finish well inside it.
rig_deadline_init "${RIG_BUDGET:-840}"
rig_ensure_path

root="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ -z "$(rig_trusted_owners)" ]; then
    rig_log "no trusted owners configured; nothing provisioned (see bin/rig-install --help)"
    exit 0
fi

mapfile -d '' -t repos < <(rig_discover_repos "$root")
if [ "${#repos[@]}" -eq 0 ]; then
    rig_log "no repositories found under $root"
    exit 0
fi

# shellcheck disable=SC2317,SC2329  # invoked indirectly via rig_run
_rig_member_setup() {
    cd "$1" && timeout "$2" bash .rig/setup.sh </dev/null >>"$RIG_LOG" 2>&1
}

beads_ready=""
for repo in "${repos[@]}"; do
    name="$(basename "$repo")"

    if ! rig_repo_trusted "$repo"; then
        rig_log "$name: skipped (origin owner not trusted)"
        continue
    fi

    if [ -f "$repo/.rig/setup.sh" ]; then
        t="$(rig_step_timeout 900)"
        if [ "$t" -le 0 ]; then
            rig_warn "$name: no time left for .rig/setup.sh"
        elif rig_run _rig_member_setup "$repo" "$t"; then
            rig_log "$name: .rig/setup.sh ok"
        else
            rig_warn "$name: .rig/setup.sh failed (see $RIG_LOG)"
        fi
    fi

    if [ -d "$repo/.beads" ]; then
        if [ -z "$beads_ready" ]; then
            beads_ready=no
            rig_install_dolt </dev/null && rig_install_bd </dev/null && beads_ready=yes
        fi
        if [ "$beads_ready" = yes ]; then
            rig_bootstrap_beads "$repo" </dev/null || true
        else
            rig_warn "$name: has beads, but bd/dolt are unavailable"
        fi
    fi
done

exit 0
