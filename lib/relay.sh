#!/usr/bin/env bash
# lib/relay.sh — the beads relay: stage a session's beads changes as a file
# and push it on an inbox branch, and apply inbox branches to the store from
# CI.
#
# A cloud session can push refs/heads/* only, so `bd dolt push` cannot work
# there and every other bd write is lost with the container (design.md,
# constraint 5). The session stages its changes as one file and pushes it,
# alone, on a branch beads-inbox/<time>-<label>. A workflow run from the
# default branch (.github/workflows/beads-relay.yml) reads that file as
# data, applies it and pushes refs/dolt/data. See docs/relay.md.
#
# Source it after lib/common.sh (and, to apply, lib/beads.sh). Used through
# bin/rig-relay.

[ -n "${_RIG_RELAY_LOADED:-}" ] && return 0
_RIG_RELAY_LOADED=1

RIG_RELAY_INBOX=".beads/inbox"
RIG_RELAY_PREFIX="beads-inbox/"
# <time>-<label>: the name of an inbox branch after the prefix, and of the
# one file it adds under the inbox.
RIG_RELAY_NAME_RE='^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_][A-Za-z0-9_-]{0,39}$'
RIG_RELAY_MAX_BYTES=$(( 16 * 1024 * 1024 ))

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

# A safe file- and branch-name fragment from a free-text label. No dots:
# a branch name may not hold "..", or end in ".lock".
_rig_relay_label() {
    local l
    l="$(printf '%s' "${1:-session}" | tr -c 'A-Za-z0-9_-' '-' | sed 's/^-*//' | cut -c1-40)"
    printf '%s\n' "${l:-session}"
}

