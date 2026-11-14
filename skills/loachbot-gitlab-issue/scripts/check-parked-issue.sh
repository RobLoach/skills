#!/usr/bin/env bash
#
# Decide whether a `state::blocked`-parked issue has been answered.
#
# Usage: bash scripts/check-parked-issue.sh <project> <issue-iid>
#
# An issue in somebody else's queue is not a title to rewrite, so this skill parks with
# `state::blocked` rather than a " (Needs Info)" suffix. The label alone cannot be the
# marker - maintainers set it for their own reasons, and it carries no timestamp - so the
# marker is your own comment carrying the /do:label command, question and command in one.
#
# A reply is a later comment by anyone but you or drupalbot. Other bots are not reliably
# named and can still surface as replies, so read what is printed before acting on it.
#
# Exit codes:
#   0  Answered. The replies are printed, one JSON object per line. Read them: they are
#      candidate answers, not a verdict.
#   5  No parking comment exists, so `state::blocked` was applied by hand and there is
#      nothing to measure replies against. Skip the issue and mention it to the user.
#   6  Parked, and nobody has answered yet. Skip the issue.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/check-parked-issue.sh <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

if ! ME=$(api user 2>/dev/null | jq -r '.username // empty') || [ -z "$ME" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# --paginate prints one array per page; slurp them into one.
NOTES=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/issues/$IID/notes?sort=asc&order_by=created_at&per_page=100" \
    2>/dev/null | jq -sc 'add') ||
    NOTES=''

if [ "$(printf '%s' "${NOTES:-null}" | jq -r 'type')" != "array" ]; then
    echo "cannot read the notes of issue #$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

# The most recent parking comment wins. drupalbot rewrites a /do: comment in place to
# append its result, so the command is matched loosely rather than anchored.
PARKED=$(printf '%s' "$NOTES" | jq -r --arg me "$ME" '
    map(select(.system == false
               and .author.username == $me
               and (.body | contains("/do:label") and contains("state::blocked"))))
    | last
    | .created_at // empty
')

# Guard on the timestamp: every string sorts after an empty one, so an unparked issue
# would return its whole comment history below and read as a pile of replies.
if [ -z "$PARKED" ]; then
    echo "no parking comment found for issue #$IID" >&2
    exit 5
fi

REPLIES=$(printf '%s' "$NOTES" | jq -c --arg parked "$PARKED" --arg me "$ME" '
    .[]
    | select(.system == false
             and .created_at > $parked
             and .author.username != $me
             and .author.username != "drupalbot")
    | {author: .author.username, created_at, body}
')

if [ -z "$REPLIES" ]; then
    echo "parked and still unanswered" >&2
    exit 6
fi

printf '%s\n' "$REPLIES"
