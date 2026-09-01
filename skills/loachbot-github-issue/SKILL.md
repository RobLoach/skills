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

## Related skills

Part of the LoachBot trio, chained together by self-assignment:

- **`loachbot-github-planner`** files issues assigned to you, which feed this skill.
- **`loachbot-github-issue`** (this skill) picks up those issues and opens a Pull Request you authored, assigned to you.
- **`loachbot-github-pr`** takes over once you review that Pull Request, leave inline comments, and set it back to **Draft**.

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable: the default location for clones and worktrees; adjust if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<owner>`, `<repo>`, and `<number>` before running them, and adapt anything that doesn't fit the repository in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes. `scripts/wait-for-checks.sh` is a verbatim copy of the one in `loachbot-github-pr`, because each skill directory installs on its own — keep the copies identical.

## Workflow

### 1. Find one actionable issue

The search spans every repository by default. Scope it first, in this order:

1. A repo named in the prompt or skill arguments (URL or `owner/repo`): add `--repo <owner>/<repo>`.
2. Otherwise, if the user asked to work "on this project" and the current working directory is a git repo, use its `origin` remote: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`, and add `--repo` for that.
3. Otherwise search account-wide, as below.

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
- Title ends with ` (Needs Info)` → a previous run asked a question and parked it (Step 4). Find that parking rename, then look for anything posted since:
    ```bash
    # A parking run comments first and renames second, so the parking rename is the newest
    # event it leaves behind. Take the most recent one: an issue can be parked, answered
    # and re-parked any number of times.
    PARKED=$(gh api --paginate "repos/<owner>/<repo>/issues/<number>/events" \
        --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' | tail -1)

    # `export` so the filter below can read the timestamp as `env.PARKED`.
    export PARKED
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}'
    ```
    Three outcomes:
    - `$PARKED` is empty → no parking rename exists, so the suffix was added by hand and there is nothing to measure replies against. Skip the issue and mention it to the user.
    - Replies came back → the question was answered. Keep them for Step 2; the issue is actionable.
    - No replies → nobody has answered yet. Skip the issue.

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

Delegate codebase investigation to subagents rather than reading files into the main thread. Fan independent lookups out in parallel.

### 3. Do the work

Each issue gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-issue worktrees live under `~/Projects/<owner>/<repo>.worktrees/issue-<number>` and are deleted after the run is complete.

The branch name is **deterministic** — `fix/issue-<number>` — so the same issue always maps to the same branch across runs, regardless of any title edits.

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <owner> <repo> <number> | tail -1)
cd "$WT"
```

The script clones on first use, recreates the worktree from scratch, resumes from `origin/fix/issue-<number>` when an earlier run pushed one, rebases onto the default branch, and syncs submodules. Read its header for the details.

Recovery paths, by exit code:

- **4** — the branch is checked out by another worktree left behind by an earlier run. Remove it (`git worktree remove <stale-path> --force`) and run the script again.
- **3** — the rebase conflicted and has already been aborted. Handle it like Step 4 (comment + `(Needs Info)`) and stop; never keep working in a half-rebased worktree.
- If `git push` later fails because you lack push access to the repository, fork it and push the branch there instead (`gh repo fork <owner>/<repo> --remote --remote-name fork`, then `git push --force-with-lease -u fork HEAD`), then open the PR against the upstream repo with the fork's branch as its head:
    ```bash
    gh pr create --repo <owner>/<repo> --head "$(gh api user --jq '.login'):fix/issue-<number>" \
        --title "<title>" --body "<body>" --assignee @me
    ```
    The `<user>:<branch>` form of `--head` also tells `gh` the branch is already pushed, so it won't offer to fork a second time. It does not accept an organization as the user, so a fork living in an org needs its PR opened by hand. Keep the fork remote named `fork`: the default naming takes over `origin` and renames the real origin to `upstream`, which would silently repoint every later `origin/$DEFAULT` reference at the fork's stale default branch. Or, if forking isn't appropriate, handle it like Step 4 (comment + `(Needs Info)`) and stop.

For anything beyond a small edit, delegate to a subagent (`cd "$WT"`, make the change, test, report back). The main thread keeps the git/push/PR steps.

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
    gh pr create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
    PR_NUMBER=$(gh pr view --json number --jq '.number')
fi
```

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

- Work on exactly one issue per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run — sequentially, never in parallel — and stop early when a run reports "Nothing to do". Within a single run, use subagents for codebase reads and implementation; keep the main thread for orchestration and git/PR/un-assign steps.
- Never post comments except to ask for clarification (see Step 4). Un-assign silently.
- All git operations for an issue must run inside that issue's worktree: never run `git checkout`, branch creation, or commits from the base clone.
- Only one LoachBot skill at a time may run against a given repository. All three share the base clone at `~/Projects/<owner>/<repo>`, and a concurrent run fetching, deleting branches or resetting it underneath you will corrupt this one. If the user asks for overlapping runs, do them one after another.
- Keep commit messages to one concise line, following your global commit conventions.
- Pull Request description should only have one short paragraph, with a link to the issue as "Fixes #<number>"
