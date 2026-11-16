#!/usr/bin/env bash
# owner-guard.sh — PreToolUse hook: keep agents off the owner's decisions.
#
# Agents and the owner act on GitHub as one login, so nothing posted from it
# proves who wrote it. An owner decision counts only when the owner gives it
# first-hand in a session's chat, or merges a PR themselves. This hook
# refuses the tool calls that would let an agent stand in for the owner:
#
#   - merging a held PR: one labelled `owner-review`, or whose body,
#     comments or reviews carry a "Do not merge — owner review" line. Covers
#     `gh pr merge`, `gh api` and curl calls to a merge or auto-merge
#     endpoint, GraphQL merge mutations, and the GitHub MCP merge and
#     auto-merge tools; and, since they land a change without its PR, the
#     Merges API and a push or ref update to the default branch;
#   - taking a hold away so the PR can then be merged: editing or deleting
#     the body, comment or review that carries the hold line;
#   - posting a hold release ("hold released" and close variants) in a
#     comment, review, PR or issue body, by `gh`, curl or the GitHub MCP
#     tools;
#   - removing the `owner-review` label, or deleting or renaming it.
#
# It fails closed: a call it cannot classify, or a PR it cannot read, is
# refused with a message saying how to proceed. A refusal is exit 2 with
# the reason on stderr, which Claude Code shows the session in place of the
# tool's result. Calls that touch none of the above pass untouched.
#
# Input: the hook's JSON on stdin (tool_name, tool_input, cwd). Needs jq,
# and gh (authenticated, REST only) to read a PR. Self-contained, so it
# works from the plugin's cache as well as from rig's checkout. Written for
# bash 3.2 too (macOS).
#
# A guard against mistakes and injected instructions, not a sandbox: a
# command assembled at run time (a variable holding "gh") is not seen.

set -euo pipefail

LABEL="owner-review"
HOLD_RE="(do not|don[^[:alnum:][:space:]]{0,3}t)[[:space:]]+merge[^[:alnum:]]{1,8}owner[[:space:]-]*review"
# A hold release: "hold released", "the hold is lifted", "releasing the
# hold", "unheld". Prose about the rule ("only the owner can release the
# hold", "agents never post a hold release") is not matched.
REL_VERB='(released|releasing|lifted|lifting|cleared|clearing|removed|removing|withdrawn|withdrawing|dropped|dropping|rescinded|rescinding)'
RELEASE_RE="(^|[^[:alnum:]])hold[[:space:]]+((is|has|was|now|been|hereby)[[:space:]]+)*${REL_VERB}|${REL_VERB}[[:space:]]+((the|this|my|that|your|its|owner|owner-review|review)[[:space:]]+)*hold([^[:alnum:]]|$)|(^|[^[:alnum:]])un-?hold|(^|[^[:alnum:]])un-?held"

input="$(cat)"
relevant=0
refuse() {
    printf 'rig owner guard: %s\n' "$*" >&2
    relevant=0
    exit 2
}
# Fail closed: a relevant call the guard errored on is refused.
trap 'st=$?; if [ "$relevant" = 1 ] && [ "$st" != 0 ] && [ "$st" != 2 ]; then
        printf "rig owner guard: could not check this call (error %s), so it is refused. Retry it in a plainer form (gh pr merge <number> --repo OWNER/REPO, or the GitHub MCP tools).\n" "$st" >&2
        exit 2
      fi' EXIT

if ! command -v jq >/dev/null 2>&1; then
    if printf '%s' "$input" | grep -qiE 'merge|hold|label|comment|review|pull|issue|push|update-ref|api\.github|gh '; then
        relevant=1
        refuse "jq is not installed, so this call cannot be checked for an owner hold; it is refused."
    fi
    exit 0
fi

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[ -n "$cwd" ] || cwd="$PWD"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Run a command with a time limit where `timeout` exists.
limited() {
    if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; else "$@"; fi
}

# gh api GET of PATH, paginated, to stdout; fails if gh is missing or the
# call fails.
api_get() {
    command -v gh >/dev/null 2>&1 || return 1
    limited gh api --paginate "$1" </dev/null 2>/dev/null
}

# Why PR $1/$2#$3 is held, on stdout; nothing if it is not held. Fails
# (status 1) if any part of it cannot be read.
hold_reason() {
    local base="repos/$1/$2" n="$3" issue bodies
    issue="$(api_get "$base/issues/$n")" || return 1
    printf '%s' "$issue" | jq -e 'type == "object" and has("labels")' >/dev/null 2>&1 || return 1
    if printf '%s' "$issue" | jq -e --arg l "$LABEL" \
        '[.labels[]? | (.name // .) | ascii_downcase] | index($l)' >/dev/null; then
        printf "it carries the \`%s\` label" "$LABEL"; return 0
    fi
    bodies="$(printf '%s' "$issue" | jq -r '.body // ""')" || return 1
    local p out
    for p in "issues/$n/comments" "pulls/$n/reviews" "pulls/$n/comments"; do
        out="$(api_get "$base/$p")" || return 1
        out="$(printf '%s' "$out" | jq -r '.[]? | .body // ""')" || return 1
        bodies="$bodies"$'\n'"$out"
    done
    if printf '%s' "$bodies" | grep -qiE "$HOLD_RE"; then
        printf 'its body or a comment carries a "Do not merge — owner review" hold'
    fi
}

