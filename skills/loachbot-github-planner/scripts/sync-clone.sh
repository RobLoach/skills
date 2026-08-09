#!/usr/bin/env bash
#
# Get a clean, up-to-date clone to plan against, and print its path.
#
# Usage: bash scripts/sync-clone.sh <owner> <repo>
#
# Clones into ~/Projects/<owner>/<repo> if it isn't there yet, otherwise resets to the
# remote default branch. Local changes are never clobbered: a dirty clone stops the
# run instead, since notes, an experiment or a stash-in-progress are the user's to
# deal with, not this skill's.
#
# Exit codes:
#   0  Clean and current. The last line of stdout is the clone path.
#   5  The existing clone has uncommitted changes. `git status --short` has been
#      printed to stderr; report it to the user and stop.

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
git checkout "$DEFAULT"
git reset --hard "origin/$DEFAULT"
git clean -fd
git submodule sync --recursive
git submodule update --init --recursive

echo "$BASE"
