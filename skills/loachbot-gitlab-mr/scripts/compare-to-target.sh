#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Split a merge request's failing CI jobs into the ones this branch introduced and the
# ones its target branch already fails, so a run fixes its own breakage and reports the
# rest instead of working around it.
#
# Usage: bash scripts/compare-to-target.sh <project> <mr-iid>
#
# Compares the merge request's head pipeline with the newest finished pipeline on its
# target branch, job by job and newest-attempt-wins, as wait-for-pipeline.sh does. A job
# that fails on both is pre-existing - but it can still hide new errors (one more phpstan
# finding in an already-red phpstan), so the two logs are diffed as well. Numbers are
# masked before diffing, since line numbers, timings and counts shift on any change, and
# runner chatter (pod names, upload tokens) is dropped. What is left under `+` is in this
# branch's log and not the target's: read it, but it is a lead rather than a verdict.
#
# Logs come through job-log.sh beside this script, which strips the ANSI noise.
#
# Exit codes:
#   0  Nothing new: every failing job also fails on the target branch with no extra
#      log lines, or nothing fails at all. Report the pre-existing ones; fix nothing.
#   1  Something is new: a job that passes on the target branch, or extra `+` lines in
#      one that fails on both. Printed under "new:".
#   6  The target branch has no finished pipeline to compare against, so every failure
#      is listed under "new:" as this branch's.
#   7  The merge request or its pipeline jobs could not be read.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/compare-to-target.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
HERE=$(cd "$(dirname "$0")" && pwd)
MAX_LINES=${LOACHBOT_COMPARE_MAX_LINES:-20}

api() { glab api --hostname "$HOST" "$@"; }

# Failing jobs of one pipeline as "name<TAB>id" lines, newest attempt per name.
failing_jobs() {
    local JOBS
    JOBS=$(api --paginate "projects/$1/pipelines/$2/jobs?per_page=100" 2>/dev/null |
        jq -sc 'add') || return 1
    [ "$(printf '%s' "$JOBS" | jq -r 'type')" = array ] || return 1
    printf '%s' "$JOBS" | jq -r 'group_by(.name) | map(max_by(.id))
        | .[] | select(.status == "failed" or .status == "canceled") | "\(.name)\t\(.id)"'
}

# A log reduced to its distinct lines, with what shifts between any two runs masked.
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
if [ -z "$MR_PIPELINE" ] || [ -z "$MR_PROJECT" ]; then
    echo "merge request !$IID has no pipeline to compare" >&2
    exit 7
fi

if ! MR_FAILING=$(failing_jobs "$MR_PROJECT" "$MR_PIPELINE"); then
    echo "cannot read the jobs of pipeline $MR_PIPELINE in project $MR_PROJECT" >&2
    exit 7
fi
if [ -z "$MR_FAILING" ]; then
    echo "nothing is failing"
    exit 0
fi

# Newest finished pipeline that actually ran: canceled and skipped ones say nothing.
TARGET_PIPELINE=$(api "projects/$NAMESPACE%2F$PROJECT/pipelines?ref=$TARGET&scope=finished&per_page=20" \
    2>/dev/null | jq -r '[.[] | select(.status == "success" or .status == "failed")][0].id // empty') ||
    TARGET_PIPELINE=
if [ -z "$TARGET_PIPELINE" ]; then
    echo "no finished pipeline on $TARGET in $NAMESPACE/$PROJECT to compare against"
    printf '\nnew:\n'
    printf '%s\n' "$MR_FAILING" | awk -F'\t' '{print "  " $1 " job=" $2}'
    exit 6
fi

if ! TARGET_FAILING=$(failing_jobs "$NAMESPACE%2F$PROJECT" "$TARGET_PIPELINE"); then
    echo "cannot read the jobs of pipeline $TARGET_PIPELINE on $TARGET" >&2
    exit 7
fi

echo "merge request pipeline $MR_PIPELINE (project $MR_PROJECT) against $TARGET pipeline $TARGET_PIPELINE"

NEW=
OLD=
while IFS=$'\t' read -r NAME ID; do
    [ -n "$NAME" ] || continue
    TARGET_ID=$(printf '%s\n' "$TARGET_FAILING" | awk -F'\t' -v n="$NAME" '$1 == n {print $2}')
    if [ -z "$TARGET_ID" ]; then
        NEW+="  $NAME job=$ID (passes on $TARGET)"$'\n'
        continue
    fi
    OLD+="  $NAME job=$ID ($TARGET job=$TARGET_ID)"$'\n'
    if ! MINE=$(normalized_log "$MR_PROJECT" "$ID") ||
        ! THEIRS=$(normalized_log "$NAMESPACE%2F$PROJECT" "$TARGET_ID"); then
        OLD+="    (logs unreadable; not compared)"$'\n'
        continue
    fi
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
