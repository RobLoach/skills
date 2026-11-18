#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Wait for a merge request's pipeline to settle, then report every job that is not
# green - including the ones the pipeline itself forgives.
#
# Usage: bash scripts/wait-for-pipeline.sh <project> <mr-iid> [head-sha]
#
# Pass [head-sha] after a push: for a few seconds the merge request still points at the
# previous commit's pipeline, whose result is stale. A short SHA is expanded with the
# local git, since GitLab only reports full ones. A merged-results pipeline runs a merge
# commit with [head-sha] as a parent, so that counts as a match too.
#
# Drupal's CI template marks some jobs `allow_failure: true`, so the pipeline and the
# merge request badge both say passed with those gates red. This reads per-job status
# and matches each job's own allow_failure flag, since which jobs are forgiven varies by
# project.
#
# The pipeline may run in the parent project rather than the fork (GitLab does that when
# the author can push to the parent), and asking the wrong one is a flat 404, so
# head_pipeline.project_id decides. The merge request list endpoint omits head_pipeline,
# so this polls the single-merge-request read.
#
# A pipeline that ends other than `success` with no failed job to show for it - blocked
# on a manual job, canceled, or red in a downstream pipeline this cannot read - is not
# passing, whatever its jobs say.
#
# On a failure this runs compare-to-target.sh, so the caller learns whether the target
# branch was already red. Polls with `sleep` rather than GNU `timeout`, absent on macOS;
# LOACHBOT_PIPELINE_TIMEOUT (default 420) bounds the wait, and LOACHBOT_PIPELINE_CEILING
# (default 540) the whole call: the comparison gets what is left and skips the log diffs
# once it is spent, so one call stays within a 10-minute tool limit.
#
# Whether [head-sha] configures CI is read from the local git, so run this inside the
# worktree; a commit git cannot find there counts as configuring CI, which waits rather
# than calling a missing pipeline "no CI".
#
# Exit codes:
#   0  Every job passed, or the project has no CI at all - which is only believed when
#      no [head-sha] was given, or that commit carries no CI configuration.
#   1  New failures, listed under `new:`: this branch's to fix, forgiven or not.
#   2  Only failures the target branch already has. Report them; never work around them.
#   7  The pipeline or its jobs could not be read, or it ended other than success with
#      no failed job to show for it. Unknown is not passing: report it.
#   8  Still running when the time ran out, or no pipeline for [head-sha] appeared yet
#      though the project has CI.
#      Run it again; report the pending jobs only once repeats stop helping.

set -euo pipefail

# Usage errors exit 64: `${1:?}` would exit 1, which reads as "new failures".
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || ! [[ $2 =~ ^[0-9]+$ ]] ||
    { [ "$#" -eq 3 ] && [ -z "$3" ]; }; then
    echo "usage: bash scripts/wait-for-pipeline.sh <project> <mr-iid> [head-sha]" >&2
    echo "(an empty [head-sha] is refused: it would judge whichever pipeline is current)" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
HEAD_SHA=${3:-}
HERE=$(cd "$(dirname "$0")" && pwd)

SETTLE_SECONDS=${LOACHBOT_PIPELINE_SETTLE:-20}
POLL_SECONDS=${LOACHBOT_PIPELINE_POLL:-20}
TIMEOUT_SECONDS=${LOACHBOT_PIPELINE_TIMEOUT:-420}
CEILING_SECONDS=${LOACHBOT_PIPELINE_CEILING:-540}
NO_PIPELINE_PROBES=${LOACHBOT_PIPELINE_PROBES:-5}

# A non-number would surface mid-wait as a `[` or `$((...))` error, exiting 1 or 2 and
# read as a verdict; a leading zero is octal to `$((...))`.
case "$NO_PIPELINE_PROBES" in
    '' | *[!0-9]* | 0 | 0*) echo "LOACHBOT_PIPELINE_PROBES must be an integer >= 1" >&2; exit 64 ;;
esac
for KNOB in "LOACHBOT_PIPELINE_SETTLE=$SETTLE_SECONDS" "LOACHBOT_PIPELINE_POLL=$POLL_SECONDS" \
    "LOACHBOT_PIPELINE_TIMEOUT=$TIMEOUT_SECONDS" "LOACHBOT_PIPELINE_CEILING=$CEILING_SECONDS"; do
    case "${KNOB#*=}" in
        '' | *[!0-9]* | 0?*) echo "${KNOB%%=*} must be an integer >= 0" >&2; exit 64 ;;
    esac
done

if [ -n "$HEAD_SHA" ] && ! [[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]]; then
    if ! HEAD_SHA=$(git rev-parse --verify --quiet "$HEAD_SHA^{commit}" 2>/dev/null); then
        echo "[head-sha] must be a full 40-character SHA, or resolvable here: $3" >&2
        exit 64
    fi
fi

api() { glab api --hostname "$HOST" "$@"; }

out_of_time() { [ "$SECONDS" -ge "$TIMEOUT_SECONDS" ]; }

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

# Is the attached pipeline the one for [head-sha], directly or as a merged-results
# parent? A failed read is just "not yet".
pipeline_matches_head() {
    if [ -z "$HEAD_SHA" ] || [ "$PIPELINE_SHA" = "$HEAD_SHA" ]; then
        return 0
    fi
    local PARENTS
    PARENTS=$(api "projects/$PIPELINE_PROJECT/repository/commits/$PIPELINE_SHA" 2>/dev/null |
        jq -r '.parent_ids[]?') || return 1
    printf '%s\n' "$PARENTS" | grep -qx "$HEAD_SHA"
}