# Whether issue or PR $1/$2#$3 is labelled owner-review; fails if unreadable.
has_label() {
    local issue
    issue="$(api_get "repos/$1/$2/issues/$3")" || return 2
    printf '%s' "$issue" | jq -e 'type == "object" and has("labels")' >/dev/null 2>&1 || return 2
    printf '%s' "$issue" | jq -e --arg l "$LABEL" \
        '[.labels[]? | (.name // .) | ascii_downcase] | index($l)' >/dev/null
}

HELD_ADVICE="Only the owner merges a held PR, by pressing merge on GitHub; an owner decision counts only when given first-hand in this session's chat or by that merge, never by a comment from the shared login. Leave the PR open and report that it awaits the owner."

# Refuse unless PR $1/$2#$3 is readable and not held.
check_merge() {
    local why
    if ! why="$(hold_reason "$1" "$2" "$3")"; then
        refuse "could not read $1/$2#$3 to check it for an owner hold, so the merge is refused. Check gh is installed and can read the repository (gh api repos/$1/$2/issues/$3), then retry. If it still cannot be read, leave the merge to the owner, who merges by pressing merge on GitHub."
    fi
    [ -z "$why" ] || refuse "$1/$2#$3 is held for the owner: $why. $HELD_ADVICE"
}

# Refuse unless issue or PR $1/$2#$3 is readable and not labelled.
check_label_kept() {
    local st=0
    has_label "$1" "$2" "$3" || st=$?
    case "$st" in
        0) refuse "this would remove the \`$LABEL\` label from $1/$2#$3. Only the owner removes it; removing it does not release a hold." ;;
        1) ;;
        *) refuse "could not read $1/$2#$3 to check for the \`$LABEL\` label, so this label change is refused." ;;
    esac
}

RELEASE_ADVICE="Agents never post a hold release, and nothing posted from the shared login releases a hold: only the owner does, by merging the PR themselves. Reword the text so it does not read as a release, or leave the PR for the owner."

check_text() {   # refuse if text $1 reads as a hold release
    local hit
    hit="$(printf '%s' "$1" | grep -oiE "$RELEASE_RE" | head -n 1)" || true
    [ -z "$hit" ] || refuse "this posts text that reads as a hold release (\"$hit\"). $RELEASE_ADVICE"
}

holds() { printf '%s' "$1" | grep -qiE "$HOLD_RE"; }

UNREADABLE="so it is refused. Check gh is installed and can read the repository, then retry; if it still cannot, leave this to the owner."

# An edit of PR or issue $1/$2#$3's body to text $4 (empty: unknown, which
# is refused if the body holds): refused if the body carries the hold line
# and the new text does not.
check_body_edit() {
    local issue
    issue="$(api_get "repos/$1/$2/issues/$3")" || refuse "could not read $1/$2#$3 to check its body for an owner hold, $UNREADABLE"
    holds "$(printf '%s' "$issue" | jq -r '.body // ""')" || return 0
    holds "$4" && return 0
    refuse "this would take the \"Do not merge — owner review\" line out of $1/$2#$3's body. The hold stays until the owner merges or closes the PR; agents never remove it."
}

# An edit (method $5, new text $6) or deletion of comment $4 on $1/$2, of
# kind $3: issues (a PR or issue comment), pulls (a review comment) or
# reviews/<PR>/<id> (a review body). Refused if it carries the hold line
# and the new text does not; refused if it cannot be read.
check_comment_edit() {
    local path c
    case "$3" in
        issues|pulls) path="repos/$1/$2/$3/comments/$4" ;;
        *) path="repos/$1/$2/pulls/${3#reviews/}/reviews/$4" ;;
    esac
    c="$(api_get "$path")" || refuse "could not read the comment or review this changes ($path) to check it for an owner hold, $UNREADABLE"
    holds "$(printf '%s' "$c" | jq -r '.body // ""')" || return 0
    [ "$5" != DELETE ] && holds "$6" && return 0
    refuse "this would edit or delete a comment or review that carries an owner hold ($path). The hold stays until the owner merges or closes the PR; agents never remove it."
}

# Refuse if any comment on $1/$2#$3 carries the hold line (for gh's
# --edit-last and --delete-last, which name no comment).
check_no_comment_holds() {
    local out
    out="$(api_get "repos/$1/$2/issues/$3/comments")" || refuse "could not read $1/$2#$3's comments to check them for an owner hold, $UNREADABLE"
    if holds "$(printf '%s' "$out" | jq -r '.[]? | .body // ""')"; then
        refuse "$1/$2#$3 has a comment carrying an owner hold, and this edits or deletes a comment without naming which. Agents never remove a hold; post a new comment instead."
    fi
}

# --- GitHub MCP tools -----------------------------------------------------

