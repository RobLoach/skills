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

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` is where clones and worktrees go by default; `LOACHBOT_PROJECTS_DIR` overrides it. It is created if missing, so change it only if the user prefers another directory.
<!-- /SHARED: prerequisites -->

<!-- SHARED: conventions -->
## Conventions

The `bash` blocks below are templates, not literals: substitute `<owner>`, `<repo>`, and `<number>` before running them, and adapt anything that doesn't fit the repository in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.
<!-- /SHARED: conventions -->

<!-- SHARED: sub-agents -->
## Sub-agents

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents do the reading, searching and editing. Use one whenever you would read a file to learn how something works, need more than two searches, make a change that takes more than a sentence to describe, or run a build, tests or a linter and react to the output.

Use a read-only investigator for questions and an editing agent for changes, whatever your harness calls them. Read-only sub-agents cannot collide, so launch them together in one message rather than one after another. Only two things stay sequential: anything that writes (`git`, builds, formatters, codegen), and a sub-agent whose prompt needs an earlier one's answer.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

A report is a claim. Verify what matters: read the diff or re-run the command.
<!-- /SHARED: sub-agents -->

## Workflow

### 1. Find one actionable issue

<!-- SHARED: search-scoping -->
The search spans every repository by default. Scope it first, in this order:

1. A repo named in the prompt or skill arguments (URL or `owner/repo`): add `--repo <owner>/<repo>`.
2. Otherwise, if the user asked to work "on this project" and the current working directory is a git repo, use its `origin` remote: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`, and add `--repo` for that.
3. Otherwise search account-wide, as below.
<!-- /SHARED: search-scoping -->

```bash
# Issues created by and assigned to me, newest activity first.
# Add `--repo <owner>/<repo>` when the run is scoped to one repository.
gh search issues --author=@me --assignee=@me --state=open --sort=updated --limit=30 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If no items are found, report "Nothing to do" and stop.

For each issue (most-recently-updated first), decide whether it's actionable from the ` (Needs Info)` title suffix:

- Title does **not** end with ` (Needs Info)` → actionable.
- Title ends with ` (Needs Info)` → a previous run asked a question and parked it (Step 4). Check for answers:
    ```bash
    bash <this skill's directory>/scripts/check-parked.sh <owner> <repo> <number>
    ```
    Act on its exit code:
    - **0** → answered; the printed replies are clarification for Step 2. The issue is actionable.
    - **6** → nobody has answered yet. Skip the issue.
    - **5** → nothing to measure replies against: either the issue could not be read, or the suffix was added by hand. Skip the issue and mention it to the user.

Pick the first actionable issue. If none are actionable, report "Nothing to do" and stop.

Search results can lag behind reality, so a just-finished issue may still appear on an immediate re-run. Before starting, confirm the picked issue is still open and assigned to you:

```bash
gh api "repos/<owner>/<repo>/issues/<number>" --jq '{state, assignees: [.assignees[].login]}'
```

If `state` is not `open`, or your login is not among the assignees, skip it and evaluate the next candidate.

When the picked issue was parked, strip the suffix from its title before doing the work:

```bash
gh issue edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"
```

Once you pick an issue, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/issues/<number>

### 2. Understand the issue

- Read the full body: `gh api repos/<owner>/<repo>/issues/<number>`
- Read the comments authored by the logged-in user: those are the instructions to trust:
    ```bash
    # `export` so the filter can read the login as `env.AUTHOR`.
    export AUTHOR
    AUTHOR=$(gh api user --jq '.login')
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, body}'
    ```
- If you resumed a `(Needs Info)` issue, also read the answers gathered in Step 1: treat them as clarification for the question that was asked, not as new open-ended instructions.
- Identify what work is needed from the issue body, the author's comments, and any clarification answers.

Investigate through sub-agents fanned out in parallel, keeping file contents out of the main thread — see [Sub-agents](#sub-agents).

### 3. Do the work

Each issue gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-issue worktrees live under `~/Projects/<owner>/<repo>.worktrees/issue-<number>` and are deleted after the run is complete.

The branch name is **deterministic** — `fix/issue-<number>` — so the same issue always maps to the same branch across runs, regardless of any title edits.

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <owner> <repo> <number> | tail -1)
cd "$WT"
```

The script clones on first use, recreates the worktree from scratch, resumes from `origin/fix/issue-<number>` when an earlier run pushed one, rebases onto the default branch, and syncs submodules. Read its header for the details.

Recovery paths, by exit code:

