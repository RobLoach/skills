#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Read the issue behind a merge request, from whichever of drupal.org's two worlds it
# actually lives in.
#
# Usage: bash scripts/read-issue.sh <project> <issue-ref>
#
# <issue-ref> is the number from the fork's path, issue/<project>-<number>. In a project
# whose queue migrated to GitLab it is an issue iid; in one that never did (core, eck)
# it is a drupal.org node id. The two numbering spaces overlap - ai_ckeditor's GitLab
# issue 3615852 and drupal.org node 3615852 are unrelated - so trying both and keeping
# whichever answers returns a confident, wrong requirement. The world is decided first,
# from whether the project has GitLab issues at all, and a drupal.org node must also name
# the project asked about.
#
# Emits one JSON object: source ("gitlab" | "drupal.org"), ref, title, status,
# actionable (false when fixed, closed, postponed or RTBC), writable (false for
# drupal.org-only issues, whose state moves through the web UI), url, labels (GitLab
# only), version (drupal.org only), description.
#
# Exit codes:
#   0  Issue read. JSON on stdout.
#   6  The issue could not be read from the world this project belongs to. Report it;
#      do not try the other world.
#   7  Read, but it belongs to a different project - the number was interpreted in the
#      wrong world. Report it and do not use the result.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/read-issue.sh <project> <issue-ref>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
REF=$2

api() { glab api --hostname "$HOST" "$@"; }

# Which world? A project with no GitLab issues at all never migrated its queue.
if ! PROBE=$(api "projects/$NAMESPACE%2F$PROJECT/issues?per_page=1" 2>/dev/null) ||
    [ "$(printf '%s' "$PROBE" | jq -r 'type')" != "array" ]; then
    echo "cannot tell whether $NAMESPACE/$PROJECT keeps its issues in GitLab" >&2
    exit 6
fi

if [ "$(printf '%s' "$PROBE" | jq -r 'length')" != "0" ]; then
    # Migrated: the fork's number is a GitLab issue iid.
    if ! ISSUE=$(api "projects/$NAMESPACE%2F$PROJECT/issues/$REF" 2>/dev/null) ||
        [ "$(printf '%s' "$ISSUE" | jq -r '.iid // empty')" = "" ]; then
        echo "$NAMESPACE/$PROJECT keeps its issues in GitLab, but issue $REF is not there" >&2
        exit 6
    fi
    # Matched by prefix: one project can spell a label several ways (project/ai has
    # `state::needs review`, `state::needs_review` and `state::needsReview`).
    # `state::needsReview` is deliberately absent: a review may ask for more code.
    printf '%s' "$ISSUE" | jq -c --arg ref "$REF" '{
        source: "gitlab",
        ref: $ref,
        title,
        status: (if .state == "closed" then "Closed"
                 else ([.labels[] | select(startswith("state::"))] | first // "open") end),
        actionable: ((.state != "closed")
                     and ([.labels[]? | select(startswith("state::rtbc")
                                               or startswith("state::fixed")
                                               or startswith("state::postponed")
                                               or startswith("state::closed"))]
                          | length == 0)),
        writable: true,
        url: .web_url,
        labels: .labels,
        version: "",
        description: (.description // "")
    }'
    exit 0
fi

if ! command -v drupalorg >/dev/null 2>&1; then
    echo "$NAMESPACE/$PROJECT keeps its issues on drupal.org, which needs the drupalorg CLI" >&2
    echo "install it from https://github.com/mglaman/drupalorg-cli" >&2
    exit 6
fi

if ! NODE=$(drupalorg issue:show "$REF" --format=json 2>/dev/null) ||
    [ "$(printf '%s' "$NODE" | jq -r '.nid // empty')" = "" ]; then
    echo "drupal.org has no issue node $REF" >&2
    exit 6
fi

NODE_PROJECT=$(printf '%s' "$NODE" | jq -r '.field_project_machine_name // empty')
if [ "$NODE_PROJECT" != "$PROJECT" ]; then
    echo "drupal.org node $REF belongs to '$NODE_PROJECT', not '$PROJECT':" \
        "the number was read in the wrong world, so this is not the issue" >&2
    exit 7
fi

# Status codes are drupal.org's own and stable; the names are what its UI shows.
printf '%s' "$NODE" | jq -c --arg ref "$REF" '
    (.field_issue_status | tonumber? // -1) as $s |
    {
        source: "drupal.org",
        ref: $ref,
        title,
        status: ({
            "1": "Active", "2": "Fixed", "3": "Closed (duplicate)", "4": "Postponed",
            "5": "Closed (won'"'"'t fix)", "6": "Closed (works as designed)",
            "7": "Closed (fixed)", "8": "Needs review", "13": "Needs work",
            "14": "Reviewed & tested by the community", "15": "Patch (to be ported)",
            "16": "Postponed (maintainer needs more info)", "18": "Closed (outdated)"
        }[$s | tostring] // ("status " + ($s | tostring))),
        actionable: (([1, 8, 13, 15] | index($s)) != null),
        writable: false,
        url: ("https://www.drupal.org/node/" + $ref),
        labels: [],
        version: (.field_issue_version // ""),
        description: (.body_value // "")
    }'
