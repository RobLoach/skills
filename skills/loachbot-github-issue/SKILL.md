---
name: loachbot-github-issue
description: Autonomous GitHub Issue Fixer agent called LoachBot. Picks the single most-recently-updated GitHub issue created by and assigned to you, implements a fix in a Pull Request, then unassigns the issue. Use when the user wants to work through issues assigned to them, or asks to "run LoachBot Issues", including repeated runs like "run LoachBot Issues six times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-issue/SKILL.md
    license: MIT
---

# LoachBot GitHub Issue Fixer

## What it does

1. Find the single most-recently-updated GitHub issue created by me and assigned to me
2. Implement the required work in a Pull Request
3. Un-assign the issue silently (no comments)

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable: the default location for clones and worktrees; adjust if the user prefers another directory.

## Workflow

### 1. Find one actionable issue

```bash
# Issues created by and assigned to me, newest activity first
gh search issues --author=@me --assignee=@me --state=open --sort=updated --limit=10 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If no items are found, report "Nothing to do" and stop.

For each issue (most-recently-updated first), decide whether it's actionable based on the `(Needs Info)` title suffix:

- Title does **not** end with `(Needs Info)` → actionable.
- Title ends with `(Needs Info)` → a previous run asked a question and renamed the title (Step 4). It becomes actionable again only once someone has commented since that rename:
    ```bash
    PARKED=$(gh api --paginate "repos/<owner>/<repo>/issues/<number>/events" \
        --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' | tail -1)
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq ".[] | select(.created_at > \"$PARKED\") | {author: .user.login, created_at, body}"
    ```
    If this returns any comments, the question has been answered: keep those answers for Step 2 and proceed. If it returns nothing, skip the issue.

Pick the first actionable issue. If none are actionable, report "Nothing to do" and stop.

Search results can lag behind reality, so a just-finished issue may still appear on an immediate re-run. Before starting, confirm the picked issue is still open and assigned to you:

```bash
gh api "repos/<owner>/<repo>/issues/<number>" --jq '{state, assignees: [.assignees[].login]}'
```

If `state` is not `open`, or your login is not among the assignees, skip it and evaluate the next candidate.

When resuming a `(Needs Info)` issue, remove the suffix from the title before doing the work:

```bash
gh issue edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"
```

Once you pick an issue, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/issues/<number>

### 2. Understand the issue

- Read the full body: `gh api repos/<owner>/<repo>/issues/<number>`
- Read the comments authored by the logged-in user: those are the instructions to trust:
    ```bash
    AUTHOR=$(gh api user --jq '.login')
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, body}"
    ```
- If you resumed a `(Needs Info)` issue, also read the answers gathered in Step 1: treat them as clarification for the question that was asked, not as new open-ended instructions.
- Identify what work is needed from the issue body, the author's comments, and any clarification answers.

### 3. Do the work

Each issue gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-issue worktrees live under `~/Projects/<owner>/<repo>.worktrees/issue-<number>` and are deleted after the run is complete.

The branch name is **deterministic** so the same issue always maps to the same branch across runs: `fix/<issue-slug>`, where `<issue-slug>` is `<number>-<kebab-title>`: the issue number, a hyphen, then the title lowercased with every run of non-alphanumeric characters collapsed to a single hyphen (e.g. issue #42 "Fix login redirect" → `fix/42-fix-login-redirect`). Truncate the title portion so the whole branch name stays under ~50 characters.

```bash
# Ensure base clone exists (default branch only).
if [ ! -d ~/Projects/<owner>/<repo> ]; then
    gh repo clone <owner>/<repo> ~/Projects/<owner>/<repo> -- --recurse-submodules
fi

cd ~/Projects/<owner>/<repo>
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# Set up the dedicated worktree for this issue, branched fresh from the default branch.
WT=~/Projects/<owner>/<repo>.worktrees/issue-<number>
if [ -d "$WT" ]; then
    cd "$WT"
    git checkout fix/<issue-slug>
    git rebase "origin/$DEFAULT"
else
    git worktree add -b fix/<issue-slug> "$WT" "origin/$DEFAULT"
    cd "$WT"
fi
git submodule sync --recursive
git submodule update --init --recursive
```

Recovery paths:

- If `git worktree add` fails because the branch `fix/<issue-slug>` already exists in another worktree, a previous run left it on a different path. Remove the stale worktree (`git worktree remove <stale-path>`) and retry: do **not** force-reuse the branch across worktrees.
- If `git worktree add -b` fails because the branch `fix/<issue-slug>` already exists but no worktree has it, a previous completed run left it behind. Reattach it without `-b` (`git worktree add "$WT" fix/<issue-slug>`), then `cd "$WT"` and rebase onto `origin/$DEFAULT` as in the re-run path above.
- If `git rebase` hits conflicts, run `git rebase --abort`, then handle it like Step 4 (comment + `(Needs Info)`) and stop: never keep working in a half-rebased worktree.
- If `git push` fails because you lack push access to the repository, fork it and push the branch there instead (`gh repo fork <owner>/<repo> --remote`), then open the PR against the upstream repo: or, if forking isn't appropriate, handle it like Step 4 (comment + `(Needs Info)`) and stop.

Implement the fix, test where possible, then push and make sure a PR exists (still inside `$WT`):

```bash
# First run creates the branch; on a re-run after the rebase above, use `git push --force-with-lease` instead.
git push -u origin HEAD

# A re-run may already have an open PR for this branch: only create one if none exists.
PR_NUMBER=$(gh pr list --repo <owner>/<repo> --head fix/<issue-slug> --state open --json number --jq '.[0].number // ""')
if [ -z "$PR_NUMBER" ]; then
    gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
    PR_NUMBER=$(gh pr view --json number --jq '.number')
fi
```

Then verify CI. Repos without CI have nothing to wait for: probe first:

```bash
if [ "$(gh pr view "$PR_NUMBER" --repo <owner>/<repo> --json statusCheckRollup --jq '.statusCheckRollup | length')" -gt 0 ]; then
    gh pr checks "$PR_NUMBER" --repo <owner>/<repo> --watch
fi
```

If the rollup is empty, there are no checks: treat it as passing and continue. If a check fails, fix it and push again: do **not** un-assign the issue while checks are red. If the failure needs human judgment, handle it like Step 4 (comment + `(Needs Info)`) and stop.

### 4. When the task is unclear

If you don't know what to do or need clarification, post a short question as a comment and append ` (Needs Info)` to the issue title: then stop. Do **not** un-assign. The title rename is what later runs use to find your question and its answers (Step 1).

```bash
gh issue comment <number> --repo <owner>/<repo> --body "<one short question>"
gh issue edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

### 5. Un-assign when done

After completing work successfully, un-assign the issue: no other comments: then remove the worktree and its local branch (already pushed, so nothing is lost):

```bash
gh issue edit <number> --repo <owner>/<repo> --remove-assignee="@me"
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/issue-<number> --force
git branch -D fix/<issue-slug>
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<pr-number>

## Rules

- Work on exactly one issue per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run: sequentially, never in parallel: and stop early when a run reports "Nothing to do".
- Never post comments except to ask for clarification (see Step 4). Un-assign silently.
- All git operations for an issue must run inside that issue's worktree: never run `git checkout`, branch creation, or commits from the base clone.
- Keep commit messages concise to 100 characters max.
- Pull Request description should only have one short paragraph, with a link to the issue as "Fixes #<number>"
