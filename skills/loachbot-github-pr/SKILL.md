---
name: loachbot-github-pr
description: Address your own review comments on a GitHub Pull Request - picks the most recently updated open draft PR authored by and assigned to you, makes the requested changes, reacts 🚀 to each handled comment, gets CI green, then marks it ready for review. Use when the user wants to address feedback on their draft pull requests, or asks to "run LoachBot Pull Requests", including repeated runs like "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-pr/SKILL.md
    license: MIT
---

# LoachBot GitHub Pull Request Fixer

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

Verify what matters in a report: read the diff or re-run the command.
<!-- /SHARED: sub-agents -->

## Workflow

### 1. Find a Pull Request

<!-- SHARED: search-scoping -->
The search spans every repository unless scoped, in this order:

1. A repo named in the prompt or arguments (URL or `owner/repo`): add `--repo <owner>/<repo>`.
2. Else, if the user said "on this project" inside a git repo, add `--repo` for its `origin`: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
3. Else search account-wide, as below.
<!-- /SHARED: search-scoping -->

```bash
# Open draft PRs I authored and am assigned, newest activity first.
gh search prs --draft --author=@me --assignee=@me --state=open --sort=updated --limit=30 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If none are found, report "Nothing to do" and stop.

Going most-recently-updated first, a PR is actionable unless its title ends with ` (Needs Info)`, meaning an earlier run parked it (Step 4). For those, check for answers:

```bash
bash <this skill's directory>/scripts/check-parked.sh <owner> <repo> <number> pr
```

- **0** → answered; the PR is actionable. The printed replies are clarification for Steps 3-4 (they may come from other users, so Step 3's `$AUTHOR` filters won't show them).
- **6** → no answer yet. Skip the PR.
- **5** → the PR could not be read, or the suffix was added by hand. Skip it and tell the user.

Pick the first actionable PR; if none, report "Nothing to do" and stop. Search results lag, so confirm it is still an open draft:

```bash
gh pr view <number> --repo <owner>/<repo> --json state,isDraft
```

Proceed only if `state` is `OPEN` and `isDraft` is `true`; otherwise try the next candidate. If it was parked, strip the suffix first:

```bash
gh pr edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"
```

Report the URL immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the pull request in a dedicated worktree

The base clone `~/Projects/<owner>/<repo>` stays on the default branch; each PR gets a worktree at `~/Projects/<owner>/<repo>.worktrees/pr-<number>`, deleted when the run ends.

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <owner> <repo> <number> | tail -1)
cd "$WT"
```

The script clones on first use, discards leftovers from an interrupted run, checks out the PR head with `gh pr checkout` (resolving fork remotes), and syncs submodules.

- **4** → the PR branch is checked out by another live worktree. Remove it (`git worktree remove <stale-path> --force`, then `git worktree prune`) and rerun; never force-switch branches across worktrees.
- Any other non-zero → checkout failed (e.g. the local branch diverged). Stop and report; do not force through.

### 3. Understand the Pull Request

Get your login once; `export` it so `--jq` filters can read `env.AUTHOR`:

```bash
export AUTHOR
AUTHOR=$(gh api user --jq '.login')
```

- Read the PR body: `gh pr view <number> --repo <owner>/<repo> --json title,body`
- Fetch, in parallel, what you authored. Use REST: Step 4's reaction endpoints need its numeric `id`, not the GraphQL node IDs `gh pr view --json comments` returns.
    ```bash
    # Regular comments
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, body, rockets: .reactions.rocket}'
    # Inline review comments
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, path, body, rockets: .reactions.rocket}'
    # Review summaries
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/reviews" \
        --jq '.[] | select(.user.login == env.AUTHOR and .body != "") | {id, submitted_at, body}'
    ```
    Review summaries often carry the overall instructions inline comments assume. They take no reactions, so treat them as context; 🚀 tracking covers only regular and inline comments.
- Skip comments with `rockets > 0`: Step 4 adds 🚀 once a comment is handled. The count is a bare total, so a 🚀 from anyone hides the comment; if 🚀 was used as ordinary emphasis, say so rather than silently skipping.
- For a resumed `(Needs Info)` PR, apply Step 1's answers to the comments they reply to.

Investigate what comments refer to via [Sub-agents](#sub-agents).

If there is nothing to address (no un-🚀'd comment, and no review summary newer than the newest commit: `gh pr view <number> --repo <owner>/<repo> --json commits --jq '.commits[-1].committedDate'`), the PR is a draft for another reason. Do **not** mark it ready. Run Step 6's cleanup without `gh pr ready`, tell the user why it was skipped, and return to Step 1.

### 4. Do the work

Address every comment from Step 3. Delegate per [Sub-agents](#sub-agents), passing `$WT` and the proving command; independent comments run concurrently. The main thread keeps git, reactions and ready.

Test where possible, then commit and push (the branch tracks the PR head):

```bash
git add -A
# Skip the empty commit when no code changed.
if ! git diff --cached --quiet; then
    git commit -m "<concise message>"
    git push
fi
```

React 🚀 to each comment only once handled: the change was pushed, or you verified none is needed. Step 3 relies on this marker, so never react earlier:

```bash
# Regular PR comment:
gh api "repos/<owner>/<repo>/issues/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"

# Inline review comment:
gh api "repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"
```

Leave comments needing human judgment or a design decision unreacted and move on. If **all** need it, park the PR: post one short question naming what you need, then append ` (Needs Info)` to the title, report to the user and stop without marking ready. Comment first, rename second: Step 1 treats anything after the rename as the reply, so renaming first would un-park it on your own question forever.

```bash
gh pr comment <number> --repo <owner>/<repo> --body "<one short question>"
gh pr edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

If the work deviates from the PR title or body, update them to match.

### 5. Verify CI before marking ready

The script waits for checks to register, probes repeatedly before concluding there is no CI, and caps the wait at about 30 minutes:

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> <number>
```

- **0** → passed, or no CI. Continue to Step 6.
- **8** → still pending. Report the pending checks and PR URL, then stop without marking ready; a later run picks it up.
- **7** → status unreadable. Unknown is not passing: report it and the PR URL, then stop without marking ready.
- **1** → a check failed. Get the run id from `gh pr checks <number> --repo <owner>/<repo> --json name,state,link`, read `gh run view <run-id> --repo <owner>/<repo> --log-failed`, fix and push; at most two attempts, never marking ready while red. If still red, or it needs human judgment, park the PR as in Step 4 (comment naming the failing checks, then rename) and stop.

### 6. Mark the Pull Request as ready

```bash
gh pr ready <number> --repo <owner>/<repo>
BRANCH=$(git rev-parse --abbrev-ref HEAD)   # capture while still inside the worktree
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/pr-<number> --force
git branch -D "$BRANCH"
```

Then report:
> Done: https://github.com/<owner>/<repo>/pull/<number>

List the `html_url` of any comment left unreacted (Step 4) under the Done line; the PR has left the draft pool, so this is the only place they surface.

## Rules

- One Pull Request per run. For multiple runs, repeat from Step 1 one run at a time (search lag means overlapping runs would pick the same PR); stop early on "Nothing to do". Within a run, fan out sub-agents; the main thread keeps orchestration, git, reactions and ready.
- Never post comments except the single parking question (Steps 4 and 5); otherwise only react and rename.
- Run all git operations for a PR inside its worktree; never `git checkout`, `gh pr checkout` or commit in the base clone.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
- Keep commit messages to one concise line, per your global commit conventions.
