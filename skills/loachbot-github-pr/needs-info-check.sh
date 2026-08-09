#!/usr/bin/env bash
#
# Has a parked `(Needs Info)` item been answered yet?
#
# Usage: bash needs-info-check.sh <owner> <repo> <number>
#
# Prints one verdict on the first line of stdout:
#
#   UNPARKED       Someone replied after the item was parked. The replies follow
#                  as one JSON object per line; use them as clarification.
#   PARKED         Nobody has replied yet. Skip the item.
#   MANUAL-SUFFIX  No parking rename exists, so the ` (Needs Info)` suffix was
#                  added by hand and there is nothing to measure replies against.
#                  Skip the item and mention it to the user.
#
# All three verdicts exit 0. A non-zero exit means the script itself failed - bad
# arguments, `gh` not authenticated, no such item - and should be reported as-is.
#
# Works for issues and pull requests alike: the issues API carries renames and
# regular comments for both, and inline review comments are fetched only when the
# item turns out to be a pull request.
#
# This file is duplicated verbatim in every LoachBot skill that parks items,
# because each skill directory is installed on its own. Keep the copies identical.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: bash needs-info-check.sh <owner> <repo> <number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3

# A parking run comments first and renames second, so the parking rename is the
# newest event it leaves behind. Take the most recent one: an item can be parked,
# answered and re-parked any number of times.
export PARKED
PARKED=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/events" \
    --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' \
    | tail -1)

if [ -z "$PARKED" ]; then
    echo MANUAL-SUFFIX
    exit 0
fi

# Regular comments, on both issues and pull requests.
REPLIES=$(gh api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/comments" \
    --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}')

# A pull request can also be answered with an inline review comment.
if [ "$(gh api "repos/$OWNER/$REPO/issues/$NUMBER" --jq '.pull_request != null')" = "true" ]; then
    REPLIES=$(printf '%s\n%s' "$REPLIES" "$(gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, path, body}')")
fi

REPLIES=$(printf '%s' "$REPLIES" | sed '/^[[:space:]]*$/d')

if [ -z "$REPLIES" ]; then
    echo PARKED
    exit 0
fi

echo UNPARKED
printf '%s\n' "$REPLIES"
