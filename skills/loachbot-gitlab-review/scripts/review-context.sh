#!/usr/bin/env bash
#
# Gather everything a review of one drupal.org merge request needs, as one JSON object.
#
# Usage: bash scripts/review-context.sh <project> <mr-iid>
#
# Keys: merge_request {iid, title, author, state, draft, source_branch, target_branch,
# source_project_id, web_url, description}, diff_refs {base_sha, start_sha, head_sha}
# (inline comments need these), issue_ref, files [{new_path, old_path, new_file,
# deleted_file, renamed_file, diff}], pipeline_project_id, discussions [{id, resolved,
# path, line, author, body}].
#
# `discussions` (each thread's first note, trimmed) is there so a review replies in an
# existing thread rather than re-posting a finding. `pipeline_project_id` is where job
# logs live: GitLab runs a fork's pipeline in the parent when the author can push there.
# `issue_ref` is null for a plain-branch merge request; review the diff anyway.
#
# Exit codes:
#   0  Context on stdout.
#   5  The merge request, its diff or its discussions could not be read. Report it.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/review-context.sh <project> <mr-iid>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
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
PIPELINE_PROJECT=$(printf '%s' "$MR" |
    jq -r '.head_pipeline.project_id // .source_project_id // empty')

# The last hyphen-separated field of issue/<project>-<number>, which survives a hyphen
# in the machine name. What the number means is read-issue.sh's question.
ISSUE_REF=null
if [ -n "$SOURCE_ID" ]; then
    REF=$(api "projects/$SOURCE_ID" 2>/dev/null |
        jq -r 'if (.path_with_namespace // "") | startswith("issue/")
               then (.path_with_namespace | split("-") | last)
               else empty end' || true)
    [ -n "$REF" ] && ISSUE_REF=$(printf '%s' "$REF" | jq -R .)
fi

# An unreadable diff or discussion list is an error, never an empty one: an empty diff
# reviews as "nothing to find", and empty discussions re-post findings already left.
if ! RAW_FILES=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/diffs?per_page=100" 2>/dev/null); then
    echo "cannot read the diff of !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi
FILES=$(printf '%s' "$RAW_FILES" |
    jq -sc 'add // [] | map({new_path, old_path, new_file, deleted_file, renamed_file, diff})')

if ! RAW_DISCUSSIONS=$(api --paginate \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/discussions?per_page=100" 2>/dev/null); then
    echo "cannot read the discussions of !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi
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

# Diffs go through files rather than --argjson: a single argument is capped at 128 KiB on
# Linux, and one large merge request's diff text is enough to hit it.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$MR" >"$TMP/mr.json"
printf '%s' "$FILES" >"$TMP/files.json"
printf '%s' "$DISCUSSIONS" >"$TMP/discussions.json"

jq -n \
    --slurpfile mr "$TMP/mr.json" \
    --slurpfile files "$TMP/files.json" \
    --slurpfile discussions "$TMP/discussions.json" \
    --argjson issue_ref "$ISSUE_REF" \
    --arg pipeline_project "$PIPELINE_PROJECT" \
    '$mr[0] as $mr
     | {
        merge_request: ($mr | {iid, title, author: .author.username, state, draft,
                              source_branch, target_branch, source_project_id,
                              web_url, description}),
        diff_refs: ($mr.diff_refs // null),
        issue_ref: $issue_ref,
        files: $files[0],
        pipeline_project_id: (if $pipeline_project == "" then null else ($pipeline_project | tonumber) end),
        discussions: $discussions[0]
    }'
