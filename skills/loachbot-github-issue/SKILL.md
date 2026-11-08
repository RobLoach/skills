---
name: loachbot-github-issue
description: Fix the most recently updated GitHub issue that you created and is assigned to you - implement it in a worktree, open a Pull Request, get CI green, then unassign the issue. Use when the user wants to work through their own assigned GitHub issues, fix the next one, or asks to "run LoachBot Issues", including repeated runs like "six times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-issue/SKILL.md
    license: MIT
---

# LoachBot GitHub Issue Fixer

<!-- SHARED: prerequisites -->
## Prerequisites

- Run `gh auth status` first; if it fails, report that and stop.
- Clones and worktrees go in `~/Projects` (created if missing), or in `LOACHBOT_PROJECTS_DIR` if the user prefers another directory.
<!-- /SHARED: prerequisites -->

<!-- SHARED: conventions -->
## Conventions

The `bash` blocks below are templates: substitute `<owner>`, `<repo>` and `<number>`, and adapt them to the repository.

Longer sequences live in `scripts/` beside this `SKILL.md`, run as `bash <this skill's directory>/scripts/<name>.sh`; each header documents arguments and exit codes.
<!-- /SHARED: conventions -->

<!-- SHARED: sub-agents -->
## Sub-agents

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents read, search and edit. Delegate whenever you would read a file to learn how something works, run more than two searches, make a change that needs more than a sentence to describe, or run a build, tests or a linter and react to its output.

Use read-only investigators for questions and editing agents for changes. Launch read-only ones together in one message; they cannot collide. Keep sequential only writes (`git`, builds, formatters, codegen) and sub-agents that need an earlier answer.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

Verify what matters in a report: read the diff or re-run the command. Wait for every sub-agent you launched before reporting, and tell sub-agents that launch their own helpers to do the same: a report sent while helpers still run is unfinished work.
<!-- /SHARED: sub-agents -->

<!-- SHARED: repeated-runs -->
## Repeated runs

When the user asks for several runs ("five times", "until there aren't any left", "a sub-agent for each"):

1. Run them one at a time, never overlapping: search results lag, so overlapping runs pick the same item.
2. With sub-agents, give each run its own, launched only after the previous one has reported. Its prompt carries the skill name and arguments, "Follow the skill from Step 1", the items earlier runs already handled or parked (to skip), and "Wait for your own sub-agents to finish before reporting".
3. Stop early on "Nothing to do".
4. Finish with one table: run, item, outcome (done, parked, nothing to do), link, and what is waiting on the user. Then say how many runs completed out of how many asked.
<!-- /SHARED: repeated-runs -->

<!-- SHARED: parking -->
## Parking

To park an item, post one short question naming what you need, then append ` (Needs Info)` to its title, and stop without un-assigning or marking it ready. Comment first, rename second: `check-parked.sh` treats anything after the rename as the reply, so renaming first would let your own question un-park it in a loop. Issues and Pull Requests share these endpoints:

```bash
gh api -X POST "repos/<owner>/<repo>/issues/<number>/comments" -f body="<one short question>"
gh api -X PATCH "repos/<owner>/<repo>/issues/<number>" -f title="<original title> (Needs Info)"
```

Once `check-parked.sh` reports an answer, strip the suffix before working on the item:

```bash
gh api -X PATCH "repos/<owner>/<repo>/issues/<number>" -f title="<title without ' (Needs Info)'>"
```
<!-- /SHARED: parking -->

## Workflow

### 1. Find one actionable issue

<!-- SHARED: search-scoping -->
The search spans every repository unless scoped, in this order:

1. A repo named in the prompt or arguments (URL or `owner/repo`): add `--repo <owner>/<repo>`.
2. Else, if the user said "on this project" inside a git repo, add `--repo` for its `origin`: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
3. Else search account-wide, as below.
<!-- /SHARED: search-scoping -->

