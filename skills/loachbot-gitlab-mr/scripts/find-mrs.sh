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
# Triage on `failing` (latest attempts that failed, forgiven ones included), not
# `pipeline=`: drupal.org's `allow_failure` jobs leave a pipeline `success` with them red.
# Jobs of downstream pipelines count too. `failing=?` means the jobs could not be read,
# or the pipeline ended red, canceled or blocked with no failed job to show for it.
# The list endpoint omits head_pipeline, so each merge request is read on its own.
#
# Exit codes:
#   0  Merge requests printed.
#   5  The authenticated user or the merge request search could not be read, or
#      merge requests were found but none of them could be read.
#   6  You have no open merge requests (in [project], when given).

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: bash scripts/find-mrs.sh [project]" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
SCOPE=$NAMESPACE/
# A named project is asked directly: in the global search, merge requests elsewhere
# could push this project's off the page.
ENDPOINT="merge_requests?scope=all&"
if [ "$#" -eq 1 ]; then
    SCOPE="$NAMESPACE/$1!"
    ENDPOINT="projects/$NAMESPACE%2F$1/merge_requests?"
fi

api() { glab api --hostname "$HOST" "$@"; }

# A pipeline's jobs plus those of the pipelines its bridges trigger, as one array of
# {id, name, status, allow_failure, project_id}. A bridge without `strategy: depend`
# stays green whatever its child does, so only the child's own jobs say red. Child jobs
# are named <bridge>/<job> and carry their own project, where their logs live; a bridge
# that triggered nothing stands in for itself. Only one level down is followed.
pipeline_jobs() {
    local JOBS BRIDGES ALL CHILD NAME PID ID
    JOBS=$(api --paginate "projects/$1/pipelines/$2/jobs?per_page=100" 2>/dev/null |
        jq -sc 'add | map({id, name, status, allow_failure})') || return 1
    BRIDGES=$(api --paginate "projects/$1/pipelines/$2/bridges?per_page=100" 2>/dev/null |
        jq -sc 'add // [] | map({id, name, status, allow_failure,
            down: (.downstream_pipeline // null | if . then {id, project_id} else null end)})') ||
        return 1
    ALL=$(printf '%s\n%s' "$JOBS" "$BRIDGES" | jq -sc --arg p "$1" '
        .[0] + [.[1][] | select(.down == null) | del(.down)] | map(. + {project_id: $p})')
    while IFS=$'\t' read -r NAME PID ID; do
        [ -n "$NAME" ] || continue
        CHILD=$(api --paginate "projects/$PID/pipelines/$ID/jobs?per_page=100" 2>/dev/null |
            jq -sc --arg b "$NAME" --arg p "$PID" '
                add | map({id, name: "\($b)/\(.name)", status, allow_failure, project_id: $p})') ||
            return 1
        ALL=$(printf '%s\n%s' "$ALL" "$CHILD" | jq -sc 'add')
    done < <(printf '%s' "$BRIDGES" |
        jq -r '.[] | select(.down) | "\(.name)\t\(.down.project_id)\t\(.down.id)"')
    printf '%s' "$ALL"
}

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

# A merge request that cannot be read is skipped, but counted: with nothing printed,
# skips are an outage, not "nothing to do".
PRINTED=0
SKIPPED=0
while read -r PID MR_IID; do
    MR=$(api "projects/$PID/merge_requests/$MR_IID" 2>/dev/null) || MR=''
    if [ -z "$MR" ]; then
        SKIPPED=$((SKIPPED + 1))
        echo "cannot read merge request !$MR_IID in project $PID; skipped" >&2
        continue
    fi
    PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
    PIPELINE_PROJECT=$(printf '%s' "$MR" | jq -r '.head_pipeline.project_id // .source_project_id // empty')
    PIPELINE_STATUS=$(printf '%s' "$MR" | jq -r '.head_pipeline.status // empty')
    FAILING=0
    if [ -n "$PIPELINE_ID" ]; then
        JOBS=$(pipeline_jobs "$PIPELINE_PROJECT" "$PIPELINE_ID") || JOBS=''
        FAILING=$(printf '%s' "${JOBS:-null}" | jq 'group_by(.name) | map(max_by(.id))
            | map(select(.status == "failed" or .status == "canceled")) | length' 2>/dev/null) ||
            FAILING='?'
        case $PIPELINE_STATUS in
            failed | canceled | skipped | manual | scheduled)
                if [ "$FAILING" = 0 ]; then FAILING='?'; fi
                ;;
        esac
    fi
    printf '%s' "$MR" | jq -r --arg failing "$FAILING" \
        '"\(.references.full)\t\(.target_branch)\tpipeline=\(.head_pipeline.status // "none")\tfailing=\($failing)\t\(.title)"'
    PRINTED=$((PRINTED + 1))
done <<<"$CANDIDATES"

if [ "$PRINTED" -eq 0 ] && [ "$SKIPPED" -gt 0 ]; then
    echo "none of the $SKIPPED merge requests found could be read on $HOST" >&2
    exit 5
fi
