#!/usr/bin/env bash
#
# Reply to review threads on a merge request and resolve them, once the fixes they asked
# for have landed.
#
# Usage: bash scripts/resolve-threads.sh <project> <mr-iid> <sha-or-message> <discussion-id>...
#
# A commit SHA (7 to 40 hex) becomes "Resolved in <sha>."; anything else is the reply
# verbatim, sent with `-f` so a leading `@` is not read as a file. Replying before
# resolving leaves a trail of where the fix went. Already-resolved threads are skipped,
# so a rerun posts no duplicates.
#
# Exit codes:
#   0  Every thread named is resolved, by this run or an earlier one.
#   1  At least one could not be read, replied to or resolved. Each is named on stderr;
#      resolving needs the merge request's author or a maintainer.
#   5  The merge request could not be read.

set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "usage: bash scripts/resolve-threads.sh <project> <mr-iid> <sha-or-message> <discussion-id>..." >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
MESSAGE=$3
shift 3

if [[ $MESSAGE =~ ^[0-9a-f]{7,40}$ ]]; then
    MESSAGE="Resolved in $MESSAGE."
fi

api() { glab api --hostname "$HOST" "$@"; }

MR_PATH="projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID"
if ! api "$MR_PATH" >/dev/null 2>&1; then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

FAILED=0
for ID in "$@"; do
    RESOLVED=$(api "$MR_PATH/discussions/$ID" 2>/dev/null | jq -r '.notes[0].resolved') || RESOLVED=
    case $RESOLVED in
        true)
            echo "$ID: already resolved"
            continue
            ;;
        false) ;;
        *)
            echo "$ID: not a resolvable thread on !$IID" >&2
            FAILED=1
            continue
            ;;
    esac
    if ! api -X POST "$MR_PATH/discussions/$ID/notes" -f "body=$MESSAGE" >/dev/null 2>&1; then
        echo "$ID: reply failed" >&2
        FAILED=1
        continue
    fi
    if ! api -X PUT "$MR_PATH/discussions/$ID" -f "resolved=true" >/dev/null 2>&1; then
        echo "$ID: replied, but could not resolve it" >&2
        FAILED=1
        continue
    fi
    echo "$ID: resolved"
done

[ "$FAILED" -eq 0 ] || exit 1
