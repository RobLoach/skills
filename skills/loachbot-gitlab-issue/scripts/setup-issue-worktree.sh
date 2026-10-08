#!/usr/bin/env bash
#
# Prepare a dedicated git worktree for one drupal.org issue, on its shared issue fork
# branch and rebased onto the target branch, and print the worktree path.
#
# Usage: bash scripts/setup-issue-worktree.sh <project> <issue-iid>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# The fork must already exist and be writable: run scripts/ensure-fork.sh first. This
# script only reads it, so it never comments on the issue.
#
# Two repositories are involved, and they are not the same remote: the work targets
# <namespace>/<project> (`upstream`) while the branch lives on the shared issue fork
# (`fork`). API calls go to git.drupalcode.org and git operations go to git.drupal.org -
# two names for one service, not interchangeable - so both URLs are taken from the API's
# own ssh_url_to_repo rather than composed here.
#
# Which branch on the fork is the issue's is not something to assume. /do:fork makes
# <issue-iid>-issue-branch, but contributors routinely push a descriptive
# <issue-iid>-<slug> instead, and a long-lived issue can end up with several. So every
# fork branch prefixed with the issue number is a candidate, and the most recently
# committed one wins - that is the branch somebody worked on last, and so the one a
# merge request for this issue should continue. The selection is deliberately done in
# git rather than from the API's branch list: GitLab reports commit dates in the
# committer's own offset, and comparing those as strings silently prefers whichever
# contributor happened to be furthest west.
#
# With no candidate branch at all, the worktree starts from the target branch and the
# caller's first push creates <issue-iid>-issue-branch on the fork.
#
# The worktree is recreated on every run. Finished work is always pushed, so the fork
# branch is the source of truth and leftovers from an interrupted run are simply redone.
#
# Exit codes:
#   0  Ready. stdout ends with the worktree path; cd into it. `fork_branch=`,
#      `target_branch=` and `resumed=` are reported on stderr.
#   3  The rebase onto the target branch conflicted. It has been aborted and the
#      worktree left in place; park the issue rather than working here.
#   4  The branch is checked out by another, still-live worktree. Remove that one
#      (`git worktree remove <path> --force`) and run this again.
#   5  The project or its issue fork could not be read. Run scripts/ensure-fork.sh.
#   Any other non-zero: the command named in stderr failed; report it.

set -euo pipefail

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=${1:?project machine name required}
IID=${2:?issue iid required}

# Issue forks live under issue/ whatever namespace the parent sits in.
FORK_ENC="issue%2F$PROJECT-$IID"

BASE=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/$PROJECT
WT=$BASE.worktrees/issue-$IID

api() { glab api --hostname "$HOST" "$@"; }

if ! UPSTREAM=$(api "projects/$NAMESPACE%2F$PROJECT" 2>/dev/null); then
    echo "cannot read $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

UPSTREAM_URL=$(printf '%s' "$UPSTREAM" | jq -r '.ssh_url_to_repo // empty')
TARGET_BRANCH=$(printf '%s' "$UPSTREAM" | jq -r '.default_branch // empty')

if [ -z "$UPSTREAM_URL" ] || [ -z "$TARGET_BRANCH" ]; then
    echo "$NAMESPACE/$PROJECT has no clone URL or no default branch" >&2
    exit 5
fi

if ! FORK_URL=$(api "projects/$FORK_ENC" 2>/dev/null | jq -r '.ssh_url_to_repo // empty') ||
    [ -z "$FORK_URL" ]; then
    echo "no readable issue fork at issue/$PROJECT-$IID; run scripts/ensure-fork.sh" >&2
    exit 5
fi

# Clone on first use. `upstream` rather than `origin`, so nothing here implies the
# fork and the project are the same remote.
if [ ! -d "$BASE/.git" ]; then
    mkdir -p "$(dirname "$BASE")"
    git clone --origin upstream "$UPSTREAM_URL" "$BASE" >&2
fi

cd "$BASE"

git remote set-url upstream "$UPSTREAM_URL"
if git remote | grep -qx fork; then
    git remote set-url fork "$FORK_URL"
else
    git remote add fork "$FORK_URL"
fi

git fetch --prune upstream >&2
git fetch --prune fork >&2

# A still-live worktree holding this branch has to be dealt with by the caller:
# removing it here could discard work another run is mid-way through.
EXISTING=$(git worktree list --porcelain |
    awk -v b="refs/heads/issue-$IID" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$WT" ] && [ -d "$EXISTING" ]; then
    echo "branch issue-$IID is checked out at $EXISTING" >&2
    exit 4
fi

# Newest commit wins among the issue's branches on the fork; see the header for why
# this is asked of git rather than of the API.
FORK_BRANCH=$(git for-each-ref --sort=-committerdate --count=1 \
    --format='%(refname:lstrip=3)' "refs/remotes/fork/$IID-*")

RESUMED=true
if [ -z "$FORK_BRANCH" ]; then
    # Nothing to resume: name the branch the way /do:fork would have.
    FORK_BRANCH="$IID-issue-branch"
    RESUMED=false
fi

if [ -d "$WT" ]; then
    git worktree remove "$WT" --force >&2 || rm -rf "$WT"
fi
git worktree prune >&2
# May legitimately not exist on a first run.
git branch -D "issue-$IID" >/dev/null 2>&1 || true

if [ "$RESUMED" = true ]; then
    START="fork/$FORK_BRANCH"
else
    START="upstream/$TARGET_BRANCH"
fi

# The local branch is disposable; the fork branch is what a merge request reads from.
git worktree add -b "issue-$IID" "$WT" "$START" >&2

cd "$WT"

# Starting from the target branch is already up to date, so only a resumed branch has
# anything to rebase - and only a resumed branch can conflict.
if [ "$RESUMED" = true ]; then
    if ! git rebase "upstream/$TARGET_BRANCH" >&2; then
        git rebase --abort >&2 2>/dev/null || true
        echo "rebase onto upstream/$TARGET_BRANCH conflicted; aborted" >&2
        exit 3
    fi
fi

git submodule sync --recursive >&2
git submodule update --init --recursive >&2

# Everything the caller needs, with the path last so `| tail -1` picks it up.
echo "fork_branch=$FORK_BRANCH" >&2
echo "target_branch=$TARGET_BRANCH" >&2
echo "resumed=$RESUMED" >&2
echo "$WT"
