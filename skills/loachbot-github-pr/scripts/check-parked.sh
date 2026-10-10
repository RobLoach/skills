#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Decide whether a " (Needs Info)"-parked issue or Pull Request has been answered.
#
# Usage: bash scripts/check-parked.sh <owner> <repo> <number> [pr]
#
# Two sibling scripts answer this same question elsewhere, and none of the three can
# share this file - one speaks `gh`, the others `glab` - so nothing in CI catches them
# drifting apart:
#   * loachbot-gitlab-mr/scripts/check-parked-mr.sh parks by renaming too, with the same
#     comment-then-rename invariant and the same 0/5/6 contract. Change the parking logic
#     in one and change it there.
#   * loachbot-gitlab-issue/scripts/check-parked-issue.sh keeps the 0/5/6 contract but
#     parks with a `state::blocked` label rather than a rename, because an issue in
#     somebody else's queue is not a title to rewrite. That difference is deliberate: it
#     is not a copy of this logic and must not be synced to it.
#
# A parking run comments first and renames second, so the parking rename is the
# newest event it leaves behind. The most recent one wins: an item can be parked,
# answered and re-parked any number of times. A reply is anything posted after that
# rename; pass `pr` to count inline review comments as replies too.
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

# Every read here is taken in two steps. `gh` exits non-zero on a 404, and under
# `set -e -o pipefail` that ends the run before it can say which read failed - so an
# unreadable item would hand back `gh`'s own exit code, which means nothing to the
# caller. None of them may fall back to "found nothing" either: a failed comments read
# treated as "no replies" would report an answered item as unanswered and skip it on
# every future run.
RENAMES=''
if ! RENAMES=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/events" \
    --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' \
    2>/dev/null); then
    echo "cannot read the events of $OWNER/$REPO#$NUMBER" >&2
    exit 5
fi

# Guard on the timestamp: every string sorts after an empty one, so an unparked
# item would return its entire comment history below and read as a pile of replies.
PARKED=$(printf '%s' "$RENAMES" | tail -1)
if [ -z "$PARKED" ]; then
    echo "no parking rename found" >&2
    exit 5
fi
export PARKED

if ! REPLIES=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
    --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}' \
    2>/dev/null); then
    echo "cannot read the comments of $OWNER/$REPO#$NUMBER" >&2
    exit 5
fi

INLINE=
if [ "$KIND" = "pr" ]; then
    if ! INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, path, body}' \
        2>/dev/null); then
        echo "cannot read the review comments of $OWNER/$REPO#$NUMBER" >&2
        exit 5
    fi
fi

if [ -z "$REPLIES$INLINE" ]; then
    echo "parked and still unanswered" >&2
    exit 6
fi

printf '%s\n' "$REPLIES" "$INLINE" | sed '/^$/d'
