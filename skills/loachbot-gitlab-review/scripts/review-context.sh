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
#     "files":         [ { new_path, old_path, new_file, deleted_file, renamed_file } ],
#     "jobs":          [ { name, status, allow_failure } ],
#     "failing_jobs":  [ { name, status, allow_failure } ]
#   }
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
# The pipeline belongs to the *source* fork, not the project the merge request targets;
# asking the target project for it returns 404. The diff itself is read from the target.
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
    --argjson issue_ref "$ISSUE_REF" \
    --argjson files "$FILES" \
    --argjson jobs "$JOBS" \
    '{
        merge_request: ($mr | {iid, title, author: .author.username, state, draft,
                              source_branch, target_branch, source_project_id,
                              web_url, description}),
        diff_refs: ($mr.diff_refs // null),
        issue_ref: $issue_ref,
        files: $files,
        jobs: $jobs,
        failing_jobs: ($jobs | map(select(.status == "failed" or .status == "canceled")))
    }'