if [[ "$tool" == mcp__* ]]; then
    op="$(lower "${tool##*__}")"
    case "$op" in
        *comment*|*review*|*pull_request*|*issue*|*merge*|*label*) ;;
        *) exit 0 ;;
    esac
    relevant=1
    ti="$(printf '%s' "$input" | jq -c '.tool_input // {}')"
    get() { printf '%s' "$ti" | jq -r "$1 // empty"; }
    owner="$(get .owner)"; repo="$(get .repo)"
    number="$(get '(.pullNumber // .pull_number // .issue_number // .issueNumber // .number)')"
    method="$(lower "$(get .method)")"

    case "$op" in
        merge_pull_request|enable_pr_auto_merge|*merge_pull_request*|*auto_merge*|*merge_branch*)
            case "$op" in disable_*) exit 0 ;; esac
            case "$op" in *merge_branch*) refuse "$tool merges a branch without a PR the guard can check, so it is refused. Merge through the PR." ;; esac
            if [ -z "$owner" ] || [ -z "$repo" ] || ! [[ "$number" =~ ^[0-9]+$ ]]; then
                refuse "could not tell which PR $tool merges (owner, repo and pullNumber), so it is refused."
            fi
            check_merge "$owner" "$repo" "$number" ;;
    esac

    case "$op" in
        get_*|list_*|search_*|*_read|read_*) exit 0 ;;
    esac

    # Text it would post: every string in the input.
    check_text "$(printf '%s' "$ti" | jq -r '[.. | strings] | join("\n")')"

    # Edits that could take a hold line away.
    body="$(printf '%s' "$ti" | jq -r 'if has("body") then .body // "" | tostring else empty end')"
    has_body="$(printf '%s' "$ti" | jq -r 'has("body")')"
    cid="$(get '(.comment_id // .commentId // .review_id // .reviewId)')"
    case "$op:$method" in
        *update_pull_request*|*edit_pull_request*|*issue_write*:update|*update_issue:*|*edit_issue:*)
            if [ "$has_body" = true ] && [[ "$number" =~ ^[0-9]+$ ]]; then
                [ -n "$owner" ] && [ -n "$repo" ] || refuse "could not tell which repository $tool edits, so it is refused."
                check_body_edit "$owner" "$repo" "$number" "$body"
            fi ;;
    esac
    case "$op" in
        *comment*update*|*update*comment*|*comment*edit*|*edit*comment*|*comment*delet*|*delet*comment*|*minimi*|*hide*comment*)
            kind=issues
            case "$op" in *review*|*pull_request*) kind=pulls ;; esac
            m=PATCH
            case "$op" in *delet*|*minimi*|*hide*) m=DELETE ;; esac
            [ -n "$owner" ] && [ -n "$repo" ] && [[ "$cid" =~ ^[0-9]+$ ]] \
                || refuse "could not tell which comment $tool changes, so it is refused."
            check_comment_edit "$owner" "$repo" "$kind" "$cid" "$m" "$body" ;;
    esac

    # Labels: a tool that sets the whole list (issue_write, say) drops
    # owner-review if it leaves it out; one that names the label to remove
    # or delete it.
    if printf '%s' "$ti" | jq -e 'has("labels") and (.labels | type == "array")' >/dev/null; then
        if ! printf '%s' "$ti" | jq -e --arg l "$LABEL" '[.labels[] | strings | ascii_downcase] | index($l)' >/dev/null; then
            if [[ "$number" =~ ^[0-9]+$ ]]; then
                [ -n "$owner" ] && [ -n "$repo" ] \
                    || refuse "could not tell which repository $tool changes labels on, so it is refused."
                check_label_kept "$owner" "$repo" "$number"
            fi
        fi
    fi
    if [[ "$op" == *label* ]] \
        && printf '%s' "$ti" | jq -e --arg l "$LABEL" '[.. | strings | ascii_downcase] | index($l)' >/dev/null; then
        case "$op:$method" in
            *add*|*create*|*:get|*:list) ;;
            *) refuse "$tool would remove, delete or rename the \`$LABEL\` label. Only the owner does that; removing it does not release a hold." ;;
        esac
    fi
    exit 0
fi

# --- Shell commands -------------------------------------------------------

[ "$tool" = Bash ] || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
# Only commands that can reach GitHub or push concern the guard.
printf '%s' "$cmd" | grep -qE 'gh|github|curl|wget|https?:|git' || exit 0
relevant=1

SEP=$'\x1f'
# Split the command into words, honouring quotes and backslashes, with a
# lone $SEP word at each unquoted ; & | ( or newline, and "$SEP)" at each
# unquoted ). Not a shell: expansions stay as text. Words go to WORDS.
WORDS=()
tokenize() {
    local s="$1" n=${#1} i=0 c q="" w="" inw=0
    while [ "$i" -lt "$n" ]; do
        c="${s:i:1}"
        if [ -n "$q" ]; then
            if [ "$c" = "$q" ]; then q=""
            elif [ "$q" = '"' ] && [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
                i=$((i + 1)); w="$w${s:i:1}"
            else w="$w$c"; fi
            i=$((i + 1)); continue
        fi
        case "$c" in
            "'"|'"') q="$c"; inw=1 ;;
            "\\")
                i=$((i + 1))
                if [ "${s:i:1}" != $'\n' ]; then w="$w${s:i:1}"; inw=1; fi ;;
            ' '|$'\t')
                if [ "$inw" = 1 ]; then WORDS+=("$w"); w=""; inw=0; fi ;;
            ';'|'&'|'|'|'('|')'|$'\n')
                if [ "$inw" = 1 ]; then WORDS+=("$w"); w=""; inw=0; fi
                if [ "$c" = ')' ]; then WORDS+=("$SEP)"); else WORDS+=("$SEP"); fi ;;
            *) w="$w$c"; inw=1 ;;
        esac
        i=$((i + 1))
    done
    if [ "$inw" = 1 ]; then WORDS+=("$w"); fi
    return 0
}
tokenize "$cmd"
# One level of nesting: the script of sh -c, bash -c or eval is split too.
nested=()
prev=""
for w in ${WORDS[@]+"${WORDS[@]}"}; do
    case "$prev" in -c|eval) nested+=("$w") ;; esac
    prev="$w"
