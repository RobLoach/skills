#!/usr/bin/env bash
#
# Claim a drupal.org issue by assigning it to yourself, and confirm the assignment
# actually landed.
#
# Usage: bash scripts/claim-issue.sh <project> <issue-iid>
#
# GitLab's own /assign needs a project role most contributors do not have on somebody
# else's project, so drupal.org provides /do:assign - a comment drupalbot reads and acts
# on. That makes claiming asynchronous: the comment posts immediately and the assignment
# follows a few seconds later, or does not. Nothing downstream should start on an issue
# whose claim silently failed, so this polls until the assignment is visible.
#
# /do:assign *adds* an assignee rather than replacing the list, so claiming an issue
# somebody else already took would put both of you on it and read, to them, as a
# takeover. The assignees are therefore re-read immediately before posting: the search
# that picked this issue is a snapshot, and an issue claimed in between is somebody
# else's now.
#
# Exit codes:
#   0  Assigned to you. The assignee list is printed.
#   5  The issue could not be read; nothing was posted.
#   6  /do:assign was posted but drupalbot never applied it within the wait. The comment
#      is public, so report it with the issue URL rather than posting it again.
#   7  Somebody else claimed it between the search and now; nothing was posted. Leave it
#      to them and pick another issue.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/claim-issue.sh <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

POLL_SECONDS=${LOACHBOT_CLAIM_POLL:-5}
MAX_POLLS=${LOACHBOT_CLAIM_MAX_POLLS:-24}

api() { glab api --hostname "$HOST" "$@"; }

mine() {
    case ",$1," in
        *",$ME,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# `glab api` exits non-zero on an unreadable response, which under `set -e -o pipefail`
# would end a poll over one dropped connection. An unreadable response is fed to jq as
# `null` so it answers "nobody" and the next poll decides.
assignees() {
    local json=''
    json=$(api "projects/$NAMESPACE%2F$PROJECT/issues/$IID" 2>/dev/null) || json=''
    printf '%s' "${json:-null}" |
        jq -r 'if type == "object" then ([.assignees[].username] | join(",")) else "" end'
}

if ! ME=$(api user 2>/dev/null | jq -r '.username // empty') || [ -z "$ME" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# One read answers both "can this be read at all" and "who holds it". Keeping them
# together matters: a dropped connection that fell back to an empty assignee list would
# look exactly like an unclaimed issue, and claiming over somebody is the mistake this
# script is most concerned with not making.
if ! ISSUE=$(api "projects/$NAMESPACE%2F$PROJECT/issues/$IID" 2>/dev/null); then
    echo "cannot read issue #$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

CURRENT=$(printf '%s' "$ISSUE" | jq -r '[.assignees[].username] | join(",")')

if mine "$CURRENT"; then
    echo "already assigned to $ME: $CURRENT"
    exit 0
fi

if [ -n "$CURRENT" ]; then
    echo "issue #$IID is assigned to $CURRENT, not to you" >&2
    exit 7
fi

glab issue note "$IID" -R "$HOST/$NAMESPACE/$PROJECT" -m "/do:assign me" >&2

for _ in $(seq 1 "$MAX_POLLS"); do
    sleep "$POLL_SECONDS"
    CURRENT=$(assignees)
    if mine "$CURRENT"; then
        echo "assigned to $ME: $CURRENT"
        exit 0
    fi
done

echo "drupalbot did not assign issue #$IID to $ME within the wait" >&2
exit 6
