#!/usr/bin/env bash
# lib/common.sh — shared helpers for rig scripts and member .rig/setup.sh.
#
# Source it; do not execute it. Safe to source more than once.

[ -n "${_RIG_COMMON_LOADED:-}" ] && return 0
_RIG_COMMON_LOADED=1

RIG_LOCAL_BIN="${RIG_LOCAL_BIN:-$HOME/.local/bin}"
RIG_CONFIG_DIR="${RIG_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/curve-rig}"
RIG_STATE_DIR="${RIG_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/curve-rig}"
# Detailed output from tools goes here, not to stdout: a SessionStart hook's
# stdout is added to the agent's context.
RIG_LOG="${RIG_LOG:-$RIG_STATE_DIR/rig.log}"

# With RIG_LOG_COPY=1 (the hook sets it, unexported), each line is also
# appended to $RIG_LOG, so the log holds everything the hook prints.
rig_log()  { printf '[rig] %s\n' "$*"; _rig_log_copy "[rig] $*"; }
rig_warn() { printf '[rig] WARNING: %s\n' "$*" >&2; _rig_log_copy "[rig] WARNING: $*"; }
_rig_log_copy() {
    [ "${RIG_LOG_COPY:-}" = 1 ] || return 0
    printf '%s\n' "$1" >> "$RIG_LOG" 2>/dev/null || true
}

# First line of a string, without a pipe: `cmd | head -1` can SIGPIPE the
# producer and, under pipefail, turn a good result into a failure.
rig_first_line() { printf '%s\n' "${1%%$'\n'*}"; }

# Put the user-level bin directory first on PATH for this shell.
rig_ensure_path() {
    mkdir -p "$RIG_LOCAL_BIN"
    case ":$PATH:" in *":$RIG_LOCAL_BIN:"*) ;; *) PATH="$RIG_LOCAL_BIN:$PATH" ;; esac
    export PATH
}

rig_open_log() {
    mkdir -p "$(dirname "$RIG_LOG")"
    printf '\n=== %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RIG_LOG"
}

# --- Deadline -------------------------------------------------------------
# The hook runs under a timeout set at registration. Every step takes its
# timeout from what remains, so the hook finishes (and restores what it
# touched) before it is killed.

rig_deadline_init() { RIG_DEADLINE=$(( $(date +%s) + $1 )); }

# Seconds a step may take: the smaller of CAP and what remains, less a
# margin for clean-up. Prints 0 when there is no time left.
rig_step_timeout() {
    local cap="$1" left
    [ -n "${RIG_DEADLINE:-}" ] || { echo "$cap"; return; }
    left=$(( RIG_DEADLINE - $(date +%s) - 20 ))
    [ "$left" -lt 0 ] && left=0
    [ "$left" -lt "$cap" ] && echo "$left" || echo "$cap"
}

# --- Pending restores -----------------------------------------------------
# A step that rewrites a member's tracked file registers the backup here
# first; rig_restore_all puts every registered file back. Hooks trap EXIT,
# INT and TERM to it, so a killed hook still leaves trees as it found them.

RIG_RESTORE_TARGETS=()
RIG_RESTORE_BACKUPS=()

rig_restore_register() { RIG_RESTORE_TARGETS+=("$1"); RIG_RESTORE_BACKUPS+=("$2"); }

# Run a long step so that a signal to the hook is handled at once: bash
# defers traps until a foreground child exits, but `wait` is interrupted.
# rig_on_signal stops the running child before restoring.
RIG_CHILD=""
rig_run() {
    local rc=0
    "$@" &
    RIG_CHILD=$!
    wait "$RIG_CHILD" || rc=$?
    RIG_CHILD=""
    return "$rc"
}

rig_on_signal() {
    if [ -n "${RIG_CHILD:-}" ]; then
        # The child is a subshell; stop what it is running (timeout passes
        # the signal on to its command), then the subshell itself.
        pkill -TERM -P "$RIG_CHILD" 2>/dev/null || true
        kill -TERM "$RIG_CHILD" 2>/dev/null || true
    fi
    rig_restore_all
    exit 0
}