done
for w in ${nested[@]+"${nested[@]}"}; do
    WORDS+=("$SEP"); tokenize "$w"
done

heredoc=0
case "$cmd" in *'<<'*) heredoc=1 ;; esac

# The directory each simple command runs in: the session's, then each cd
# or pushd in turn. Empty once it cannot be told (cd to a variable, cd -,
# popd, or leaving a subshell that changed directory).
CUR_DIR="$cwd"
CD_SEEN=0
change_dir() {   # $1 the argument of cd, if any
    local d="${1:-$HOME}"
    case "$d" in
        -|*'$'*|*'`'*|*'*'*) CUR_DIR=""; return 0 ;;
        \~|\~/*) d="$HOME${d#\~}" ;;
    esac
    case "$d" in /*) ;; *) [ -n "$CUR_DIR" ] && d="$CUR_DIR/$d" || d="" ;; esac
    if [ -n "$d" ] && [ -d "$d" ]; then CUR_DIR="$(cd "$d" && pwd)"; else CUR_DIR=""; fi
}

# The repository gh acts on without --repo: GH_REPO in the command or the
# environment, else, as gh chooses, the remote marked by
# `gh repo set-default`, else the only GitHub remote of the directory.
# Several GitHub remotes and no default cannot be told.
GH_REPO_IN_CMD=""
for w in ${WORDS[@]+"${WORDS[@]}"}; do
    case "$w" in GH_REPO=*) GH_REPO_IN_CMD="${w#GH_REPO=}" ;; esac
done
repo_of_url() {
    printf '%s' "$1" | sed -nE 's#^.*github\.com[:/]+([^/]+)/([^/]+)$#\1/\2#p' | sed -E 's#/$##; s#\.git$##'
}
default_repo() {   # $1 directory, default CUR_DIR
    local r="${GH_REPO_IN_CMD:-${GH_REPO:-}}" d="${1:-$CUR_DIR}" line name val urls
    if [ -z "$r" ]; then
        [ -n "$d" ] || return 1
        line="$(git -C "$d" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | head -n 1)" || true
        if [ -n "$line" ]; then
            name="${line%% *}"; name="${name#remote.}"; name="${name%.gh-resolved}"
            val="${line#* }"
            if [ "$val" = base ]; then
                r="$(repo_of_url "$(git -C "$d" remote get-url "$name" 2>/dev/null)")"
            else r="$val"; fi
        else
            urls="$(git -C "$d" remote -v 2>/dev/null | awk '$3 == "(fetch)" { print $2 }' \
                | while IFS= read -r u; do repo_of_url "$u"; echo; done | sed '/^$/d' | sort -u)"
            [ "$(printf '%s\n' "$urls" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ] || return 1
            r="$urls"
        fi
    fi
    r="${r#https://github.com/}"; r="${r#github.com/}"; r="${r%/}"
    [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s' "$r"
}
NO_REPO="could not tell which repository this acts on, so it is refused. Name it: --repo OWNER/REPO, or a full PR URL."

# Files whose contents a command posts: a body file, a field read with
# @file, curl data. "-" (stdin) is fine only when the command carries the
# text itself, in a heredoc.
POST_FILES=()
add_file() { POST_FILES+=("$1"); }
add_at() {   # a value read from a file only with @: @path, or key=@path
    case "$1" in *=@*) POST_FILES+=("${1#*=@}") ;; @*) POST_FILES+=("${1#@}") ;; esac
    return 0
}
# The text of file $1 as this command sends it, on stdout; fails if it
# cannot be read. "-" is the command itself when it carries a heredoc.
payload_of() {
    local f="$1"
    if [ "$f" = - ]; then [ "$heredoc" = 1 ] || return 1; printf '%s' "$cmd"; return 0; fi
    case "$f" in /*) ;; *) [ -n "$CUR_DIR" ] || return 1; f="$CUR_DIR/$f" ;; esac
    [ -f "$f" ] && [ -r "$f" ] || return 1
    head -c 1048576 -- "$f"
}
POSTS_TEXT=0
MERGE_CHECKED=0

# OWNER REPO of an API path, resolving {owner} and {repo}.
api_repo() {   # $1 path
    [[ "$1" =~ ^repos/([^/]+)/([^/]+) ]] || return 1
    local o="${BASH_REMATCH[1]}" r="${BASH_REMATCH[2]}" d
    if [ "$o" = "{owner}" ] || [ "$r" = "{repo}" ]; then
        d="$(default_repo)" || return 1
        [ "$o" = "{owner}" ] && o="${d%%/*}"
        [ "$r" = "{repo}" ] && r="${d#*/}"
    fi
    printf '%s %s' "$o" "$r"
}

