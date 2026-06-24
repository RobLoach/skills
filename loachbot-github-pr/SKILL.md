---
name: loachbot-github-pr
description: Autonomous GitHub Pull Request Fixer agent called LoachBot. Scans GitHub for your own draft Pull Requests, implements fixes or updates the pull request, then moves it back to Open. Use when the user asks "run LoachBot Pull Requests".
---

# LoachBot GitHub Pull Request Fixer

## What it does

1. Find the latest Draft Pull Request created by me and assigned to me
2. Implement the required work directly in the Pull Request
3. Push the changes back into the Pull Request
4. Move the Pull Request out of Draft, back into Open

## Prerequisites

- `gh` is authenticated — run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable (the base clone and per-PR worktrees live there).

## Workflow

### 1. Find a Pull Request

```bash
# Get an open draft Pull Request by myself, assigned to myself
gh search prs --draft --author="@me" --assignee="@me" --state="open" --sort=updated --limit 1
```

If no items are found, report "Nothing to do" and stop.

Once you find a PR, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the project and pull request in a dedicated worktree

Each PR gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<repo>` stays on the default branch; per-PR worktrees live under `~/Projects/<repo>.worktrees/pr-<number>` and are deleted after the run is complete.

```bash
# Ensure base clone exists (default branch only).
if [ ! -d ~/Projects/<repo> ]; then
    gh repo clone <owner>/<repo> ~/Projects/<repo> -- --recurse-submodules
fi

cd ~/Projects/<repo>
git fetch origin --prune

# Set up the dedicated worktree for this PR.
WT=~/Projects/<repo>.worktrees/pr-<number>
if [ ! -d "$WT" ]; then
    git worktree add --detach "$WT"
fi
cd "$WT"

# Check out the PR head into this worktree. `gh pr checkout` handles fork remotes.
gh pr checkout <number>
git submodule sync --recursive
git submodule update --init --recursive
```

If `gh pr checkout` reports the branch is checked out in another worktree, that means a previous run left it on a different path. Resolve by removing the stale worktree (`git worktree remove <stale-path>`) and retrying — do **not** force-switch branches across worktrees.

### 3. Understand the Pull Request

Determine your own login once, then reuse it for every filter:

```bash
AUTHOR=$(gh api user --jq '.login')
```

- Read the full body of the pull request `gh pr view <number> --repo <owner>/<repo> --json title,body`
- Filter PR comments to only those you authored:
    ```bash
    gh pr view <number> --repo <owner>/<repo> --json comments \
        --jq ".comments[] | select(.author.login == \"$AUTHOR\") | {id, createdAt, url, body}"
    ```
- If you also need **review comments** (inline code review), query them separately:
    ```bash
    gh api repos/<owner>/<repo>/pulls/<number>/comments \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, path, position, body}"
    ```
- Skip any comment that already has a 🚀 reaction from you - it has already been acted upon:
    ```bash
    # For regular PR comments:
    gh api repos/<owner>/<repo>/issues/comments/<comment_id>/reactions \
        --jq ".[] | select(.user.login == \"$AUTHOR\" and .content == \"rocket\")"

    # For inline review comments:
    gh api repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions \
        --jq ".[] | select(.user.login == \"$AUTHOR\" and .content == \"rocket\")"
    ```

### 4. Do the work

Address all the comments you left (the ones filtered to `$AUTHOR` in step 3), and push the change back directly to the pull request. Do not make any comments. Test where possible.

After addressing each comment, react with a 🚀 to indicate it was acted upon:

```bash
# React to a regular PR comment (issue comment)
gh api repos/<owner>/<repo>/issues/comments/<comment_id>/reactions \
    --method POST --field content="rocket"

# React to an inline review comment
gh api repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions \
    --method POST --field content="rocket"
```

The comment ID can be extracted from the `id` field of the comment JSON.

If a comment requires human judgment or a design decision that can't be resolved autonomously, leave it unreacted and continue to the next comment. If **all** comments require human judgment (none were acted upon), report this to the user and stop — do not mark the PR as ready.

### 5. Update the PR title and body as needed

If the changes made deviate from what the original title or body described, update them to accurately reflect the work done.

### 6. Verify CI before marking ready

Wait for all checks to complete and confirm they pass:

```bash
gh pr checks <number> --repo <owner>/<repo> --watch
```

If any check fails, do **not** mark the PR ready — report the failing checks to the user and stop.

### 7. Mark the Pull Request as Ready

```bash
gh pr ready <number> --repo <owner>/<repo>
```

Then delete the worktree:

```bash
cd ~/Projects/<repo>
git worktree remove ~/Projects/<repo>.worktrees/pr-<number> --force
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<number>

## Rules

- Work one item at a time, most recently updated first
- When running multiple times, always run sequentially — never in parallel
- Never post comments
- If a repo needs to be cloned, use the Projects directory at `~/Projects`. The base clone (`~/Projects/<repo>`) stays on the default branch; per-PR work happens in worktrees at `~/Projects/<repo>.worktrees/pr-<number>`
- All git operations for a PR must run inside that PR's worktree — never run `git checkout`, `gh pr checkout`, or commits from the base clone
- Delete the worktree after a successful run with `git worktree remove <path> --force` from the base clone
- Commit with a concise message, 100 characters max; no AI-attribution footers
