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

`needs-info-check.sh`, bundled next to this `SKILL.md`, decides whether a parked item has been answered (Step 1). It is a verbatim copy of the one in `loachbot-github-pr`, because each skill directory installs on its own — keep the copies identical.

## Workflow

### 1. Find one actionable issue

```bash
# Issues created by and assigned to me, newest activity first
gh search issues --author=@me --assignee=@me --state=open --sort=updated --limit=30 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If no items are found, report "Nothing to do" and stop.

For each issue (most-recently-updated first), decide whether it's actionable from the ` (Needs Info)` title suffix:

- Title does **not** end with ` (Needs Info)` → actionable.
- Title ends with ` (Needs Info)` → a previous run asked a question and parked it (Step 4). Ask the bundled script whether anyone has replied since:
    ```bash
    bash <this skill's directory>/needs-info-check.sh <owner> <repo> <number>
    ```
    It prints one verdict:
    - `UNPARKED` → the question was answered, and the replies follow as JSON. Keep them for Step 2; the issue is actionable.
    - `PARKED` → nobody has replied yet. Skip the issue.
    - `MANUAL-SUFFIX` → the suffix was added by hand, so there is no parking rename to measure replies against. Skip the issue and mention it to the user.

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
    AUTHOR=$(gh api user --jq '.login')
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq ".[] | select(.user.login == \"$AUTHOR\") | {id, created_at, html_url, body}"
    ```
- If you resumed a `(Needs Info)` issue, also read the answers gathered in Step 1: treat them as clarification for the question that was asked, not as new open-ended instructions.
- Identify what work is needed from the issue body, the author's comments, and any clarification answers.

Delegate codebase investigation to subagents rather than reading files into the main thread. Fan independent lookups out in parallel.

### 3. Do the work

Each issue gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-issue worktrees live under `~/Projects/<owner>/<repo>.worktrees/issue-<number>` and are deleted after the run is complete.

The branch name is **deterministic** — `fix/issue-<number>` — so the same issue always maps to the same branch across runs, regardless of any title edits.

```bash
# Ensure base clone exists (default branch only).
if [ ! -d ~/Projects/<owner>/<repo> ]; then
    gh repo clone <owner>/<repo> ~/Projects/<owner>/<repo> -- --recurse-submodules
fi

cd ~/Projects/<owner>/<repo>
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune

# Recreate the worktree from scratch each run: completed work is always pushed, so the
# remote branch is the source of truth, and leftovers from interrupted runs are redone.
WT=~/Projects/<owner>/<repo>.worktrees/issue-<number>
git worktree remove "$WT" --force 2>/dev/null
git branch -D fix/issue-<number> 2>/dev/null

# Resume from the remote branch when an earlier run pushed one (e.g. the issue was
# re-assigned while its PR is still open); otherwise start fresh from the default branch.
START="origin/$DEFAULT"
git rev-parse --verify -q "origin/fix/issue-<number>" >/dev/null && START="origin/fix/issue-<number>"
git worktree add -b fix/issue-<number> "$WT" "$START"
cd "$WT"
git rebase "origin/$DEFAULT"
git submodule sync --recursive
git submodule update --init --recursive
```

Recovery paths:

- If `git worktree add -b` fails because the branch `fix/issue-<number>` still exists, the `git branch -D` was blocked by a stale worktree at another path holding it checked out. Remove it (`git worktree remove <stale-path> --force`) and retry.
- If `git rebase` hits conflicts, run `git rebase --abort`, then handle it like Step 4 (comment + `(Needs Info)`) and stop — never keep working in a half-rebased worktree.
- If `git push` fails because you lack push access to the repository, fork it and push the branch there instead (`gh repo fork <owner>/<repo> --remote --remote-name fork`, then `git push --force-with-lease -u fork HEAD`), then open the PR against the upstream repo with the fork's branch as its head:
    ```bash
    gh pr create --repo <owner>/<repo> --head "$(gh api user --jq '.login'):fix/issue-<number>" \
        --title "<title>" --body "<body>" --assignee @me
    ```
    The `<user>:<branch>` form of `--head` also tells `gh` the branch is already pushed, so it won't offer to fork a second time. It does not accept an organization as the user, so a fork living in an org needs its PR opened by hand. Keep the fork remote named `fork`: the default naming takes over `origin` and renames the real origin to `upstream`, which would silently repoint every later `origin/$DEFAULT` reference at the fork's stale default branch. Or, if forking isn't appropriate, handle it like Step 4 (comment + `(Needs Info)`) and stop.

For anything beyond a small edit, delegate to a subagent (`cd "$WT"`, make the change, test, report back). The main thread keeps the git/push/PR steps.

Implement the fix, test where possible, then push and make sure a PR exists (still inside `$WT`):

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

Then verify CI. Repos without CI have nothing to wait for — but checks take a moment to register after a push, so pause before probing, and bound the wait so a stuck check can't hang the run:

```bash
sleep 30
CHECKS=0
if [ "$(gh pr view "$PR_NUMBER" --repo <owner>/<repo> --json statusCheckRollup --jq '.statusCheckRollup | length')" -gt 0 ]; then
    # Poll rather than `--watch`, so the 30-minute bound needs nothing but `sleep`.
    # `gh pr checks` exits 8 while checks are pending, 0 once they all pass.
    for _ in $(seq 30); do
        gh pr checks "$PR_NUMBER" --repo <owner>/<repo>
        CHECKS=$?
        [ "$CHECKS" -eq 8 ] || break
        sleep 60
    done
fi
```

If the rollup is empty after the pause, there are no checks, so treat it as passing and continue. Otherwise read the `CHECKS` the loop left behind:

- `0` → checks passed; continue.
- `8` → still pending after the full 30 minutes. Report the pending checks and the PR URL to the user, then stop this run without un-assigning the issue — the next run picks it up once CI has settled.
- anything else → a check failed. Fix it and push again, at most two fix attempts, and do **not** un-assign the issue while checks are red. If it's still red after that, or the failure needs human judgment, handle it like Step 4 (comment + `(Needs Info)`) and stop.

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
- Keep commit messages to one concise line, following your global commit conventions.
- Pull Request description should only have one short paragraph, with a link to the issue as "Fixes #<number>"