# A PR named as gh names one: a number (#n too) with --repo, or a URL.
# Sets PO PRR PN, or refuses with $2.
resolve_pr() {   # $1 selector, $2 refusal, $3 --repo value
    local sel="${1#\#}" repo="$3"
    if [[ "$sel" =~ ^https?://github\.com/([^/]+)/([^/]+)/(pull|issues)/([0-9]+) ]]; then
        PO="${BASH_REMATCH[1]}"; PRR="${BASH_REMATCH[2]}"; PN="${BASH_REMATCH[4]}"; return 0
    fi
    [[ "$sel" =~ ^[0-9]+$ ]] || refuse "$2"
    PN="$sel"
    [ -n "$repo" ] || repo="$(default_repo)" || refuse "$NO_REPO"
    repo="${repo#https://github.com/}"; repo="${repo%/}"
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse "$NO_REPO"
    PO="${repo%%/*}"; PRR="${repo#*/}"
}

# gh pr|issue SUB ARGS...: merges, body and comment edits, label removal.
gh_pr() {
    local kind="$1" sub="$2" repo="" sel="" body="" has_body=0 edit_last=0 w v
    shift 2
    while [ "$#" -gt 0 ]; do
        w="$1"; shift; v=""
        case "$w" in
            -R|--repo) repo="${1:-}"; shift || true ;;
            --repo=*) repo="${w#--repo=}" ;;
            -R?*) repo="${w#-R}" ;;
            -F|--body-file)
                add_file "${1:-}"; has_body=1
                body="$body$(payload_of "${1:-}" || printf '%s' "$SEP")"; shift || true ;;
            --body-file=*)
                add_file "${w#*=}"; has_body=1
                body="$body$(payload_of "${w#*=}" || printf '%s' "$SEP")" ;;
            -b|--body) has_body=1; body="$body${1:-}"; shift || true ;;
            --body=*) has_body=1; body="$body${w#*=}" ;;
            --edit-last|--delete-last) edit_last=1 ;;
            --remove-label) v="${1:-}"; shift || true ;;
            --remove-label=*) v="${w#--remove-label=}" ;;
            -t|--title|--subject|--match-head-commit|-A|--author-email|-a|--assignee|-l|--label|--add-label|\
            -m|--milestone|-B|--base|-H|--head|-r|--reviewer|-p|--project|-c|--comment|--add-assignee|\
            --remove-assignee|--add-reviewer|--remove-reviewer|--add-project|--remove-project|-T|--template|--reason)
                [ "$sub" = merge ] && [ "$w" = -r ] && continue   # gh pr merge -r is --rebase
                shift || true ;;
            -*) ;;
            *) [ -n "$sel" ] || sel="$w" ;;
        esac
        if [ -n "$v" ] && printf ',%s,' "$(lower "$v" | tr -d ' ')" | grep -q ",$LABEL,"; then
            refuse "this removes the \`$LABEL\` label. Only the owner removes it; removing it does not release a hold."
        fi
    done
    case "$sub" in
        merge)
            [ "$kind" = pr ] || return 0
            resolve_pr "$sel" "could not tell which PR this merges, so it is refused. Name it by number with its repository: gh pr merge <number> --repo OWNER/REPO." "$repo"
            check_merge "$PO" "$PRR" "$PN"; MERGE_CHECKED=1 ;;
        edit)
            if [ "$has_body" = 1 ]; then
                resolve_pr "$sel" "could not tell which PR or issue this edits the body of, so it is refused. Name it by number with --repo OWNER/REPO." "$repo"
                case "$body" in *"$SEP"*) body="" ;; esac   # a body file it cannot read
                check_body_edit "$PO" "$PRR" "$PN" "$body"
            fi ;;
        comment)
            if [ "$edit_last" = 1 ]; then
                resolve_pr "$sel" "could not tell which PR or issue's comment this edits or deletes, so it is refused. Name it by number with --repo OWNER/REPO." "$repo"
                check_no_comment_holds "$PO" "$PRR" "$PN"
            fi ;;
    esac
    return 0
}

# gh label delete|edit owner-review.
gh_label() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        delete|edit|rename)
            local w
            for w in "$@"; do
                [ "$(lower "$w")" = "$LABEL" ] \
                    && refuse "this deletes or renames the \`$LABEL\` label. Only the owner does that."
            done ;;
    esac
    return 0
}

# gh api: method, path and the payload it sends.
gh_api() {
    local method="" path="" fields=0 w text="" bad=0 f
    while [ "$#" -gt 0 ]; do
        w="$1"; shift; f=""
        case "$w" in
            -X|--method) method="${1:-}"; shift || true ;;
            --method=*) method="${w#--method=}" ;;
            -X?*) method="${w#-X}" ;;
            -F|--field) fields=1; f="${1:-}"; shift || true ;;
            --field=*) fields=1; f="${w#*=}" ;;
            -f|--raw-field) fields=1; text="$text"$'\n'"${1:-}"; shift || true ;;
            --raw-field=*) fields=1; text="$text"$'\n'"${w#*=}" ;;
            --input)
                fields=1; add_file "${1:-}"
                text="$text"$'\n'"$(payload_of "${1:-}")" || bad=1; shift || true ;;
            -H|--header|-q|--jq|-t|--template|--hostname|--cache|-p|--preview) shift || true ;;
            -*) ;;
            *) [ -n "$path" ] || path="$w" ;;
        esac
        if [ -n "$f" ]; then
            text="$text"$'\n'"$f"
            case "$f" in
                *=@*|@*) add_at "$f"; text="$text"$'\n'"$(payload_of "${f#*@}")" || bad=1 ;;
            esac
        fi
    done
    [ -n "$method" ] || { if [ "$fields" = 1 ]; then method=POST; else method=GET; fi; }
    method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
    [ "$method" = GET ] || POSTS_TEXT=1
    path="${path#/}"; path="${path#https://api.github.com/}"
    api_path_rules "$method" "$path" "$text" "$bad"
    if [ "$path" = graphql ]; then POSTS_TEXT=1; fi
}

