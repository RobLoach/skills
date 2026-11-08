#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Wait for a merge request's pipeline to settle, then report every job that is not
# green - including the ones the pipeline itself forgives.
#
# Usage: bash scripts/wait-for-pipeline.sh <project> <mr-iid> [head-sha]
#
# Pass [head-sha] - `git rev-parse HEAD` after a push - whenever you have just pushed.
# For a few seconds after a push the merge request still points at the *previous*
# commit's pipeline, and settling on that one reports a stale result: a green from
# before the change, or a red that the push already fixed. With [head-sha] given, only a
# pipeline for that commit counts. [head-sha] must be a full 40-character SHA; a short
# one is expanded with the current checkout's git, since GitLab only reports full SHAs.
#
# A merged-results pipeline (project/ai runs them) does not run [head-sha] itself: it
# runs refs/merge-requests/<iid>/merge, a merge commit with [head-sha] as one parent. So
# a pipeline whose commit has [head-sha] among its parents counts as well; without that,
# such a project is never matched and every wait ends in 8.
#
# Drupal's GitLab CI template marks some jobs `allow_failure: true`: they fail without
# failing the pipeline, so `glab ci status` and the merge request's own badge both agree
# it passed. Anything that trusts the rollup will call such a merge request done with
# those gates broken, which is the one outcome this script exists to prevent: it reads
# per-job status and treats a forgiven failure as a failure.
#
# Which jobs are forgiven is per-project configuration rather than a fixed set - the lint
# jobs usually, but eslint, composer variants and phpunit variants on some projects - so
# this matches on each job's own allow_failure flag and never on a list of names.
#
# Two details that are easy to get wrong, and silently:
#   * Which project holds the pipeline is not fixed. GitLab runs a fork's merge request
#     pipeline in the *parent* project when its author can push there, so a maintainer's
#     own merge request keeps it on the project while a contributor's leaves it on the
#     fork - and asking the wrong one returns a flat 404 rather than anything to act on.
#     head_pipeline.project_id says which it is; source_project_id is only the fallback
#     for a payload that omits it.
#   * The merge request *list* endpoint omits head_pipeline entirely. Only a
#     single-merge-request read carries it, so that is what this polls.
#
# Each failing job is printed with its id, and the pipeline's project is printed once,
# so its log can be read from the right project:
#   glab api "projects/<pipeline-project>/jobs/<job-id>/trace"
#
# Jobs are reported newest-run-wins: a retried job appears more than once in the
# API's list, and only the latest attempt reflects reality.
#
# Polls rather than streaming, so bounding the wait needs nothing but `sleep` - no
# GNU `timeout`, which is absent on stock macOS. The whole wait is capped at
# LOACHBOT_PIPELINE_TIMEOUT seconds (default 510) so one call fits a 10-minute tool
# limit; a progress line goes to stderr on every poll so a long wait is not mistaken for
# a hang. On 8, just run it again.
#
# Exit codes:
#   0  Every job passed, or the project has no CI at all.
#   1  At least one job failed. The failures are printed, forgiven ones marked
#      `(allow_failure)`; fix them and push again.
#   7  The pipeline or its jobs could not be read. Unknown is not passing: report it.
#   8  Still running when the time ran out, or no pipeline for [head-sha] appeared yet.
#      Run it again; report the pending jobs only once repeats stop helping.

set -euo pipefail

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=${1:?project machine name required}
IID=${2:?merge request iid required}
HEAD_SHA=${3:-}

SETTLE_SECONDS=${LOACHBOT_PIPELINE_SETTLE:-20}
POLL_SECONDS=${LOACHBOT_PIPELINE_POLL:-20}
TIMEOUT_SECONDS=${LOACHBOT_PIPELINE_TIMEOUT:-510}
NO_PIPELINE_PROBES=${LOACHBOT_PIPELINE_PROBES:-5}

if [ -n "$HEAD_SHA" ] && ! [[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]]; then
    if ! HEAD_SHA=$(git rev-parse --verify --quiet "$HEAD_SHA^{commit}" 2>/dev/null); then
        echo "[head-sha] must be a full 40-character SHA, or resolvable here: $3" >&2
        exit 64
    fi
fi

api() { glab api --hostname "$HOST" "$@"; }

read_mr() { api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null; }

out_of_time() { [ "$SECONDS" -ge "$TIMEOUT_SECONDS" ]; }

# Is the attached pipeline the one for [head-sha]? Directly, or as a merged-results
# pipeline whose merge commit has it as a parent. Remembered per pipeline SHA, so the
# commit is read once rather than on every poll.
CHECKED_SHA=
CHECKED_MATCH=false
pipeline_matches_head() {
    if [ -z "$HEAD_SHA" ] || [ "$PIPELINE_SHA" = "$HEAD_SHA" ]; then
        return 0
    fi
    if [ "$PIPELINE_SHA" != "$CHECKED_SHA" ]; then
        # Remember the answer only once the read succeeds: a dropped call must be
        # retried on the next poll, not cached as "no match" for the whole wait.
        local PARENTS
        PARENTS=$(api "projects/$PIPELINE_PROJECT/repository/commits/$PIPELINE_SHA" 2>/dev/null |
            jq -r '.parent_ids[]?') || return 1
        CHECKED_SHA=$PIPELINE_SHA
        CHECKED_MATCH=false
        if printf '%s\n' "$PARENTS" | grep -qx "$HEAD_SHA"; then
            CHECKED_MATCH=true
        fi
    fi
    [ "$CHECKED_MATCH" = true ]
}