# Does the pushed commit configure CI (in the repo, or via a project-level
# ci_config_path)? If so a missing pipeline is one still coming - drupal.org's pipeline
# creation can lag a push by minutes - rather than one that never will.
has_ci() {
    [ -n "$HEAD_SHA" ] || return 1
    git cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null || return 0
    git cat-file -e "$HEAD_SHA:.gitlab-ci.yml" 2>/dev/null && return 0
    [ -n "$(api "projects/$NAMESPACE%2F$PROJECT" 2>/dev/null |
        jq -r '.ci_config_path // empty')" ]
}
HAS_CI=false
has_ci && HAS_CI=true

sleep "$SETTLE_SECONDS"

# A pipeline not attached yet looks exactly like no CI, so "no CI" is believed only
# after several probes; believing it early would mark the merge request done unverified.
PIPELINE_ID=
PIPELINE_SHA=
PIPELINE_PROJECT=
MR_IID=
MATCHED=false
POLL=0
while :; do
    POLL=$((POLL + 1))
    if MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null); then
        MR_IID=$(printf '%s' "$MR" | jq -r '.iid // empty')
        PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
        PIPELINE_SHA=$(printf '%s' "$MR" | jq -r '.head_pipeline.sha // empty')
        PIPELINE_PROJECT=$(printf '%s' "$MR" |
            jq -r '.head_pipeline.project_id // .source_project_id // empty')
    fi
    if [ -n "$PIPELINE_ID" ] && pipeline_matches_head; then
        MATCHED=true
        break
    fi
    # A commit that configures CI keeps waiting, up to the timeout.
    if [ -z "$PIPELINE_ID" ] && [ "$POLL" -ge "$NO_PIPELINE_PROBES" ] &&
        { [ -z "$MR_IID" ] || [ "$HAS_CI" != true ]; }; then
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

if [ -z "$PIPELINE_ID" ] && [ "$HAS_CI" = true ]; then
    echo "no pipeline attached to !$IID for $HEAD_SHA after ${SECONDS}s, though it configures CI" >&2
    exit 8
fi

if [ -z "$PIPELINE_ID" ]; then
    echo "no pipeline attached to !$IID after $NO_PIPELINE_PROBES probes: treating the project as having no CI"
    exit 0
fi

if [ "$MATCHED" != true ]; then
    echo "!$IID still points at pipeline $PIPELINE_ID for $PIPELINE_SHA; none for $HEAD_SHA yet" >&2
    exit 8
fi

# `manual` and `scheduled` are terminal: nothing further happens without a human. One
# unreadable response is a blip, so only a run of them counts as "cannot read".
STATUS=
MISSES=0
SETTLED=false
while :; do
    STATUS=$(api "projects/$PIPELINE_PROJECT/pipelines/$PIPELINE_ID" 2>/dev/null |
        jq -r '.status // empty') || STATUS=
    case $STATUS in
        success | failed | canceled | skipped | manual | scheduled)
            SETTLED=true
            break
            ;;
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

if [ "$SETTLED" != true ]; then
    echo "pipeline $PIPELINE_ID is still $STATUS after ${SECONDS}s; run this again" >&2
    exit 8
fi

if ! JOBS=$(pipeline_jobs "$PIPELINE_PROJECT" "$PIPELINE_ID"); then
    echo "cannot read the jobs of pipeline $PIPELINE_ID in project $PIPELINE_PROJECT" >&2
    exit 7
fi

# A retried job is listed once per attempt; the highest id is the latest run.
LATEST=$(printf '%s' "$JOBS" | jq -c 'group_by(.name) | map(max_by(.id))')

FAILED=$(printf '%s' "$LATEST" | jq -r --arg p "$PIPELINE_PROJECT" '
    .[]
    | select(.status == "failed" or .status == "canceled")
    | "  \(.name): \(.status)\(if .allow_failure then " (allow_failure)" else "" end) job=\(.id)"
      + (if .project_id != $p then " project=\(.project_id)" else "" end)
')

echo "pipeline $PIPELINE_ID in project $PIPELINE_PROJECT reports $STATUS; per-job results:"
printf '%s' "$LATEST" | jq -r '.[] | "  \(.name): \(.status)"' | sort

if [ -z "$FAILED" ]; then
    [ "$STATUS" != success ] || exit 0
    echo "pipeline $PIPELINE_ID is $STATUS, yet no job in it failed: a blocking manual" \
        "job, a canceled run or a downstream pipeline this cannot read; not passing" >&2
    exit 7
fi
printf '\nfailing jobs:\n%s\n\n' "$FAILED"

CMP=0
# Exit 2 only on the compare's say-so: its 0 can mean it read a newer pipeline with
# nothing failing, which confirms nothing about the failures above.
BUDGET=$((CEILING_SECONDS - SECONDS))
[ "$BUDGET" -ge 0 ] || BUDGET=0
CMP_OUT=$(LOACHBOT_COMPARE_BUDGET=$BUDGET \
    bash "$HERE/compare-to-target.sh" "$PROJECT" "$IID") || CMP=$?
printf '%s\n' "$CMP_OUT"
case $CMP in
    0) grep -q '^pre-existing' <<<"$CMP_OUT" && exit 2 ;;
    1 | 6) exit 1 ;;
esac
printf 'could not compare with the target branch; every failure counts\n\nnew:\n%s\n' "$FAILED"
exit 1
