#!/usr/bin/env bash
# lib/common.sh — shared helpers for rig scripts and member .rig/setup.sh.
#
# Source it; do not execute it. Safe to source more than once.

[ -n "${_RIG_COMMON_LOADED:-}" ] && return 0
_RIG_COMMON_LOADED=1

RIG_LOCAL_BIN="${RIG_LOCAL_BIN:-$HOME/.local/bin}"

rig_log()  { printf '[rig] %s\n' "$*"; }
rig_warn() { printf '[rig] WARNING: %s\n' "$*" >&2; }

# First line of a string, without a pipe: `cmd | head -1` can SIGPIPE the
# producer and, under pipefail, turn a good result into a failure.
rig_first_line() { printf '%s\n' "${1%%$'\n'*}"; }

# Put the usual user-level bin directories on PATH for this shell.
rig_ensure_path() {
    mkdir -p "$RIG_LOCAL_BIN"
    case ":$PATH:" in *":$RIG_LOCAL_BIN:"*) ;; *) PATH="$RIG_LOCAL_BIN:$PATH" ;; esac
    case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) PATH="$PATH:$HOME/go/bin" ;; esac
    export PATH
}

# Print every git work tree in the session, one per line.
#
# A single-repo session starts in the repository; a multi-repo session starts
# in a non-git parent with the clones below it (sometimes one level deeper,
# under an owner directory). Look at the start directory and two levels down.
rig_discover_repos() {
    local root="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    if git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$root" rev-parse --show-toplevel
        return 0
    fi
    find "$root" -mindepth 2 -maxdepth 3 -name .git \
        -not -path '*/node_modules/*' -printf '%h\n' 2>/dev/null | sort -u
}

# Download a release asset to stdout. Bounded so a stalled transfer cannot
# hang the session.
rig_fetch() {
    curl -fsSL --connect-timeout 15 --max-time 300 "$1"
}
