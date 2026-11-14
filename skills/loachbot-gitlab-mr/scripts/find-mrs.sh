#!/usr/bin/env bash
#
# List your open drupal.org merge requests with what each one's pipeline really says,
# most recently updated first.
#
# Usage: bash scripts/find-mrs.sh [project]
#
# Prints one line per merge request:
#   <namespace>/<project>!<iid>\t<target-branch>\tpipeline=<status>\tfailing=<n>\t<title>
#
# `failing` counts jobs whose latest attempt failed, forgiven ones included. That is the
# number to triage on rather than `pipeline=`: drupal.org's CI template marks jobs
# `allow_failure: true`, so a pipeline reads `success` with those jobs red.
#
# The list endpoint omits head_pipeline entirely, so each merge request is read on its
# own. One loop here costs a handful of reads; it is not worth a sub-agent per candidate.
#
# Exit codes:
#   0  Merge requests printed.
#   5  The authenticated user or the merge request search could not be read.
#   6  You have no open merge requests (in [project], when given).

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: bash scripts/find-mrs.sh [project]" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
SCOPE=$NAMESPACE/
# A named project is asked directly rather than filtered out of the global search: that
# search returns your merge requests from every project, and one busy elsewhere would
# push this project's off the page.
ENDPOINT="merge_requests?scope=all&"
if [ "$#" -eq 1 ]; then
    SCOPE="$NAMESPACE/$1!"
    ENDPOINT="projects/$NAMESPACE%2F$1/merge_requests?"
fi

api() { glab api --hostname "$HOST" "$@"; }

if ! MY_ID=$(api user 2>/dev/null | jq -r '.id // empty') || [ -z "$MY_ID" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# --paginate prints one array per page; slurp them into one.
LIST=$(api --paginate "${ENDPOINT}author_id=$MY_ID&state=opened&order_by=updated_at&sort=desc&per_page=100" \
    2>/dev/null | jq -sc 'add') || LIST=''
if [ "$(printf '%s' "${LIST:-null}" | jq -r 'type')" != "array" ]; then
    echo "cannot search merge requests on $HOST" >&2
    exit 5
fi

CANDIDATES=$(printf '%s' "$LIST" |
    jq -r --arg scope "$SCOPE" '.[] | select(.references.full | startswith($scope)) | "\(.project_id) \(.iid)"')

if [ -z "$CANDIDATES" ]; then
    echo "no open merge requests of yours" >&2
    exit 6
fi

while read -r PID MR_IID; do
    MR=$(api "projects/$PID/merge_requests/$MR_IID" 2>/dev/null) || MR=''
    [ -n "$MR" ] || continue
    PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
    PIPELINE_PROJECT=$(printf '%s' "$MR" | jq -r '.head_pipeline.project_id // .source_project_id // empty')
    FAILING=0
    if [ -n "$PIPELINE_ID" ]; then
        FAILING=$(api --paginate "projects/$PIPELINE_PROJECT/pipelines/$PIPELINE_ID/jobs?per_page=100" \
            2>/dev/null | jq -s 'add // [] | group_by(.name) | map(max_by(.id))
                | map(select(.status == "failed" or .status == "canceled")) | length') || FAILING='?'
    fi
    printf '%s' "$MR" | jq -r --arg failing "$FAILING" \
        '"\(.references.full)\t\(.target_branch)\tpipeline=\(.head_pipeline.status // "none")\tfailing=\($failing)\t\(.title)"'
done <<<"$CANDIDATES"