# What changed between commit BASE and the working set, as tab-separated
# "<kind>\t<id or key>" lines. Rows are compared by content, not by row
# identity: bd's schema migrations rewrite every row of a table, or re-key
# comments, so a plain dolt_diff would report the whole tracker as changed.
#
#   issue        the issue's own row changed (every bd write to an issue
#                bumps updated_at), or it gained a comment, label or
#                dependency (those export inside its record)
#   memory       a memory was added or its value changed
#   lost-*       a change the relay cannot carry: bd import merges a
#                record's labels, dependencies and comments rather than
#                replacing them, and cannot delete issues or memories
_rig_relay_changes() {
    local doltdir="$1" b="$2"
    ( cd "$doltdir" && dolt sql -r json -q "
select 'issue' as kind, w.id as k from issues w
 where not exists (select 1 from issues as of '$b' o
                    where o.id = w.id and o.updated_at <=> w.updated_at)
union select 'issue', w.issue_id from comments w
 where not exists (select 1 from comments as of '$b' o
                    where o.issue_id = w.issue_id and o.text <=> w.text
                      and o.created_at <=> w.created_at)
union select 'issue', w.issue_id from dependencies w
 where not exists (select 1 from dependencies as of '$b' o
                    where o.issue_id = w.issue_id and o.type <=> w.type
                      and o.depends_on_issue_id <=> w.depends_on_issue_id)
union select 'issue', w.issue_id from labels w
 where not exists (select 1 from labels as of '$b' o
                    where o.issue_id = w.issue_id and o.label = w.label)
union select 'memory', substring(w.\`key\`, 11) from config w
 where w.\`key\` like 'kv.memory.%'
   and not exists (select 1 from config as of '$b' o
                    where o.\`key\` = w.\`key\` and o.value <=> w.value)
union select 'lost-comment', o.issue_id from comments as of '$b' o
 where not exists (select 1 from comments w
                    where o.issue_id = w.issue_id and o.text <=> w.text
                      and o.created_at <=> w.created_at)
union select 'lost-dependency', concat(o.issue_id, ' -> ', o.depends_on_issue_id)
  from dependencies as of '$b' o
 where not exists (select 1 from dependencies w
                    where o.issue_id = w.issue_id and o.type <=> w.type
                      and o.depends_on_issue_id <=> w.depends_on_issue_id)
union select 'lost-label', concat(o.issue_id, ' ', o.label) from labels as of '$b' o
 where not exists (select 1 from labels w
                    where o.issue_id = w.issue_id and o.label = w.label)
union select 'lost-issue', o.id from issues as of '$b' o
 where not exists (select 1 from issues w where w.id = o.id)
union select 'lost-memory', substring(o.\`key\`, 11) from config as of '$b' o
 where o.\`key\` like 'kv.memory.%'
   and not exists (select 1 from config w where w.\`key\` = o.\`key\`)
" </dev/null ) | jq -r '.rows[]? | [.kind, .k] | @tsv' | LC_ALL=C sort -u
}

# Stage this session's beads changes in REPO as one JSONL file under
# .beads/inbox/, named by time and LABEL, and push it on an inbox branch
# (rig_relay_push) unless RIG_RELAY_NO_BRANCH=1. Says what it staged, or
# that there was nothing to stage. Diffs against the merge base of the local
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
    local kind key lost=0
    while IFS=$'\t' read -r kind key; do
        case "$kind" in
            lost-issue)      rig_warn "not carried: issue $key was deleted"; lost=1 ;;
            lost-memory)     rig_warn "not carried: memory $key was forgotten"; lost=1 ;;
            lost-label)      rig_warn "not carried: label removed ($key)"; lost=1 ;;
            lost-dependency) rig_warn "not carried: dependency removed ($key)"; lost=1 ;;
            lost-comment)    rig_warn "not carried: a comment on $key was removed or edited"; lost=1 ;;
        esac
    done <<< "$changes"
    [ "$lost" -eq 0 ] || rig_warn "the relay merges records and cannot remove;" \
        "make the changes above from a session that can push the store."
    ids="$(sed -n 's/^issue\t//p' <<< "$changes")"
    mems="$(sed -n 's/^memory\t//p' <<< "$changes")"
    if [ -z "$ids" ] && [ -z "$mems" ]; then
        echo "No beads changes to relay."
        return 0
    fi

    tmp="$(mktemp)"
    if ! ( cd "$repo" && timeout 120 bd export --all -o "$tmp" </dev/null >/dev/null 2>&1 ); then
        rm -f "$tmp"; rig_warn "bd export failed"; return 1
    fi
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    out="$RIG_RELAY_INBOX/$stamp-$label.jsonl"
    mkdir -p "$repo/$RIG_RELAY_INBOX"
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
        rig_warn "changed issues missing from bd's export: $(tr '\n' ' ' <<< "$missing")"
        return 1
    fi
    mv "$repo/$out.tmp" "$repo/$out"
    n="$(wc -l < "$repo/$out" | tr -d ' ')"
    echo "Staged $n record(s) in $out"
    [ "${RIG_RELAY_NO_BRANCH:-}" = 1 ] && return 0
    rig_relay_push "$repo" "$out"
}


# The member's default branch: $RIG_RELAY_DEFAULT_BRANCH, else what origin
# says its HEAD is, else origin/HEAD as last fetched.
rig_relay_default_branch() {
    local repo="$1" b=""
    if [ -n "${RIG_RELAY_DEFAULT_BRANCH:-}" ]; then
        printf '%s\n' "$RIG_RELAY_DEFAULT_BRANCH"; return 0
    fi
    b="$(cd "$repo" && timeout 60 git ls-remote --symref origin HEAD </dev/null 2>/dev/null |
        sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p')" || true
    [ -n "$b" ] || b="$(cd "$repo" && git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)" || true
    b="${b#origin/}"
    [ -n "$b" ] || { rig_warn "cannot tell the default branch of $repo's origin"; return 1; }
    printf '%s\n' "$b"
}

# Remove a delta this run staged and pushed, and the inbox directory if
# that leaves it empty.
_rig_relay_unstage() {
    rm -f -- "${1:?}/${2:?}"
    rmdir -- "${1:?}/$RIG_RELAY_INBOX" 2>/dev/null || true
}

# Push the staged delta named by FILE (.beads/inbox/<time>-<label>.jsonl in
# REPO) as the only change on a new branch beads-inbox/<time>-<label>,
# based on the default branch. Builds the commit with a scratch index, so
# the working tree, index and HEAD are left alone, then removes the staged
# file: it must not ride in the session's own PRs. Safe to re-run: a branch
# that already holds this file is success.
rig_relay_push() {
    local repo="$1" name path branch def tip blob tree commit tmp have
    local -a ident=()
    name="$(basename -- "$2" .jsonl)"
    path="$RIG_RELAY_INBOX/$name.jsonl"
    if ! [[ "$name" =~ $RIG_RELAY_NAME_RE ]] || [ ! -f "$repo/$path" ]; then
        rig_warn "not a staged delta: $2 (expected $RIG_RELAY_INBOX/<time>-<label>.jsonl)"
        return 1
    fi
    branch="$RIG_RELAY_PREFIX$name"
    def="$(rig_relay_default_branch "$repo")" || return 1
    ( cd "$repo" && timeout 120 git fetch -q --no-tags origin "refs/heads/$def" </dev/null ) || {
        rig_warn "could not fetch $def; retry with: rig-relay push $path"; return 1; }
    tip="$(cd "$repo" && git rev-parse --verify -q 'FETCH_HEAD^{commit}')" || {
        rig_warn "could not resolve $def"; return 1; }
    blob="$(cd "$repo" && git hash-object -w -- "$path")"

    have="$(cd "$repo" && timeout 60 git ls-remote origin "refs/heads/$branch" </dev/null)" || {
        rig_warn "could not reach origin; retry with: rig-relay push $path"; return 1; }
    if [ -n "$have" ]; then
        if ( cd "$repo" && timeout 120 git fetch -q --no-tags origin "refs/heads/$branch" </dev/null ) &&
           [ "$(cd "$repo" && git rev-parse -q --verify "FETCH_HEAD:$path" 2>/dev/null)" = "$blob" ]; then
            _rig_relay_unstage "$repo" "$path"
            echo "Already pushed: $branch"
            return 0
        fi
        rig_warn "$branch already exists with other content; stage again for a new name"
        return 1
    fi

    # commit-tree needs an identity; supply one only if git has none.
    ( cd "$repo" && git var GIT_COMMITTER_IDENT >/dev/null 2>&1 ) ||
        ident=(GIT_AUTHOR_NAME="beads relay" GIT_AUTHOR_EMAIL="beads-relay@users.noreply.github.com"
               GIT_COMMITTER_NAME="beads relay" GIT_COMMITTER_EMAIL="beads-relay@users.noreply.github.com")
    tmp="$(mktemp -d)"
    tree="$(cd "$repo" && export GIT_INDEX_FILE="$tmp/index" &&
            git read-tree "$tip" &&
            git update-index --add --cacheinfo "100644,$blob,$path" &&
            git write-tree)" || tree=""
    rm -rf -- "${tmp:?}"
    [ -n "$tree" ] || { rig_warn "could not build the inbox commit"; return 1; }
    commit="$(cd "$repo" && env "${ident[@]}" git commit-tree "$tree" -p "$tip" \
        -m "beads: relay $name")" || { rig_warn "could not build the inbox commit"; return 1; }
    ( cd "$repo" && timeout 120 git push -q origin "$commit:refs/heads/$branch" </dev/null ) || {
        rig_warn "push failed; $path is kept. Retry with: rig-relay push $path"; return 1; }
    _rig_relay_unstage "$repo" "$path"
    echo "Pushed $branch; the member's beads relay applies it."
}

# Fail, naming them, if any record in the given deltas is older than the
# store: bd import is an upsert, so applying it would silently reinstate
# stale values. Also refuses a record that is not JSON, or has no id (an
# issue) or key (a memory). Memories carry no timestamp and are not gated.
# Returns 1 when it refuses, 2 when it could not check.
rig_relay_gate() {
    local repo="$1"; shift
    local store out
    store="$(mktemp)"
    if ! ( cd "$repo" && timeout 120 bd export --all -o "$store" </dev/null >/dev/null 2>&1 ); then
        rm -f "$store"; rig_warn "bd export failed"; return 2
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
        echo "REFUSED: not valid JSONL: $out"
        return 1
    fi
    rm -f "$store"
    case "$out" in
        "ok "*) echo "Staleness gate passed: ${out#ok } record(s) in $# delta(s)." ;;
        *) printf '%s\n' "$out"; return 1 ;;
    esac
}

# A GitHub Actions annotation in CI, a plain line elsewhere.
_rig_relay_note() {
    if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::%s::%s\n' "$1" "$2"
    else printf '[rig] %s: %s\n' "$1" "$2"; fi
}

_rig_relay_reject() {
    printf '%s\t%s\n' "$2" "$3" >> "$1/rejected"
    rig_warn "rejected $2: $3"
}

# Gather what is waiting to be applied in REPO into DIR (CI):
#   DIR/deltas/<name>.jsonl   each delta, read from git as data only
#   DIR/manifest              "<name>.jsonl\t<branch|tree>\t<branch>\t<sha>",
#                             in name (time) order
#   DIR/rejected              "<branch>\t<reason>" for each inbox branch
#                             that is not exactly one well-named new delta
# Deltas come from every beads-inbox/* branch on origin, and from any
# *.jsonl still in the default branch's own inbox (where sessions put them
# before inbox branches). Nothing from an inbox branch is checked out.
rig_relay_collect() {
    local repo="$1" dir="$2" def ref name branch tip mb diff want meta path mode type blob size
    local -a manifest=()
    mkdir -p "$dir/deltas"
    : > "$dir/manifest"; : > "$dir/rejected"
    def="$(rig_relay_default_branch "$repo")" || return 1
    # One fetch, so the default branch is at least as new as the base of
    # every inbox branch it brings.
    ( cd "$repo" && timeout 300 git fetch -q --no-tags --prune origin \
        "+refs/heads/$def:refs/rig-relay/base" \
        "+refs/heads/$RIG_RELAY_PREFIX*:refs/rig-relay/inbox/*" </dev/null ) || {
        rig_warn "could not fetch $def and the inbox branches"; return 1; }

    while IFS=$'\t' read -r meta path; do
        read -r mode type blob <<< "$meta"
        case "$path" in */*.jsonl) ;; *) continue ;; esac
        [ "$mode $type" = "100644 blob" ] || continue
        name="$(basename -- "$path")"
        ( cd "$repo" && git cat-file blob "$blob" ) > "$dir/deltas/$name" || return 1
        manifest+=("$name"$'\t'tree$'\t'-$'\t'-)
    done < <(cd "$repo" && git ls-tree refs/rig-relay/base -- "$RIG_RELAY_INBOX/")

    while IFS= read -r ref; do
        name="${ref#refs/rig-relay/inbox/}"
        branch="$RIG_RELAY_PREFIX$name"
        if ! [[ "$name" =~ $RIG_RELAY_NAME_RE ]]; then
            _rig_relay_reject "$dir" "$branch" \
                "name is not ${RIG_RELAY_PREFIX}<yyyymmddThhmmssZ>-<label>"
            continue
        fi
        want="$RIG_RELAY_INBOX/$name.jsonl"
        tip="$(cd "$repo" && git rev-parse --verify -q "$ref^{commit}")" || {
            _rig_relay_reject "$dir" "$branch" "does not name a commit"; continue; }
        mb="$(cd "$repo" && git merge-base refs/rig-relay/base "$tip")" || {
            _rig_relay_reject "$dir" "$branch" "shares no history with $def"; continue; }
        diff="$(cd "$repo" && git diff --no-renames --name-status "$mb" "$tip")"
        if [ "$diff" != "A"$'\t'"$want" ]; then
            _rig_relay_reject "$dir" "$branch" \
                "must add $want and change nothing else relative to $def; it changes: $(
                cd "$repo" && git diff --no-renames --name-only "$mb" "$tip" | head -n 5 | paste -sd ' ' -)"
            continue
        fi
        if [ -n "$(cd "$repo" && git ls-tree refs/rig-relay/base -- "$want")" ]; then
            _rig_relay_reject "$dir" "$branch" "$want is already on $def"; continue
        fi
        read -r mode type blob _ < <(cd "$repo" && git ls-tree "$tip" -- "$want")
        if [ "$mode $type" != "100644 blob" ]; then
            _rig_relay_reject "$dir" "$branch" "$want is not a regular file"; continue
        fi
        size="$(cd "$repo" && git cat-file -s "$blob")" || {
            _rig_relay_reject "$dir" "$branch" "cannot read $want"; continue; }
        if [ "$size" -gt "$RIG_RELAY_MAX_BYTES" ]; then
            _rig_relay_reject "$dir" "$branch" \
                "$want is $size bytes, over the $RIG_RELAY_MAX_BYTES limit"
            continue
        fi
        ( cd "$repo" && git cat-file blob "$blob" ) > "$dir/deltas/$name.jsonl" || return 1
        manifest+=("$name.jsonl"$'\t'branch$'\t'"$branch"$'\t'"$tip")
    done < <(cd "$repo" && git for-each-ref --format='%(refname)' refs/rig-relay/inbox/ | LC_ALL=C sort)

    [ "${#manifest[@]}" -eq 0 ] ||
        printf '%s\n' "${manifest[@]}" | LC_ALL=C sort -t $'\t' -k1,1 > "$dir/manifest"
    if [ -s "$dir/manifest" ]; then
        echo "Queued:"
        while IFS=$'\t' read -r name _ branch _; do
            [ "$branch" = - ] && echo "  $RIG_RELAY_INBOX/$name on $def" || echo "  $branch"
        done < "$dir/manifest"
    else
        echo "Nothing queued."
    fi
}

# Apply the deltas DIR/manifest lists to REPO's store, in order, each behind
# the staleness gate, and push refs/dolt/data unless RIG_RELAY_NO_PUSH=1.
# A refused delta is recorded in DIR/refused and skipped; the rest still
# apply. Once the store is pushed, DIR/applied holds the manifest lines of
# what was applied. Fails only when it could not do its job.
rig_relay_apply() {
    local repo="$1" dir="$2" f src ref sha what rc
    local -a applied=()
    : > "$dir/applied"; : > "$dir/refused"
    if [ ! -s "$dir/manifest" ]; then
        echo "Nothing to apply."
        return 0
    fi
    while IFS=$'\t' read -r f src ref sha; do
        if [ "$src" = branch ]; then what="$ref"
        else what="$RIG_RELAY_INBOX/$f on the default branch"; fi
        echo "--- $what"
        rc=0
        ( cd "$repo" && rig_relay_gate "$repo" "$dir/deltas/$f" ) || rc=$?
        case "$rc" in
            0) ;;
            1) printf '%s\t%s\n' "$what" "refused by the staleness gate (see the log)" >> "$dir/refused"
               continue ;;
            *) return 1 ;;
        esac
        ( cd "$repo" && timeout 300 bd import "$dir/deltas/$f" </dev/null ) || {
            rig_warn "bd import failed on $what"; return 1; }
        applied+=("$f"$'\t'"$src"$'\t'"$ref"$'\t'"$sha")
    done < "$dir/manifest"
    if [ "${#applied[@]}" -eq 0 ]; then
        echo "Nothing applied."
        return 0
    fi
    # bd may already have committed each write; nothing to commit is fine.
    ( cd "$repo" && timeout 120 bd dolt commit -m "beads relay: apply ${#applied[@]} delta(s)" </dev/null ) || true
    if [ "${RIG_RELAY_NO_PUSH:-}" = 1 ]; then
        echo "RIG_RELAY_NO_PUSH=1: not pushing."
    else
        rig_beads_config_https "$repo"
        ( cd "$repo" && timeout 600 bd dolt push </dev/null ) || {
            rig_restore_all; rig_warn "bd dolt push failed"; return 1; }
        rig_restore_all
    fi
    printf '%s\n' "${applied[@]}" > "$dir/applied"
    echo "Applied ${#applied[@]} delta(s)."
}

# Delete the inbox branches in DIR/applied, each only if it has not moved
# since it was read, then report. Fails, naming them, if any inbox branch
# was rejected or refused; those are left in place.
rig_relay_finish() {
    local repo="$1" dir="$2" f src ref sha what why status=0 legacy=0
    if [ -f "$dir/applied" ]; then
        while IFS=$'\t' read -r f src ref sha; do
            if [ "$src" != branch ]; then legacy=$((legacy + 1)); continue; fi
            if ( cd "$repo" && timeout 120 git push -q --force-with-lease="refs/heads/$ref:$sha" \
                    origin ":refs/heads/$ref" </dev/null ); then
                echo "Deleted $ref"
            else
                _rig_relay_note warning "could not delete $ref (it moved, or the push was refused); the next run reads it again"
            fi
        done < "$dir/applied"
    fi
    [ "$legacy" -eq 0 ] || _rig_relay_note warning \
        "$legacy file(s) in $RIG_RELAY_INBOX on the default branch were applied; remove them in a PR (curve-rig docs/relay.md, Adopting it)"
    for f in rejected refused; do
        [ -f "$dir/$f" ] || continue
        while IFS=$'\t' read -r what why; do
            _rig_relay_note error "$what: $why"
            status=1
        done < "$dir/$f"
    done
    [ "$status" -eq 0 ] || echo "Left in place. To recover, redo the writes in a fresh session and stage again, then delete the abandoned branch (curve-rig docs/relay.md, When it is stuck)."
    return "$status"
}
