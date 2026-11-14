#!/usr/bin/env bash
#
# Make sure a drupal.org issue has a fork you can push to, creating it if it does not.
#
# Usage: bash scripts/ensure-fork.sh <project> <issue-iid>
#
# Every issue has one shared fork at issue/<project>-<issue-iid>. A contributor who is not
# a project member cannot create it or join it through the API, so this asks drupalbot -
# /do:fork creates it with <issue-iid>-issue-branch, /do:access grants push - and polls,
# since both are queued rather than answered.
#
# A fork this run created is also waited on until its import finishes and
# <issue-iid>-issue-branch exists: a worktree set up before then has no tracking ref, and
# the first --force-with-lease push is rejected as stale once the branch lands.
#
# A 404 is confirmed by a second read before /do:fork is posted, so one dropped
# connection cannot put a duplicate fork request on the issue.
#
# Emits one JSON object: fork_path, fork_id, fork_ssh_url (the git.drupal.org URL to push
# to), created (this run asked for the fork), access_via ("existing" | "comment").
#
# Exit codes:
#   0  The fork exists and you have push access. JSON on stdout.
#   5  The project, its issue or its existing fork could not be read; nothing was posted.
#   6  /do:fork or /do:access was posted but drupalbot did not act within the wait, or
#      the fork it created never finished importing. Report it with the issue URL - the
#      comment is public, so do not post it again.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/ensure-fork.sh <project> <issue-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

# Issue forks live under issue/ whatever namespace the parent sits in.
FORK_PATH="issue/$PROJECT-$IID"
FORK_ENC="issue%2F$PROJECT-$IID"

POLL_SECONDS=${LOACHBOT_FORK_POLL:-5}
MAX_POLLS=${LOACHBOT_FORK_MAX_POLLS:-24}
# GitLab's Developer role. Below this a branch cannot be pushed, so it is the real
# question rather than mere membership.
MIN_ACCESS=30

api() { glab api --hostname "$HOST" "$@"; }

# An unreadable response is fed to jq as `null` rather than nothing: jq prints nothing
# for empty input, and an empty string would then break a numeric comparison.
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

# "none" is the steady state of a fork whose copy finished long ago.
fork_ready() {
    local json=''
    json=$(api "projects/$FORK_ID" 2>/dev/null) || json=''
    FORK_SSH_URL=$(printf '%s' "${json:-null}" | jq -r '
        if type == "object" and ((.import_status // "none") | IN("finished", "none"))
        then (.ssh_url_to_repo // empty) else empty end')
    [ -n "$FORK_SSH_URL" ] &&
        api "projects/$FORK_ID/repository/branches/$IID-issue-branch" >/dev/null 2>&1
}

FORK_SSH_URL=
if [ "$CREATED" = true ]; then
    READY=false
    for _ in $(seq 1 "$MAX_POLLS"); do
        if fork_ready; then
            READY=true
            break
        fi
        echo "waiting for $FORK_PATH to finish importing" >&2
        sleep "$POLL_SECONDS"
    done
    if [ "$READY" != true ]; then
        echo "$FORK_PATH exists but never finished importing $IID-issue-branch" >&2
        exit 6
    fi
elif ! FORK_SSH_URL=$(api "projects/$FORK_ID" 2>/dev/null | jq -r '.ssh_url_to_repo // empty') ||
    [ -z "$FORK_SSH_URL" ]; then
    echo "cannot read $FORK_PATH (project $FORK_ID) on $HOST" >&2
    exit 5
fi

# members/all, because push access is often inherited from the parent project. A
# non-member is a 404, which answers 0.
my_access() {
    local json=''
    json=$(api "projects/$FORK_ID/members/all/$MY_ID" 2>/dev/null) || json=''
    printf '%s' "${json:-null}" |
        jq -r 'if type == "object" then (.access_level // 0) else 0 end'
}

ACCESS_VIA=existing
ACCESS=$(my_access)

if [ "$ACCESS" -lt "$MIN_ACCESS" ]; then
    echo "no push access to $FORK_PATH (access level $ACCESS); asking drupalbot with /do:access" >&2
    glab issue note "$IID" -R "$HOST/$NAMESPACE/$PROJECT" -m "/do:access" >&2
    ACCESS_VIA=comment
    for _ in $(seq 1 "$MAX_POLLS"); do
        sleep "$POLL_SECONDS"
        ACCESS=$(my_access)
        [ "$ACCESS" -ge "$MIN_ACCESS" ] && break
    done
fi

if [ "$ACCESS" -lt "$MIN_ACCESS" ]; then
    echo "push access to $FORK_PATH never arrived (access level $ACCESS)" >&2
    exit 6
fi

jq -nc \
    --arg path "$FORK_PATH" \
    --argjson id "$FORK_ID" \
    --arg url "$FORK_SSH_URL" \
    --argjson created "$CREATED" \
    --arg via "$ACCESS_VIA" \
    '{fork_path: $path, fork_id: $id, fork_ssh_url: $url, created: $created, access_via: $via}'
