#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Decide whether a " (Needs Info)"-parked issue or Pull Request has been answered.
#
# Usage: bash scripts/check-parked.sh <owner> <repo> <number> [pr]
#
# A parking run comments first and renames second, so the parking rename is the
# newest event it leaves behind. The most recent one wins: an item can be parked,
# answered and re-parked any number of times. A reply is anything posted after that
# rename; pass `pr` to count inline review comments and review summaries as replies
# too.
#
# Exit codes:
#   0  Answered. The replies are printed, one JSON object per line.
#   6  Parked, but nobody has answered yet. Skip the item.
#   5  Nothing to measure replies against: either the item could not be read, or no
#      parking rename exists because the suffix was added by hand. Which one is named
#      on stderr. Skip the item and mention it to the user.

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: bash scripts/check-parked.sh <owner> <repo> <number> [pr]" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3
KIND=${4:-issue}

# gh's own message (a 404, an expired token) is the useful part of a failed read, so it
# is kept and printed rather than discarded.
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

# <description> <endpoint> <jq filter>: prints the filtered result, or exits 5.
read_api() {
    if ! gh api --paginate "$2" --jq "$3" 2>"$ERR"; then
        cat "$ERR" >&2
        echo "cannot read the $1 of $OWNER/$REPO#$NUMBER" >&2
        exit 5
    fi
}

RENAMES=$(read_api events "repos/$OWNER/$REPO/issues/$NUMBER/events" \
    '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at')

# Guard on the timestamp: every string sorts after an empty one, so an unparked
# item would return its entire comment history below and read as a pile of replies.
PARKED=$(printf '%s' "$RENAMES" | tail -1)
if [ -z "$PARKED" ]; then
    echo "no parking rename found" >&2
    exit 5
fi
export PARKED

REPLIES=$(read_api comments "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
    '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}')

INLINE=
REVIEWS=
if [ "$KIND" = "pr" ]; then
    INLINE=$(read_api "review comments" "repos/$OWNER/$REPO/pulls/$NUMBER/comments" \
        '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, path, body}')
    # A review summary is where an answer often goes, and it is neither kind of comment.
    # An empty body is a bare approval or the shell around inline comments counted above.
    REVIEWS=$(read_api reviews "repos/$OWNER/$REPO/pulls/$NUMBER/reviews" \
        '.[] | select(.submitted_at != null and .submitted_at > env.PARKED and (.body // "") != "")
             | {author: .user.login, created_at: .submitted_at, body}')
fi

if [ -z "$REPLIES$INLINE$REVIEWS" ]; then
    echo "parked and still unanswered" >&2
    exit 6
fi

printf '%s\n' "$REPLIES" "$INLINE" "$REVIEWS" | sed '/^$/d'
