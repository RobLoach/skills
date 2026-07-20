---
name: loachbot-github-pr
description: Autonomous GitHub Pull Request Fixer agent called LoachBot. Scans GitHub for your own draft Pull Requests, addresses your review comments, then marks the Pull Request ready for review. Use when the user wants to address feedback on their draft pull requests, or asks to "run LoachBot Pull Requests", including repeated runs like "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-pr/SKILL.md
    license: MIT
---

# LoachBot GitHub Pull Request Fixer

## What it does

1. Find the most-recently-updated open Draft Pull Request created by me and assigned to me
2. Implement the work my review comments ask for, directly in the Pull Request
3. Push the changes back to the Pull Request
4. Mark the Pull Request as ready for review

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable: the default location for clones and worktrees; adjust if the user prefers another directory.

## Workflow

### 1. Find a Pull Request

```bash
# Open draft Pull Requests by myself, assigned to myself, newest activity first
gh search prs --draft --author=@me --assignee=@me --state=open --sort=updated --limit=10 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If no items are found, report "Nothing to do" and stop.

For each PR (most-recently-updated first), decide whether it's actionable based on the `(Needs Info)` title suffix:

- Title does **not** end with `(Needs Info)` → actionable.
- Title ends with `(Needs Info)` → a previous run parked it because every comment needed human judgment (Step 4). It becomes actionable again only once someone has commented since that rename:
    ```bash
    PARKED=$(gh api --paginate "repos/<owner>/<repo>/issues/<number>/events" \
        --jq '.[] | select(.event == "renamed") | .created_at' | tail -1)
    # Any regular or inline review comment newer than the rename?
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq ".[] | select(.created_at > \"$PARKED\") | .id"
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/comments" \
        --jq ".[] | select(.created_at > \"$PARKED\") | .id"
    ```
    If either query returns anything, remove the suffix (`gh pr edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"`) and proceed. Otherwise skip the PR.

Pick the first actionable PR. If none are actionable, report "Nothing to do" and stop.

Search results can lag behind reality, so a PR just marked ready may still appear on an immediate re-run. Before starting, confirm the picked PR is still an open draft:

```bash
gh pr view <number> --repo <owner>/<repo> --json state,isDraft
```

Proceed only if `state` is `OPEN` and `isDraft` is `true`; otherwise skip it and evaluate the next candidate.

Once you pick a PR, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the pull request in a dedicated worktree

Each PR gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-PR worktrees live under `~/Projects/<owner>/<repo>.worktrees/pr-<number>` and are deleted after the run is complete.

```bash
# Ensure base clone exists (default branch only).
if [ ! -d ~/Projects/<owner>/<repo> ]; then
    gh repo clone <owner>/<repo> ~/Projects/<owner>/<repo> -- --recurse-submodules
fi

cd ~/Projects/<owner>/<repo>
git fetch origin --prune

# Set up the dedicated worktree for this PR.
WT=~/Projects/<owner>/<repo>.worktrees/pr-<number>
if [ ! -d "$WT" ]; then
    git worktree add --detach "$WT"
fi
cd "$WT"

# Check out the PR head into this worktree. `gh pr checkout` handles fork remotes.
gh pr checkout <number>
git submodule sync --recursive
git submodule update --init --recursive
```

Recovery paths:

- If `gh pr checkout` reports the branch is checked out in another worktree, a previous run left it on a different path. Remove the stale worktree (`git worktree remove <stale-path>`) and retry: do **not** force-switch branches across worktrees.
- If `gh pr checkout` fails for any other reason (e.g. the local branch diverged), stop and report: do not force through it.

### 3. Understand the Pull Request

Determine your own login once, then reuse it for every filter:

```bash
AUTHOR=$(gh api user --jq '.login')
```

- Read the full body of the pull request: `gh pr view <number> --repo <owner>/<repo> --json title,body`
- Fetch regular PR comments you authored. Use the REST endpoint: it returns the numeric `id` the reaction endpoints below require (`gh pr view --json comments` returns GraphQL node IDs, which do not work there):
    ```bash
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, body}"
    ```
- Fetch inline review comments you authored:
    ```bash
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/comments" \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, path, body}"
    ```
- Fetch review summaries you authored (the body written when submitting a review): they often carry the overall instructions the inline comments assume:
    ```bash
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/reviews" \
        --jq ".[] | select(.user.login == \"$AUTHOR\" and .body != \"\") | {id, submitted_at, body}"
    ```
    Review bodies do not support reactions, so treat them as instructions and context for the run; the 🚀 tracking below applies only to regular and inline comments.
- Skip any comment that already has a 🚀 reaction from you: it has already been acted upon:
    ```bash
    # Regular PR comments:
    gh api "repos/<owner>/<repo>/issues/comments/<comment_id>/reactions" \
        --jq ".[] | select(.user.login == \"$AUTHOR\" and .content == \"rocket\")"

    # Inline review comments:
    gh api "repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions" \
        --jq ".[] | select(.user.login == \"$AUTHOR\" and .content == \"rocket\")"
    ```

### 4. Do the work

Address all the comments you left (the ones filtered to `$AUTHOR` in Step 3). Test where possible, then commit and push back to the PR: the branch already tracks the PR head from `gh pr checkout`, so a plain push suffices:

```bash
git add -A
# Nothing staged means the addressed comments needed no code changes: skip the empty commit.
if ! git diff --cached --quiet; then
    git commit -m "<concise message>"
    git push
fi
```

React with a 🚀 to each comment that was addressed, only once it has actually been handled: the change was pushed, or you verified no change is needed. A comment verified to need no code change still counts as addressed. The reaction is the persistent "already handled" marker Step 3 relies on, so never react before that point:

```bash
# Regular PR comment:
gh api "repos/<owner>/<repo>/issues/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"

# Inline review comment:
gh api "repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"
```

If a comment requires human judgment or a design decision that can't be resolved autonomously, leave it unreacted and continue to the next comment. If **all** comments require human judgment (none were acted upon), park the PR so later runs skip it until someone replies: append ` (Needs Info)` to the title, report this to the user, and stop. Do not mark the PR as ready.

```bash
gh pr edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

### 5. Update the PR title and body as needed

If the changes made deviate from what the original title or body described, update them to accurately reflect the work done.

### 6. Verify CI before marking ready

Repos without CI have nothing to wait for: probe first, then watch, bounded so a stuck check can't hang the run:

```bash
if [ "$(gh pr view <number> --repo <owner>/<repo> --json statusCheckRollup --jq '.statusCheckRollup | length')" -gt 0 ]; then
    timeout 30m gh pr checks <number> --repo <owner>/<repo> --watch
fi
```

If the rollup is empty, there are no checks: treat it as passing. If the watch times out (exit code 124), report the still-pending checks and the PR URL to the user, then stop this run without marking the PR ready: it stays draft, and the next run will pick it up once CI has settled. If any check fails, do **not** mark the PR ready: report the failing checks to the user and stop.

### 7. Mark the Pull Request as ready

```bash
gh pr ready <number> --repo <owner>/<repo>
BRANCH=$(git rev-parse --abbrev-ref HEAD)   # capture while still inside the worktree
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/pr-<number> --force
git branch -D "$BRANCH"
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<number>

If any comments were left unreacted because they need human judgment (Step 4), list their `html_url`s under the Done line: the PR has left the draft pool, so this report is the only place they surface.

## Rules

- Work on exactly one Pull Request per run, most recently updated first. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run: sequentially, never in parallel: and stop early when a run reports "Nothing to do".
- Never post comments. React and rename only, as described above.
- All git operations for a PR must run inside that PR's worktree: never run `git checkout`, `gh pr checkout`, or commits from the base clone.
- Keep commit messages concise to 100 characters max.
