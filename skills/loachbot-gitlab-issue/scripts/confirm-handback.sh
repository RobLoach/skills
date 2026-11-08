#!/usr/bin/env bash
#
# Confirm drupalbot acted on a handback comment: you are no longer assigned, and the
# issue carries `state::needsReview`.
#
# Usage: bash scripts/confirm-handback.sh <project> <issue-iid>
#
# /do: commands are queued rather than answered, so the comment lands at once and the
# assignment and label follow a few seconds later - or do not. This polls instead of
# assuming, the same way claim-issue.sh does for the claim.
#
# Exit codes:
#   0  Both took effect. The assignees and labels are printed.
#   6  Not both within the wait. The current assignees and labels are on stderr. Do not
#      post the comment again: a duplicated handback in the thread is worse than a label
#      somebody sets by hand.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/confirm-handback.sh <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
LABEL=state::needsReview

# The claim's knobs on purpose: both wait on the same drupalbot queue.
POLL_SECONDS=${LOACHBOT_CLAIM_POLL:-5}
MAX_POLLS=${LOACHBOT_CLAIM_MAX_POLLS:-24}

api() { glab api --hostname "$HOST" "$@"; }

ME=$(api user 2>/dev/null | jq -r '.username // empty') || ME=''

STATE=''
for _ in $(seq 1 "$MAX_POLLS"); do
    sleep "$POLL_SECONDS"
    # An unreadable response is a blip: feed jq `null` and let the next poll decide.
    JSON=$(api "projects/$NAMESPACE%2F$PROJECT/issues/$IID" 2>/dev/null) || JSON=''
    STATE=$(printf '%s' "${JSON:-null}" | jq -r --arg me "$ME" --arg label "$LABEL" '
        if type != "object" then "unread"
        else
            ([.assignees[].username] | index($me) == null) as $unassigned
            | ((.labels | index($label)) != null) as $labelled
            | "\(if $unassigned and $labelled then "done" else "pending" end)" +
              " assignees=[\([.assignees[].username] | join(","))] labels=[\(.labels | join(","))]"
        end')
    case $STATE in
        done*)
            echo "${STATE#done }"
            exit 0
            ;;
    esac
done

echo "drupalbot has not finished the handback on #$IID: ${STATE#* }" >&2
exit 6
