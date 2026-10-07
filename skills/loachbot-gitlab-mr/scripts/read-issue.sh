#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Read the issue behind a merge request, from whichever of drupal.org's two worlds it
# actually lives in.
#
# Usage: bash scripts/read-issue.sh <project> <issue-ref>
#
# <issue-ref> is the number from the issue fork's path - the tail of
# issue/<project>-<number>. What that number *means* depends on the project, which is
# the whole reason this script exists:
#
#   * A project whose issues were migrated into GitLab (most of contrib) numbers them
#     itself. The fork's number is a GitLab issue iid.
#   * A project whose issues were never migrated - Drupal core and eck among them -
#     keeps its queue on drupal.org only. The fork's number is a drupal.org node id.
#
# The two numbering spaces overlap, and that is a trap rather than a convenience:
# ai_ckeditor's GitLab issue 3615852 is "Uninstalling ai_ckeditor leaves stale toolbar
# items"; drupal.org's *node* 3615852 is an unrelated Drupal core issue about
# ConfigManager. Trying one number against both places and keeping whichever answers
# therefore does not degrade gracefully - it returns a confident, wrong requirement to
# review a merge request against. So the world is decided first, from whether the
# project has GitLab issues at all, and only then is the number interpreted.
#
# As a second guard, an issue read from drupal.org must name the project it was asked
# about. A mismatch means the number was interpreted in the wrong world and is reported
# rather than returned.
#
# Emits one JSON object:
#   {
#     "source":     "gitlab" | "drupal.org",
#     "ref":        the number as given,
#     "title":      string,
#     "status":     human-readable where known, else the raw value,
#     "actionable": false when the issue is fixed, closed, postponed or RTBC - do not
#                   force-push over it and do not pick it up,
#     "writable":   true when /do: commands can be posted from here. False for
#                   drupal.org-only issues: those move state through the web UI, so the
#                   handback has to go to the user instead,
#     "url":        where a human should look,
#     "labels":     [string],   # GitLab only, empty otherwise
#     "version":    string,     # drupal.org only, empty otherwise
#     "description": string
#   }
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
PROJECT=$1
REF=$2

api() { glab api --hostname "$HOST" "$@"; }

# Which world? A project with no GitLab issues at all never migrated its queue.
if ! PROBE=$(api "projects/project%2F$PROJECT/issues?per_page=1" 2>/dev/null) ||
    [ "$(printf '%s' "$PROBE" | jq -r 'type')" != "array" ]; then
    echo "cannot tell whether project/$PROJECT keeps its issues in GitLab" >&2
    exit 6
fi

if [ "$(printf '%s' "$PROBE" | jq -r 'length')" != "0" ]; then
    # Migrated: the fork's number is a GitLab issue iid.
    if ! ISSUE=$(api "projects/project%2F$PROJECT/issues/$REF" 2>/dev/null) ||
        [ "$(printf '%s' "$ISSUE" | jq -r '.iid // empty')" = "" ]; then
        echo "project/$PROJECT keeps its issues in GitLab, but issue $REF is not there" >&2
        exit 6
    fi
    printf '%s' "$ISSUE" | jq -c --arg ref "$REF" '{
        source: "gitlab",
        ref: $ref,
        title,
        status: (if .state == "closed" then "Closed"
                 else ([.labels[] | select(startswith("state::"))] | first // "open") end),
        actionable: ((.state != "closed")
                     and ((.labels | index("state::rtbc")) | not)
                     and ((.labels | index("state::fixed")) | not)),
        writable: true,
        url: .web_url,
        labels: .labels,
        version: "",
        description: (.description // "")
    }'
    exit 0
fi

# Not migrated: the fork's number is a drupal.org node id, and drupal.org is the only
# place the issue exists.
if ! command -v drupalorg >/dev/null 2>&1; then
    echo "project/$PROJECT keeps its issues on drupal.org, which needs the drupalorg CLI" >&2
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
# Actionable means someone is still expected to work on it: anything fixed, closed,
# postponed or already reviewed-and-tested is not for this run to touch.
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
