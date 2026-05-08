---
name: loachbot-github-pr
description: Autonomous GitHub Pull Request Fixer agent called LoachBot. Scans GitHub for Pull Requests where RobLoach has set the PR to Draft, implements fixes or updates the pull request, then moves it back to Open. Use when the user asks "run LoachBot Pull Requests".
---

# LoachBot GitHub Pull Request Fixer

## What it does

1. Find the latest GitHub Draft Pull Requests that have been created by me, and assigned to me
```
gh search prs --draft --author="@me" --assignee="@me" --state="open" --sort="created" --limit 1
```

2. Implement the required work directly in a Pull Request

3. Push the changes back into the Pull Request

4. Moves the Pull Request out of Draft, and back into Open

## Workflow

### 1. Find a Pull Request

```bash
# Get an open draft Pull Request by myself, assigned to myself
gh search prs --draft --author="@me" --assignee="@me" --state="open" --sort="created" --limit 1
```

Once you find a PR, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the project and pull request locally if it isn't already

```bash
gh repo clone <owner/repo> ~/Projects/<repo>
cd ~/Projects/<repo>
gh pr co <number>
```

### 3. Understand the Pull Request

- Read the full body of the pull request `gh pr view <number> --repo <owner/repo> --json title,body`
- Filter PR comments to only those authored by `@RobLoach`:
    ```bash
    gh pr view <number> --repo <owner/repo> --json comments \
        --jq '.comments[] | select(.author.login == "RobLoach") | {id, createdAt, url, body}'
    ```
- If you also need **review comments** (inline code review), query them separately:
    ```bash
    gh api repos/<owner>/<repo>/pulls/<number>/comments \
        --jq '.[] | select(.user.login == "RobLoach") | {id, created_at, html_url, path, position, body}'
    ```
- Skip any comment that already has a 🚀 reaction from you - it has already been acted upon:
    ```bash
    gh api repos/<owner>/<repo>/issues/comments/<comment_id>/reactions \
        --jq '.[] | select(.user.login == "RobLoach" and .content == "rocket")'
    ```

### 4. Do the work

Address all the comments @RobLoach suggested, and push the change back directly to the pull request. Do not make any comments. Test where possible.

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

If a comment requires human judgment or a design decision that can't be resolved autonomously, leave it unreacted and continue to the next comment.

### 5. Mark the Pull Request as Ready

```bash
# Mark the Pull Request as Ready
gh pr ready <number> --repo <owner/repo>
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<number>

### 6. Update the PR title and body as needed

## Rules

- Work one item at a time, most recently updated first
- Never post comments
- If a repo needs to be cloned, use a the Projects directory at `~/Projects`
- Commit with a concise message, 100 characters max; no AI-attribution footers
