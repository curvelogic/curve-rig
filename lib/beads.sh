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

_rig_bd_bootstrap() {
    cd "$1" && timeout "$2" bd bootstrap --yes </dev/null >>"$RIG_LOG" 2>&1
}

# Materialise the beads store for one repo from refs/dolt/data, over https.
#
# The tracked .beads/config.yaml usually names an ssh remote and the
# container has no ssh, so the remote is rewritten to https for the
# bootstrap and restored afterwards — also if the hook is killed, via the
# pending-restore trap. If bd commits on our behalf, that commit is unwound.
# On failure only the store directories this run created are removed; an
# existing store may hold local writes not yet relayed.
rig_bootstrap_beads() {
    local repo="$1" beads cfg bak head_before head_after before_file t d status=0
    local -a pre_existing=()
    beads="$repo/.beads"
    cfg="$beads/config.yaml"
    [ -d "$beads" ] || return 0

    if [ -L "$beads" ]; then
        rig_warn "$(basename "$repo"): .beads is a symlink — refusing"
        return 1
    fi
    case "$(cd "$beads" && pwd -P)/" in
        "$(cd "$repo" && pwd -P)"/*) ;;
        *) rig_warn "$(basename "$repo"): .beads resolves outside the repo — refusing"; return 1 ;;
    esac
    chmod 700 "$beads" 2>/dev/null || true

    if _rig_beads_store_ok "$repo"; then
        rig_log "$(basename "$repo"): beads store already materialised"
        return 0
    fi

    t="$(rig_step_timeout 600)"
    if [ "$t" -le 0 ]; then
        rig_warn "$(basename "$repo"): no time left to bootstrap beads"
        return 1
    fi

    for d in embeddeddolt dolt proxieddb; do
        [ -e "$beads/$d" ] && pre_existing+=("$d")
    done
    head_before="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    before_file="$(mktemp)"
    git -C "$repo" status --porcelain -z > "$before_file" 2>/dev/null || true

    if [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
        bak="$(mktemp)"; cp "$cfg" "$bak"
        rig_restore_register "$cfg" "$bak"
        sed -i -e 's#git+ssh://git@github\.com/#https://github.com/#g' \
               -e 's#git@github\.com:#https://github.com/#g' "$cfg"
    fi

    rig_run _rig_bd_bootstrap "$repo" "$t" || status=$?

    rig_restore_all
    _rig_beads_restore_tree "$repo" "$before_file"
    rm -f "$before_file"

    head_after="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$head_before" ] && [ "$head_after" != "$head_before" ]; then
        case "$(git -C "$repo" log -1 --format=%s 2>/dev/null)" in
            "bd init"*|"bd bootstrap"*)
                git -C "$repo" reset -q --mixed "$head_before" 2>/dev/null || true ;;
            *) rig_warn "$(basename "$repo"): HEAD moved during bootstrap; left alone" ;;
        esac
    fi

    if [ "$status" -eq 0 ] && _rig_beads_store_ok "$repo"; then
        rig_log "$(basename "$repo"): beads store materialised, $(rig_beads_open_count "$repo") open issues"
        return 0
    fi
    # An empty store would read as an empty tracker rather than a broken one,
    # so remove what this run created — and nothing that was already there.
    for d in embeddeddolt dolt proxieddb; do
        [[ " ${pre_existing[*]} " == *" $d "* ]] || rm -rf "${beads:?}/$d"
    done
    rig_warn "$(basename "$repo"): beads bootstrap failed (see $RIG_LOG)." \
        "Do NOT seed from .beads/issues.jsonl."
    return 1
}