# A pipeline takes a moment to attach after a push.
sleep "$SETTLE_SECONDS"

# A project whose pipeline has not attached yet looks exactly like one with no CI, so
# believe "no CI" only after several probes. Getting this wrong would mark a merge
# request done with its CI never run. A pipeline for an older commit is not the one
# being waited for: keep polling until the merge request points at [head-sha].
PIPELINE_ID=
PIPELINE_SHA=
PIPELINE_PROJECT=
MR_IID=
POLL=0
while :; do
    POLL=$((POLL + 1))
    if MR=$(read_mr); then
        MR_IID=$(printf '%s' "$MR" | jq -r '.iid // empty')
        PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
        PIPELINE_SHA=$(printf '%s' "$MR" | jq -r '.head_pipeline.sha // empty')
        # The pipeline names the project it ran in; fall back to the fork without it.
        PIPELINE_PROJECT=$(printf '%s' "$MR" |
            jq -r '.head_pipeline.project_id // .source_project_id // empty')
    fi
    if [ -n "$PIPELINE_ID" ] && pipeline_matches_head; then
        break
    fi
    # Nothing attached at all after the probes: an unreadable merge request, or no CI.
    if [ -z "$PIPELINE_ID" ] && [ "$POLL" -ge "$NO_PIPELINE_PROBES" ]; then
        break
    fi
    out_of_time && break
    echo "waiting for a pipeline for ${HEAD_SHA:-the head commit} (${SECONDS}s)" >&2
    sleep "$POLL_SECONDS"
done

if [ -z "$MR_IID" ]; then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 7
fi

if [ -z "$PIPELINE_ID" ]; then
    echo "no pipeline attached to !$IID after $NO_PIPELINE_PROBES probes: treating the project as having no CI"
    exit 0
fi

if ! pipeline_matches_head; then
    echo "!$IID still points at pipeline $PIPELINE_ID for $PIPELINE_SHA; none for $HEAD_SHA yet" >&2
    exit 8
fi

# Wait for the pipeline itself to reach a terminal state. `manual` and `scheduled`
# are terminal too: nothing further happens without a human.
#
# A single unreadable response is a blip, not an answer. Giving up on the first one
# would abandon a run over one dropped connection, so only a run of them counts as
# "cannot read" - the same reasoning as the no-pipeline probes above.
STATUS=
MISSES=0
while :; do
    if ! STATUS=$(api "projects/$PIPELINE_PROJECT/pipelines/$PIPELINE_ID" 2>/dev/null |
        jq -r '.status // empty'); then
        STATUS=
    fi
    case $STATUS in
        success | failed | canceled | skipped | manual | scheduled) break ;;
        "")
            MISSES=$((MISSES + 1))
            if [ "$MISSES" -ge "$NO_PIPELINE_PROBES" ]; then
                echo "cannot read pipeline $PIPELINE_ID in project $PIPELINE_PROJECT" \
                    "($MISSES consecutive failures)" >&2
                exit 7
            fi
            ;;
        *) MISSES=0 ;;
    esac
    out_of_time && break
    echo "pipeline $PIPELINE_ID is ${STATUS:-unreadable} (${SECONDS}s)" >&2
    sleep "$POLL_SECONDS"
done

case $STATUS in
    success | failed | canceled | skipped | manual | scheduled) ;;
    *)
        echo "pipeline $PIPELINE_ID is still $STATUS after ${SECONDS}s; run this again" >&2
        exit 8
        ;;
esac

# --paginate prints one array per page; a large pipeline (Drupal core's) has more than
# one page of jobs, and the second page is as likely to hold the failure as the first.
if ! JOBS=$(api --paginate "projects/$PIPELINE_PROJECT/pipelines/$PIPELINE_ID/jobs?per_page=100" \
    2>/dev/null | jq -sc 'add') ||
    [ "$(printf '%s' "$JOBS" | jq -r 'type')" != "array" ]; then
    echo "cannot read the jobs of pipeline $PIPELINE_ID in project $PIPELINE_PROJECT" >&2
    exit 7
fi

# A retried job is listed once per attempt; keep the highest id per name, which is
# always the most recent run.
LATEST=$(printf '%s' "$JOBS" | jq -c '
    group_by(.name)
    | map(max_by(.id))
    | map({id, name, status, allow_failure})
')

FAILED=$(printf '%s' "$LATEST" | jq -r '
    map(select(.status == "failed" or .status == "canceled"))
    | .[]
    | "  \(.name): \(.status)\(if .allow_failure then " (allow_failure)" else "" end) job=\(.id)"
')

echo "pipeline $PIPELINE_ID in project $PIPELINE_PROJECT reports $STATUS; per-job results:"
printf '%s' "$LATEST" | jq -r '.[] | "  \(.name): \(.status)"' | sort

if [ -n "$FAILED" ]; then
    echo
    echo "failing jobs:"
    echo "$FAILED"
    exit 1
fi

exit 0