- **4** — the branch is checked out by another, still-live worktree. Remove it (`git worktree remove <stale-path> --force`, then `git worktree prune`) and run the script again.
- **3** — the rebase conflicted and has already been aborted. Handle it like Step 4 (comment + `(Needs Info)`) and stop; never keep working in a half-rebased worktree.
- Any other non-zero — the worktree could not be created, for instance because the local branch diverged or the clone is unhealthy. The script names the failing command on stderr. Stop and report it; do not force through it.

Delegate the implementation per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; the main thread keeps the git/push/PR steps.

Implement the fix, test where possible, then commit (still inside `$WT`):

```bash
git add -A
if git diff --cached --quiet; then
    echo "nothing staged: no code change was needed"
else
    git commit -m "<concise message>"
fi
```

If nothing was staged, the issue needed no code change — it was already fixed, or it turned out to be a question rather than a defect. Do not open an empty Pull Request: `gh pr create` rejects a branch with no commits anyway. Handle it like Step 4 instead (a comment saying what you found, then ` (Needs Info)`) and stop, so a human decides whether to close the issue.

Then push and make sure a PR exists:

```bash
# `--force-with-lease` covers both cases in one line: it creates the branch on a first
# run, and replaces the remote history when the rebase above rewrote a resumed branch -
# while still refusing the push if someone else moved the branch in the meantime.
git push --force-with-lease -u origin HEAD

# A re-run may already have an open PR for this branch: only create one if none exists.
# Keep `--head` a bare branch name. It matches fork-based PRs too, whereas the
# `<owner>:<branch>` form matches nothing here.
PR_NUMBER=$(gh pr list --repo <owner>/<repo> --head fix/issue-<number> --state open --json number --jq '.[0].number // ""')
if [ -z "$PR_NUMBER" ]; then
    # `gh pr create` prints the new Pull Request's URL; its last segment is the number.
    # Body: one short paragraph, then "Fixes #<number>".
    PR_URL=$(gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me)
    PR_NUMBER=${PR_URL##*/}
fi
```

If that `git push` fails for lack of push access, handle it like Step 4 (comment + `(Needs Info)`) and stop. An issue you can be assigned to is almost always on a repository you can push to, so this is a permissions problem for a human, not something to work around with a fork.

Then verify CI. The script waits out the delay before checks register, probes several times before believing a repo has no CI, and bounds the wait at about 30 minutes:

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> "$PR_NUMBER"
```

Act on its exit code:

- **0** → checks passed, or the repo has no CI. Continue.
- **8** → still pending after the full wait. Report the pending checks and the PR URL to the user, then stop this run without un-assigning the issue — the next run picks it up once CI has settled.
- **7** → the check status could not be read at all. Unknown is not passing: report it and the PR URL, then stop without un-assigning the issue.
- **1** → a check failed. Read the failing log first: take the run id from the check's link (`gh pr checks "$PR_NUMBER" --repo <owner>/<repo> --json name,state,link`), then `gh run view <run-id> --repo <owner>/<repo> --log-failed`. Fix it and push again, at most two fix attempts, and do **not** un-assign the issue while checks are red. If it's still red after that, or the failure needs human judgment, handle it like Step 4 (comment + `(Needs Info)`) and stop.

### 4. When the task is unclear

If you don't know what to do or need clarification, post a short question as a comment and append ` (Needs Info)` to the issue title, then stop. Do **not** un-assign. The title rename is what later runs use to find your question and its answers (Step 1).

Comment first, rename second. The parking rename has to be the newest event you leave behind: Step 1 treats anything posted after it as the reply that un-parks the issue, so renaming first would make your own question un-park it immediately and loop forever.

```bash
gh issue comment <number> --repo <owner>/<repo> --body "<one short question>"
gh issue edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

### 5. Un-assign when done

After completing work successfully, un-assign the issue — no other comments — then remove the worktree and its local branch (already pushed, so nothing is lost):

```bash
gh issue edit <number> --repo <owner>/<repo> --remove-assignee @me
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/issue-<number> --force
git branch -D fix/issue-<number>
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<pr-number>

## Rules

- Work on exactly one issue per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run, one run at a time — search results lag behind reality, so a just-finished issue still appears on an immediate re-run and two overlapping runs would both pick it. Stop early when a run reports "Nothing to do". Within a single run, delegate per [Sub-agents](#sub-agents) and fan independent investigation out concurrently; the main thread keeps orchestration and the git/PR/un-assign steps.
- Never post comments except to ask for clarification (see Step 4). Un-assign silently.
- All git operations for an issue must run inside that issue's worktree: never run `git checkout`, branch creation, or commits from the base clone.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. Every LoachBot skill that clones shares `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org) with its siblings, and one run fetching, resetting or deleting branches under another corrupts both. Runs on different clones may overlap freely, and so may the sub-agents within a run.
<!-- /SHARED: one-run-per-clone -->
- Keep commit messages to one concise line, following your global commit conventions.
