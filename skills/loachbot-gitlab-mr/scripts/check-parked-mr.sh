#!/usr/bin/env bash
#
# Decide whether a " (Needs Info)"-parked merge request has been answered.
#
# Usage: bash scripts/check-parked-mr.sh <project> <mr-iid>
#
# loachbot-github-issue/scripts/check-parked.sh is the GitHub half of this, with the
# same comment-then-rename invariant and the same 0/5/6 contract. It cannot share this
# file - one speaks `gh`, the other `glab` - so nothing in CI catches the two drifting
# apart. Change the parking logic in one and change it in the other.
#
# A parking run comments first and renames second, so the parking rename is the newest
# event it leaves behind. A reply is anything posted after that rename.
#
# GitLab records a rename as a system note reading "changed title from ...". The new
# title is embedded in that note as HTML, which is not worth parsing: if the merge
# request's *current* title ends with the suffix, then the latest title change is by
# definition the one that parked it. A merge request can be parked, answered and
# re-parked any number of times; the most recent rename wins.
#
# Inline review comments on a merge request are ordinary notes, so they count as
# replies without asking anywhere else.
#
# Exit codes:
#   0  Answered. The replies are printed, one JSON object per line.
#   5  No parking rename exists: the suffix was added by hand, so there is nothing to
#      measure replies against. Skip it and mention it to the user.
#   6  Parked, but nobody has answered yet. Skip it.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/check-parked-mr.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

NOTES=$(api --paginate \
    "projects/project%2F$PROJECT/merge_requests/$IID/notes?sort=asc&order_by=created_at" 2>/dev/null)

if [ "$(printf '%s' "$NOTES" | jq -r 'type')" != "array" ]; then
    echo "cannot read the notes of !$IID in project/$PROJECT on $HOST" >&2
    exit 5
fi

PARKED=$(printf '%s' "$NOTES" | jq -r '
    map(select(.system == true and (.body | contains("changed title from"))))
    | last
    | .created_at // empty
')

# Guard on the timestamp: every string sorts after an empty one, so an unparked merge
# request would return its whole comment history below and read as a pile of replies.
if [ -z "$PARKED" ]; then
    echo "no parking rename found" >&2
    exit 5
fi

REPLIES=$(printf '%s' "$NOTES" | jq -c --arg parked "$PARKED" '
    .[]
    | select(.system == false and .created_at > $parked)
    | {author: .author.username, created_at, body}
')

if [ -z "$REPLIES" ]; then
    echo "parked and still unanswered" >&2
    exit 6
fi

printf '%s\n' "$REPLIES"
