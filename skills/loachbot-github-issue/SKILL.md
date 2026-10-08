---
name: loachbot-github-issue
description: Autonomous GitHub Issue Fixer agent called LoachBot. Picks the single most-recently-updated GitHub issue created by and assigned to you, implements a fix in a Pull Request, then unassigns the issue. Use when the user wants to work through issues assigned to them, or asks to "run LoachBot Issues", including repeated runs like "run LoachBot Issues six times" or "until there aren't any left".
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

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents do the reading, searching and editing.

Spin one up when any one of these holds:

- You would read a file to understand how something works.
- A question needs more than two searches.
- A change needs more than one sentence to describe.
- You would run a build, tests or a linter and react to the output.

Exception: reading a file you already decided to edit. A run with no sub-agents at all almost certainly stretched it.

Types: `Explore` for read-only investigation (say how thorough); `general-purpose` for anything that edits or iterates.

### Fan out

Independent work goes out in one message, not one after another.

Read-only investigation is always independent. Nothing two `Explore` sub-agents do can collide, however much they overlap, so asking three questions about one repository means three sub-agents launched together — never one, then the next once it reports back. Staggering reads buys no safety; it only costs wall-clock.

The sequential rules under [Rules](#rules) govern *writes*: whole repeated runs, and anything touching the shared base clone or a worktree. They are not a general ban on concurrency, and they do not reach the sub-agents inside a single run.

What does have to stay sequential:

- Anything that writes — `git` in any form, builds that drop artefacts, formatters, codegen.
- A sub-agent whose prompt needs an earlier one's answer.

Otherwise, ask what two sub-agents would fight over. If the answer is nothing, they go out together.

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
    - **5** → the suffix was added by hand, so there is nothing to measure replies against. Skip the issue and mention it to the user.

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
    PR_URL=$(gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me)
    PR_NUMBER=${PR_URL##*/}
fi
```

If that `git push` fails because you lack push access to the repository, fork it and push the branch there instead (`gh repo fork <owner>/<repo> --remote --remote-name fork`, then `git push --force-with-lease -u fork HEAD`), then open the PR against the upstream repo with the fork's branch as its head, extracting `PR_NUMBER` as above:

```bash
PR_URL=$(gh pr create --repo <owner>/<repo> --head "$(gh api user --jq '.login'):fix/issue-<number>" \
    --title "<title>" --body "<body>" --assignee @me)
```

The `<user>:<branch>` form of `--head` tells `gh` the branch is already pushed; it does not accept an organization as the user, so a fork living in an org needs its PR opened by hand. Keep the fork remote named `fork` — the default naming renames the real origin to `upstream`, silently repointing every later `origin/$DEFAULT` reference at the fork. If forking isn't appropriate, handle it like Step 4 (comment + `(Needs Info)`) and stop.

Then verify CI. The script waits out the delay before checks register, probes several times before believing a repo has no CI, and bounds the wait at about 30 minutes:

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> "$PR_NUMBER"
```

Act on its exit code:

- **0** → checks passed, or the repo has no CI. Continue.
- **8** → still pending after the full wait. Report the pending checks and the PR URL to the user, then stop this run without un-assigning the issue — the next run picks it up once CI has settled.
- **7** → the check status could not be read at all. Unknown is not passing: report it and the PR URL, then stop without un-assigning the issue.
- **1** → a check failed. Fix it and push again, at most two fix attempts, and do **not** un-assign the issue while checks are red. If it's still red after that, or the failure needs human judgment, handle it like Step 4 (comment + `(Needs Info)`) and stop.

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
- Runs collide only through the base clone they share, so that is what the limit is about. Two runs against the same clone must not overlap: one fetching, deleting branches or resetting it underneath the other corrupts both. Runs against *different* clones are independent and may overlap freely — including any of the GitLab skills, which clone to `~/Projects/drupalcode/<project>` and so can never collide with a GitHub one at `~/Projects/<owner>/<repo>`. This bounds whole runs, not the sub-agents within one, which fan out per [Fan out](#fan-out).
- Keep commit messages to one concise line, following your global commit conventions.
- Pull Request description should only have one short paragraph, with a link to the issue as "Fixes #<number>"
