#!/usr/bin/env bash
#
# Gather everything a plan has to be checked against - the queue, the releases, the
# branches, the labels and the open merge requests - as one JSON object.
#
# Usage: bash scripts/project-context.sh <project>
#
# `issue_queue` comes from the project's `issues_enabled` flag, not an empty issue list:
# a queue that never migrated (core, eck) has the tracker off, while a freshly migrated
# one is legitimately empty. `open_issues` is one page; `capped` says the queue is
# larger, the cue to search per candidate.
#
# Keys: project, path, default_branch, archived, issue_queue ("gitlab" | "drupal.org"),
# open_issues_count, capped, labels, branches [{name, default}], tags [{name, date}],
# open_issues [{iid, title, labels, updated_at, url, mrs}], recently_closed
# [{iid, title, updated_at, url}], open_merge_requests [{iid, title, source_branch, url}].
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
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
ENC="$NAMESPACE%2F$PROJECT"
PAGE=100

api() { glab api --hostname "$HOST" "$@"; }

META=$(api "projects/$ENC" 2>/dev/null) || META=''

if [ "$(printf '%s' "${META:-null}" | jq -r '.id // empty')" = "" ]; then
    echo "cannot read $NAMESPACE/$PROJECT on $HOST" >&2
    exit 6
fi

# Every read goes to a file and reaches jq through --slurpfile rather than --argjson: a
# single argument is capped at 128 KiB on Linux, and a hundred issues with their
# descriptions and links are several times that.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s' "$META" >"$TMP/meta.json"

# A read allowed to come back empty or fail reads as [] so the output keeps its shape.
read_array() {
    if ! api "$2" >"$TMP/$1.json" 2>/dev/null ||
        [ "$(jq -r 'type' "$TMP/$1.json" 2>/dev/null)" != "array" ]; then
        printf '[]' >"$TMP/$1.json"
    fi
}

printf '[]' >"$TMP/open_issues.json"
printf '[]' >"$TMP/closed_issues.json"
if [ "$(printf '%s' "$META" | jq -r '.issues_enabled')" = "true" ]; then
    read_array open_issues \
        "projects/$ENC/issues?state=opened&order_by=updated_at&sort=desc&per_page=$PAGE"
    # An issue fixed last month is the commonest thing a plan files again.
    read_array closed_issues \
        "projects/$ENC/issues?state=closed&order_by=updated_at&sort=desc&per_page=50"
fi

read_array labels "projects/$ENC/labels?per_page=$PAGE"
read_array branches "projects/$ENC/repository/branches?per_page=$PAGE"
read_array tags "projects/$ENC/repository/tags?per_page=10"
read_array merge_requests \
    "projects/$ENC/merge_requests?state=opened&order_by=updated_at&sort=desc&per_page=50"

jq -n \
    --arg project "$PROJECT" \
    --arg path "$NAMESPACE/$PROJECT" \
    --argjson page "$PAGE" \
    --slurpfile meta "$TMP/meta.json" \
    --slurpfile open_issues "$TMP/open_issues.json" \
    --slurpfile closed_issues "$TMP/closed_issues.json" \
    --slurpfile labels "$TMP/labels.json" \
    --slurpfile branches "$TMP/branches.json" \
    --slurpfile tags "$TMP/tags.json" \
    --slurpfile merge_requests "$TMP/merge_requests.json" \
    '$meta[0] as $meta
     | $open_issues[0] as $open_issues
     | $closed_issues[0] as $closed_issues
     | $labels[0] as $labels
     | $branches[0] as $branches
     | $tags[0] as $tags
     | $merge_requests[0] as $merge_requests
     | ($meta.open_issues_count // 0) as $total
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
