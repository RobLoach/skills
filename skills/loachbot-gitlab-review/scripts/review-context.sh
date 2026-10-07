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
#     "issue":         { iid, title, labels, state, description } | null,
#     "files":         [ { new_path, old_path, new_file, deleted_file, renamed_file } ],
#     "jobs":          [ { name, status, allow_failure } ],
#     "failing_jobs":  [ { name, status, allow_failure } ]
#   }
#
# `failing_jobs` is the point of collecting `jobs` at all. Drupal's CI template marks
# cspell, phpcs, phpstan and stylelint `allow_failure: true`, so the pipeline reports
# success with those jobs red. A reviewer who trusts the rollup signs off on a branch
# with broken lint gates, so the failures are surfaced separately and the forgiven ones
# keep their `allow_failure` flag rather than being filtered out.
#
# The pipeline belongs to the *source* fork, not the project the merge request targets;
# asking the target project for it returns 404. The diff itself is read from the target.
#
# `issue` is null when the id cannot be derived - a merge request opened from a branch
# rather than a drupal.org issue fork. Review the diff anyway and say so.
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
PROJECT=$1
IID=$2

api() { glab api --hostname "$HOST" "$@"; }

if ! MR=$(api "projects/project%2F$PROJECT/merge_requests/$IID" 2>/dev/null) ||
    [ "$(printf '%s' "$MR" | jq -r '.iid // empty')" = "" ]; then
    echo "cannot read merge request !$IID in project/$PROJECT on $HOST" >&2
    exit 5
fi

SOURCE_ID=$(printf '%s' "$MR" | jq -r '.source_project_id // empty')
PIPELINE_ID=$(printf '%s' "$MR" | jq -r '.head_pipeline.id // empty')

# The issue id is the numeric tail of the fork's path: issue/<project>-<issue-id>. Taking
# the last hyphen-separated field keeps working for projects whose machine name itself
# contains a hyphen.
ISSUE_ID=
if [ -n "$SOURCE_ID" ]; then
    ISSUE_ID=$(api "projects/$SOURCE_ID" 2>/dev/null |
        jq -r 'if (.path_with_namespace // "") | startswith("issue/")
               then (.path_with_namespace | split("-") | last)
               else empty end' || true)
fi

# Not every drupal.org project keeps its issues in GitLab: for the ones that have not
# migrated, this 404s and the issue only exists on drupal.org. A `... | jq ... || echo
# null` fallback would be wrong here - under `pipefail` the failing call still emits the
# 404 body through jq, so the fallback appends a *second* JSON value and the result
# parses as neither. Test the read, then convert it.
ISSUE=null
if [ -n "$ISSUE_ID" ] &&
    RAW_ISSUE=$(api "projects/project%2F$PROJECT/issues/$ISSUE_ID" 2>/dev/null) &&
    [ "$(printf '%s' "$RAW_ISSUE" | jq -r '.iid // empty')" != "" ]; then
    ISSUE=$(printf '%s' "$RAW_ISSUE" | jq -c '{iid, title, labels, state, description}')
fi

FILES='[]'
if RAW_FILES=$(api --paginate \
    "projects/project%2F$PROJECT/merge_requests/$IID/diffs?per_page=100" 2>/dev/null); then
    FILES=$(printf '%s' "$RAW_FILES" |
        jq -sc 'add // [] | map({new_path, old_path, new_file, deleted_file, renamed_file})')
fi

JOBS='[]'
if [ -n "$PIPELINE_ID" ] && [ -n "$SOURCE_ID" ]; then
    RAW=$(api "projects/$SOURCE_ID/pipelines/$PIPELINE_ID/jobs?per_page=100" 2>/dev/null || echo '[]')
    if [ "$(printf '%s' "$RAW" | jq -r 'type')" = "array" ]; then
        # A retried job is listed once per attempt; the highest id is the latest run.
        JOBS=$(printf '%s' "$RAW" |
            jq -c 'group_by(.name) | map(max_by(.id)) | map({name, status, allow_failure})')
    fi
fi

jq -n \
    --argjson mr "$MR" \
    --argjson issue "$ISSUE" \
    --argjson files "$FILES" \
    --argjson jobs "$JOBS" \
    '{
        merge_request: ($mr | {iid, title, author: .author.username, state, draft,
                              source_branch, target_branch, source_project_id,
                              web_url, description}),
        diff_refs: ($mr.diff_refs // null),
        issue: $issue,
        files: $files,
        jobs: $jobs,
        failing_jobs: ($jobs | map(select(.status == "failed" or .status == "canceled")))
    }'