```bash
# Issues created by and assigned to me, newest activity first.
gh search issues --author=@me --assignee=@me --state=open --sort=updated --limit=30 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If none are found, report "Nothing to do" and stop.

Walk the issues newest first. A title without ` (Needs Info)` is actionable. One with it was [parked](#parking); check for answers:

```bash
bash <this skill's directory>/scripts/check-parked.sh <owner> <repo> <number>
```

- **0** → answered; the printed replies are clarification for Step 2. Actionable.
- **6** → no answer yet. Skip it.
- **5** → the issue could not be read, or the suffix was added by hand. Skip it and tell the user.

Pick the first actionable issue; if there is none, report "Nothing to do" and stop.

Search results lag, so confirm the pick is still open and assigned to you:

```bash
gh api "repos/<owner>/<repo>/issues/<number>" --jq '{state, assignees: [.assignees[].login]}'
```

If it is not `open` or you are not an assignee, try the next candidate.

If the pick was parked, strip the suffix ([Parking](#parking)).

Report the pick to the user immediately:
> Working on: https://github.com/<owner>/<repo>/issues/<number>

### 2. Understand the issue

- Read the body: `gh api repos/<owner>/<repo>/issues/<number>`
- Read the logged-in user's comments; those are the instructions to trust:
    ```bash
    # `export` so the filter can read it as `env.AUTHOR`.
    export AUTHOR
    AUTHOR=$(gh api user --jq '.login')
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, body}'
    ```
- For a resumed issue, treat Step 1's answers as clarification of the question asked, not new open-ended instructions.

Investigate through parallel sub-agents, keeping file contents out of the main thread (see [Sub-agents](#sub-agents)).

### 3. Do the work

```bash
WT=$(bash <this skill's directory>/scripts/setup-github-worktree.sh <owner> <repo> issue <number>)
cd "$WT"
```

- **3** — the rebase conflicted and was aborted. [Park](#parking) it; never work in a half-rebased worktree.
- **9** — a submodule could not be fetched (stderr names it); the worktree is still usable. If the fix does not touch that submodule, continue without it. Otherwise [park](#parking) it, naming the submodule.
- Any other non-zero — stderr names the failing command. Report it and stop; do not force through.

Delegate the implementation per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix. Test where possible, then review `git status --short` and stage only the files the fix meant to change: delete stray artifacts (screenshots, test output) or leave them untracked, never commit them.

```bash
git add <paths>
if git diff --cached --quiet; then
    echo "nothing staged: no code change was needed"
else
    git commit -m "<one-line message>"
fi
```

If nothing was staged (already fixed, or a question rather than a defect), open no Pull Request. [Park](#parking) it with a comment saying what you found, so a human decides whether to close it.

Push and make sure a PR exists:

```bash
# Creates the branch on a first run, replaces history a rebase rewrote, and still
# refuses if someone else moved the branch.
git push --force-with-lease -u origin HEAD

# Reuse an open PR from an earlier run. Keep `--head` a bare branch name; the
# `<owner>:<branch>` form matches nothing here.
PR_NUMBER=$(gh pr list --repo <owner>/<repo> --head fix/issue-<number> --state open --json number --jq '.[0].number // ""')
if [ -z "$PR_NUMBER" ]; then
    # Body: one short paragraph, then "Fixes #<number>". Prints the PR URL.
    PR_URL=$(gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me)
    PR_NUMBER=${PR_URL##*/}
fi
```

If the push fails for lack of access, [park](#parking) it; it is a permissions problem for a human, not a reason to fork.

Verify CI (the script waits up to about 30 minutes):

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> "$PR_NUMBER"
```

- **0** → passed, or no CI. Continue.
- **8** → still pending, or status unreadable (stderr says which). Report it and the PR URL, then stop without un-assigning; a later run picks it up.
- **1** → a check failed. Get the run id from `gh pr checks "$PR_NUMBER" --repo <owner>/<repo> --json name,state,link`, read `gh run view <run-id> --repo <owner>/<repo> --log-failed`, fix and push. At most two attempts, never un-assigning while red; if still red or it needs human judgment, [park](#parking) it.

### 4. When the task is unclear

[Park](#parking) it.

### 5. Un-assign when done

Un-assign silently, then remove the worktree and its already-pushed local branch:

```bash
gh issue edit <number> --repo <owner>/<repo> --remove-assignee @me
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/issue-<number> --force
git branch -D fix/issue-<number>
```

Report the PR to the user:
> Done: https://github.com/<owner>/<repo>/pull/<pr-number>

## Rules

- One issue per run; for more, see [Repeated runs](#repeated-runs).
- Never comment except to ask for clarification ([Parking](#parking)).
- Run all git operations for an issue inside its worktree; never `git checkout` or commit in the base clone, which stays on the default branch.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
