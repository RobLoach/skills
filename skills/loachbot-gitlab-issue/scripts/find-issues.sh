#!/usr/bin/env bash
#
# List the open drupal.org issues you reported that this skill could pick up, most
# recently updated first.
#
# Usage: bash scripts/find-issues.sh [project]
#
# Prints one line per candidate:
#   <kind>\t<namespace>/<project>#<iid>\tmrs=<count>\t[<labels>]\t<title>
#
#   resume  assigned to you, at an open state: an earlier run stopped before an MR.
#   ready   unassigned, at an open state.
#   parked  assigned to you and `state::blocked`.
#
# Only issues you reported: claiming somebody else's queue uninvited is not this skill's
# call. "Open state" is an allowlist - no `state::` label, `state::accepted` or
# `state::needsWork` - so a label nobody has invented yet is left alone, not guessed at.
#
# Exit codes:
#   0  Candidates printed.
#   5  The authenticated user or the issue search could not be read.
#   6  Nothing to pick up.

set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "usage: bash scripts/find-issues.sh [project]" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
SCOPE=$NAMESPACE/
# A named project is asked directly: in the global search, issues elsewhere could push
# this project's off the page.
ENDPOINT="issues?scope=all&"
if [ "$#" -eq 1 ]; then
    SCOPE="$NAMESPACE/$1#"
    ENDPOINT="projects/$NAMESPACE%2F$1/issues?"
fi

api() { glab api --hostname "$HOST" "$@"; }

USER_JSON=$(api user 2>/dev/null) || USER_JSON=''
ME=$(printf '%s' "${USER_JSON:-null}" | jq -r '.username // empty')
MY_ID=$(printf '%s' "${USER_JSON:-null}" | jq -r '.id // empty')
if [ -z "$ME" ] || [ -z "$MY_ID" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

# --paginate prints one array per page; slurp them into one.
ISSUES=$(api --paginate "${ENDPOINT}author_id=$MY_ID&state=opened&order_by=updated_at&sort=desc&per_page=100" \
    2>/dev/null | jq -sc 'add') || ISSUES=''
if [ "$(printf '%s' "${ISSUES:-null}" | jq -r 'type')" != "array" ]; then
    echo "cannot search issues on $HOST" >&2
    exit 5
fi

FOUND=$(printf '%s' "$ISSUES" | jq -r --arg me "$ME" --arg scope "$SCOPE" '
    .[]
    | select(.references.full | startswith($scope))
    | . as $i
    | [$i.labels[] | select(startswith("state::"))] as $state
    | [$i.assignees[].username] as $who
    | ($state | all(IN("state::accepted", "state::needsWork"))) as $open_state
    | (if ($who | index($me)) != null and ($state | index("state::blocked")) != null
       then "parked"
       elif ($who | index($me)) != null and $open_state then "resume"
       elif ($who | length) == 0 and $open_state then "ready"
       else null end) as $kind
    | select($kind != null)
    | "\($kind)\t\($i.references.full)\tmrs=\($i.merge_requests_count)\t[\($i.labels | join(","))]\t\($i.title)"')

if [ -z "$FOUND" ]; then
    echo "no open issues of yours to pick up" >&2
    exit 6
fi

printf '%s\n' "$FOUND"
