#!/usr/bin/env bash
#
# Make sure a drupal.org issue has a fork you can push to, creating it if it does not.
#
# Usage: bash scripts/ensure-fork.sh <project> <issue-iid>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# Drupal.org has no personal forks. Every issue gets one shared fork at
# issue/<project>-<issue-iid>, and everyone working the issue pushes to that. Creating
# it and getting push access are both done by commenting at drupalbot rather than
# through the GitLab API, because the API would refuse: a contributor who is not a
# member of the project cannot fork it, and cannot add themselves to the fork either.
# So this posts the two commands drupal.org provides for exactly that and then waits for
# the bot to act:
#
#   /do:fork     creates the fork and a <issue-iid>-issue-branch off the default branch
#   /do:access   grants the commenting user push access to the existing fork
#
# Both are asynchronous. Observed latency is a few seconds, but it is a queue rather
# than a request/response, so this polls instead of assuming.
#
# Posting /do:fork at an issue that already has one is the one way this script could
# make a mess that a human has to look at, so a 404 is confirmed by a second read before
# anything is written. One dropped connection should not produce a comment.
#
# Emits one JSON object:
#   {
#     "fork_path":    "issue/<project>-<issue-iid>",
#     "fork_id":      number,
#     "fork_ssh_url": the git.drupal.org URL to push to,
#     "created":      true when this run asked drupalbot to create the fork,
#     "granted":      true when this run asked drupalbot for push access
#   }
#
# Exit codes:
#   0  The fork exists and you have push access. JSON on stdout.
#   5  The project or its issue could not be read; nothing was posted.
#   6  /do:fork was posted but no fork appeared within the wait. Report it with the
#      issue URL - the comment is public, so do not post it again.
#   7  The fork exists, /do:access was posted, but push access never arrived within the
#      wait. Same handling: report it rather than re-posting.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/ensure-fork.sh <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

# Issue forks live under issue/ whatever namespace the parent sits in, so this one is
# not configurable alongside the others.
FORK_PATH="issue/$PROJECT-$IID"
FORK_ENC="issue%2F$PROJECT-$IID"

POLL_SECONDS=${LOACHBOT_FORK_POLL:-5}
MAX_POLLS=${LOACHBOT_FORK_MAX_POLLS:-24}
# GitLab's Developer role. Below this a branch cannot be pushed, so it is the real
# question rather than mere membership.
MIN_ACCESS=30

api() { glab api --hostname "$HOST" "$@"; }

# A missing fork is the expected case here, not an error, and `glab api` reports a 404
# by exiting non-zero - which under `set -e -o pipefail` would end the run before it
# could do anything about it. So every read whose absence is meaningful is taken in two
# steps, and an unreadable response is fed to jq as `null` rather than as nothing: jq
# emits no output at all for empty input, and an empty string would then flow on into a
# numeric comparison as a syntax error.
read_fork() {
    local json=''
    json=$(api "projects/$FORK_ENC" 2>/dev/null) || json=''
    printf '%s' "${json:-null}" |
        jq -r 'if type == "object" then (.id // empty) else empty end'
}

if ! MY_ID=$(api user 2>/dev/null | jq -r '.id // empty') || [ -z "$MY_ID" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

if ! api "projects/$NAMESPACE%2F$PROJECT/issues/$IID" >/dev/null 2>&1; then
    echo "cannot read issue #$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

CREATED=false
FORK_ID=$(read_fork)

if [ -z "$FORK_ID" ]; then
    # Confirm before writing: see the note above about not commenting on a blip.
    sleep "$POLL_SECONDS"
    FORK_ID=$(read_fork)
fi

if [ -z "$FORK_ID" ]; then
    echo "no fork at $FORK_PATH; asking drupalbot to create one" >&2
    glab issue note "$IID" -R "$HOST/$NAMESPACE/$PROJECT" -m "/do:fork" >&2
    CREATED=true
    for _ in $(seq 1 "$MAX_POLLS"); do
        sleep "$POLL_SECONDS"
        FORK_ID=$(read_fork)
        [ -n "$FORK_ID" ] && break
    done
fi

if [ -z "$FORK_ID" ]; then
    echo "drupalbot did not create $FORK_PATH within the wait" >&2
    exit 6
fi

if ! FORK_SSH_URL=$(api "projects/$FORK_ID" 2>/dev/null | jq -r '.ssh_url_to_repo // empty') ||
    [ -z "$FORK_SSH_URL" ]; then
    echo "cannot read $FORK_PATH (project $FORK_ID) on $HOST" >&2
    exit 5
fi

# members/all rather than members: push access is often inherited from the parent
# project rather than granted on the fork, and plain members cannot see that. A
# non-member reads as a 404, so this answers 0 rather than failing.
my_access() {
    local json=''
    json=$(api "projects/$FORK_ID/members/all/$MY_ID" 2>/dev/null) || json=''
    printf '%s' "${json:-null}" |
        jq -r 'if type == "object" then (.access_level // 0) else 0 end'
}

GRANTED=false
ACCESS=$(my_access)

if [ "$ACCESS" -lt "$MIN_ACCESS" ]; then
    echo "no push access to $FORK_PATH (access level $ACCESS); asking drupalbot" >&2
    glab issue note "$IID" -R "$HOST/$NAMESPACE/$PROJECT" -m "/do:access" >&2
    GRANTED=true
    for _ in $(seq 1 "$MAX_POLLS"); do
        sleep "$POLL_SECONDS"
        ACCESS=$(my_access)
        [ "$ACCESS" -ge "$MIN_ACCESS" ] && break
    done
fi

if [ "$ACCESS" -lt "$MIN_ACCESS" ]; then
    echo "push access to $FORK_PATH never arrived (access level $ACCESS)" >&2
    exit 7
fi

jq -nc \
    --arg path "$FORK_PATH" \
    --argjson id "$FORK_ID" \
    --arg url "$FORK_SSH_URL" \
    --argjson created "$CREATED" \
    --argjson granted "$GRANTED" \
    '{fork_path: $path, fork_id: $id, fork_ssh_url: $url, created: $created, granted: $granted}'
