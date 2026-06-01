---
name: loachbot-github-pr
description: Autonomous GitHub Pull Request Fixer agent called LoachBot. Scans GitHub for Pull Requests where RobLoach has set the PR to Draft, implements fixes or updates the pull request, then moves it back to Open. Use when the user asks "run LoachBot Pull Requests".
---

# LoachBot GitHub Pull Request Fixer

## What it does

1. Find the latest GitHub Draft Pull Requests that have been created by me, and assigned to me
```
gh search prs --draft --author="@me" --assignee="@me" --state="open" --sort=updated --limit 1
```

2. Implement the required work directly in a Pull Request

3. Push the changes back into the Pull Request

4. Moves the Pull Request out of Draft, and back into Open

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
git submodule update --init --recursive
```

If `gh pr checkout` reports the branch is checked out in another worktree, that means a previous run left it on a different path. Resolve by removing the stale worktree (`git worktree remove <stale-path>`) and retrying — do **not** force-switch branches across worktrees.

### 3. Understand the Pull Request

- Read the full body of the pull request `gh pr view <number> --repo <owner/repo> --json title,body`
- Fetch **unresolved** review threads containing comments by `@RobLoach`. Resolved threads have already been acted upon — skip them.
    ```bash
    gh api graphql -F owner=<owner> -F name=<repo> -F number=<number> -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 100) {
                  nodes {
                    databaseId
                    author { login }
                    body
                    path
                    url
                  }
                }
              }
            }
          }
        }
      }' \
      --jq '.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved == false)
            | select(any(.comments.nodes[]; .author.login == "RobLoach"))'
    ```
    The thread `id` (a GraphQL node ID like `PRRT_...`) is what you'll use to resolve the thread later.

### 4. Do the work

Address all the unresolved review threads from @RobLoach, and push the change back directly to the pull request. Do not make any comments. Test where possible.

After addressing each thread, resolve it via GraphQL to indicate it was acted upon:

```bash
gh api graphql -F threadId=<thread_id> -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { id isResolved }
    }
  }'
```

The `<thread_id>` is the GraphQL node `id` from the review thread query above (not the comment's `databaseId`).

If a thread requires human judgment or a design decision that can't be addressed autonomously, leave it unresolved and react with a 😕 on the first comment in the thread so it's clear it was seen but deferred:

```bash
gh api repos/<owner>/<repo>/pulls/comments/<comment_databaseId>/reactions \
    --method POST --field content="confused"
```

Use the `databaseId` of the first comment in the thread (from the review-threads query above). Then continue to the next thread. If **all** threads require human judgment (none were resolved), report this to the user and stop — do not mark the PR as ready.

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
gh pr ready <number> --repo <owner/repo>
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
