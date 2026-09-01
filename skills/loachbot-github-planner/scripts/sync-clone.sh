#!/usr/bin/env bash
#
# Get a clean, up-to-date clone to plan against, and print its path.
#
# Usage: bash scripts/sync-clone.sh <owner> <repo>
#
# Clones into ~/Projects/<owner>/<repo> if it isn't there yet, otherwise resets to the
# remote default branch. Local work is never clobbered: a clone holding anything origin
# does not have stops the run instead, since notes, an experiment or a stash-in-progress
# are the user's to deal with, not this skill's. That path is just as likely to be the
# user's own clone as a scratch one, so the bar is deliberately low.
#
# Exit codes:
#   0  Clean and current. The last line of stdout is the clone path.
#   5  The existing clone holds local work: uncommitted changes, or commits that
#      origin/<default> does not have. What was found has been printed to stderr;
#      report it to the user and stop.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/sync-clone.sh <owner> <repo>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
BASE="$HOME/Projects/$OWNER/$REPO"

if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --recurse-submodules
    echo "$BASE"
    exit 0
fi

cd "$BASE"

if [ -n "$(git status --porcelain)" ]; then
    echo "clone has uncommitted local changes:" >&2
    git status --short >&2
    exit 5
fi

DEFAULT=$(gh repo view "$OWNER/$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# A clean tree can still hold work. Commits that were never pushed survive
# `git status --porcelain` and would be thrown away by the reset below, so anything
# origin/<default> does not already have stops the run.
AHEAD=$(git rev-list --count "origin/$DEFAULT..HEAD")
if [ "$AHEAD" -ne 0 ]; then
    echo "clone has $AHEAD commit(s) that origin/$DEFAULT does not:" >&2
    git log --oneline "origin/$DEFAULT..HEAD" >&2
    exit 5
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$DEFAULT" ]; then
    echo "note: moving this clone from '$CURRENT' to '$DEFAULT'" >&2
fi

git checkout "$DEFAULT"
git reset --hard "origin/$DEFAULT"
git clean -fd
git submodule sync --recursive
git submodule update --init --recursive

echo "$BASE"
