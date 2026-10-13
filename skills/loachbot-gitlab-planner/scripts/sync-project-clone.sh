#!/usr/bin/env bash
#
# Get a clean, up-to-date clone of a drupal.org project to plan against, and print its
# path.
#
# Usage: bash scripts/sync-project-clone.sh <project>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# The clone lands at ~/Projects/drupalcode/<project>, which is the same clone
# loachbot-gitlab-issue and loachbot-gitlab-mr build their worktrees from. So a clone
# made here names the project remote `upstream` the way those two expect, rather than
# `origin`: the three skills have to be able to pick up one another's clone.
#
# API calls go to git.drupalcode.org and git itself to git.drupal.org - two names for one
# service, not interchangeable - so the clone URL is taken from the API's own
# ssh_url_to_repo rather than composed from the host.
#
# An existing clone's remote is fetched but never re-pointed. Planning is a read, and a
# checkout the user made themselves may well reach drupal.org over https, or under a
# remote named something else; whichever remote is already there is the one to ask.
#
# Local work is never clobbered: a clone holding anything the remote does not have stops
# the run instead, since notes, an experiment or a stash-in-progress are the user's to
# deal with, not this skill's. That path is just as likely to be the user's own working
# clone as a scratch one, so the bar is deliberately low.
#
# Exit codes:
#   0  Clean and current. The last line of stdout is the clone path, and
#      `default_branch=` is reported on stderr.
#   5  The existing clone cannot be safely reset: it holds uncommitted changes, or commits
#      the remote default branch does not have, or it has no usable remote to compare
#      against. What was found is on stderr; report it to the user and stop.
#   6  The project could not be read on the API host.
#   Any other non-zero: the git command named on stderr failed; report it.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bash scripts/sync-project-clone.sh <project>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
BASE=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/$PROJECT

# Taken in two steps: `glab api` exits non-zero on a 404, and under `set -e` that would
# end the run before it could say which read failed.
META=$(glab api --hostname "$HOST" "projects/$NAMESPACE%2F$PROJECT" 2>/dev/null) || META=''

CLONE_URL=$(printf '%s' "${META:-null}" | jq -r '.ssh_url_to_repo // empty')
DEFAULT=$(printf '%s' "${META:-null}" | jq -r '.default_branch // empty')

if [ -z "$CLONE_URL" ] || [ -z "$DEFAULT" ]; then
    echo "cannot read a clone URL and a default branch for $NAMESPACE/$PROJECT on $HOST" >&2
    exit 6
fi

if [ ! -d "$BASE/.git" ]; then
    mkdir -p "$(dirname "$BASE")"
    # `upstream` rather than `origin`, so the fixer skills can build worktrees on this
    # same clone without re-pointing anything.
    git clone --origin upstream "$CLONE_URL" "$BASE" >&2
    cd "$BASE"
    git submodule update --init --recursive >&2
    echo "default_branch=$DEFAULT" >&2
    echo "$BASE"
    exit 0
fi

cd "$BASE"

# `upstream` is what the LoachBot skills create; a clone of the user's own will have
# `origin`, and either is fine to plan from. What matters is not inventing a second
# remote for a repository that already has one.
REMOTE=upstream
if ! git remote | grep -qx upstream; then
    REMOTE=$(git remote | head -n 1)
fi

if [ -z "$REMOTE" ]; then
    echo "the clone at $BASE has no git remote to fetch from" >&2
    exit 5
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "clone has uncommitted local changes:" >&2
    git status --short >&2
    exit 5
fi

git fetch --prune "$REMOTE" >&2

if ! git rev-parse --verify --quiet "refs/remotes/$REMOTE/$DEFAULT" >/dev/null; then
    echo "the clone at $BASE has no $REMOTE/$DEFAULT to reset to" >&2
    exit 5
fi

# A clean tree can still hold work. Commits that were never pushed survive
# `git status --porcelain` and would be thrown away by the reset below, so anything
# $REMOTE/<default> does not already have stops the run.
AHEAD=$(git rev-list --count "$REMOTE/$DEFAULT..HEAD")
if [ "$AHEAD" -ne 0 ]; then
    echo "clone has $AHEAD commit(s) that $REMOTE/$DEFAULT does not:" >&2
    git log --oneline "$REMOTE/$DEFAULT..HEAD" >&2
    exit 5
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$DEFAULT" ]; then
    echo "note: moving this clone from '$CURRENT' to '$DEFAULT'" >&2
fi

git checkout "$DEFAULT" >&2
git reset --hard "$REMOTE/$DEFAULT" >&2
git clean -fd >&2
git submodule sync --recursive >&2
git submodule update --init --recursive >&2

echo "default_branch=$DEFAULT" >&2
echo "$BASE"
