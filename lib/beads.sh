#!/usr/bin/env bash
# lib/beads.sh — install bd and dolt, and materialise a repo's beads store.
#
# Source it after lib/common.sh and lib/pins.sh. Functions return non-zero
# on failure and print their own one-line diagnostics; detailed tool output
# goes to $RIG_LOG. Callers decide whether to carry on.

[ -n "${_RIG_BEADS_LOADED:-}" ] && return 0
_RIG_BEADS_LOADED=1

# Install one binary from a pinned, digest-checked release archive.
#   $1 name   $2 url   $3 expected sha256   $4 path of the binary in the archive
_rig_install_pinned() {
    local name="$1" url="$2" sha="$3" member="$4" tmp dest
    if [ -z "$sha" ]; then
        rig_warn "$name: no pinned digest for this platform"
        return 1
    fi
    tmp="$(mktemp -d)"
    if ! rig_fetch "$url" "$tmp/archive.tar.gz"; then
        rm -rf "$tmp"; rig_warn "$name: download failed ($url)"; return 1
    fi
    if ! rig_sha256_ok "$tmp/archive.tar.gz" "$sha"; then
        rm -rf "$tmp"; rig_warn "$name: digest mismatch for $url — not installed"; return 1
    fi
    if ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp" "$member" 2>>"$RIG_LOG"; then
        rm -rf "$tmp"; rig_warn "$name: archive did not contain $member"; return 1
    fi
    if [ -w /usr/local/bin ]; then dest="/usr/local/bin/$name"; else dest="$RIG_LOCAL_BIN/$name"; fi
    if ! install -m 0755 "$tmp/$member" "$dest"; then
        rm -rf "$tmp"; rig_warn "$name: could not install to $dest"; return 1
    fi
    rm -rf "$tmp"
    rig_log "$name: installed $(rig_first_line "$("$dest" version 2>/dev/null </dev/null)")"
}

rig_install_dolt() {
    command -v dolt >/dev/null 2>&1 && return 0
    local plat os_arch sha_var
    plat="$(rig_platform)" || { rig_warn "dolt: unsupported platform"; return 1; }
    os_arch="${plat/_/-}"
    sha_var="RIG_DOLT_SHA256_$plat"
    _rig_install_pinned dolt \
        "https://github.com/dolthub/dolt/releases/download/v$RIG_DOLT_VERSION/dolt-$os_arch.tar.gz" \
        "${!sha_var:-}" "dolt-$os_arch/bin/dolt"
}

rig_install_bd() {
    rig_ensure_path
    command -v bd >/dev/null 2>&1 && return 0
    local plat sha_var
    plat="$(rig_platform)" || { rig_warn "bd: unsupported platform"; return 1; }
    sha_var="RIG_BD_SHA256_$plat"
    _rig_install_pinned bd \
        "https://github.com/gastownhall/beads/releases/download/v$RIG_BD_VERSION/beads_${RIG_BD_VERSION}_$plat.tar.gz" \
        "${!sha_var:-}" bd
}

# True when the repo's store was materialised from the remote. `bd list`
# alone is not enough: bd hydrates an empty store from a stray
# .beads/issues.jsonl and answers happily over stale data. A bootstrapped
# store has a Dolt remote; a hydrated one does not. Output is captured
# rather than piped to `grep -q`, which can SIGPIPE the producer.
_rig_beads_store_ok() {
    local remotes
    ( cd "$1" && timeout 30 bd list </dev/null >/dev/null 2>&1 ) || return 1
    remotes="$(cd "$1" && timeout 30 bd dolt remote list </dev/null 2>/dev/null)" || return 1
    grep -q origin <<< "$remotes"
}

# Open-issue count, read from bd's own total line.
rig_beads_open_count() {
    local out
    out="$(cd "$1" && timeout 30 bd list --status open </dev/null 2>/dev/null)" || return 0
    sed -n 's/^Total: \([0-9]\{1,\}\) issues.*/\1/p' <<< "$out" | head -1
}

