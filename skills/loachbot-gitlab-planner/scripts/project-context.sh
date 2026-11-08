#!/usr/bin/env bash
#
# Gather everything a plan has to be checked against - the queue, the releases, the
# branches, the labels and the open merge requests - in one read, as one JSON object.
#
# Usage: bash scripts/project-context.sh <project>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# `issue_queue` comes from the project's `issues_enabled` flag, not an empty issue list:
# a queue that never migrated (core, eck) has the tracker switched off, while a freshly
# migrated one is legitimately empty. `open_issues` is one page; `capped` says when the
# queue is larger, the cue to search per candidate.
#
# Emits one JSON object:
#   {
#     "project", "path", "default_branch", "archived",
#     "issue_queue":  "gitlab" | "drupal.org",
#     "open_issues_count": the queue's real total, 0 when it is not in GitLab,
#     "capped":       true when open_issues is a sample rather than the whole queue,
#     "labels":       [string], the names this project has actually defined,
#     "branches":     [{name, default}],
#     "tags":         [{name, date}], newest releases first,
#     "open_issues":  [{iid, title, labels, updated_at, url, mrs}],
#     "recently_closed": [{iid, title, updated_at, url}],
#     "open_merge_requests": [{iid, title, source_branch, url}]
#   }
#
# Exit codes:
#   0  Context on stdout, as one JSON object.
#   6  The project could not be read on the API host.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bash scripts/project-context.sh <project>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
ENC="$NAMESPACE%2F$PROJECT"
PAGE=100

api() { glab api --hostname "$HOST" "$@"; }

# Two steps: `glab api` exits non-zero on a 404, which `set -e` would turn into a silent end.
META=$(api "projects/$ENC" 2>/dev/null) || META=''

if [ "$(printf '%s' "${META:-null}" | jq -r '.id // empty')" = "" ]; then
    echo "cannot read $NAMESPACE/$PROJECT on $HOST" >&2
    exit 6
fi

# A read allowed to come back empty or fail reads as [] so the output keeps its shape.
read_array() {
    local out
    out=$(api "$1" 2>/dev/null) || out=''
    if [ "$(printf '%s' "${out:-null}" | jq -r 'type')" = "array" ]; then
        printf '%s' "$out"
    else
        printf '[]'
    fi
}

OPEN_ISSUES='[]'
CLOSED_ISSUES='[]'
if [ "$(printf '%s' "$META" | jq -r '.issues_enabled')" = "true" ]; then
    OPEN_ISSUES=$(read_array \
        "projects/$ENC/issues?state=opened&order_by=updated_at&sort=desc&per_page=$PAGE")
    # An issue fixed last month is the commonest thing a plan files again.
    CLOSED_ISSUES=$(read_array \
        "projects/$ENC/issues?state=closed&order_by=updated_at&sort=desc&per_page=50")
fi

LABELS=$(read_array "projects/$ENC/labels?per_page=$PAGE")
BRANCHES=$(read_array "projects/$ENC/repository/branches?per_page=$PAGE")
TAGS=$(read_array "projects/$ENC/repository/tags?per_page=10")
MERGE_REQUESTS=$(read_array \
    "projects/$ENC/merge_requests?state=opened&order_by=updated_at&sort=desc&per_page=50")

jq -n \
    --arg project "$PROJECT" \
    --arg path "$NAMESPACE/$PROJECT" \
    --argjson page "$PAGE" \
    --argjson meta "$META" \
    --argjson open_issues "$OPEN_ISSUES" \
    --argjson closed_issues "$CLOSED_ISSUES" \
    --argjson labels "$LABELS" \
    --argjson branches "$BRANCHES" \
    --argjson tags "$TAGS" \
    --argjson merge_requests "$MERGE_REQUESTS" \
    '($meta.open_issues_count // 0) as $total
     | {
        project: $project,
        path: $path,
        default_branch: ($meta.default_branch // ""),
        archived: ($meta.archived == true),
        issue_queue: (if $meta.issues_enabled == true then "gitlab" else "drupal.org" end),
        open_issues_count: $total,
        capped: (($open_issues | length) >= $page and $total > ($open_issues | length)),
        labels: [$labels[].name],
        branches: [$branches[] | {name, default: .default}],
        tags: [$tags[] | {name, date: .commit.created_at}],
        open_issues: [$open_issues[] | {
            iid, title, labels, updated_at, url: .web_url, mrs: .merge_requests_count
        }],
        recently_closed: [$closed_issues[] | {iid, title, updated_at, url: .web_url}],
        open_merge_requests: [$merge_requests[] | {iid, title, source_branch, url: .web_url}]
    }'
