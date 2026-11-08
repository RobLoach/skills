#!/usr/bin/env bash
#
# Put a detached, read-only worktree of a drupal.org project's default branch at
# ~/Projects/drupalcode/<project>.worktrees/plan, and print its path.
#
# Usage: bash scripts/setup-plan-worktree.sh <project>
#
# The base clone is shared with loachbot-gitlab-issue and loachbot-gitlab-mr, so its own
# checkout is never touched: only a fetch, and a worktree beside it. Clone URL from the
# API's ssh_url_to_repo, since git.drupalcode.org (API) and git.drupal.org (git) differ.
#
# Exit codes:
#   0  stdout is the worktree path.
#   6  The project could not be read on the API host.
#   Any other non-zero: the git command named on stderr failed.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bash scripts/setup-plan-worktree.sh <project>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
BASE=${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/$1
WT=$BASE.worktrees/plan

# Two steps: `glab api` exits non-zero on a 404, which `set -e` would turn into a silent end.
META=$(glab api --hostname "$HOST" "projects/$NAMESPACE%2F$1" 2>/dev/null) || META=null
URL=$(printf '%s' "$META" | jq -r '.ssh_url_to_repo // empty')
DEFAULT=$(printf '%s' "$META" | jq -r '.default_branch // empty')
if [ -z "$URL" ] || [ -z "$DEFAULT" ]; then
    echo "cannot read $NAMESPACE/$1 on $HOST" >&2
    exit 6
fi

if [ ! -d "$BASE/.git" ]; then
    mkdir -p "$(dirname "$BASE")"
    git clone --origin upstream "$URL" "$BASE" >&2
fi
cd "$BASE"
git remote | grep -qx upstream || git remote add upstream "$URL"
git fetch --prune upstream >&2

git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
git worktree prune
git worktree add --detach "$WT" "upstream/$DEFAULT" >&2
echo "$WT"
