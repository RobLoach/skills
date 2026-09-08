---
name: loachbot-github-pr
description: Autonomous GitHub Pull Request Fixer agent called LoachBot. Scans GitHub for your own draft Pull Requests, addresses your review comments, then marks the Pull Request ready for review. Use when the user wants to address feedback on their draft pull requests, or asks to "run LoachBot Pull Requests", including repeated runs like "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-pr/SKILL.md
    license: MIT
---

# LoachBot GitHub Pull Request Fixer

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable: the default location for clones and worktrees; adjust if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<owner>`, `<repo>`, and `<number>` before running them, and adapt anything that doesn't fit the repository in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

## Workflow

### 1. Find a Pull Request

The search spans every repository by default. Scope it first, in this order:

1. A repo named in the prompt or skill arguments (URL or `owner/repo`): add `--repo <owner>/<repo>`.
2. Otherwise, if the user asked to work "on this project" and the current working directory is a git repo, use its `origin` remote: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`, and add `--repo` for that.
3. Otherwise search account-wide, as below.

```bash
# Open draft Pull Requests I authored that are assigned to me, newest activity first.
# Add `--repo <owner>/<repo>` when the run is scoped to one repository.
gh search prs --draft --author=@me --assignee=@me --state=open --sort=updated --limit=30 \
    --json number,title,url,repository \
    --jq '.[] | {number, title, url, repo: .repository.nameWithOwner}'
```

If no items are found, report "Nothing to do" and stop.

For each PR (most-recently-updated first), decide whether it's actionable from the ` (Needs Info)` title suffix:

- Title does **not** end with ` (Needs Info)` → actionable.
- Title ends with ` (Needs Info)` → a previous run asked a question and parked it (Step 4). Find that parking rename, then look for anything posted since — a reply can be a regular comment or an inline review comment:
    ```bash
    # A parking run comments first and renames second, so the parking rename is the newest
    # event it leaves behind. Take the most recent one: a PR can be parked, answered and
    # re-parked any number of times.
    PARKED=$(gh api --paginate "repos/<owner>/<repo>/issues/<number>/events" \
        --jq '.[] | select(.event == "renamed" and (.rename.to | endswith("(Needs Info)"))) | .created_at' | tail -1)

    # `export` so the filters below can read the timestamp as `env.PARKED`.
    export PARKED
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, body}'
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/comments" \
        --jq '.[] | select(.created_at > env.PARKED) | {author: .user.login, created_at, path, body}'
    ```
    Three outcomes:
    - `$PARKED` is empty → no parking rename exists, so the suffix was added by hand and there is nothing to measure replies against. Skip the PR and mention it to the user.
    - Either query returned replies → the question was answered. Keep them for Steps 3-4; they may come from other users, so Step 3's `$AUTHOR` filters won't resurface them. The PR is actionable.
    - No replies → nobody has answered yet. Skip the PR.

Pick the first actionable PR. If none are actionable, report "Nothing to do" and stop.

Search results can lag behind reality, so a PR just marked ready may still appear on an immediate re-run. Before starting, confirm the picked PR is still an open draft:

```bash
gh pr view <number> --repo <owner>/<repo> --json state,isDraft
```

Proceed only if `state` is `OPEN` and `isDraft` is `true`; otherwise skip it and evaluate the next candidate.

When the picked PR was parked, strip the suffix from its title before doing the work:

```bash
gh pr edit <number> --repo <owner>/<repo> --title "<original title without ' (Needs Info)'>"
```

Once you pick a PR, report its URL to the user immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the pull request in a dedicated worktree