# What a REST call of METHOD to PATH may do, for gh api and curl alike.
api_path_rules() {   # $1 method $2 path $3 payload text $4 1 if part of it is unreadable
    local m="$1" p="${2%%\?*}" t="$3" o r n id lp rr
    p="${p%/}"; lp="$(lower "$p")"
    [[ "$p" =~ ^repos/ ]] || return 0
    if [[ "$lp" =~ ^repos/[^/]+/[^/]+/(pulls/[^/]+/(.*/)?[^/]*merge[^/]*|merges)$ ]]; then MERGE_CHECKED=1; fi
    case "$m" in GET|HEAD) return 0 ;; esac
    rr="$(api_repo "$p")" || refuse "$NO_REPO"
    read -r o r <<<"$rr"
    unreadable() { [ "$4" != 1 ] || refuse "this sends a payload the guard cannot read, to $p, so it is refused. Write the file first, in a separate step, or pass the text inline."; }

    # Merges: the merge and auto-merge endpoints of a PR, and the Merges
    # API, which lands a branch with no PR to check.
    if [[ "$lp" =~ ^repos/[^/]+/[^/]+/pulls/[^/]+/(.*/)?[^/]*merge[^/]*$ ]]; then
        MERGE_CHECKED=1
        [ "$m" = DELETE ] && return 0   # turning auto-merge off
        [[ "$p" =~ ^repos/[^/]+/[^/]+/pulls/([0-9]+)/ ]] \
            || refuse "could not tell which PR this merges, so it is refused. Use gh pr merge <number> --repo OWNER/REPO, or the GitHub MCP merge tool."
        check_merge "$o" "$r" "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$lp" =~ ^repos/[^/]+/[^/]+/merges$ ]]; then
        MERGE_CHECKED=1
        refuse "this merges a branch through the Merges API, with no PR the guard can check, so it is refused. Merge through the PR."
    fi
    # Moving the default branch by ref.
    if [[ "$lp" =~ ^repos/[^/]+/[^/]+/git/refs/heads/(.+)$ ]] && is_default_branch "${BASH_REMATCH[1]}" "$o/$r"; then
        refuse "this moves the default branch directly, which lands changes without their PR. Agents never do that; open a PR."
    fi

    # Labels.
    if [[ "$lp" =~ ^repos/[^/]+/[^/]+/(issues/[^/]+/)?labels/$LABEL$ ]]; then
        refuse "this removes, deletes or renames the \`$LABEL\` label. Only the owner does that; removing it does not release a hold."
    fi
    if [[ "$p" =~ ^repos/[^/]+/[^/]+/issues/([0-9]+)/labels$ ]] && [ "$m" != POST ]; then
        n="${BASH_REMATCH[1]}"
        unreadable "$@"
        if [ "$m" = PUT ] && printf '%s' "$(lower "$t")" | grep -q "$LABEL"; then return 0; fi
        check_label_kept "$o" "$r" "$n"
    elif [[ "$p" =~ ^repos/[^/]+/[^/]+/issues/[^/]+/labels$ ]] && [ "$m" != POST ]; then
        refuse "could not tell which PR's labels this changes, so it is refused."
    fi

    # Edits of a PR or issue: labels and the body.
    if [[ "$p" =~ ^repos/[^/]+/[^/]+/(issues|pulls)/([^/]+)$ ]] && [ "$m" = PATCH ]; then
        n="${BASH_REMATCH[2]}"
        [[ "$n" =~ ^[0-9]+$ ]] || refuse "could not tell which PR or issue this edits, so it is refused."
        unreadable "$@"
        if printf '%s' "$t" | grep -q 'labels' && ! printf '%s' "$(lower "$t")" | grep -q "$LABEL"; then
            check_label_kept "$o" "$r" "$n"
        fi
        if printf '%s' "$t" | grep -q 'body'; then check_body_edit "$o" "$r" "$n" "$t"; fi
    fi

    # Edits and deletions of comments and reviews.
    if [[ "$p" =~ ^repos/[^/]+/[^/]+/(issues|pulls)/comments/([^/]+)$ ]]; then
        id="${BASH_REMATCH[2]}"; n="${BASH_REMATCH[1]}"
        [[ "$id" =~ ^[0-9]+$ ]] || refuse "could not tell which comment this changes, so it is refused."
        unreadable "$@"
        check_comment_edit "$o" "$r" "$n" "$id" "$m" "$t"
    fi
    if [[ "$p" =~ ^repos/[^/]+/[^/]+/pulls/([^/]+)/reviews/([^/]+)$ ]]; then
        n="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"
        [[ "$n$id" =~ ^[0-9]+$ ]] || refuse "could not tell which review this changes, so it is refused."
        unreadable "$@"
        check_comment_edit "$o" "$r" "reviews/$n" "$id" "$m" "$t"
    fi
    return 0
}

