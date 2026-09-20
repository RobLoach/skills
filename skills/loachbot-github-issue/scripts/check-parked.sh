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
# rename; pass `pr` to count inline review comments as replies too.
#
# Exit codes:
#   0  Answered. The replies are printed, one JSON object per line.
#   6  Parked, but nobody has answered yet. Skip the item.
#   5  No parking rename exists: the suffix was added by hand, so there is nothing
#      to measure replies against. Skip the item and mention it to the user.

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: bash scripts/check-parked.sh <owner> <repo> <number> [pr]" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3
KIND=${4:-issue}

PARKED=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/events" \
    --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' \
    | tail -1)

# Guard on the timestamp: every string sorts after an empty one, so an unparked
# item would return its entire comment history below and read as a pile of replies.
if [ -z "$PARKED" ]; then
    echo "no parking rename found" >&2
    exit 5
fi
export PARKED

REPLIES=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
    --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}')

INLINE=
if [ "$KIND" = "pr" ]; then
    INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, path, body}')
fi

if [ -z "$REPLIES$INLINE" ]; then
    echo "parked and still unanswered" >&2
    exit 6
fi

printf '%s\n' "$REPLIES" "$INLINE" | sed '/^$/d'
