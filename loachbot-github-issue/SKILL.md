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

For each issue (most-recently-updated first), skip any whose title ends with `(Needs Info)`. Pick the first issue that does **not** have that suffix and proceed with it. If all issues have `(Needs Info)` in their title, report "Nothing to do" and stop.

Once you pick an issue, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/issues/<number>

### 2. Understand the issue

- Read the full body: `gh api repos/<owner/repo>/issues/<number>`
- Read recent comments: `gh api repos/<owner/repo>/issues/<number>/comments`
- Identify what work is needed based on the thread

### 3. Do the work

Clone the repo with SSH if it doesn't already exist locally, then pull latest and update submodules before branching:
```bash
# If cloning fresh:
git clone --recurse-submodules git@github.com:<owner>/<repo>.git ~/Projects/<repo>
cd ~/Projects/<repo>

# If the repo already exists locally:
git checkout <default-branch>
git reset --hard origin/<default-branch>
git clean -fd
git pull origin <default-branch>
git submodule update --init --recursive

# Then create the work branch from the clean default branch:
git checkout -b fix/<issue-slug>
```

Implement the fix, test where possible, then open a PR:
```bash
git push origin HEAD
gh pr create --repo <owner/repo> --title "<title>" --body "<body>" --assignee @me
```

### 4. When the task is unclear

If you don't know what to do or need clarification, post a short question as a comment and append ` (Needs Info)` to the issue title — then stop. Do **not** un-assign.

```bash
gh issue comment <number> --repo <owner/repo> --body "<one short question>"
gh issue edit <number> --repo <owner/repo> --title "<original title> (Needs Info)"
```

### 5. Un-assign when done

After completing work successfully, un-assign the issue. Do not make any other comments.

```bash
gh issue edit <number> --repo <owner/repo> --remove-assignee="@me"
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<pr-number>

## Rules

- Work on exactly one issue per run
- Never post comments except to ask for clarification (see Step 4). Un-assign silently.
- If a repo needs to be cloned, use the Projects directory at `~/Projects`
- Commit with a concise message, 100 characters max; no AI-attribution footers
- Pull Request description should only have a one short paragraph, with a link to the issue as "Fixes #<number>"
