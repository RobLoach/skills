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
# REST rather than `gh pr view --json comments`: the reaction endpoints need numeric ids.
# `handled` means *you* reacted 🚀; the count alone would let someone else's 🚀 hide a
# comment nobody handled.
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
    local kind=$1 list=$2 prefix=$3 lines id rockets json mine
    export KIND=$kind
    # The id and 🚀 count lead each line, tab-separated, so the shell can pick out the
    # comments worth a reaction lookup without a separate JSON parser.
    if ! lines=$(gh api --paginate "$list" \
        --jq '.[] | select(.user.login == env.AUTHOR)
              | "\(.id)\t\(.reactions.rocket // 0)\t\({kind: env.KIND, id, created_at, html_url, path, body, handled: false}
                                                    | with_entries(select(.value != null)) | tojson)"' \
        2>/dev/null); then
        echo "cannot read $list" >&2
        exit 5
    fi
    while IFS=$'\t' read -r id rockets json; do
        [ -n "$id" ] || continue
        # Only comments with a 🚀 at all cost an extra read.
        if [ "$rockets" -gt 0 ]; then
            if ! mine=$(gh api --paginate "$prefix/$id/reactions?content=rocket" \
                --jq '.[] | select(.user.login == env.AUTHOR) | .id' 2>/dev/null); then
                echo "cannot read the reactions of $prefix/$id" >&2
                exit 5
            fi
            # tojson escapes every quote inside a string value, so the first unescaped
            # "handled":false can only be the key itself.
            [ -z "$mine" ] || json=${json/'"handled":false'/'"handled":true'}
        fi
        printf '%s\n' "$json"
    done <<<"$lines"
}

# Collected before printing, so a failed read prints nothing rather than half a list.
COMMENTS=$(fetch_comments comment "repos/$OWNER/$REPO/issues/$NUMBER/comments" "repos/$OWNER/$REPO/issues/comments")
INLINE=$(fetch_comments inline "repos/$OWNER/$REPO/pulls/$NUMBER/comments" "repos/$OWNER/$REPO/pulls/comments")

printf '%s\n' "$PR" "$REVIEWS" "$COMMENTS" "$INLINE" | sed '/^$/d'
