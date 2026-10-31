#!/usr/bin/env bash
#
# List the open drupal.org issues you reported that this skill could pick up, sorted
# into the three kinds worth looking at, most recently updated first.
#
# Usage: bash scripts/find-issues.sh [project]
#
# Prints one line per candidate:
#   <kind>\t<namespace>/<project>#<iid>\tmrs=<count>\t[<labels>]\t<title>
#
#   resume  assigned to you, at an open state: an earlier run claimed it and stopped
#           before opening a merge request. Finish these first.
#   ready   unassigned, at an open state: the ordinary candidate.
#   parked  assigned to you and `state::blocked`: an earlier run asked a question.
#
# Only issues you reported, because the skill claims what it picks and claiming
# somebody else's queue uninvited is not its call to make.
#
# The state test is an allowlist. `state::needsReview`, `state::rtbc`, `state::fixed`,
# `state::postponed` and the `state::closed*` family all mean the issue is not waiting
# on code, and a label nobody has invented yet means something this skill has never
# heard of - so anything outside `state::accepted` and `state::needsWork` is left alone
# rather than guessed at. An issue with no `state::` label at all passes, which is the
# usual state of a freshly reported one.
#
# Every issue this search returns lives in GitLab by definition, so none of them can be
# a drupal.org-only issue the skill has no way to claim.
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
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
SCOPE=$NAMESPACE/
if [ "$#" -eq 1 ]; then
    SCOPE="$NAMESPACE/$1#"
fi

api() { glab api --hostname "$HOST" "$@"; }

USER_JSON=$(api user 2>/dev/null) || USER_JSON=''
ME=$(printf '%s' "${USER_JSON:-null}" | jq -r '.username // empty')
MY_ID=$(printf '%s' "${USER_JSON:-null}" | jq -r '.id // empty')
if [ -z "$ME" ] || [ -z "$MY_ID" ]; then
    echo "cannot read the authenticated user from $HOST" >&2
    exit 5
fi

ISSUES=$(api "issues?author_id=$MY_ID&state=opened&scope=all&order_by=updated_at&sort=desc&per_page=50" \
    2>/dev/null) || ISSUES=''
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
