#!/usr/bin/env bash
#
# Decide whether a " (Needs Info)"-parked merge request has been answered.
#
# Usage: bash scripts/check-parked-mr.sh <project> <mr-iid>
#
# The GitHub skills' check-parked.sh has the same 0/5/6 contract but speaks `gh`; keep
# the two in step by hand.
#
# A parking run comments first and renames second, so a reply is anything after the
# newest rename. GitLab embeds the new title in its rename note as HTML, which is not
# worth parsing: if the current title carries the suffix, the latest rename parked it.
# Inline review comments are ordinary notes, so they count as replies too.
#
# Exit codes:
#   0  Answered. The replies are printed, one JSON object per line.
#   5  Nothing to measure replies against: either the merge request could not be read,
#      or no parking rename exists because the suffix was added by hand. Which one is
#      named on stderr. Skip it and mention it to the user.
#   6  Parked, but nobody has answered yet. Skip it.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/check-parked-mr.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

# --paginate prints one array per page; slurp them into one.
NOTES=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/notes?sort=asc&order_by=created_at&per_page=100" \
    2>/dev/null | jq -sc 'add') ||
    NOTES=''

if [ "$(printf '%s' "${NOTES:-null}" | jq -r 'type')" != "array" ]; then
    echo "cannot read the notes of !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
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
