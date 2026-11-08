#!/usr/bin/env bash
#
# Print everything Step 3 needs about a Pull Request's feedback, one JSON object per line.
#
# Usage: bash scripts/fetch-feedback.sh <owner> <repo> <pr-number>
#
# Lines, by `kind`:
#   pr       title, body, last_commit (the newest commit's date)
#   review   your review summaries with a body: id, submitted_at, body
#   comment  your regular comments: id, created_at, html_url, body, handled
#   inline   your inline review comments: the same, plus path
#
# Only the logged-in user's feedback is printed; it is the only feedback to act on.
# REST rather than `gh pr view --json comments`, because Step 4's reaction endpoints need
# the numeric `id`, not a GraphQL node ID. `handled` is true once *you* reacted 🚀: the
# reaction count alone is a bare total, so someone else's 🚀 used as emphasis would hide
# a comment nobody handled.
#
# Exit codes:
#   0  Printed.
#   5  A read failed; stderr names which. Nothing is printed, since a partial list
#      would read as "nothing left to address".

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: bash scripts/fetch-feedback.sh <owner> <repo> <pr-number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3

# Every read is taken in two steps: `gh` exits non-zero on a 404, and `set -e` would
# hand its code back instead of 5.
if ! AUTHOR=$(gh api user --jq '.login' 2>/dev/null) || [ -z "$AUTHOR" ]; then
    echo "cannot read the logged-in user" >&2
    exit 5
fi
export AUTHOR

if ! PR=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" --json title,body,commits \
    --jq '{kind: "pr", title, body, last_commit: .commits[-1].committedDate}' 2>/dev/null); then
    echo "cannot read $OWNER/$REPO#$NUMBER" >&2
    exit 5
fi

if ! REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/reviews" \
    --jq '.[] | select(.user.login == env.AUTHOR and .body != "") | {kind: "review", id, submitted_at, body}' \
    2>/dev/null); then
    echo "cannot read the reviews of $OWNER/$REPO#$NUMBER" >&2
    exit 5
fi

# <kind> <list endpoint> <reaction endpoint prefix>
fetch_comments() {
    local kind=$1 list=$2 prefix=$3 lines line id mine handled
    if ! lines=$(gh api --paginate "$list" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, path, body, rockets: .reactions.rocket}' \
        2>/dev/null); then
        echo "cannot read $list" >&2
        exit 5
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        handled=false
        # Only comments with a 🚀 at all cost an extra read.
        if [ "$(jq '.rockets' <<<"$line")" -gt 0 ]; then
            id=$(jq '.id' <<<"$line")
            if ! mine=$(gh api --paginate "$prefix/$id/reactions?content=rocket" \
                --jq '.[] | select(.user.login == env.AUTHOR) | .id' 2>/dev/null); then
                echo "cannot read the reactions of $prefix/$id" >&2
                exit 5
            fi
            [ -z "$mine" ] || handled=true
        fi
        jq -c --arg kind "$kind" --argjson handled "$handled" \
            '{kind: $kind} + (del(.rockets) | with_entries(select(.value != null))) + {handled: $handled}' <<<"$line"
    done <<<"$lines"
}

# Collected before printing, so a failed read prints nothing rather than half a list.
COMMENTS=$(fetch_comments comment "repos/$OWNER/$REPO/issues/$NUMBER/comments" "repos/$OWNER/$REPO/issues/comments")
INLINE=$(fetch_comments inline "repos/$OWNER/$REPO/pulls/$NUMBER/comments" "repos/$OWNER/$REPO/pulls/comments")

printf '%s\n' "$PR" "$REVIEWS" "$COMMENTS" "$INLINE" | sed '/^$/d'
