#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Prepare a dedicated git worktree for one drupal.org merge request or issue, on its
# fork's branch and rebased onto the target branch, and print the worktree path.
#
# Usage: bash scripts/setup-worktree.sh <project> mr|issue <iid>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# Two repositories are involved, and they are not the same remote: the work targets
# <namespace>/<project> (`upstream`) while the branch lives on the issue fork (`fork`).
# API calls go to git.drupalcode.org and git operations go to git.drupal.org - two names
# for one service, not interchangeable - so both URLs come from the API's own
# ssh_url_to_repo rather than being composed here.
#
# mr:    the merge request's source branch, rebased onto its target branch.
# issue: the fork must already exist (ensure-fork.sh). /do:fork makes
#        <iid>-issue-branch, but contributors routinely push a descriptive <iid>-<slug>
#        instead, so every fork branch prefixed with the issue number is a candidate and
#        the most recently committed one wins. That is asked of git rather than the API:
#        GitLab reports commit dates in the committer's own offset, and comparing those
#        as strings silently prefers whoever is furthest west. With no candidate, the
#        worktree starts from the default branch and the first push creates
#        <iid>-issue-branch.
#
# The worktree is recreated on every run. Finished work is always pushed, so the fork
# branch is the source of truth and leftovers from an interrupted run are simply redone.
#
# Only the path goes to stdout; `fork_branch=`, `target_branch=` and `resumed=` go to
# stderr with git's own output.
#
# Exit codes:
#   0  Ready. stdout is the worktree path; cd into it.
#   3  The rebase onto the target branch conflicted. It has been aborted and the
#      worktree left in place; park rather than working here.
#   4  The branch is checked out by another, still-live worktree. Remove that one
#      (`git worktree remove <path> --force`) and run this again.
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
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
MODE=$2
IID=$3

BRANCH=$MODE-$IID
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

# Clone on first use. `upstream` rather than `origin`, so nothing here implies the
# fork and the project are the same remote.
if [ ! -d "$BASE/.git" ]; then
    mkdir -p "$(dirname "$BASE")"
    git clone --origin upstream "$UPSTREAM_URL" "$BASE"
fi

cd "$BASE"

# A clone made by hand, or adopted by loachbot-gitlab-planner, may only have `origin`.
# Add `upstream` beside it rather than renaming, so the user's own remote keeps working.
remote() { git remote set-url "$1" "$2" 2>/dev/null || git remote add "$1" "$2"; }
remote upstream "$UPSTREAM_URL"
remote fork "$FORK_URL"

# A shallow clone has no merge base, so the rebase below would replay the target
# branch's entire history (one did: 1,355 commits) instead of the branch's own.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch --unshallow --prune upstream
else
    git fetch --prune upstream
fi
git fetch --prune fork

# A still-live worktree holding this branch has to be dealt with by the caller:
# removing it here could discard work another run is mid-way through.
EXISTING=$(git worktree list --porcelain |
    awk -v b="refs/heads/$BRANCH" '/^worktree /{p=$2} /^branch /{if ($2==b) print p}')
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$WT" ] && [ -d "$EXISTING" ]; then
    echo "branch $BRANCH is checked out at $EXISTING"
    exit 4
fi

RESUMED=true
if [ "$MODE" = issue ]; then
    FORK_BRANCH=$(git for-each-ref --sort=-committerdate --count=1 \
        --format='%(refname:lstrip=3)' "refs/remotes/fork/$IID-*")
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

# The local branch is disposable; the fork branch is what a merge request reads from.
# Starting from the target branch is already up to date, so only a resumed branch has
# anything to rebase - and only a resumed branch can conflict.
if [ "$RESUMED" = true ]; then
    git worktree add -b "$BRANCH" "$WT" "fork/$FORK_BRANCH"
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

echo "fork_branch=$FORK_BRANCH"
echo "target_branch=$TARGET_BRANCH"
echo "resumed=$RESUMED"
echo "$WT" >&3
