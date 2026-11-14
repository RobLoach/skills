#!/usr/bin/env bash
#
# Claim a drupal.org issue, or confirm a handback, and wait until drupalbot has acted.
#
# Usage: bash scripts/poll-issue.sh claim|handback <project> <issue-iid>
#
# /do: commands are queued for drupalbot rather than answered: the comment lands at once
# and the assignment or label follows seconds later, or never. So this polls.
#
#   claim     Posts `/do:assign me` (GitLab's /assign needs a project role contributors
#             lack) and waits until you are assigned. /do:assign *adds* an assignee, so
#             the issue is re-read just before posting: one claimed since the search is
#             somebody else's, and joining them would read as a takeover.
#   handback  Posts nothing (the caller already did) and waits until you are unassigned
#             and the issue carries `state::needsReview`.
#
# Exit codes:
#   0  Done. The assignees and labels are printed.
#   5  The authenticated user, or for claim the issue, could not be read. Nothing posted.
#   6  drupalbot did not act within the wait. The comment is public: do not post it again.
#   7  claim only: somebody else holds the issue. Nothing posted.

set -euo pipefail

if [ "$#" -ne 3 ] || { [ "$1" != claim ] && [ "$1" != handback ]; }; then
    echo "usage: bash scripts/poll-issue.sh claim|handback <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
MODE=$1
PROJECT=$2
IID=$3
LABEL=state::needsReview

POLL_SECONDS=${LOACHBOT_CLAIM_POLL:-5}
MAX_POLLS=${LOACHBOT_CLAIM_MAX_POLLS:-24}

api() { glab api --hostname "$HOST" "$@"; }

# Without a username every issue reads as "not assigned to you", and a handback would
# confirm without drupalbot having done a thing.
if ! ME=$(api user 2>/dev/null | jq -r '.username // empty') || [ -z "$ME" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# One line, "done|pending assignees=[...] labels=[...]", or "unread" when the read
# failed. An unreadable read stays distinct from an empty assignee list: claiming over
# somebody because a dropped connection looked like "unassigned" is the mistake to avoid.
state() {
    local json
    json=$(api "projects/$NAMESPACE%2F$PROJECT/issues/$IID" 2>/dev/null) || json=''
    printf '%s' "${json:-null}" | jq -r --arg me "$ME" --arg mode "$MODE" --arg label "$LABEL" '
        if type != "object" then "unread"
        else
            [.assignees[].username] as $who
            | (.labels // []) as $labels
            | (($who | index($me)) != null) as $mine
            | (if $mode == "claim" then $mine
               else ($mine | not) and ($labels | index($label)) != null end) as $done
            | "\(if $done then "done" else "pending" end)" +
              " assignees=[\($who | join(","))] labels=[\($labels | join(","))]"
        end'
}

if [ "$MODE" = claim ]; then
    STATE=$(state)
    case $STATE in
        unread)
            echo "cannot read issue #$IID in $NAMESPACE/$PROJECT on $HOST" >&2
            exit 5
            ;;
        done*)
            echo "already assigned to $ME: ${STATE#done }"
            exit 0
            ;;
        *" assignees=[] "*) ;;
        *)
            echo "issue #$IID is held by somebody else: ${STATE#* }" >&2
            exit 7
            ;;
    esac
    glab issue note "$IID" -R "$HOST/$NAMESPACE/$PROJECT" -m "/do:assign me" >&2
fi

STATE=unread
for _ in $(seq 1 "$MAX_POLLS"); do
    sleep "$POLL_SECONDS"
    STATE=$(state)
    case $STATE in
        done*)
            echo "${STATE#done }"
            exit 0
            ;;
    esac
done

echo "drupalbot has not finished the $MODE on #$IID: ${STATE#* }" >&2
exit 6
