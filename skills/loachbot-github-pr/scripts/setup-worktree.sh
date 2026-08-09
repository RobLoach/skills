#!/usr/bin/env bash
#
# Check a Pull Request out into a dedicated git worktree, and print its path.
#
# Usage: bash scripts/setup-worktree.sh <owner> <repo> <pr-number>
#
# The base clone at ~/Projects/<owner>/<repo> stays on the default branch, and each
# Pull Request gets its own worktree so branches can never bleed into each other.
# Uncommitted leftovers from an interrupted run are discarded: 🚀 reactions are only
# added after a successful push, so any comment that was not finished is simply
# re-addressed on this run.
#
# Exit codes:
#   0  Ready. The last line of stdout is the worktree path; cd into it.
#   4  The PR branch is checked out by another worktree. Remove that stale worktree
#      (`git worktree remove <path>`) and run this again - never force-switch a
#      branch across worktrees.
#   Any other non-zero: `gh pr checkout` or git failed (e.g. the local branch has
#      diverged). Report it rather than forcing through.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: bash scripts/setup-worktree.sh <owner> <repo> <pr-number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3

BASE="$HOME/Projects/$OWNER/$REPO"
WT="$HOME/Projects/$OWNER/$REPO.worktrees/pr-$NUMBER"

if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --recurse-submodules
fi

cd "$BASE"
git fetch origin --prune

if [ ! -d "$WT" ]; then
    git worktree add --detach "$WT"
fi

cd "$WT"
git reset --hard
git clean -fd

# `gh pr checkout` resolves fork remotes on its own, and --recurse-submodules covers
# the `git submodule sync`/`update` pair.
if ! gh pr checkout "$NUMBER" --repo "$OWNER/$REPO" --recurse-submodules 2>/tmp/loachbot-checkout-err; then
    cat /tmp/loachbot-checkout-err >&2
    if grep -qE "already exists|already checked out|already used by worktree" /tmp/loachbot-checkout-err; then
        exit 4
    fi
    exit 1
fi

echo "$WT"
