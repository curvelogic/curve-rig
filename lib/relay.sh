#!/usr/bin/env bash
# lib/relay.sh — the beads relay: stage a session's beads changes as a file
# in the working tree, and apply staged files to the store from CI.
#
# A cloud session can push refs/heads/* only, so `bd dolt push` cannot work
# there and every other bd write is lost with the container (design.md,
# constraint 5). The session stages its changes to .beads/inbox/ instead;
# they reach the default branch through an ordinary reviewed PR; a workflow
# (.github/workflows/beads-relay.yml) applies them and pushes refs/dolt/data.
# See docs/relay.md.
#
# Source it after lib/common.sh (and, to apply, lib/beads.sh). Used through
# bin/rig-relay.

[ -n "${_RIG_RELAY_LOADED:-}" ] && return 0
_RIG_RELAY_LOADED=1

RIG_RELAY_INBOX=".beads/inbox"

# The embedded Dolt database of a repo's beads store, e.g.
# .beads/embeddeddolt/<name>. Fails if there is none, or more than one.
rig_relay_doltdir() {
    local -a found=()
    mapfile -d '' -t found < <(
        find "$1/.beads/embeddeddolt" -mindepth 2 -maxdepth 2 -name .dolt -type d \
            -printf '%h\0' 2>/dev/null
    )
    case "${#found[@]}" in
        1) printf '%s\n' "${found[0]}" ;;
        0) rig_warn "no materialised beads store in $1/.beads/embeddeddolt"; return 1 ;;
        *) rig_warn "more than one database in $1/.beads/embeddeddolt"; return 1 ;;
    esac
}

# A safe file-name fragment from a free-text label.
_rig_relay_label() {
    local l
    l="$(printf '%s' "${1:-session}" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
    l="${l#[.-]}"
    printf '%s\n' "${l:-session}"
}