# Whether branch $1 is the default branch of repository $2 (OWNER/REPO):
# main or master always; otherwise as the checkout records it, or GitHub
# says. A repository that cannot be read counts only main and master.
is_default_branch() {
    local b="${1#refs/heads/}" d
    case "$b" in main|master) return 0 ;; esac
    if [ -n "$CUR_DIR" ]; then
        d="$(git -C "$CUR_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" && [ "${d#origin/}" = "$b" ] && return 0
    fi
    if [ -n "${2:-}" ]; then
        d="$(api_get "repos/$2" | jq -r '.default_branch // empty' 2>/dev/null)" && [ -n "$d" ] && [ "$d" = "$b" ] && return 0
    fi
    return 1
}

# git push: refuse pushing to the default branch, or every branch.
git_push() {   # $1 directory, then push's arguments
    local dir="$1" w pos=() dst cur rrepo=""
    shift
    while [ "$#" -gt 0 ]; do
        w="$1"; shift
        case "$w" in
            --all|--mirror|--branches)
                refuse "this pushes every branch, the default branch among them, which lands changes without their PR. Push the one branch your PR is from." ;;
            -o|--push-option|--repo|--receive-pack|--exec) shift || true ;;
            -*) ;;
            *) pos+=("$w") ;;
        esac
    done
    # The repository the remote names, to learn its default branch.
    if [ -n "${pos[0]:-}" ]; then
        case "${pos[0]}" in
            *github.com*) rrepo="$(repo_of_url "${pos[0]}")" ;;
            *) [ -z "$dir" ] || rrepo="$(repo_of_url "$(git -C "$dir" remote get-url "${pos[0]}" 2>/dev/null)")" ;;
        esac
    fi
    if [ "${#pos[@]}" -le 1 ]; then
        # The current branch, pushed to its upstream or the same name.
        [ -n "$dir" ] || refuse "could not tell which branch this pushes, so it is refused. Name it: git push origin <branch>."
        cur="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)" || return 0
        dst="$(git -C "$dir" rev-parse --abbrev-ref "$cur@{upstream}" 2>/dev/null)" || dst="$cur"
        dst="${dst#*/}"
        is_default_branch "$dst" "$rrepo" && refuse "this pushes to the default branch ($dst), which lands changes without their PR. Agents never do that; push a branch and open a PR."
        is_default_branch "$cur" "$rrepo" && refuse "this pushes the default branch ($cur). Agents never push it; push a branch and open a PR."
        return 0
    fi
    for w in "${pos[@]:1}"; do
        w="${w#+}"
        case "$w" in
            *:*) dst="${w#*:}"; [ -n "$dst" ] || continue ;;
            HEAD|@) dst="$(git -C "${dir:-.}" symbolic-ref --short HEAD 2>/dev/null)" || continue ;;
            *) dst="$w" ;;
        esac
        dst="${dst#refs/heads/}"
        if is_default_branch "$dst" "$rrepo"; then
            refuse "this pushes to the default branch ($dst), which lands changes without their PR. Agents never do that; push a branch and open a PR."
        fi
    done
    return 0
}

# curl or wget to GitHub: data files, method and the API paths it names.
web_call() {
    local w method="" seg=" $* " p text="" bad=0
    case "$seg" in *github.com*|*api.github*) ;; *) return 0 ;; esac
    while [ "$#" -gt 0 ]; do
        w="$1"; shift
        case "$w" in
            -X|--request) method="${1:-}"; shift || true ;;
            -X?*) method="${w#-X}" ;;
            -d|--data|--data-binary|--data-raw|--data-urlencode|-F|--form|--json|--post-data|--body-data)
                POSTS_TEXT=1; add_at "${1:-}"; text="$text"$'\n'"${1:-}"
                case "${1:-}" in *=@*|@*) text="$text"$'\n'"$(payload_of "${1#*@}")" || bad=1 ;; esac
                shift || true ;;
            -T|--upload-file|--post-file|--body-file)
                POSTS_TEXT=1; add_file "${1:-}"
                text="$text"$'\n'"$(payload_of "${1:-}")" || bad=1; shift || true ;;
            --method=*) method="${w#--method=}" ;;
        esac
    done
    [ -n "$method" ] || method=POST   # cannot tell from flags alone; assume a write
    method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
    [ "$method" = GET ] || POSTS_TEXT=1
    for p in $(printf '%s\n' "$seg" | grep -oE 'api\.github\.com/repos/[^[:space:]"#]+' || true); do
        api_path_rules "$method" "${p#api.github.com/}" "$text" "$bad"
    done
}

