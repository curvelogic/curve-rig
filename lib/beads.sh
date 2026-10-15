#!/usr/bin/env bash
# lib/beads.sh — install bd and dolt, and materialise a repo's beads store.
#
# Source it after lib/common.sh. Functions return non-zero on failure and
# print their own diagnostics; callers decide whether to carry on.
#
# Environment:
#   RIG_DOLT_VERSION   dolt release tag, e.g. v1.58.6 (default: latest)

[ -n "${_RIG_BEADS_LOADED:-}" ] && return 0
_RIG_BEADS_LOADED=1

rig_install_dolt() {
    if command -v dolt >/dev/null 2>&1; then
        return 0
    fi
    local os arch asset url tmp dest
    case "$(uname -s)" in
        Linux) os=linux ;; Darwin) os=darwin ;;
        *) rig_warn "dolt: unsupported OS $(uname -s)"; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) rig_warn "dolt: unsupported arch $(uname -m)"; return 1 ;;
    esac
    asset="dolt-${os}-${arch}.tar.gz"
    if [ "${RIG_DOLT_VERSION:-latest}" = latest ]; then
        url="https://github.com/dolthub/dolt/releases/latest/download/$asset"
    else
        url="https://github.com/dolthub/dolt/releases/download/$RIG_DOLT_VERSION/$asset"
    fi
    tmp="$(mktemp -d)"
    if ! rig_fetch "$url" | tar -xz -C "$tmp"; then
        rm -rf "$tmp"; rig_warn "dolt: download failed ($url)"; return 1
    fi
    if [ -w /usr/local/bin ]; then dest=/usr/local/bin/dolt; else dest="$RIG_LOCAL_BIN/dolt"; fi
    install -m 0755 "$tmp/dolt-${os}-${arch}/bin/dolt" "$dest"
    rm -rf "$tmp"
    rig_log "dolt: $(rig_first_line "$("$dest" version 2>/dev/null)")"
}

# TODO(plan): pin bd to a release asset instead of the upstream installer,
# which tracks the default branch.
rig_install_bd() {
    rig_ensure_path
    if command -v bd >/dev/null 2>&1; then
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"
    if ! rig_fetch https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh \
            > "$tmp/install.sh"; then
        rm -rf "$tmp"; rig_warn "bd: installer download failed"; return 1
    fi
    bash "$tmp/install.sh" >/dev/null 2>&1 || true
    rm -rf "$tmp"
    if [ -x "$HOME/go/bin/bd" ] && [ ! -e "$RIG_LOCAL_BIN/bd" ]; then
        ln -sf "$HOME/go/bin/bd" "$RIG_LOCAL_BIN/bd"
    fi
    command -v bd >/dev/null 2>&1 || { rig_warn "bd: not on PATH after install"; return 1; }
    rig_log "bd: $(rig_first_line "$(bd version 2>/dev/null)")"
}

# True when the repo's store was materialised from the remote. `bd list`
# alone is not enough: bd hydrates an empty store from a stray
# .beads/issues.jsonl and answers happily over stale data. A bootstrapped
# store has a Dolt remote; a hydrated one does not.
_rig_beads_store_ok() {
    ( cd "$1" && bd list >/dev/null 2>&1 \
        && bd dolt remote list 2>/dev/null | grep -q origin )
}

# Open-issue count, read from bd's own total line.
rig_beads_open_count() {
    ( cd "$1" && bd list --status open 2>/dev/null ) \
        | sed -n 's/^Total: \([0-9]\{1,\}\) issues.*/\1/p' | head -1
}

# Undo what a bootstrap did to the working tree, given `git status
# --porcelain` from before it. bd adds patterns to a tracked
# .beads/.gitignore when it finds them missing, and leaves lock files at the
# repo root. Tracked files it changed under .beads/ are restored; files it
# created are hidden via .git/info/exclude, which is local and untracked.
# (The lasting fix is for the member to commit bd's .gitignore additions.)
_rig_beads_restore_tree() {
    local repo="$1" before="$2" line path exclude
    exclude="$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
    case "$exclude" in /*) ;; *) exclude="$repo/$exclude" ;; esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qxF -- "$line" <<< "$before" && continue
        path="${line:3}"
        case "$line" in
            " M .beads/"*)
                git -C "$repo" checkout -q -- "$path" 2>/dev/null || true ;;
            "?? "*)
                mkdir -p "$(dirname "$exclude")"
                grep -qxF -- "/$path" "$exclude" 2>/dev/null \
                    || printf '/%s\n' "$path" >> "$exclude" ;;
        esac
    done < <(git -C "$repo" status --porcelain 2>/dev/null)
}

# Materialise the beads store for one repo from refs/dolt/data, over https.
#
# The tracked .beads/config.yaml usually names an ssh remote and the
# container has no ssh, so the remote is rewritten to https for the bootstrap
# and the file restored afterwards. If bd commits on our behalf, that commit
# is unwound; the working tree is left as found.
rig_bootstrap_beads() {
    local repo="$1" cfg bak head_before head_after status_before status=0
    cfg="$repo/.beads/config.yaml"
    [ -d "$repo/.beads" ] || return 0
    chmod 700 "$repo/.beads" 2>/dev/null || true

    if _rig_beads_store_ok "$repo"; then
        rig_log "beads ($repo): already materialised"
        return 0
    fi

    head_before="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    status_before="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
    bak=""
    if [ -f "$cfg" ]; then
        bak="$(mktemp)"; cp "$cfg" "$bak"
        sed -i -e 's#git+ssh://git@github\.com/#https://github.com/#g' \
               -e 's#git@github\.com:#https://github.com/#g' "$cfg"
    fi

    ( cd "$repo" && timeout 600 bd bootstrap --yes >/dev/null 2>&1 ) || status=$?

    if [ -n "$bak" ]; then cp "$bak" "$cfg"; rm -f "$bak"; fi

    _rig_beads_restore_tree "$repo" "$status_before"

    head_after="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    if [ -n "$head_before" ] && [ "$head_after" != "$head_before" ]; then
        case "$(git -C "$repo" log -1 --format=%s 2>/dev/null)" in
            "bd init"*|"bd bootstrap"*)
                git -C "$repo" reset --mixed "$head_before" >/dev/null 2>&1 || true ;;
            *) rig_warn "beads ($repo): HEAD moved during bootstrap; left alone" ;;
        esac
    fi

    if [ "$status" -eq 0 ] && _rig_beads_store_ok "$repo"; then
        rig_log "beads ($repo): $(rig_beads_open_count "$repo") open issues"
        return 0
    fi
    # An empty store would read as an empty tracker rather than a broken one.
    rm -rf "$repo/.beads/embeddeddolt" "$repo/.beads/dolt" "$repo/.beads/proxieddb"
    rig_warn "beads ($repo): bootstrap failed; bd will not work in this session." \
        "Do NOT seed from .beads/issues.jsonl."
    return 1
}
