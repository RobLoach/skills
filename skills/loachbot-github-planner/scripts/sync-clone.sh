#!/usr/bin/env bash
#
# Get a clean, up-to-date clone to plan against, and print its path.
#
# Usage: bash scripts/sync-clone.sh <owner> <repo>
#
# Clones into ~/Projects/<owner>/<repo> (or LOACHBOT_PROJECTS_DIR) if it isn't there yet,
# otherwise checks out origin/<default> as a detached HEAD. Planning only reads code, so
# no local branch is moved or reset: resetting the local default branch would discard
# commits on it that were never pushed, and HEAD being elsewhere would hide them from
# any check against HEAD. Local work is never clobbered: uncommitted or untracked files,
# or commits that only a detached HEAD holds, stop the run instead, since notes, an
# experiment or a stash-in-progress are the user's to deal with, not this skill's. That
# path is just as likely to be the user's own clone as a scratch one, so the bar is
# deliberately low.
#
# Planning reads code, it does not build it, so a first clone fetches blobs lazily and
# skips submodules: --recurse-submodules spent minutes on ones like libretro-database.
# A clone that already has submodules initialized keeps them in step, or the next run
# would see them as local changes.
#
# Exit codes:
#   0  Clean and current. Stdout is the clone path, and nothing else.
#   5  The existing clone holds local work: uncommitted or untracked files, or a
#      detached HEAD with commits no branch holds. What was found has been printed to
#      stderr; report it to the user and stop.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/sync-clone.sh <owner> <repo>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
BASE="${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/$OWNER/$REPO"

# git checkout chats on stdout, and the caller captures stdout as the path
# without a pipe (a pipe would hide exit 5), so everything but the path goes to stderr.
exec 3>&1 1>&2

if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --filter=blob:none
    echo "$BASE" >&3
    exit 0
fi

cd "$BASE"

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