# Walk the simple commands.
i=0; nw=${#WORDS[@]}
while [ "$i" -lt "$nw" ]; do
    seg=()
    while [ "$i" -lt "$nw" ] && [ "${WORDS[$i]}" != "$SEP" ] && [ "${WORDS[$i]}" != "$SEP)" ]; do
        seg+=("${WORDS[$i]}"); i=$((i + 1))
    done
    # Leaving a subshell that changed directory: where we are is unknown.
    if [ "$i" -lt "$nw" ] && [ "${WORDS[$i]}" = "$SEP)" ] && [ "$CD_SEEN" = 1 ]; then
        closing=1
    else
        closing=0
    fi
    i=$((i + 1))
    if [ "${#seg[@]}" -gt 0 ]; then
        # Find gh, curl, wget, git or cd in it, past assignments and wrappers.
        k=0
        while [ "$k" -lt "${#seg[@]}" ]; do
            b="$(basename -- "${seg[$k]}" 2>/dev/null || printf '%s' "${seg[$k]}")"
            case "$b" in gh|curl|wget|git|cd|pushd|popd) break ;; esac
            k=$((k + 1))
        done
        if [ "$k" -lt "${#seg[@]}" ]; then
            rest=()
            [ "${#seg[@]}" -le $((k + 1)) ] || rest=("${seg[@]:$((k + 1))}")
            case "$b" in
                cd|pushd) CD_SEEN=1; change_dir "${rest[0]:-}" ;;
                popd) CD_SEEN=1; CUR_DIR="" ;;
                curl|wget) web_call ${rest[@]+"${rest[@]}"} ;;
                git)
                    # git's own options before the subcommand.
                    gdir="$CUR_DIR"; j=0
                    while [ "$j" -lt "${#rest[@]}" ]; do
                        case "${rest[$j]}" in
                            -C) j=$((j + 1)); w="${rest[$j]:-}"
                                case "$w" in /*) gdir="$w" ;; *) [ -n "$gdir" ] && gdir="$gdir/$w" ;; esac
                                case "$w" in *'$'*) gdir="" ;; esac ;;
                            -c|--git-dir|--work-tree|--namespace) j=$((j + 1)) ;;
                            -*) ;;
                            *) break ;;
                        esac
                        j=$((j + 1))
                    done
                    if [ "${rest[$j]:-}" = push ]; then
                        git_push "$gdir" ${rest[@]+"${rest[@]:$((j + 1))}"}
                    fi ;;
                gh)
                    if [ "${#rest[@]}" -gt 0 ]; then
                        a="${rest[0]}"; s="${rest[1]:-}"
                        args=()
                        [ "${#rest[@]}" -le 2 ] || args=("${rest[@]:2}")
                        case "$a" in
                            pr|issue)
                                case "$s" in
                                    comment|review|create|edit|close|reopen|merge|lock) POSTS_TEXT=1 ;;
                                esac
                                gh_pr "$a" "$s" ${args[@]+"${args[@]}"} ;;
                            label) gh_label "$s" ${args[@]+"${args[@]}"} ;;
                            api) [ "${#rest[@]}" -le 1 ] || gh_api "${rest[@]:1}" ;;
                        esac
                    fi ;;
            esac
        fi
    fi
    [ "$closing" = 0 ] || CUR_DIR=""
done

# GraphQL mutations name no PR or comment the guard can read: refuse them.
GQL_RE='mergePullRequest|enablePullRequestAutoMerge|mergeBranch|updateRefs?[^[:alnum:]]|removeLabelsFromLabelable|clearLabelsFromLabelable|deleteLabel|updateLabel|updatePullRequest[^[:alnum:]]|updateIssue[^[:alnum:]]|updateIssueComment|deleteIssueComment|minimizeComment|updatePullRequestReview|deletePullRequestReview|updatePullRequestReviewComment|deletePullRequestReviewComment'

all_text="$cmd"
for f in ${POST_FILES[@]+"${POST_FILES[@]}"}; do
    case "$f" in ''|*=*) continue ;; esac
    if [ "$f" = - ]; then
        [ "$heredoc" = 1 ] || refuse "this posts text read from stdin, which the guard cannot check, so it is refused. Pass the text inline, in a heredoc, or from a file."
        continue
    fi
    if t="$(payload_of "$f")"; then
        all_text="$all_text"$'\n'"$t"
    elif [ "$heredoc" = 0 ]; then
        refuse "this posts the contents of $f, which the guard cannot read, so it is refused. Write the file first, in a separate step, or pass the text inline."
    fi
done

if [ "$POSTS_TEXT" = 1 ] && printf '%s' "$all_text" | grep -qE "$GQL_RE"; then
    refuse "this runs a GraphQL mutation that merges, moves a branch, changes labels or edits or deletes a PR, issue, comment or review. It names nothing the guard can check, so it is refused. Use gh pr, gh api with a REST path, or the GitHub MCP tools."
fi

# A merge endpoint the walk above did not parse (a path built from
# variables, say) cannot be checked.
if [ "$MERGE_CHECKED" = 0 ] \
    && printf '%s' "$cmd" | grep -qE 'pulls/[^[:space:]]*/[^[:space:]/]*merge([^[:alnum:]_]|$)|/merges([^[:alnum:]_]|$)'; then
    case "$cmd" in
        *gh*|*api.github*|*curl*|*wget*)
            refuse "could not tell which PR this merges, so it is refused. Use gh pr merge <number> --repo OWNER/REPO, or the GitHub MCP merge tool." ;;
    esac
fi

if [ "$POSTS_TEXT" = 1 ]; then
    check_text "$all_text"
fi

relevant=0
exit 0
