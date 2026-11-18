#!/usr/bin/env bash
#
# Find the issue number behind a drupal.org merge request, from its source fork's path.
#
# Usage: bash scripts/mr-issue-ref.sh <project> <mr-iid>
#
# The number comes from the fork, issue/<project>-<number>, not the branch name, which
# contributors rename; it is the last hyphen-separated field, which survives a hyphen in
# the machine name. What the number means is read-issue.sh's question.
#
# This is the guard that keeps a force-push from resetting an RTBC, so an unreadable
# merge request or fork is its own exit, never mistaken for "no issue to check".
# source_project_id= goes to stderr either way, for opening a port on the same fork.
#
# Exit codes:
#   0  The issue number is printed.
#   3  The branch lives in the target project itself, not a fork: there is nowhere to
#      push it except the canonical repository. Skip it.
#   5  The merge request or its source project could not be read. Skip it.
#   6  The source is a fork, but not an issue fork, so there is no issue to check.

set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ $2 =~ ^[0-9]+$ ]]; then
    echo "usage: bash scripts/mr-issue-ref.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null) || MR=''
SOURCE_ID=$(printf '%s' "${MR:-null}" | jq -r '.source_project_id // empty' 2>/dev/null) || SOURCE_ID=
TARGET_ID=$(printf '%s' "${MR:-null}" | jq -r '.target_project_id // empty' 2>/dev/null) || TARGET_ID=
if [ -z "$SOURCE_ID" ] || [ -z "$TARGET_ID" ]; then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi
echo "source_project_id=$SOURCE_ID" >&2

if [ "$SOURCE_ID" = "$TARGET_ID" ]; then
    echo "!$IID's branch lives in $NAMESPACE/$PROJECT itself, not a fork" >&2
    exit 3
fi

SOURCE=$(api "projects/$SOURCE_ID" 2>/dev/null) || SOURCE=''
SOURCE_PATH=$(printf '%s' "${SOURCE:-null}" | jq -r '.path_with_namespace // empty' 2>/dev/null) ||
    SOURCE_PATH=
if [ -z "$SOURCE_PATH" ]; then
    echo "cannot read the source project ($SOURCE_ID) of !$IID on $HOST" >&2
    exit 5
fi

REF=${SOURCE_PATH##*-}
if [[ $SOURCE_PATH != issue/* ]] || ! [[ $REF =~ ^[0-9]+$ ]]; then
    echo "!$IID comes from $SOURCE_PATH, not an issue fork" >&2
    exit 6
fi

echo "$REF"
