#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Prepare a dedicated git worktree for one issue or Pull Request, and print its path.
#
# Usage: bash scripts/setup-github-worktree.sh <owner> <repo> issue|pr <number>
#
# The base clone at ~/Projects/<owner>/<repo> stays on the default branch. The worktree
# is recreated from scratch on every run: finished work is always pushed (and a PR's 🚀
# reactions only follow a push), so the remote is the source of truth and leftovers from
# an interrupted run are simply redone.
#
#   issue  Branch fix/issue-<number>, the same whatever the title says. Resumes from
#          origin/fix/issue-<number> when an earlier run pushed one, then rebases onto
#          the default branch. The branch is bot-owned, so another worktree holding it
#          is stale and removed.
#   pr     `gh pr checkout`, which resolves fork remotes. The branch may be the user's
#          own checkout, so another worktree holding it is reported, never taken. A
#          local branch no worktree holds is a leftover from an earlier run, and after
#          a force-push to the PR it can no longer fast-forward, so `--force` resets it
#          to the PR head; finished work is always pushed, so nothing is lost.
#
# Only the worktree path goes to stdout, so callers capture it without a pipe.
#
# Exit codes:
#   0  Ready. Stdout is the worktree path.
#   3  issue only: the rebase onto the default branch conflicted. It has been aborted
#      and the worktree left in place.
#   4  pr only: the PR branch is checked out by another worktree, named on stderr.
#   9  A submodule could not be fetched (e.g. "not our ref": the branch pins a commit
#      that no longer exists). The worktree is ready and its path still printed; the
#      failing submodule is named on stderr.
#   Any other non-zero: the command named in stderr failed.

set -euo pipefail

if [ "$#" -ne 4 ] || { [ "$3" != issue ] && [ "$3" != pr ]; }; then
    echo "usage: bash scripts/setup-github-worktree.sh <owner> <repo> issue|pr <number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
MODE=$3
NUMBER=$4

PROJECTS=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}
BASE="$PROJECTS/$OWNER/$REPO"
WT="$PROJECTS/$OWNER/$REPO.worktrees/$MODE-$NUMBER"

exec 3>&1 1>&2

# Blobless: the full history stays available for rebases, but file contents are fetched
# only when checked out. No submodules here; each worktree fetches its own.
if [ ! -d "$BASE" ]; then
    gh repo clone "$OWNER/$REPO" "$BASE" -- --filter=blob:none
fi

cd "$BASE"
git fetch origin --prune

# This run's own worktree from an earlier run, registered or not; prune forgets it.
rm -rf "$WT"
git worktree prune

# <branch>: prints the path of the worktree that has it checked out, if any.
holder() {
    git worktree list --porcelain |
        awk -v ref="branch refs/heads/$1" '/^worktree /{wt = substr($0, 10)} $0 == ref {print wt}'
}

if [ "$MODE" = pr ]; then
    BRANCH=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" --json headRefName --jq '.headRefName')
    HOLDER=$(holder "$BRANCH")
    if [ -n "$HOLDER" ]; then
        echo "$BRANCH is checked out by worktree $HOLDER"
        exit 4
    fi
    git worktree add --detach "$WT"
    cd "$WT"
    if ! ERR=$(gh pr checkout "$NUMBER" --repo "$OWNER/$REPO" --force 2>&1); then
        printf '%s\n' "$ERR" >&2
        # gh names a fork's branch <owner>/<branch> when it would shadow the default
        # branch, which the check above does not see; git still refuses to share it.
        case "$ERR" in
            *"already checked out"* | *"already used by worktree"*) exit 4 ;;
        esac
        exit 1
    fi
else
    BRANCH="fix/issue-$NUMBER"
    DEFAULT=$(gh repo view "$OWNER/$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
    HOLDER=$(holder "$BRANCH")
    if [ -n "$HOLDER" ]; then
        echo "removing stale worktree $HOLDER, which held $BRANCH"
        git worktree remove "$HOLDER" --force
    fi
    git branch -D "$BRANCH" 2>/dev/null || true

    START="origin/$DEFAULT"
    if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
        START="origin/$BRANCH"
    fi
    git worktree add -b "$BRANCH" "$WT" "$START"
    cd "$WT"

    if ! git rebase "origin/$DEFAULT"; then
        git rebase --abort || true
        echo "rebase onto origin/$DEFAULT conflicted; aborted"
        exit 3
    fi
fi

# Shallow: a full recursive clone of a large submodule took most of a run. A change
# that bumps a submodule can deepen it with `git -C <path> fetch --unshallow`.
git submodule sync --recursive
if ! git submodule update --init --recursive --depth 1; then
    echo "$WT" >&3
    exit 9
fi

echo "$WT" >&3
