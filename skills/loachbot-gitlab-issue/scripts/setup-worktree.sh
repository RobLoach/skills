#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Prepare a dedicated git worktree for one drupal.org merge request or issue, on its
# fork's branch and rebased onto the target branch, and print the worktree path.
#
# Usage: bash scripts/setup-worktree.sh <project> mr|issue <iid>
#
# API calls go to git.drupalcode.org and git to git.drupal.org - two names for one
# service, not interchangeable - so both clone URLs come from the API's ssh_url_to_repo.
#
# issue: /do:fork makes <iid>-issue-branch, but contributors often push <iid>-<slug>, so
# the most recently committed fork branch with that prefix wins. git decides that, not
# the API: GitLab reports commit dates in the committer's offset, and comparing those as
# strings prefers whoever is furthest west. With none, start from the default branch.
#
# The fork remote is fork-<mode>-<iid> rather than `fork`: remotes live in the base
# clone's config, shared by every worktree, so one name would be re-pointed by another
# run and a push would land on the wrong fork.
#
# The worktree is recreated every run; the pushed fork branch is the source of truth.
# Only the path goes to stdout; remote=, fork_branch=, target_branch= and resumed= go to
# stderr.
#
# Exit codes:
#   0  Ready. stdout is the worktree path; cd into it.
#   3  The rebase onto the target branch conflicted. It has been aborted and the
#      worktree left in place; park rather than working here.
#   4  The branch is checked out by another, still-live worktree, named on stderr. It
#      may hold somebody's uncommitted work, so this never removes it.
#   Any other non-zero: the project, merge request or fork could not be read, or the
#   command named in stderr failed; report it.

set -euo pipefail

if [ "$#" -ne 3 ] || { [ "$2" != mr ] && [ "$2" != issue ]; }; then
    echo "usage: bash scripts/setup-worktree.sh <project> mr|issue <iid>" >&2
    exit 64
fi

# Keep stdout for the path alone, so `WT=$(...)` needs no filtering.
exec 3>&1 1>&2

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
MODE=$2
IID=$3

BRANCH=$MODE-$IID
FORK_REMOTE=fork-$BRANCH
BASE=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/$PROJECT
WT=$BASE.worktrees/$BRANCH

api() { glab api --hostname "$HOST" "$@" 2>/dev/null; }
die() {
    echo "$*"
    exit 1
}

UPSTREAM=$(api "projects/$NAMESPACE%2F$PROJECT") || die "cannot read $NAMESPACE/$PROJECT on $HOST"
UPSTREAM_URL=$(printf '%s' "$UPSTREAM" | jq -r '.ssh_url_to_repo // empty')
[ -n "$UPSTREAM_URL" ] || die "$NAMESPACE/$PROJECT has no clone URL"

if [ "$MODE" = mr ]; then
    MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID") ||
        die "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST"
    FORK_BRANCH=$(printf '%s' "$MR" | jq -r '.source_branch // empty')
    TARGET_BRANCH=$(printf '%s' "$MR" | jq -r '.target_branch // empty')
    FORK="projects/$(printf '%s' "$MR" | jq -r '.source_project_id // empty')"
else
    TARGET_BRANCH=$(printf '%s' "$UPSTREAM" | jq -r '.default_branch // empty')
    # Issue forks live under issue/ whatever namespace the parent sits in.
    FORK="projects/issue%2F$PROJECT-$IID"
fi
[ -n "$TARGET_BRANCH" ] || die "no target branch for $MODE $IID in $NAMESPACE/$PROJECT"

FORK_URL=$(api "$FORK" | jq -r '.ssh_url_to_repo // empty') || FORK_URL=
[ -n "$FORK_URL" ] || die "cannot read the fork ($FORK) for $MODE $IID; for an issue, run ensure-fork.sh"

if [ ! -d "$BASE/.git" ]; then
    mkdir -p "$(dirname "$BASE")"
    git clone --origin upstream "$UPSTREAM_URL" "$BASE"
fi

cd "$BASE"

# A clone made by hand may only have `origin`; add `upstream` beside it, not over it.
remote() { git remote set-url "$1" "$2" 2>/dev/null || git remote add "$1" "$2"; }
remote upstream "$UPSTREAM_URL"
remote "$FORK_REMOTE" "$FORK_URL"

# A shallow clone has no merge base, so the rebase below would replay the target
# branch's entire history (one did: 1,355 commits) instead of the branch's own.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch --unshallow --prune upstream
else
    git fetch --prune upstream
fi
git fetch --prune "$FORK_REMOTE"

# Removing a still-live worktree could discard another run's work: the caller decides.
EXISTING=$(git worktree list --porcelain |
    awk -v b="refs/heads/$BRANCH" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$WT" ] && [ -d "$EXISTING" ]; then
    echo "branch $BRANCH is checked out at $EXISTING"
    exit 4
fi

RESUMED=true
if [ "$MODE" = issue ]; then
    FORK_BRANCH=$(git for-each-ref --sort=-committerdate --count=1 \
        --format='%(refname:lstrip=3)' "refs/remotes/$FORK_REMOTE/$IID-*")
    if [ -z "$FORK_BRANCH" ]; then
        FORK_BRANCH="$IID-issue-branch"
        RESUMED=false
    fi
fi
[ -n "$FORK_BRANCH" ] || die "merge request !$IID has no source branch"

if [ -d "$WT" ]; then
    git worktree remove "$WT" --force || rm -rf "$WT"
fi
git worktree prune
# May legitimately not exist on a first run.
git branch -D "$BRANCH" >/dev/null 2>&1 || true

# Only a resumed branch has anything to rebase, so only it can conflict.
if [ "$RESUMED" = true ]; then
    git worktree add -b "$BRANCH" "$WT" "$FORK_REMOTE/$FORK_BRANCH"
    cd "$WT"
    if ! git rebase "upstream/$TARGET_BRANCH"; then
        git rebase --abort 2>/dev/null || true
        echo "rebase onto upstream/$TARGET_BRANCH conflicted; aborted"
        exit 3
    fi
else
    git worktree add -b "$BRANCH" "$WT" "upstream/$TARGET_BRANCH"
    cd "$WT"
fi

git submodule sync --recursive
git submodule update --init --recursive

echo "remote=$FORK_REMOTE"
echo "fork_branch=$FORK_BRANCH"
echo "target_branch=$TARGET_BRANCH"
echo "resumed=$RESUMED"
echo "$WT" >&3
