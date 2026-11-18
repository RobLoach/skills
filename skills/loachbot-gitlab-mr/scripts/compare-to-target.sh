#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Split a merge request's failing CI jobs into the ones this branch introduced and the
# ones its target branch already fails.
#
# Usage: bash scripts/compare-to-target.sh <project> <mr-iid>
#
# A job failing on both can still hide new errors (one more phpstan finding in an
# already-red phpstan), so their logs are diffed too, with numbers masked (line numbers,
# timings and counts shift on any change) and runner chatter dropped. Lines under `+`
# are a lead, not a verdict. A job whose logs cannot be compared - unreadable, or the
# LOACHBOT_COMPARE_BUDGET seconds wait-for-pipeline.sh passes are spent - cannot be
# proven pre-existing, so it is listed as new.
#
# Exit codes:
#   0  Nothing new: every failing job also fails on the target branch with no extra
#      log lines, or the pipeline succeeded with nothing failing. Report the
#      pre-existing ones; fix nothing.
#   1  Something is new: a job that passes on the target branch, or extra `+` lines in
#      one that fails on both. Printed under "new:".
#   6  The target branch has no finished pipeline to compare against, so every failure
#      is listed under "new:" as this branch's.
#   7  The merge request or its pipeline jobs could not be read, or its pipeline is
#      not a success (still running, blocked on a manual job, canceled) yet no job in
#      it failed.

set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ $2 =~ ^[0-9]+$ ]]; then
    echo "usage: bash scripts/compare-to-target.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
HERE=$(cd "$(dirname "$0")" && pwd)
MAX_LINES=${LOACHBOT_COMPARE_MAX_LINES:-20}
BUDGET=${LOACHBOT_COMPARE_BUDGET:-}

# A non-number would surface as a `[` error mid-comparison, exiting 2 and read as a
# verdict.
case "$MAX_LINES" in
    '' | *[!0-9]* | 0 | 0*) echo "LOACHBOT_COMPARE_MAX_LINES must be an integer >= 1" >&2; exit 64 ;;
esac
case "$BUDGET" in
    *[!0-9]* | 0?*) echo "LOACHBOT_COMPARE_BUDGET must be empty or an integer >= 0" >&2; exit 64 ;;
esac

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

# Failing jobs of one pipeline as "name<TAB>id<TAB>project" lines, newest attempt per name.
failing_jobs() {
    local JOBS
    JOBS=$(pipeline_jobs "$1" "$2") || return 1
    printf '%s' "$JOBS" | jq -r 'group_by(.name) | map(max_by(.id))
        | .[] | select(.status == "failed" or .status == "canceled")
        | "\(.name)\t\(.id)\t\(.project_id)"'
}

out_of_budget() { [ -n "$BUDGET" ] && [ "$SECONDS" -ge "$BUDGET" ]; }

# grep exits 1 when it filters out every line, which pipefail would report as an
# unreadable log; only its 2, a real error, is allowed through.
normalized_log() {
    bash "$HERE/job-log.sh" "$1" "$2" |
        sed -E 's#/builds/[^/ ]+/[^/ ]+#/builds/P#g; s/[0-9]+/N/g; s/[[:space:]]+/ /g; s/^ //; s/ $//' |
        { grep -vE '^.?$|correlation_id=|^(Running on|Waiting for pod|Checking out|Getting source|Fetching|Preparing|Using|Pulling|Downloading|Uploading|Direct download|Restoring cache|Saving cache|Created fresh)' ||
            [ "$?" -eq 1 ]; } |
        sort -u
}

if ! MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null); then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 7
fi
TARGET=$(printf '%s' "$MR" | jq -r '.target_branch // empty')
MR_PIPELINE=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
MR_PROJECT=$(printf '%s' "$MR" | jq -r '.head_pipeline.project_id // .source_project_id // empty')
MR_STATUS=$(printf '%s' "$MR" | jq -r '.head_pipeline.status // empty')
if [ -z "$MR_PIPELINE" ] || [ -z "$MR_PROJECT" ]; then
    echo "merge request !$IID has no pipeline to compare" >&2
    exit 7
