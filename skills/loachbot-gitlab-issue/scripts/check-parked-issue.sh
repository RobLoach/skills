#!/usr/bin/env bash
#
# Decide whether a `state::blocked`-parked issue has been answered.
#
# Usage: bash scripts/check-parked-issue.sh <project> <issue-iid>
#
# loachbot-github-issue and loachbot-gitlab-mr park their work by appending
# " (Needs Info)" to a title they own. An issue in somebody else's queue is not a title
# to rewrite, so this skill parks with drupal.org's own `state::blocked` label instead.
# That costs nothing in the issue queue, where the label is what a human already reads
# to mean "waiting on something", and it is removed with /do:unlabel when the answer
# arrives.
#
# The label alone cannot be the marker, for two reasons. A maintainer applies
# `state::blocked` for their own reasons, and a label carries no timestamp a reply can
# be measured against. So the marker is the parking *comment*: a note of your own
# carrying the /do:label command that applied the label. Question and command go in one
# comment, which is also why this needs none of the comment-then-rename ordering care
# its siblings document - there is only ever one event to be newest.
#
# A reply is any later comment by somebody else. Your own notes are excluded, so a
# summary you post afterwards cannot un-park your own question, and drupalbot's are
# excluded because acknowledging a command is not an answer. Other project bots do
# comment on drupal.org issues and are not reliably named, so an automated triage note
# can still surface here as a reply - which is why the caller reads what is printed and
# decides whether it answers the question, rather than treating exit 0 as a green light.
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
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

if ! ME=$(api user 2>/dev/null | jq -r '.username // empty') || [ -z "$ME" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# Taken in two steps so the type check below is what reports an unreadable issue:
# `glab api` exits non-zero on a 404, and under `set -e` that would end the run here
# with no explanation of which read failed.
NOTES=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/issues/$IID/notes?sort=asc&order_by=created_at" 2>/dev/null) ||
    NOTES=''

if [ "$(printf '%s' "${NOTES:-null}" | jq -r 'type')" != "array" ]; then
    echo "cannot read the notes of issue #$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

# An issue can be parked, answered and re-parked any number of times; the most recent
# parking comment wins. drupalbot rewrites a /do: comment in place to append its own
# result, so match the command loosely rather than anchoring it.
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