# Issue ids whose exported record differs between commit BASE and the
# working set, and memory keys likewise, printed as "issue <id>" and
# "memory <key>" lines. Rows are compared by content, not by row identity:
# bd's schema migrations rewrite every row of a table, or re-key comments,
# so a plain dolt_diff would report the whole tracker as changed. An issue's
# own row counts as changed when its updated_at moved (every bd write to an
# issue bumps it); its comments, labels and dependencies, which export
# inside its record, count when one was added or removed.
_rig_relay_changes() {
    local doltdir="$1" b="$2"
    ( cd "$doltdir" && dolt sql -r csv -q "
select 'issue', w.id from issues w
 where not exists (select 1 from issues as of '$b' o
                    where o.id = w.id and o.updated_at <=> w.updated_at)
union select 'issue', w.issue_id from comments w
 where not exists (select 1 from comments as of '$b' o
                    where o.issue_id = w.issue_id and o.text <=> w.text
                      and o.created_at <=> w.created_at)
union select 'issue', o.issue_id from comments as of '$b' o
 where not exists (select 1 from comments w
                    where o.issue_id = w.issue_id and o.text <=> w.text
                      and o.created_at <=> w.created_at)
union select 'issue', w.issue_id from dependencies w
 where not exists (select 1 from dependencies as of '$b' o
                    where o.issue_id = w.issue_id and o.type <=> w.type
                      and o.depends_on_issue_id <=> w.depends_on_issue_id)
union select 'issue', o.issue_id from dependencies as of '$b' o
 where not exists (select 1 from dependencies w
                    where o.issue_id = w.issue_id and o.type <=> w.type
                      and o.depends_on_issue_id <=> w.depends_on_issue_id)
union select 'issue', w.issue_id from labels w
 where not exists (select 1 from labels as of '$b' o
                    where o.issue_id = w.issue_id and o.label = w.label)
union select 'issue', o.issue_id from labels as of '$b' o
 where not exists (select 1 from labels w
                    where o.issue_id = w.issue_id and o.label = w.label)
union select 'memory', substring(w.\`key\`, 11) from config w
 where w.\`key\` like 'kv.memory.%'
   and not exists (select 1 from config as of '$b' o
                    where o.\`key\` = w.\`key\` and o.value <=> w.value)
union select 'gone-issue', o.id from issues as of '$b' o
 where not exists (select 1 from issues w where w.id = o.id)
union select 'gone-memory', substring(o.\`key\`, 11) from config as of '$b' o
 where o.\`key\` like 'kv.memory.%'
   and not exists (select 1 from config w where w.\`key\` = o.\`key\`)
" </dev/null ) | tail -n +2 | sed '/^$/d' | tr ',' ' ' | sort -u
}

# Stage this session's beads changes in REPO as one JSONL file under
# .beads/inbox/, named by time and LABEL. Prints the file staged, or says
# there was nothing to stage. Diffs against the merge base of the local
# store and the remote's history, so a row the remote changed underneath
# the session is never staged with this store's stale values.
rig_relay_stage() {
    local repo="$1" label doltdir base changes ids mems out tmp stamp n
    label="$(_rig_relay_label "${2:-}")"
    command -v bd >/dev/null 2>&1 || { rig_warn "bd is not on PATH"; return 1; }
    command -v dolt >/dev/null 2>&1 || { rig_warn "dolt is not on PATH"; return 1; }
    doltdir="$(rig_relay_doltdir "$repo")" || return 1

    # A store bootstrapped from the remote has an origin remote; one hydrated
    # from a stray issues.jsonl does not, and has no shared history to diff.
    if ! ( cd "$doltdir" && dolt remote -v </dev/null 2>/dev/null ) | grep -q '^origin[[:space:]]'; then
        rig_warn "the beads store has no origin remote, so it was not bootstrapped" \
            "from the tracker and its rows are not the tracker's. Nothing staged."
        return 1
    fi
    # A fresh bootstrap has no remotes/origin/main until something fetches.
    if ! ( cd "$doltdir" && timeout 120 dolt fetch origin </dev/null >/dev/null 2>&1 ); then
        if ( cd "$doltdir" && dolt branch -a </dev/null 2>/dev/null ) | grep -q 'remotes/origin/main$'; then
            rig_warn "dolt fetch failed; diffing against the last-fetched remote state"
        else
            rig_warn "dolt fetch failed and there is no remotes/origin/main to diff" \
                "against. Nothing staged; check the network and retry."
            return 1
        fi
    fi
    base="$(cd "$doltdir" && dolt merge-base main remotes/origin/main </dev/null 2>/dev/null)"
    [[ "$base" =~ ^[0-9a-v]{32}$ ]] || {
        rig_warn "no merge base between main and remotes/origin/main"; return 1; }

    changes="$(_rig_relay_changes "$doltdir" "$base")" || {
        rig_warn "could not compute the store's changes"; return 1; }
    while read -r kind key; do
        case "$kind" in
            gone-issue)  rig_warn "issue $key was deleted locally; the relay cannot carry deletions" ;;
            gone-memory) rig_warn "memory $key was forgotten locally; the relay cannot carry deletions" ;;
        esac
    done <<< "$changes"
    ids="$(sed -n 's/^issue //p' <<< "$changes")"
    mems="$(sed -n 's/^memory //p' <<< "$changes")"
    if [ -z "$ids" ] && [ -z "$mems" ]; then
        echo "No beads changes to relay."
        return 0
    fi

    tmp="$(mktemp)"
    if ! ( cd "$repo" && bd export --all -o "$tmp" </dev/null >/dev/null 2>&1 ); then
        rm -f "$tmp"; rig_warn "bd export failed"; return 1
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    out="$RIG_RELAY_INBOX/$stamp-$label.jsonl"
    mkdir -p "$repo/$RIG_RELAY_INBOX"
    [ -e "$repo/$RIG_RELAY_INBOX/README.md" ] || cat > "$repo/$RIG_RELAY_INBOX/README.md" <<'README'
# Beads inbox

Beads changes staged by cloud sessions, which cannot push the store
themselves. Each file is applied by the `beads relay` workflow when it
reaches the default branch, and then removed. Do not edit or add files by
hand: stage them with `rig-relay stage`. See curve-rig's `docs/relay.md`.
README
    if ! jq -c --arg ids "$ids" --arg mems "$mems" '
            ($ids | split("\n") | map(select(. != ""))) as $i
          | ($mems | split("\n") | map(select(. != ""))) as $m
          | select(if ._type == "memory" then (.key as $k | $m | index($k))
                   else (.id as $k | $k != null and ($i | index($k))) end)
        ' "$tmp" > "$repo/$out.tmp"; then
        rm -f "$tmp" "$repo/$out.tmp"; rig_warn "could not filter the export"; return 1
    fi
    rm -f "$tmp"

    # Every changed issue must be in the export; a silent gap is lost work.
    local missing
    missing="$(jq -r --arg ids "$ids" '
        [inputs | .id // empty] as $have
        | $ids | split("\n") | map(select(. != "" and (. as $x | $have | index($x) | not)))
        | .[]' -n "$repo/$out.tmp")"
    if [ -n "$missing" ]; then
        rm -f "$repo/$out.tmp"
        rig_warn "changed issues missing from bd's export:" $missing
        return 1
    fi
    mv "$repo/$out.tmp" "$repo/$out"
    n="$(wc -l < "$repo/$out" | tr -d ' ')"
    echo "Staged $n record(s) in $out"
}

# Fail, naming them, if any record in the given deltas is older than the
# store: bd import is an upsert, so applying it would silently reinstate
# stale values. Also refuses a record that is not JSON, or has no id (an
# issue) or key (a memory). Memories carry no timestamp and are not gated.
rig_relay_gate() {
    local repo="$1"; shift
    local store out
    store="$(mktemp)"
    if ! ( cd "$repo" && bd export --all -o "$store" </dev/null >/dev/null 2>&1 ); then
        rm -f "$store"; rig_warn "bd export failed"; return 1
    fi
    if ! out="$(jq -n -r --slurpfile store "$store" '
            ($store | map(select(.id != null) | {(.id): (.updated_at // "")}) | add // {}) as $s
          | [inputs] as $d
          | [ $d[] | select(._type != "memory" and (.id == null or .id == "")) ] as $bad
          | [ $d[] | select(._type == "memory" and (.key == null or .key == "")) ] as $badm
          | [ $d[] | select(.id != null and $s[.id] != null
                            and $s[.id] > (.updated_at // "")) ] as $stale
          | if ($bad | length) > 0 or ($badm | length) > 0 then
                "REFUSED: \($bad | length + ($badm | length)) record(s) without an id or key"
            elif ($stale | length) > 0 then
                "REFUSED: the store has moved on since these were staged:",
                ($stale[] | "  \(.id): staged \(.updated_at // "?") < store \($s[.id])")
            else "ok \($d | length)" end
        ' "$@" 2>&1)"; then
        rm -f "$store"
        rig_warn "a delta is not valid JSONL: $out"
        return 1
    fi
    rm -f "$store"
    case "$out" in
        "ok "*) echo "Staleness gate passed: ${out#ok } record(s) in $# delta(s)." ;;
        *) printf '%s\n' "$out"
           echo "Re-stage from a freshly bootstrapped store and retry."
           return 1 ;;
    esac
}

# Apply every delta in REPO's inbox to its store, behind the staleness
# gate, and push refs/dolt/data unless RIG_RELAY_NO_PUSH=1. Writes the
# applied file names, one per line, to $RIG_RELAY_APPLIED if it is set.
rig_relay_apply() {
    local repo="$1" d
    local -a deltas=()
    mapfile -t deltas < <(cd "$repo" && find "$RIG_RELAY_INBOX" -maxdepth 1 -type f \
        -name '*.jsonl' 2>/dev/null | LC_ALL=C sort)
    if [ "${#deltas[@]}" -eq 0 ]; then
        echo "Inbox empty; nothing to apply."
        return 0
    fi
    printf 'Queued: %s\n' "${deltas[@]}"
    ( cd "$repo" && rig_relay_gate "$repo" "${deltas[@]}" ) || return 1
    for d in "${deltas[@]}"; do
        echo "Importing $d"
        ( cd "$repo" && bd import "$d" </dev/null ) || { rig_warn "bd import failed on $d"; return 1; }
    done
    # bd may already have committed each write; nothing to commit is fine.
    ( cd "$repo" && bd dolt commit -m "beads relay: apply ${#deltas[@]} delta(s)" </dev/null ) || true
    if [ "${RIG_RELAY_NO_PUSH:-}" = 1 ]; then
        echo "RIG_RELAY_NO_PUSH=1: not pushing."
    else
        rig_beads_config_https "$repo"
        ( cd "$repo" && bd dolt push </dev/null ) || {
            rig_restore_all; rig_warn "bd dolt push failed"; return 1; }
        rig_restore_all
    fi
    [ -z "${RIG_RELAY_APPLIED:-}" ] || printf '%s\n' "${deltas[@]}" > "$RIG_RELAY_APPLIED"
    echo "Applied ${#deltas[@]} delta(s)."
}
