#!/usr/bin/env bash
#
# Prepare a dedicated git worktree for one issue, and print its path.
#
# Usage: bash scripts/setup-worktree.sh <owner> <repo> <issue-number>
#
# The base clone at ~/Projects/<owner>/<repo> stays on the default branch. The
# worktree is recreated from scratch on every run: completed work is always pushed,
# so the remote branch is the source of truth and leftovers from an interrupted run
# are simply redone. The branch name is deterministic - fix/issue-<number> - so the
# same issue always maps to the same branch, whatever the title says.
#
# Exit codes:
#   0  Ready. The last line of stdout is the worktree path; cd into it.
#   3  Rebase onto the default branch conflicted. The rebase has been aborted and
#      the worktree left in place; park the issue rather than working here.
#   4  The branch is checked out by another, still-live worktree. Remove that one
#      (`git worktree remove <path> --force`) and run this again.
#   Any other non-zero: the command named in stderr failed; report it.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: bash scripts/setup-worktree.sh <owner> <repo> <issue-number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3

BASE="$HOME/Projects/$OWNER/$REPO"
WT="$HOME/Projects/$OWNER/$REPO.worktrees/issue-$NUMBER"
BRANCH="fix/issue-$NUMBER"

if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --recurse-submodules
fi

cd "$BASE"
DEFAULT=$(gh repo view "$OWNER/$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# Clear this run's worktree and branch. Both may legitimately not exist. A directory that
# outlived its registration - an interrupted run, or a base clone deleted and re-cloned
# while .worktrees/ stayed behind - is not something `git worktree remove` will take, so
# remove it outright; the prune then clears any registration left dangling either way.
git worktree remove "$WT" --force 2>/dev/null || rm -rf "$WT"
git worktree prune
git branch -D "$BRANCH" 2>/dev/null || true

# Resume from the remote branch when an earlier run pushed one (e.g. the issue was
# re-assigned while its PR is still open); otherwise start from the default branch.
START="origin/$DEFAULT"
if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
    START="origin/$BRANCH"
fi

if ! ADD_ERR=$(git worktree add -b "$BRANCH" "$WT" "$START" 2>&1); then
    printf '%s\n' "$ADD_ERR" >&2
    # `git branch -D` above was blocked by another worktree holding the branch, so the
    # branch survived and `worktree add -b` refuses to reuse the name.
    case "$ADD_ERR" in
        *"already exists"* | *"already checked out"* | *"already used by worktree"*) exit 4 ;;
    esac
    exit 1
fi

cd "$WT"

if ! git rebase "origin/$DEFAULT"; then
    git rebase --abort || true
    echo "rebase onto origin/$DEFAULT conflicted; aborted" >&2
    exit 3
fi

git submodule sync --recursive
git submodule update --init --recursive

echo "$WT"