rig_restore_all() {
    local i
    for i in "${!RIG_RESTORE_TARGETS[@]}"; do
        if [ -f "${RIG_RESTORE_BACKUPS[$i]}" ]; then
            cp "${RIG_RESTORE_BACKUPS[$i]}" "${RIG_RESTORE_TARGETS[$i]}" 2>/dev/null || true
            rm -f "${RIG_RESTORE_BACKUPS[$i]}"
        fi
    done
    RIG_RESTORE_TARGETS=()
    RIG_RESTORE_BACKUPS=()
}

# --- Downloads ------------------------------------------------------------

# Download URL to FILE, bounded by the deadline.
rig_fetch() {
    local url="$1" dest="$2" t
    t="$(rig_step_timeout 300)"
    [ "$t" -gt 0 ] || { rig_warn "no time left to download $url"; return 1; }
    curl -fsSL --connect-timeout 15 --max-time "$t" -o "$dest" "$url"
}

rig_sha256_ok() {
    local actual
    actual="$(sha256sum "$1" 2>/dev/null)" || return 1
    [ "${actual%% *}" = "$2" ]
}

# linux_amd64 or linux_arm64; anything else is unsupported (cloud sessions
# are Linux, and local machines provision themselves).
rig_platform() {
    local arch
    [ "$(uname -s)" = Linux ] || return 1
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) return 1 ;;
    esac
    echo "linux_$arch"
}

# --- Repositories ---------------------------------------------------------

# Print every member candidate in the session, NUL-separated.
#
# A single-repo session starts in the repository; a multi-repo session
# starts in a non-git parent with the clones below it, sometimes one level
# deeper under an owner directory. Only real .git directories count (a
# submodule's .git is a file), and a repository nested inside another one
# found here is skipped.
rig_discover_repos() {
    local root="$1" top c a nested
    local -a cands=() accepted=()
    if top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
        printf '%s\0' "$top"
        return 0
    fi
    mapfile -d '' -t cands < <(
        find "$root" -mindepth 2 -maxdepth 3 -type d -name .git \
            -not -path '*/node_modules/*' -printf '%h\0' 2>/dev/null | sort -z
    )
    for c in "${cands[@]}"; do
        nested=0
        for a in "${accepted[@]}"; do
            case "$c/" in "$a"/*) nested=1; break ;; esac
        done
        [ "$nested" -eq 1 ] || accepted+=("$c")
    done
    [ "${#accepted[@]}" -eq 0 ] || printf '%s\0' "${accepted[@]}"
}

# Trusted GitHub owners, lower-cased, one per line. RIG_TRUSTED_OWNERS
# (comma- or space-separated) overrides the file bin/rig-install writes.
rig_trusted_owners() {
    local raw="${RIG_TRUSTED_OWNERS:-}"
    if [ -z "$raw" ] && [ -f "$RIG_CONFIG_DIR/trusted-owners" ]; then
        raw="$(cat "$RIG_CONFIG_DIR/trusted-owners")"
    fi
    printf '%s\n' "$raw" | sed 's/[, ]/\n/g' | tr '[:upper:]' '[:lower:]' | sed '/^$/d'
}

# The GitHub owner of a repository's origin, lower-cased; fails for an
# origin that is not exactly github.com/<owner>/<repo>. The path is matched
# whole: git and curl resolve dot segments, so github.com/acme/../evil/x
# fetches evil/x, and a prefix check would call it acme's.
rig_repo_owner() {
    local url path
    url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    case "$url" in
        https://github.com/*)        path="${url#https://github.com/}" ;;
        git@github.com:*)            path="${url#git@github.com:}" ;;
        ssh://git@github.com/*)      path="${url#ssh://git@github.com/}" ;;
        git+ssh://git@github.com/*)  path="${url#git+ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    [[ "$path" =~ ^([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/?$ ]] || return 1
    case "${BASH_REMATCH[2]}" in .|..|.git|..git) return 1 ;; esac
    printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
}

# A name safe to print into agent context: anything but letters, digits,
# '.', '_' and '-' becomes '?'. Directory names are chosen by whoever cloned
# them, and the hook's stdout is read by the agent.
rig_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '?'; }

# True when the repository's origin owner is in the trusted list. Code from
# any other repository — something an agent cloned to read, a vendored
# checkout — is never run.
rig_repo_trusted() {
    local owner owners
    owner="$(rig_repo_owner "$1")" || return 1
    owners="$(rig_trusted_owners)"
    grep -qxF -- "$owner" <<< "$owners"
}