# Escape a repository-relative path as a .git/info/exclude pattern that
# matches exactly that path and nothing else.
_rig_exclude_pattern() {
    local p="$1" tail=""
    p="${p//\\/\\\\}"
    p="${p//\*/\\*}"
    p="${p//\?/\\?}"
    p="${p//\[/\\[}"
    # Trailing spaces are ignored in patterns unless escaped.
    while [[ "$p" == *" " ]]; do p="${p% }"; tail="$tail\\ "; done
    printf '/%s%s\n' "$p" "$tail"
}

# Undo what a bootstrap did to the working tree, given a file holding
# `git status --porcelain -z` from before it. bd adds patterns to a tracked
# .beads/.gitignore when it finds them missing, and leaves lock files at the
# repo root. Tracked files it changed under .beads/ are restored; files it
# created are hidden via .git/info/exclude, which is local and untracked.
# (The lasting fix is for the member to commit bd's .gitignore additions.)
_rig_beads_restore_tree() {
    local repo="$1" before_file="$2" entry code path exclude pat
    local -A before=()
    exclude="$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
    case "$exclude" in /*) ;; *) exclude="$repo/$exclude" ;; esac

    while IFS= read -r -d '' entry; do before["$entry"]=1; done < "$before_file"

    while IFS= read -r -d '' entry; do
        code="${entry:0:2}"
        path="${entry:3}"
        # Renames and copies carry the original path as an extra field.
        case "$code" in R*|C*) IFS= read -r -d '' _ || true ;; esac
        [ -n "${before[$entry]:-}" ] && continue
        case "$code" in
            " M")
                case "$path" in
                    .beads/*) git -C "$repo" checkout -q -- ":(literal)$path" 2>/dev/null || true ;;
                esac ;;
            "??")
                case "$path" in
                    *$'\n'*) rig_warn "untracked path with a newline left visible" ;;
                    *)
                        mkdir -p "$(dirname "$exclude")"
                        pat="$(_rig_exclude_pattern "$path")"
                        grep -qxF -- "$pat" "$exclude" 2>/dev/null || printf '%s\n' "$pat" >> "$exclude"
                        ;;
                esac ;;
        esac
    done < <(git -C "$repo" status --porcelain -z 2>/dev/null)
}

# Point the tracked .beads/config.yaml at github.com over https for the
# rest of this run. It usually names an ssh remote, and neither a cloud
# session nor CI has ssh. The original is registered for restore first, so
# rig_restore_all (or the hook's trap) puts it back.
rig_beads_config_https() {
    local cfg="$1/.beads/config.yaml" bak
    [ -f "$cfg" ] && [ ! -L "$cfg" ] || return 0
    bak="$(mktemp)"; cp "$cfg" "$bak"
    rig_restore_register "$cfg" "$bak"
    sed -i -e 's#git+ssh://git@github\.com/#https://github.com/#g' \
           -e 's#git@github\.com:#https://github.com/#g' "$cfg"
}

# Set beads.role to maintainer in the repo's local git config, unless a role
# is already set there or globally. Unset, bd prints "beads.role not
# configured (GH#2950)" on every command and guesses the role from the
# origin URL; a contributor role routes bd list and ready to a separate
# planning store when contributor routing is configured. rig provisions a
# member's own store, which the session writes and the relay stages, so the
# role is maintainer — what bd init sets for whoever creates a store.
# .git/config is not part of the working tree.
rig_beads_role() {
    git -C "$1" config --get beads.role >/dev/null 2>&1 && return 0
    git -C "$1" config --local beads.role maintainer 2>/dev/null || true
}

# --- A store kept on a branch ----------------------------------------------
# A member may keep its beads store on an ordinary branch instead of
# refs/dolt/data, by naming the ref in a committed .rig/beads-ref, e.g.
#   refs/heads/beads-data
# A cloud session can push a branch, so with this it pushes the store
# itself and needs no relay (docs/relay.md, "A store on a branch"). bd
# cannot clone from or add such a remote (1.3.x has no ref option), so rig
# does both with the dolt CLI; bd then pushes and pulls through it as it is.

# The ref named in REPO's .rig/beads-ref; prints nothing when there is no
# such file. Fails, with a warning, on one that is not a plain branch.
rig_beads_ref() {
    local f="$1/.rig/beads-ref" ref
    [ -e "$f" ] || return 0
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        rig_warn "$(rig_safe_name "$(basename "$1")"): .rig/beads-ref is not a regular file"
        return 1
    fi
    ref="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$f" | head -1)"
    if [[ ! "$ref" =~ ^refs/heads/[A-Za-z0-9_][A-Za-z0-9._/-]{0,99}$ ]] ||
       ! git check-ref-format "$ref" ||
       [ "$ref" = refs/heads/__dolt_remote_info__ ]; then
        rig_warn "$(rig_safe_name "$(basename "$1")"): .rig/beads-ref must name one" \
            "branch, refs/heads/<name>"
        return 1
    fi
    printf '%s\n' "$ref"
}

# The dolt git-remote URL of REPO's origin: git+https for github.com,
# git+file for a local path (tests). Fails for anything else.
rig_beads_remote_url() {
    local url path
    url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    if rig_repo_owner "$1" >/dev/null; then
        path="${url#*github.com}"; path="${path#[:/]}"; path="${path%/}"; path="${path%.git}"
        printf 'git+https://github.com/%s.git\n' "$path"
        return 0
    fi
    case "$url" in
        /*)       printf 'git+file://%s\n' "$url" ;;
        file://*) printf 'git+%s\n' "$url" ;;
        *) return 1 ;;
    esac
}

# The embedded store's database directory, .beads/embeddeddolt/<name>, from
# .beads/metadata.json. Fails for any other storage mode: rig materialises
# only an embedded store from a branch.
rig_beads_embedded_dir() {
    local meta="$1/.beads/metadata.json" mode db
    command -v jq >/dev/null 2>&1 || { rig_warn "jq is not on PATH"; return 1; }
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rig_warn "no .beads/metadata.json"; return 1; }
    mode="$(jq -r '.dolt_mode // "embedded"' "$meta" 2>/dev/null)" || mode=""
    db="$(jq -r '.dolt_database // empty' "$meta" 2>/dev/null)" || db=""
    if [ "$mode" != embedded ]; then
        rig_warn "a beads store on a branch must be embedded (this one is ${mode:-unreadable})"
        return 1
    fi
    [[ "$db" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]] ||
        { rig_warn "no usable dolt_database in .beads/metadata.json"; return 1; }
    printf '%s\n' "$1/.beads/embeddeddolt/$db"
}

# The URL and ref of the origin remote of the dolt database at DIR, as
# "<url> <ref>" (ref empty for an ordinary remote).
rig_beads_origin_of() {
    jq -r '.remotes.origin // empty | "\(.url) \(.params.git_ref // "")"' \
        "$1/.dolt/repo_state.json" 2>/dev/null
}

# Point the dolt database at DIR's origin remote at URL's REF, unless it
# already is. The database keeps its rows; only where it pushes changes.
rig_beads_point_origin() {
    local dir="$1" url="$2" ref="$3"
    [ "$(rig_beads_origin_of "$dir")" = "$url $ref" ] && return 0
    ( cd "$dir" &&
      { ! timeout 30 dolt remote </dev/null 2>/dev/null | grep -qx origin ||
        timeout 30 dolt remote remove origin </dev/null; } &&
      timeout 30 dolt remote add --ref "$ref" origin "$url" </dev/null
    ) >>"$RIG_LOG" 2>&1
}

_rig_dolt_clone_ref() {
    mkdir -p "$(dirname "$1")" &&
        cd "$(dirname "$1")" &&
        timeout "$4" dolt clone --ref "$3" "$2" "$(basename "$1")" </dev/null >>"$RIG_LOG" 2>&1
}

_rig_bd_bootstrap() {
    cd "$1" && timeout "$2" bd bootstrap --yes </dev/null >>"$RIG_LOG" 2>&1
}

# Materialise the beads store for one repo from refs/dolt/data, over https,
# or, where the repo names one in .rig/beads-ref, from that branch.
#
# The tracked .beads/config.yaml usually names an ssh remote and the
# container has no ssh, so the remote is rewritten to https for the
# bootstrap and restored afterwards — also if the hook is killed, via the
# pending-restore trap. If bd commits on our behalf, that commit is unwound.
# On failure only the store directories this run created are removed; an
# existing store may hold local writes not yet relayed.
rig_bootstrap_beads() {
    local repo="$1" beads head_before head_after before_file t d status=0 name
    local ref="" url="" dir=""
    local -a pre_existing=()
    beads="$repo/.beads"
    name="$(rig_safe_name "$(basename "$repo")")"
    [ -d "$beads" ] || return 0

    if [ -L "$beads" ]; then
        rig_warn "$name: .beads is a symlink — refusing"
        return 1
    fi
    case "$(cd "$beads" && pwd -P)/" in
        "$(cd "$repo" && pwd -P)"/*) ;;
        *) rig_warn "$name: .beads resolves outside the repo — refusing"; return 1 ;;
    esac
    chmod 700 "$beads" 2>/dev/null || true

    ref="$(rig_beads_ref "$repo")" || return 1
    if [ -n "$ref" ]; then
        url="$(rig_beads_remote_url "$repo")" ||
            { rig_warn "$name: origin is not a github.com or local repository"; return 1; }
        dir="$(rig_beads_embedded_dir "$repo")" || { rig_warn "$name: beads store not materialised"; return 1; }
    fi

    if _rig_beads_store_ok "$repo"; then
        if [ -n "$ref" ] && ! rig_beads_point_origin "$dir" "$url" "$ref"; then
            rig_warn "$name: could not point the beads store at $ref (see $RIG_LOG)"
            return 1
        fi
        rig_beads_role "$repo"
        rig_log "$name: beads store already materialised"
        return 0
    fi

    t="$(rig_step_timeout 600)"
    if [ "$t" -le 0 ]; then
        rig_warn "$name: no time left to bootstrap beads"
        return 1
    fi

    for d in embeddeddolt dolt proxieddb; do
        [ -e "$beads/$d" ] && pre_existing+=("$d")
    done
    head_before="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    before_file="$(mktemp)"
    git -C "$repo" status --porcelain -z > "$before_file" 2>/dev/null || true

    if [ -n "$ref" ]; then
        rig_run _rig_dolt_clone_ref "$dir" "$url" "$ref" "$t" || status=$?
    else
        rig_beads_config_https "$repo"
        rig_run _rig_bd_bootstrap "$repo" "$t" || status=$?
    fi

    rig_restore_all
    _rig_beads_restore_tree "$repo" "$before_file"
    rm -f "$before_file"

    head_after="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$head_before" ] && [ "$head_after" != "$head_before" ]; then
        case "$(git -C "$repo" log -1 --format=%s 2>/dev/null)" in
            "bd init"*|"bd bootstrap"*)
                git -C "$repo" reset -q --mixed "$head_before" 2>/dev/null || true ;;
            *) rig_warn "$name: HEAD moved during bootstrap; left alone" ;;
        esac
    fi

    if [ "$status" -eq 0 ] && _rig_beads_store_ok "$repo"; then
        rig_beads_role "$repo"
        rig_log "$name: beads store materialised${ref:+ from $ref}, $(rig_beads_open_count "$repo") open issues"
        return 0
    fi
    # An empty store would read as an empty tracker rather than a broken one,
    # so remove what this run created — and nothing that was already there.
    for d in embeddeddolt dolt proxieddb; do
        [[ " ${pre_existing[*]} " == *" $d "* ]] || rm -rf "${beads:?}/$d"
    done
    rig_warn "$name: beads bootstrap failed (see $RIG_LOG)." \
        "Do NOT seed from .beads/issues.jsonl."
    return 1
}
