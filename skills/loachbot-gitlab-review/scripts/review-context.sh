#!/usr/bin/env bash
#
# Gather everything a review of one drupal.org merge request needs, as a single JSON
# object on stdout.
#
# Usage: bash scripts/review-context.sh <project> <mr-iid>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# Emitted shape:
#   {
#     "merge_request": { iid, title, author, state, draft, source_branch,
#                        target_branch, source_project_id, web_url, description },
#     "diff_refs":     { base_sha, start_sha, head_sha },   # inline comments need these
#     "issue_ref":     the issue number from the fork's path, or null,
#     "files":         [ { new_path, old_path, new_file, deleted_file, renamed_file, diff } ],
#     "pipeline_project_id": the project the pipeline ran in - read job logs from here,
#     "jobs":          [ { id, name, status, allow_failure } ],
#     "failing_jobs":  [ { id, name, status, allow_failure } ],
#     "discussions":   [ { id, resolved, path, line, author, body } ]  # existing threads
#   }
#
# `discussions` is there so a review never re-posts a finding an earlier one already
# left: reply in that thread instead. Each entry is the thread's first note, trimmed.
#
# `failing_jobs` is the point of collecting `jobs` at all. Drupal's CI template marks
# some jobs `allow_failure: true`, so the pipeline reports success with those jobs red. A
# reviewer who trusts the rollup signs off on a branch with broken gates, so the failures
# are surfaced separately and the forgiven ones keep their `allow_failure` flag rather
# than being filtered out.
#
# Which jobs carry it is per-project configuration, not a fixed set, so nothing here
# matches on job names.
#
# Which project holds the pipeline is not fixed. GitLab runs a fork's merge request
# pipeline in the *parent* project when its author can push there, so a maintainer's own
# merge request keeps it on the project while a contributor's leaves it on the fork, and
# asking the wrong one returns 404 - which would leave `jobs` empty and the review blind
# to red CI. head_pipeline.project_id says which it is. The fork is still where
# `issue_ref` comes from, and the diff is still read from the target.
#
# `issue_ref` is null when the merge request came from a plain branch rather than a
# drupal.org issue fork. Review the diff anyway and say so.
#
# Exit codes:
#   0  Context on stdout.
#   5  The merge request could not be read. Report it.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/review-context.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

if ! MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null) ||
    [ "$(printf '%s' "$MR" | jq -r '.iid // empty')" = "" ]; then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

SOURCE_ID=$(printf '%s' "$MR" | jq -r '.source_project_id // empty')
PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')
# The pipeline names the project it ran in; fall back to the fork without it.
PIPELINE_PROJECT=$(printf '%s' "$MR" |
    jq -r '.head_pipeline.project_id // .source_project_id // empty')

# The issue number is the numeric tail of the fork's path: issue/<project>-<number>.
# Taking the last hyphen-separated field keeps working for projects whose machine name
# itself contains a hyphen.
#
# Only the number is resolved here. Turning it into an issue is read-issue.sh's job,
# because what the number means depends on whether this project's queue was migrated
# into GitLab, and the two numbering spaces overlap - so guessing wrong returns a real
# but unrelated issue rather than nothing at all.
ISSUE_REF=null
if [ -n "$SOURCE_ID" ]; then
    REF=$(api "projects/$SOURCE_ID" 2>/dev/null |
        jq -r 'if (.path_with_namespace // "") | startswith("issue/")
               then (.path_with_namespace | split("-") | last)
               else empty end' || true)
    [ -n "$REF" ] && ISSUE_REF=$(printf '%s' "$REF" | jq -R .)
fi

FILES='[]'
if RAW_FILES=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/diffs?per_page=100" 2>/dev/null); then
    FILES=$(printf '%s' "$RAW_FILES" |
        jq -sc 'add // [] | map({new_path, old_path, new_file, deleted_file, renamed_file, diff})')
fi

JOBS='[]'
if [ -n "$PIPELINE_ID" ] && [ -n "$PIPELINE_PROJECT" ]; then
    RAW=$(api --paginate "projects/$PIPELINE_PROJECT/pipelines/$PIPELINE_ID/jobs?per_page=100" \
        2>/dev/null | jq -sc 'add // []' || echo '[]')
    if [ "$(printf '%s' "$RAW" | jq -r 'type')" = "array" ]; then
        # A retried job is listed once per attempt; the highest id is the latest run.
        JOBS=$(printf '%s' "$RAW" |
            jq -c 'group_by(.name) | map(max_by(.id)) | map({id, name, status, allow_failure})')
    fi
fi

DISCUSSIONS='[]'
if RAW_DISCUSSIONS=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/discussions?per_page=100" 2>/dev/null); then
    DISCUSSIONS=$(printf '%s' "$RAW_DISCUSSIONS" | jq -sc '
        add // []
        | map(.notes[0] as $n | select($n.system | not) | {
            id,
            resolved: ($n.resolved // false),
            path: ($n.position.new_path // null),
            line: ($n.position.new_line // null),
            author: $n.author.username,
            body: ($n.body | .[0:300])
        })')
fi

# Diffs go through files rather than --argjson: a single argument is capped at 128 KiB on
# Linux, and one large merge request's diff text is enough to hit it.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$MR" >"$TMP/mr.json"
printf '%s' "$FILES" >"$TMP/files.json"
printf '%s' "$JOBS" >"$TMP/jobs.json"
printf '%s' "$DISCUSSIONS" >"$TMP/discussions.json"

jq -n \
    --slurpfile mr "$TMP/mr.json" \
    --slurpfile files "$TMP/files.json" \
    --slurpfile jobs "$TMP/jobs.json" \
    --slurpfile discussions "$TMP/discussions.json" \
    --argjson issue_ref "$ISSUE_REF" \
    --arg pipeline_project "$PIPELINE_PROJECT" \
    '$mr[0] as $mr | $jobs[0] as $jobs
     | {
        merge_request: ($mr | {iid, title, author: .author.username, state, draft,
                              source_branch, target_branch, source_project_id,
                              web_url, description}),
        diff_refs: ($mr.diff_refs // null),
        issue_ref: $issue_ref,
        files: $files[0],
        pipeline_project_id: (if $pipeline_project == "" then null else ($pipeline_project | tonumber) end),
        jobs: $jobs,
        failing_jobs: ($jobs | map(select(.status == "failed" or .status == "canceled"))),
        discussions: $discussions[0]
    }'