fi

if ! MR_FAILING=$(failing_jobs "$MR_PROJECT" "$MR_PIPELINE"); then
    echo "cannot read the jobs of pipeline $MR_PIPELINE in project $MR_PROJECT" >&2
    exit 7
fi
if [ -z "$MR_FAILING" ]; then
    if [ "$MR_STATUS" = success ]; then
        echo "nothing is failing"
        exit 0
    fi
    echo "pipeline $MR_PIPELINE is ${MR_STATUS:-unreadable}, yet no job in it failed:" \
        "still running, blocked on a manual job, canceled, or red downstream; not passing" >&2
    exit 7
fi

# Newest finished pipeline that actually ran: canceled and skipped ones say nothing.
TARGET_PIPELINE=$(api "projects/$NAMESPACE%2F$PROJECT/pipelines?ref=$TARGET&scope=finished&per_page=20" \
    2>/dev/null | jq -r '[.[] | select(.status == "success" or .status == "failed")][0].id // empty') ||
    TARGET_PIPELINE=
if [ -z "$TARGET_PIPELINE" ]; then
    echo "no finished pipeline on $TARGET in $NAMESPACE/$PROJECT to compare against"
    printf '\nnew:\n'
    printf '%s\n' "$MR_FAILING" | awk -F'\t' '{print "  " $1 " job=" $2 " project=" $3}'
    exit 6
fi

if ! TARGET_FAILING=$(failing_jobs "$NAMESPACE%2F$PROJECT" "$TARGET_PIPELINE"); then
    echo "cannot read the jobs of pipeline $TARGET_PIPELINE on $TARGET" >&2
    exit 7
fi

echo "merge request pipeline $MR_PIPELINE (project $MR_PROJECT) against $TARGET pipeline $TARGET_PIPELINE"

NEW=
OLD=
while IFS=$'\t' read -r NAME ID JOB_PROJECT; do
    [ -n "$NAME" ] || continue
    TARGET_LINE=$(printf '%s\n' "$TARGET_FAILING" | awk -F'\t' -v n="$NAME" '$1 == n')
    TARGET_ID=$(printf '%s' "$TARGET_LINE" | cut -f2)
    TARGET_JOB_PROJECT=$(printf '%s' "$TARGET_LINE" | cut -f3)
    if [ -z "$TARGET_ID" ]; then
        NEW+="  $NAME job=$ID project=$JOB_PROJECT (passes on $TARGET)"$'\n'
        continue
    fi
    if out_of_budget; then
        NEW+="  $NAME job=$ID project=$JOB_PROJECT: also fails on $TARGET (job=$TARGET_ID), but out of time to compare logs, so not proven pre-existing"$'\n'
        continue
    fi
    if ! MINE=$(normalized_log "$JOB_PROJECT" "$ID") ||
        ! THEIRS=$(normalized_log "$TARGET_JOB_PROJECT" "$TARGET_ID"); then
        NEW+="  $NAME job=$ID project=$JOB_PROJECT: also fails on $TARGET (job=$TARGET_ID), but a log is unreadable, so not proven pre-existing"$'\n'
        continue
    fi
    OLD+="  $NAME job=$ID ($TARGET job=$TARGET_ID)"$'\n'
    EXTRA=$(comm -23 <(printf '%s\n' "$MINE") <(printf '%s\n' "$THEIRS"))
    if [ -n "$EXTRA" ]; then
        NEW+="  $NAME job=$ID: $(printf '%s\n' "$EXTRA" | wc -l | tr -d ' ') line(s) not in $TARGET's log"$'\n'
        NEW+=$(printf '%s\n' "$EXTRA" | head -n "$MAX_LINES" | sed 's/^/    + /')$'\n'
    fi
done <<<"$MR_FAILING"

[ -z "$OLD" ] || printf '\npre-existing (also failing on %s):\n%s' "$TARGET" "$OLD"
if [ -n "$NEW" ]; then
    printf '\nnew:\n%s' "$NEW"
    exit 1
fi
exit 0
