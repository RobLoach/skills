#!/usr/bin/env bash
#
# Get a clean, up-to-date clone to plan against, and print its path.
#
# Usage: bash scripts/sync-clone.sh <owner> <repo>
#
# Checks out origin/<default> detached rather than moving a branch: resetting the local
# default branch would discard unpushed commits on it. The path may be the user's own
# clone, so any local work - uncommitted or untracked files, or commits only a detached
# HEAD holds - stops the run instead.
#
# A first clone is blobless and skips submodules: --recurse-submodules spent minutes on
# ones like libretro-database. Already-initialized submodules are kept in step.
#
# Exit codes:
#   0  Clean and current. Stdout is the clone path, and nothing else.
#   5  The existing clone cannot be used as it is: it holds local work (uncommitted or
#      untracked files, or a detached HEAD with commits no branch holds), or its origin
#      is not <owner>/<repo> (e.g. the user's clone of a fork). What was found has been
#      printed to stderr; report it to the user and stop.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/sync-clone.sh <owner> <repo>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
BASE="${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/$OWNER/$REPO"

# stdout is the path alone: git's chatter goes to stderr.
exec 3>&1 1>&2

if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --filter=blob:none
    echo "$BASE" >&3
    exit 0
fi

cd "$BASE"

# The plan is read from origin's default branch, so a clone of a fork would quietly plan
# against the fork. Matched by owner/repo alone, whatever the scheme (ssh or https),
# `.git` suffix or case.
ORIGIN=$(git remote get-url origin 2>/dev/null || true)
FOUND=${ORIGIN%/}
FOUND=${FOUND%.git}
FOUND_REPO=${FOUND##*[:/]}
FOUND=${FOUND%[:/]*}
FOUND="${FOUND##*[:/]}/$FOUND_REPO"
if [ "$(printf '%s' "$FOUND" | tr '[:upper:]' '[:lower:]')" != \
    "$(printf '%s' "$OWNER/$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "clone has origin ${ORIGIN:-(none)}, not $OWNER/$REPO"
    exit 5
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "clone has uncommitted local changes:"
    git status --short
    exit 5
fi

DEFAULT=$(gh repo view "$OWNER/$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# A clean tree can still hold work. Commits on a branch survive the detach below, but
# ones only a detached HEAD reaches would be left to the reflog, so those stop the run.
ORPHANS=$(git rev-list --count HEAD --not --branches --remotes)
if [ "$ORPHANS" -ne 0 ]; then
    echo "clone has a detached HEAD with $ORPHANS commit(s) no branch holds:"
    git log --oneline HEAD --not --branches --remotes
    exit 5
fi

# Untracked files already stopped the run above, so there is nothing left to clean.
git checkout --detach "origin/$DEFAULT"
git submodule sync --recursive
git submodule update --recursive

echo "$BASE" >&3
