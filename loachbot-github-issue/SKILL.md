---
name: loachbot-github-issue
description: Autonomous GitHub Issue Fixer agent called LoachBot. Picks the single most-recently-updated GitHub issue created by and assigned to you, implements a fix or pull request, then unassigns the issue. Use when the user asks "run LoachBot Issues".
---

# 🔧 LoachBot GitHub Issue Fixer

## 🎯 What it does

1. Find the single most-recently-updated GitHub issue created by me and assigned to me
2. Implement the required work in a Pull Request
3. Un-assign the issue silently (no comments)

## ✅ Prerequisites

- `gh` is authenticated — run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable (the base clone and per-issue worktrees live there).

## 🔄 Workflow

### 1. 🔍 Find one actionable issue

```bash
# Issues created by and assigned to me
gh search issues --assignee=@me --state=open --limit 10 --author=@me --sort updated
```

If no items are found, report "Nothing to do" and stop.

For each issue (most-recently-updated first), decide whether it's actionable based on the `(Needs Info)` suffix:

- Title does **not** end with `(Needs Info)` → actionable.
- Title ends with `(Needs Info)` → only actionable again once someone other than you has replied since you asked. Compare the latest comment's author to your own login:
    ```bash
    AUTHOR=$(gh api user --jq '.login')
    LATEST=$(gh api "repos/<owner>/<repo>/issues/<number>/comments" --jq '.[-1].user.login // ""')
    ```
    If `LATEST` is non-empty and differs from `AUTHOR`, the question has been answered — strip the suffix (below) and proceed. Otherwise skip it.

Pick the first actionable issue. If none are actionable, report "Nothing to do" and stop.

When resuming a `(Needs Info)` issue, remove the suffix from the title before doing the work:

```bash
gh issue edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"
```

Once you pick an issue, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/issues/<number>

### 2. 📖 Understand the issue

- Read the full body: `gh api repos/<owner>/<repo>/issues/<number>`
- Read recent comments, filtering to only those from the logged-in user:
    ```bash
    AUTHOR=$(gh api user --jq '.login')
    gh api repos/<owner>/<repo>/issues/<number>/comments \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, body}"
    ```
- Identify what work is needed based on the issue body and the author's comments only

### 3. 🛠️ Do the work

Each issue gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<repo>` stays on the default branch; per-issue worktrees live under `~/Projects/<repo>.worktrees/issue-<number>` and are deleted after the run is complete.

The branch name is **deterministic** so the same issue always maps to the same branch across runs: `fix/<issue-slug>`, where `<issue-slug>` is `<number>-<kebab-title>` — the issue number, a hyphen, then the title lowercased with every run of non-alphanumeric characters collapsed to a single hyphen (e.g. issue #42 "Fix login redirect" → `fix/42-fix-login-redirect`). Truncate the title portion so the whole branch name stays under ~50 characters.

```bash
# Ensure base clone exists (default branch only).
if [ ! -d ~/Projects/<repo> ]; then
    gh repo clone <owner>/<repo> ~/Projects/<repo> -- --recurse-submodules
fi

cd ~/Projects/<repo>
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# Set up the dedicated worktree for this issue, branched fresh from the default branch.
WT=~/Projects/<repo>.worktrees/issue-<number>
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

If `git worktree add` fails because the branch `fix/<issue-slug>` already exists in another worktree, that means a previous run left it on a different path. Resolve by removing the stale worktree (`git worktree remove <stale-path>`) and retrying — do **not** force-reuse the branch across worktrees.

Implement the fix, test where possible, then open a PR (still inside `$WT`):
```bash
# First run creates the branch; on a re-run after the rebase above, use `git push --force-with-lease` instead.
git push -u origin HEAD
gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
```

Then wait for CI to finish and confirm every check passes before going further:
```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
gh pr checks "$PR_NUMBER" --repo <owner>/<repo> --watch
```

If a check fails, fix it and push again — do **not** un-assign the issue while checks are red. If the failure needs human judgment, handle it like Step 4 (comment + `(Needs Info)`) and stop.

### 4. ❓ When the task is unclear

If you don't know what to do or need clarification, post a short question as a comment and append ` (Needs Info)` to the issue title — then stop. Do **not** un-assign.

```bash
gh issue comment <number> --repo <owner>/<repo> --body "<one short question>"
gh issue edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

### 5. 🏁 Un-assign when done

After completing work successfully, un-assign the issue. Do not make any other comments.

```bash
gh issue edit <number> --repo <owner>/<repo> --remove-assignee="@me"
```

Then delete the worktree:

```bash
cd ~/Projects/<repo>
git worktree remove ~/Projects/<repo>.worktrees/issue-<number> --force
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<pr-number>

## 📏 Rules

- Work on exactly one issue per run
- When running multiple times, always run sequentially — never in parallel
- Never post comments except to ask for clarification (see Step 4). Un-assign silently.
- If a repo needs to be cloned, use the Projects directory at `~/Projects`. The base clone (`~/Projects/<repo>`) stays on the default branch; per-issue work happens in worktrees at `~/Projects/<repo>.worktrees/issue-<number>`
- All git operations for an issue must run inside that issue's worktree — never run `git checkout`, branch creation, or commits from the base clone
- Delete the worktree after a successful run with `git worktree remove <path> --force` from the base clone
- Commit with a concise message, 100 characters max; no AI-attribution footers
- Pull Request description should only have a one short paragraph, with a link to the issue as "Fixes #<number>"