Each PR gets its own git worktree so branches can never bleed into each other. The base clone at `~/Projects/<owner>/<repo>` stays on the default branch; per-PR worktrees live under `~/Projects/<owner>/<repo>.worktrees/pr-<number>` and are deleted after the run is complete.

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <owner> <repo> <number> | tail -1)
cd "$WT"
```

The script clones on first use, discards uncommitted leftovers from an interrupted run, checks the PR head out with `gh pr checkout` (which resolves fork remotes), and syncs submodules. Read its header for the details.

Recovery paths, by exit code:

- **4** — the PR branch is checked out by another worktree left behind by an earlier run. Remove it (`git worktree remove <stale-path>`) and run the script again; do **not** force-switch branches across worktrees.
- Any other non-zero — checkout failed, for instance because the local branch diverged. Stop and report; do not force through it.

### 3. Understand the Pull Request

Determine your own login once, then reuse it for every filter. `export` it so the `--jq` filters below can read it as `env.AUTHOR`:

```bash
export AUTHOR
AUTHOR=$(gh api user --jq '.login')
```

- Read the full body of the pull request: `gh pr view <number> --repo <owner>/<repo> --json title,body`
- Fetch regular PR comments you authored. Use the REST endpoint: it returns the numeric `id` the reaction endpoints in Step 4 require (`gh pr view --json comments` returns GraphQL node IDs, which do not work there):
    ```bash
    gh api --paginate "repos/<owner>/<repo>/issues/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, body, rockets: .reactions.rocket}'
    ```
- Fetch inline review comments you authored:
    ```bash
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/comments" \
        --jq '.[] | select(.user.login == env.AUTHOR) | {id, created_at, html_url, path, body, rockets: .reactions.rocket}'
    ```
- Fetch review summaries you authored (the body written when submitting a review): they often carry the overall instructions the inline comments assume:
    ```bash
    gh api --paginate "repos/<owner>/<repo>/pulls/<number>/reviews" \
        --jq '.[] | select(.user.login == env.AUTHOR and .body != "") | {id, submitted_at, body}'
    ```
    Review bodies do not support reactions, so treat them as instructions and context for the run; the 🚀 tracking below applies only to regular and inline comments.
- Skip any comment with `rockets > 0` in the fetches above: a 🚀 reaction marks it as already acted upon (Step 4 adds it only once the work is handled). The count cannot distinguish your own reaction from LoachBot's — both run under the same account — so 🚀 is reserved for this marker; if the user has been using it as ordinary emphasis, say so rather than silently skipping their comments.
- If you resumed a `(Needs Info)` PR, fold in the answers gathered in Step 1 as clarification for the comments they reply to — they may be authored by other users, so the `$AUTHOR` filters above won't surface them.

Run the comment, inline-comment, and review-summary fetches in parallel. Use subagents for any codebase investigation a comment requires.

### 4. Do the work

Address all the comments you left (the ones filtered to `$AUTHOR` in Step 3). For anything beyond a small edit, delegate to a subagent (`cd "$WT"`, make the change, test, report back). Independent comments can be worked in parallel subagents. The main thread keeps the git/reaction/ready steps.

Test where possible, then commit and push back to the PR: the branch already tracks the PR head from `gh pr checkout`, so a plain push suffices:

```bash
git add -A
# Nothing staged means the addressed comments needed no code changes, so skip the empty commit.
if ! git diff --cached --quiet; then
    git commit -m "<concise message>"
    git push
fi
```

React with a 🚀 to each comment that was addressed, only once it has actually been handled — the change was pushed, or you verified no change is needed. A comment verified to need no code change still counts as addressed. The reaction is the persistent "already handled" marker Step 3 relies on, so never react before that point:

```bash
# Regular PR comment:
gh api "repos/<owner>/<repo>/issues/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"

# Inline review comment:
gh api "repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"
```

If a comment requires human judgment or a design decision that can't be resolved autonomously, leave it unreacted and continue to the next comment. If **all** comments require human judgment (none were acted upon), park the PR so later runs skip it until someone replies: post one short question naming what you need, then append ` (Needs Info)` to the title. Report this to the user and stop. Do not mark the PR as ready.

Comment first, rename second. The parking rename has to be the newest event you leave behind: Step 1 treats anything posted after it as the reply that un-parks the PR, so renaming first would make your own question un-park it immediately and loop forever.

```bash
gh pr comment <number> --repo <owner>/<repo> --body "<one short question>"
gh pr edit <number> --repo <owner>/<repo> --title "<original title> (Needs Info)"
```

Finally, if the changes made deviate from what the original PR title or body described, update them to accurately reflect the work done.

### 5. Verify CI before marking ready

The script waits out the delay before checks register, probes several times before believing a repo has no CI, and bounds the wait at about 30 minutes:

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> <number>
```

Act on its exit code:

- **0** → checks passed, or the repo has no CI. Continue to Step 6.
- **8** → still pending after the full wait. Report the pending checks and the PR URL to the user, then stop this run without marking the PR ready — it stays draft, and the next run picks it up once CI has settled.
- **7** → the check status could not be read at all. Unknown is not passing: report it and the PR URL, then stop without marking the PR ready.
- **1** → a check failed. Fix it and push again, at most two fix attempts, and do **not** mark the PR ready while checks are red. If it's still red after that, or the failure needs human judgment, park the PR so later runs skip it instead of re-picking it forever — comment then rename, exactly as in Step 4, saying which checks are failing — then stop.

### 6. Mark the Pull Request as ready

```bash
gh pr ready <number> --repo <owner>/<repo>
BRANCH=$(git rev-parse --abbrev-ref HEAD)   # capture while still inside the worktree
cd ~/Projects/<owner>/<repo>
git worktree remove ~/Projects/<owner>/<repo>.worktrees/pr-<number> --force
git branch -D "$BRANCH"
```

Then report the completed PR URL to the user:
> Done: https://github.com/<owner>/<repo>/pull/<number>

If any comments were left unreacted because they need human judgment (Step 4), list their `html_url`s under the Done line: the PR has left the draft pool, so this report is the only place they surface.

## Rules

- Work on exactly one Pull Request per run, most recently updated first. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run — sequentially, never in parallel — and stop early when a run reports "Nothing to do". Within a single run, use subagents for codebase reads and implementation; keep the main thread for orchestration and git/reaction/ready steps.
- Never post comments except the single question that parks a Pull Request (Steps 4 and 5). Otherwise, react and rename only, as described above.
- All git operations for a PR must run inside that PR's worktree: never run `git checkout`, `gh pr checkout`, or commits from the base clone.
- Only one LoachBot skill at a time may run against a given repository. All three share the base clone at `~/Projects/<owner>/<repo>`, and a concurrent run fetching, deleting branches or resetting it underneath you will corrupt this one. If the user asks for overlapping runs, do them one after another.
- Keep commit messages to one concise line, following your global commit conventions.
