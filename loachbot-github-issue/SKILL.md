---
name: loachbot-github-issue
description: Autonomous GitHub Issue Fixer agent called LoachBot. Picks the single most-recently-updated GitHub issue created by and assigned to RobLoach, implements a fix or pull request, then unassigns the issue. Use when the user asks "run LoachBot Issues".
---

# LoachBot GitHub Issue Fixer

## What it does

1. Find the single most-recently-updated GitHub issue created by me and assigned to me
2. Implement the required work in a Pull Request
3. Un-assign the issue silently (no comments)

## Workflow

### 1. Find one actionable issue

```bash
# Issues created by and assigned to me
gh search issues --assignee=@me --state=open --limit 10 --author=@me --sort updated
```

If no items are found, report "Nothing to do" and stop.

For each issue (most-recently-updated first), check whether it already has a 😕 reaction from me:

```bash
gh api repos/<owner>/<repo>/issues/<number>/reactions --jq '.[] | select(.content == "confused") | .user.login'
```

Skip any issue where that returns `RobLoach`. Pick the first issue that does **not** have that reaction and proceed with it. If all issues have a 😕, report "Nothing to do" and stop.

### 2. Understand the issue

- Read the full body: `gh api repos/<owner/repo>/issues/<number>`
- Read recent comments: `gh api repos/<owner/repo>/issues/<number>/comments`
- Identify what work is needed based on the thread

### 3. Do the work

Clone the repo with SSH and implement the fix in a branch. Test where possible. Open a PR:
```bash
git checkout -b fix/<issue-slug>
# ... implement ...
git push origin HEAD
gh pr create --repo <owner/repo> --title "<title>" --body "<body>" --assignee RobLoach
```

### 4. When the task is unclear

If you don't know what to do or need clarification, post a short question as a comment and add a 😕 reaction — then stop. Do **not** un-assign.

```bash
gh issue comment <number> --repo <owner/repo> --body "<one short question>"
gh api repos/<owner>/<repo>/issues/<number>/reactions -f content=confused
```

### 5. Un-assign when done

After completing work successfully, un-assign the issue. Do not make any other comments.

```bash
gh issue edit <number> --repo <owner/repo> --remove-assignee="@me"
```

## Rules

- Work on exactly one issue per run
- Never post comments. Un-assign silently.
- If a repo needs to be cloned, use a the Projects directory at `~/Projects`
- Commit with a concise message, 100 characters max; no AI-attribution footers
- Pull Request description should only have a one short paragraph, with a link to the issue as "Fixes #<number>"
