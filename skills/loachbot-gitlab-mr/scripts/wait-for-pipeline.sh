#!/usr/bin/env bash
#
# Wait for a merge request's pipeline to settle, then report every job that is not
# green - including the ones the pipeline itself forgives.
#
# Usage: bash scripts/wait-for-pipeline.sh <project> <mr-iid>
#
# Drupal's GitLab CI template marks cspell, phpcs, phpstan and stylelint
# `allow_failure: true`. The pipeline goes green with all four of them red, and both
# `glab ci status` and the merge request's own badge agree it passed. Anything that
# trusts the rollup will call such a merge request done with its lint gates broken,
# which is the one outcome this script exists to prevent: it reads per-job status and
# treats a forgiven failure as a failure.
#
# Two details that are easy to get wrong, and silently:
#   * The pipeline belongs to the *source* fork, not the project the merge request
#     targets. Asking the target project for it returns 404.
#   * The merge request *list* endpoint omits head_pipeline entirely. Only a
#     single-merge-request read carries it, so that is what this polls.
#
# Jobs are reported newest-run-wins: a retried job appears more than once in the
# API's list, and only the latest attempt reflects reality.
#
# Polls rather than streaming, so bounding the wait needs nothing but `sleep` - no
# GNU `timeout`, which is absent on stock macOS. Only the settled result is printed.
#
# Exit codes:
#   0  Every job passed, or the project has no CI at all.
#   1  At least one job failed. The failures are printed, forgiven ones marked
#      `(allow_failure)`; fix them and push again.
#   7  The pipeline or its jobs could not be read. Unknown is not passing: report it.
#   8  Still running after the full wait. Report the pending jobs and stop.

set -euo pipefail

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
PROJECT=${1:?project machine name required}
IID=${2:?merge request iid required}

SETTLE_SECONDS=${LOACHBOT_PIPELINE_SETTLE:-20}
POLL_SECONDS=${LOACHBOT_PIPELINE_POLL:-20}
MAX_POLLS=${LOACHBOT_PIPELINE_MAX_POLLS:-90}
NO_PIPELINE_PROBES=${LOACHBOT_PIPELINE_PROBES:-5}

api() { glab api --hostname "$HOST" "$@"; }

read_mr() { api "projects/project%2F$PROJECT/merge_requests/$IID" 2>/dev/null; }

# A pipeline takes a moment to attach after a push.
sleep "$SETTLE_SECONDS"

# A project whose pipeline has not attached yet looks exactly like one with no CI, so
# believe "no CI" only after several probes. Getting this wrong would mark a merge
# request done with its CI never run.
PIPELINE_ID=
SOURCE_ID=
for _ in $(seq 1 "$NO_PIPELINE_PROBES"); do
    if MR=$(read_mr); then
        PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
        SOURCE_ID=$(printf '%s' "$MR" | jq -r '.source_project_id // empty')
    fi
    [ -n "$PIPELINE_ID" ] && break
    sleep "$POLL_SECONDS"
done

if [ -z "$SOURCE_ID" ]; then
    echo "cannot read merge request !$IID in project/$PROJECT on $HOST" >&2
    exit 7
fi

if [ -z "$PIPELINE_ID" ]; then
    echo "no pipeline attached to !$IID after $NO_PIPELINE_PROBES probes: treating the project as having no CI"
    exit 0
fi

# Wait for the pipeline itself to reach a terminal state. `manual` and `scheduled`
# are terminal too: nothing further happens without a human.
STATUS=
for _ in $(seq 1 "$MAX_POLLS"); do
    if ! STATUS=$(api "projects/$SOURCE_ID/pipelines/$PIPELINE_ID" 2>/dev/null |
        jq -r '.status // empty'); then
        STATUS=
    fi
    case $STATUS in
        success | failed | canceled | skipped | manual | scheduled) break ;;
        "")
            echo "cannot read pipeline $PIPELINE_ID in project $SOURCE_ID" >&2
            exit 7
            ;;
    esac
    sleep "$POLL_SECONDS"
done

case $STATUS in
    success | failed | canceled | skipped | manual | scheduled) ;;
    *)
        echo "pipeline $PIPELINE_ID is still $STATUS after the full wait" >&2
        exit 8
        ;;
esac

if ! JOBS=$(api "projects/$SOURCE_ID/pipelines/$PIPELINE_ID/jobs?per_page=100" 2>/dev/null) ||
    [ "$(printf '%s' "$JOBS" | jq -r 'type')" != "array" ]; then
    echo "cannot read the jobs of pipeline $PIPELINE_ID in project $SOURCE_ID" >&2
    exit 7
fi

# A retried job is listed once per attempt; keep the highest id per name, which is
# always the most recent run.
LATEST=$(printf '%s' "$JOBS" | jq -c '
    group_by(.name)
    | map(max_by(.id))
    | map({name, status, allow_failure})
')

FAILED=$(printf '%s' "$LATEST" | jq -r '
    map(select(.status == "failed" or .status == "canceled"))
    | .[]
    | "  \(.name): \(.status)\(if .allow_failure then " (allow_failure)" else "" end)"
')

echo "pipeline $PIPELINE_ID reports $STATUS; per-job results:"
printf '%s' "$LATEST" | jq -r '.[] | "  \(.name): \(.status)"' | sort

if [ -n "$FAILED" ]; then
    echo
    echo "failing jobs:"
    echo "$FAILED"
    exit 1
fi

exit 0
