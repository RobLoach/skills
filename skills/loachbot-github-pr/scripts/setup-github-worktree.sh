#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Prepare a dedicated git worktree for one issue or Pull Request, and print its path.
#
# Usage: bash scripts/setup-github-worktree.sh <owner> <repo> issue|pr <number>
#
# The worktree is recreated every run: finished work is always pushed, so the remote is
# the source of truth.
#
#   issue  Branch fix/issue-<number>, resumed from origin when pushed before, rebased
#          onto the default branch. Bot-owned, so a worktree holding it is stale.
#          Prints default_branch=<name> and remote_sha=<sha> on stderr, the remote
#          branch as fetched here (empty when new): the caller leases its force-push
#          against that, not origin/fix/issue-<number>, which any later fetch moves
#          onto a human's push and so would let it be overwritten.
#   pr     `gh pr checkout`, which resolves fork remotes. The branch may be the user's
#          own checkout, so a worktree holding it is reported, never taken. `--force`
#          resets a leftover local branch, which cannot fast-forward after a force-push.
#          A fork's branch may come back renamed <owner>/<branch>, tracking the fork by
#          URL or, without maintainer edits, refs/pull/<number>/head, which takes no
#          push; so the caller looks the PR's head up itself rather than trusting it.
#
# Exit codes:
#   0  Ready. Stdout is the worktree path.
#   3  issue only: the rebase onto the default branch conflicted. It has been aborted
#      and the worktree left in place.
#   4  pr only: the PR branch is checked out by another worktree, named on stderr.
#   5  The existing clone's origin is not <owner>/<repo> (e.g. the user's clone of a
#      fork, with the real repository as `upstream`); its URL is on stderr. Nothing was
#      changed.
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

# Everything below fetches, rebases onto and pushes to origin, so a clone of a fork would
# quietly work against the wrong repository. Matched by owner/repo alone, whatever the
# scheme (ssh or https), `.git` suffix or case.
ORIGIN=$(git remote get-url origin 2>/dev/null || true)
FOUND=${ORIGIN%/}
FOUND=${FOUND%.git}
FOUND_REPO=${FOUND##*[:/]}
FOUND=${FOUND%[:/]*}
FOUND="${FOUND##*[:/]}/$FOUND_REPO"
if [ "$(printf '%s' "$FOUND" | tr '[:upper:]' '[:lower:]')" != \
    "$(printf '%s' "$OWNER/$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "$BASE has origin ${ORIGIN:-(none)}, not $OWNER/$REPO"
    exit 5
fi

git fetch origin --prune

rm -rf "$WT"
git worktree prune

holder() {
    git worktree list --porcelain |
        awk -v ref="branch refs/heads/$1" '/^worktree /{wt = substr($0, 10)} $0 == ref {print wt}'
}

if [ "$MODE" = pr ]; then
    # A fork's headRefName says nothing about the local name: a fork PR from `main`
    # matches the base clone's own `main`, which would always read as taken.
    HEAD_INFO=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" \
        --json headRefName,isCrossRepository --jq '"\(.isCrossRepository) \(.headRefName)"')
    CROSS=${HEAD_INFO%% *}
    BRANCH=${HEAD_INFO#* }
    if [ "$CROSS" = false ]; then
        HOLDER=$(holder "$BRANCH")
        if [ -n "$HOLDER" ]; then
            echo "$BRANCH is checked out by worktree $HOLDER"
            exit 4
        fi
    fi
    git worktree add --detach "$WT"
    cd "$WT"
    if ! ERR=$(gh pr checkout "$NUMBER" --repo "$OWNER/$REPO" --force 2>&1); then
        printf '%s\n' "$ERR" >&2
        # Fork branches skip the check above, and gh may rename them <owner>/<branch>;
        # either way git still refuses to share a branch between worktrees.
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

    REMOTE_SHA=$(git rev-parse --verify -q "origin/$BRANCH" || true)
    echo "default_branch=$DEFAULT"
    echo "remote_sha=$REMOTE_SHA"
    git worktree add -b "$BRANCH" "$WT" "${REMOTE_SHA:-origin/$DEFAULT}"
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
