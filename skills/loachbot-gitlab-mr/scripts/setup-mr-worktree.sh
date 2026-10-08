#!/usr/bin/env bash
#
# Prepare a dedicated git worktree for one drupal.org merge request, rebased onto
# its target branch, and print the worktree path.
#
# Usage: bash scripts/setup-mr-worktree.sh <project> <mr-iid>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# Drupal.org splits a merge request across two repositories: it targets
# project/<project>, while its branch lives in a per-issue fork under issue/. Both
# are read from the API rather than guessed at, and both get a remote - `upstream`
# for the project, `fork` for the branch - so a later push goes back to the fork the
# merge request actually reads from.
#
# API calls go to git.drupalcode.org; git operations go to git.drupal.org. Those are
# two names for one service and are not interchangeable: an API path on git.drupal.org
# or an SSH URL on git.drupalcode.org both fail. The URLs here come from the API's own
# ssh_url_to_repo, which is always the git host.
#
# The worktree is recreated on every run. Finished work is always pushed, so the fork
# branch is the source of truth and leftovers from an interrupted run are simply redone.
#
# Exit codes:
#   0  Ready. The last line of stdout is the worktree path; cd into it.
#   3  The rebase onto the target branch conflicted. It has been aborted and the
#      worktree left in place; park the merge request rather than working here.
#   4  The branch is checked out by another, still-live worktree. Remove that one
#      (`git worktree remove <path> --force`) and run this again.
#   5  The merge request could not be read, or it has no source fork to push back to.
#   Any other non-zero: the command named in stderr failed; report it.

set -euo pipefail

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=${1:?project machine name required}
IID=${2:?merge request iid required}

BASE=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/$PROJECT
WT=$BASE.worktrees/mr-$IID

api() { glab api --hostname "$HOST" "$@"; }

# One read carries the branch pair and the fork's project id; the rest derives from it.
if ! MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null); then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

SOURCE_BRANCH=$(printf '%s' "$MR" | jq -r '.source_branch // empty')
TARGET_BRANCH=$(printf '%s' "$MR" | jq -r '.target_branch // empty')
SOURCE_ID=$(printf '%s' "$MR" | jq -r '.source_project_id // empty')

if [ -z "$SOURCE_BRANCH" ] || [ -z "$TARGET_BRANCH" ] || [ -z "$SOURCE_ID" ]; then
    echo "merge request !$IID is missing its branch or fork details" >&2
    exit 5
fi

if ! FORK_URL=$(api "projects/$SOURCE_ID" 2>/dev/null | jq -r '.ssh_url_to_repo // empty') ||
    [ -z "$FORK_URL" ]; then
    echo "cannot read the source fork (project $SOURCE_ID) for !$IID" >&2
    exit 5
fi

if ! UPSTREAM_URL=$(api "projects/$NAMESPACE%2F$PROJECT" 2>/dev/null | jq -r '.ssh_url_to_repo // empty') ||
    [ -z "$UPSTREAM_URL" ]; then
    echo "cannot read $NAMESPACE/$PROJECT on $HOST" >&2
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
    awk -v b="refs/heads/mr-$IID" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$WT" ] && [ -d "$EXISTING" ]; then
    echo "branch mr-$IID is checked out at $EXISTING" >&2
    exit 4
fi

if [ -d "$WT" ]; then
    git worktree remove "$WT" --force >&2 || rm -rf "$WT"
fi
git worktree prune >&2
# Both may legitimately not exist on a first run.
git branch -D "mr-$IID" >/dev/null 2>&1 || true

# The local branch is disposable; the fork branch is what the merge request shows.
git worktree add -b "mr-$IID" "$WT" "fork/$SOURCE_BRANCH" >&2

cd "$WT"

if ! git rebase "upstream/$TARGET_BRANCH" >&2; then
    git rebase --abort >&2 2>/dev/null || true
    echo "rebase onto upstream/$TARGET_BRANCH conflicted; aborted" >&2
    exit 3
fi

git submodule sync --recursive >&2
git submodule update --init --recursive >&2

# Everything the caller needs, with the path last so `| tail -1` picks it up.
echo "source_branch=$SOURCE_BRANCH" >&2
echo "target_branch=$TARGET_BRANCH" >&2
echo "$WT"
