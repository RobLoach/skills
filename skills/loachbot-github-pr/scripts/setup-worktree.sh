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
#   4  The PR branch is checked out by another, still-live worktree. Remove that one
#      (`git worktree remove <path> --force`) and run this again - never force-switch
#      a branch across worktrees.
#   9  A submodule could not be fetched (e.g. "not our ref": the PR pins a commit
#      that no longer exists). The worktree is checked out and its path still printed;
#      the failing submodule is named on stderr.
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

PROJECTS=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}
BASE="$PROJECTS/$OWNER/$REPO"
WT="$PROJECTS/$OWNER/$REPO.worktrees/pr-$NUMBER"

# Blobless: the full history stays available for rebases, but file contents are fetched
# only when checked out. No submodules here; each worktree fetches its own.
if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --filter=blob:none
fi

cd "$BASE"
git fetch origin --prune

# Drop registrations whose directory is gone, so the add below is not refused by one.
git worktree prune

# A directory can outlive its registration: an interrupted run, or a base clone that was
# deleted and re-cloned while .worktrees/ stayed behind. Entering one would point the
# reset/clean below at whatever repository encloses ~/Projects - conceivably $HOME, if
# that is a dotfiles checkout - so anything that is not this worktree is removed rather
# than reused. It is throwaway either way.
if [ -d "$WT" ] && [ "$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$WT" && pwd -P)" ]; then
    rm -rf "$WT"
fi

if [ ! -d "$WT" ]; then
    git worktree add --detach "$WT"
fi

cd "$WT"
git reset --hard
git clean -fd

# `gh pr checkout` resolves fork remotes on its own. Submodules are updated separately
# below, so their failure gets its own exit code.
if ! CHECKOUT_ERR=$(gh pr checkout "$NUMBER" --repo "$OWNER/$REPO" 2>&1); then
    printf '%s\n' "$CHECKOUT_ERR" >&2
    case "$CHECKOUT_ERR" in
        *"already exists"* | *"already checked out"* | *"already used by worktree"*) exit 4 ;;
    esac
    exit 1
fi

# Shallow: a full recursive clone of a large submodule took most of a run. A change
# that bumps a submodule can deepen it with `git -C <path> fetch --unshallow`.
git submodule sync --recursive
if ! git submodule update --init --recursive --depth 1 >&2; then
    echo "$WT"
    exit 9
fi

echo "$WT"
