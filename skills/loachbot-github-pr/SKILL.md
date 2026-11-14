---
name: loachbot-github-pr
description: Address your own review comments on a GitHub Pull Request - picks the most recently updated open draft PR authored by and assigned to you, makes the requested changes, gets CI green, then marks it ready for review. Use when the user wants to address feedback on their draft pull requests, or asks to "run LoachBot Pull Requests", including repeated runs like "until there aren't any left".
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

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents read, search, edit, and run builds, tests and linters.

Launch read-only sub-agents together in one message; they cannot collide. Keep sequential only writes (`git`, builds, formatters, codegen) and sub-agents that need an earlier answer.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

Verify what matters in a report: read the diff or re-run the command. Wait for every sub-agent you launched before reporting, and tell sub-agents that launch their own helpers to do the same.
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

Going most-recently-updated first, a PR is actionable unless its title ends with ` (Needs Info)`, meaning an earlier run [parked](#parking) it. For those, check for answers:

```bash
bash <this skill's directory>/scripts/check-parked.sh <owner> <repo> <number> pr
```

- **0** → answered; the PR is actionable. The printed replies are clarification for Steps 3-4 (they may come from other users, which Step 3 filters out).
- **6** → no answer yet. Skip the PR.
- **5** → the PR could not be read, or the suffix was added by hand. Skip it and tell the user.

Pick the first actionable PR; if none, report "Nothing to do" and stop. Search results lag, so confirm it is still an open draft:

```bash
gh pr view <number> --repo <owner>/<repo> --json state,isDraft
```

Proceed only if `state` is `OPEN` and `isDraft` is `true`; otherwise try the next candidate. If it was parked, strip the suffix ([Parking](#parking)).

Report the URL immediately:
> Working on: https://github.com/<owner>/<repo>/pull/<number>

### 2. Check out the pull request in a dedicated worktree

```bash
WT=$(bash <this skill's directory>/scripts/setup-github-worktree.sh <owner> <repo> pr <number>)
cd "$WT"
```

- **4** → another worktree (named on stderr) has the PR branch checked out, possibly the user's own. Report it and stop; never remove it or force-switch branches across worktrees.
<!-- SHARED: github-worktree-exit-9 -->
- **9** → a submodule could not be fetched (stderr names it); the worktree is still usable. If the work does not touch that submodule, continue without it. Otherwise [park](#parking) it, naming the submodule.
- Any other non-zero → stderr names the failing command. Report it and stop; do not force through.
<!-- /SHARED: github-worktree-exit-9 -->

### 3. Understand the Pull Request

Read the PR and your own feedback on it in one call:

```bash
bash <this skill's directory>/scripts/fetch-feedback.sh <owner> <repo> <number>
```

- **0** → one JSON line per `kind`: `pr` (`title`, `body`, `last_commit`), `review`, `comment` and `inline`, the comments with the numeric `id` Step 4 reacts to.
- **5** → a read failed (stderr names it). Report it and stop; a partial list would hide work.

Review summaries take no reactions; treat them as context. Address comments with `handled: false` (not yet 🚀'd). Handled comments stay binding: if one said a change is not needed, do not reintroduce it. For a resumed `(Needs Info)` PR, apply Step 1's answers to the comments they reply to.

Investigate what comments refer to via [Sub-agents](#sub-agents).

If there is nothing to address (no un-🚀'd comment, and no review summary newer than `last_commit`), the PR is a draft for another reason. Do **not** mark it ready. Run Step 6's cleanup without `gh pr ready`, tell the user why it was skipped, and return to Step 1.

### 4. Do the work

Address every comment from Step 3. Delegate per [Sub-agents](#sub-agents), passing `$WT` and the proving command; independent comments run concurrently.

Test where possible, then review `git status --short` and stage only the files the change meant to touch: delete stray artifacts (screenshots, test output) or leave them untracked, never commit them. Commit and push (the branch tracks the PR head):

```bash
git add <paths>
# Skip the empty commit when no code changed.
if ! git diff --cached --quiet; then
    git commit -m "<one-line message>"
    git push
fi
```

A comment asking to fix conflicts means rebase, never merge: `git fetch origin`, `git rebase origin/<base>` where `<base>` is `gh pr view <number> --json baseRefName --jq .baseRefName`, then `git push --force-with-lease` (a plain push is refused after a rebase). Regenerate conflicting generated or built files with the project's build rather than hand-merging them. If a conflict needs judgment, `git rebase --abort` and leave the comment unreacted.

A comment asking for a change in another repository (e.g. an upstream library) gets its own PR there. Work in a new worktree off that repo's base clone `<other-owner>/<other-repo>` under the projects directory (cloned if missing); never in a local clone with uncommitted work. Open the PR, link it in a reply to the comment, react 🚀 and remove that worktree; do not wait on its CI.

React 🚀 to each comment only once handled: the change was pushed, or you verified none is needed. Step 3 relies on this marker, so never react earlier:

```bash
# Regular PR comment:
gh api "repos/<owner>/<repo>/issues/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"

# Inline review comment:
gh api "repos/<owner>/<repo>/pulls/comments/<comment_id>/reactions" \
    --method POST --field content="rocket"
```

Leave comments needing human judgment or a design decision unreacted and move on. If **all** need it, [park](#parking) the PR and report to the user.

If the work deviates from the PR title or body, update them to match.

### 5. Verify CI before marking ready

Waits up to about 30 minutes:

```bash
bash <this skill's directory>/scripts/wait-for-checks.sh <owner> <repo> <number>
```

<!-- SHARED: github-wait-for-checks -->
- **0** → passed, or no CI. Continue.
- **8** → still pending, or status unreadable (stderr says which). Report it and the PR URL, then stop without un-assigning or marking ready; a later run picks it up.
- **1** → a check failed or was cancelled. Get the run id from `gh pr checks <pr-number> --repo <owner>/<repo> --json name,state,link`, read `gh run view <run-id> --repo <owner>/<repo> --log-failed`, fix and push. At most two attempts, never un-assigning or marking ready while red; if still red or it needs human judgment, [park](#parking) it, naming the failing checks.
<!-- /SHARED: github-wait-for-checks -->

### 6. Mark the Pull Request as ready

```bash
gh pr ready <number> --repo <owner>/<repo>
BRANCH=$(git rev-parse --abbrev-ref HEAD)   # capture while still inside the worktree
cd "${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/<owner>/<repo>"
git worktree remove "$WT" --force
git branch -D "$BRANCH"
```

Then report:
> Done: https://github.com/<owner>/<repo>/pull/<number>

List the `html_url` of any comment left unreacted (Step 4) under the Done line; the PR has left the draft pool, so this is the only place they surface.

## Rules

- One Pull Request per run; for more, see [Repeated runs](#repeated-runs).
- Never post comments except the single [parking](#parking) question and a reply linking a PR opened in another repository (Step 4); otherwise only react, rename, and update the PR title or body to match the work (Step 4).
- Run all git operations for a PR inside its worktree; never `git checkout`, `gh pr checkout` or commit in the base clone, which stays on the default branch.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
