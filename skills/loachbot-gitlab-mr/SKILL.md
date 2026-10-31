---
name: loachbot-gitlab-mr
description: Rebase a drupal.org merge request onto its target branch, resolve conflicts, and make every CI job green - including the lint jobs drupal.org's pipeline forgives behind a green badge - then hand it back for review. Takes the merge request you name, or searches your own open ones. Use when the user wants to rebase a drupal.org merge request, fix merge conflicts on one, fix pipeline or cspell/phpcs/phpstan/phpunit failures, or asks to "run LoachBot MRs", including repeated runs like "five times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-mr/SKILL.md
    license: MIT
---
# LoachBot GitLab Merge Request Fixer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) is on `PATH` for projects whose issues never moved to GitLab — Drupal core among them. Reads need no authentication. Without it, those merge requests can still be worked on, but the issue behind them cannot be read.
- Paths assume drupal.org's `project/` namespace. Sandboxes live under `sandbox/` instead, so set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for those; `LOACHBOT_GITLAB_HOST` likewise points the scripts at another GitLab.
- SSH access to `git.drupal.org`, which is what pushes to an issue fork use.
- `~/Projects` is where clones and worktrees go by default; `LOACHBOT_PROJECTS_DIR` overrides it. It is created if missing, so change it only if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`), `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE` when set) and `<iid>` before running them, and adapt anything that doesn't fit the merge request in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

`<tmp>` is a scratch directory made once per run with `mktemp -d`. Runs on different projects may overlap, so never use a fixed `/tmp` path.

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

<!-- SHARED: drupal-gotchas -->
## How drupal.org differs

Four things here are not what a GitLab habit expects. Each one fails quietly rather than loudly, so they are worth knowing before the first API call rather than after.

- **Two hostnames, one service.** The API lives at `git.drupalcode.org`; git itself lives at `git.drupal.org`. An API path on the git host and an SSH URL on the API host both fail. Take remote URLs from the API's own `ssh_url_to_repo` instead of composing them.
- **Two repositories per merge request.** It targets `project/<project>`, but its branch lives in a per-issue fork at `issue/<project>-<issue-id>`. Pushes go to the fork.
- **The pipeline is on the fork, except when it isn't.** GitLab runs a fork's merge request pipeline in the *parent* project when its author can push there, so a maintainer's own merge request keeps it on the project while a contributor's leaves it on the fork. Ask the wrong one and you get a flat `404`. Read `head_pipeline.project_id` from a single-merge-request read rather than assuming either; `source_project_id` is only the fallback for a payload that omits it.
- **A green pipeline can hide red jobs.** Drupal.org's CI template marks jobs `allow_failure: true`, so they fail without failing the pipeline — and the pipeline, the badge and `glab ci status` all then report success while those jobs are red. *Which* jobs is per-project configuration, not a fixed set: the lint jobs usually (`cspell`, `phpcs`, `phpstan`, `stylelint`), but `eslint`, `composer` variants and even `phpunit` variants carry it on some projects. So never match on a list of names — read each job's own `allow_failure` and treat a forgiven failure as a failure.

### The issue lives in one of two places

A merge request's issue number is the tail of its fork's path: `issue/ai_ckeditor-3615852` means `3615852`. What that number *means* depends on the project — a GitLab issue iid where the queue was migrated, a drupal.org node id where it never was (Drupal core and `eck` among them) — and the two numbering spaces overlap, so reading it in the wrong world returns a real but unrelated issue rather than nothing.

Never try both and keep whichever answers. One script decides the world first and then interprets the number; `read-issue.sh`'s header explains why that order matters:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-ref>
```

It returns one JSON object either way — `source`, `title`, `status`, `actionable`, `writable`, `url`, `description` — so nothing downstream has to care which world it came from. Act on its exit code:

- **0** → read. `actionable: false` means the issue is fixed, closed, postponed or already reviewed-and-tested: leave it alone. `writable: false` means `/do:` cannot be posted, so any handback goes to the user instead.
- **6** → unreadable in the world this project belongs to. Report it; do **not** try the other world.
- **7** → read, but it belongs to a different project, so the number was interpreted in the wrong world. Report it and discard the result.

Two `glab api` habits matter here: `-f` sends a plain string while `-F` types its value and reads `@path` as a file's contents, and `--paginate` prints one JSON array per page, so merge them with `jq -s 'add'`.
<!-- /SHARED: drupal-gotchas -->

Two more matter specifically for rebasing:

- **`has_conflicts` and `detailed_merge_status` are unreliable.** They sit at `unchecked` indefinitely and never settle, so filtering on them finds nothing and reports "nothing to do" forever. Conflicts are discovered by rebasing locally, which Step 3 does anyway.
- **The forgiven jobs are most of what this skill is for.** A merge request whose only problem is a red `cspell` — or a red `phpunit` variant, on a project that forgives those — looks finished from every angle except the one that counts.

## Workflow

### 1. Pick one merge request

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23`, or `ai_ckeditor!23`), take it and skip the search. It may be somebody else's: issue forks are shared, so that is allowed, but say whose it is when you report, and change nothing of theirs beyond the rebase and the CI fixes.

**Otherwise**, list your open merge requests with what each pipeline really says. Pass `<project>` when the user asked for one project, or when the working directory is a drupal.org checkout:

```bash
bash <this skill's directory>/scripts/find-mrs.sh [<project>]
```

Act on its exit code:

- **0** → one line per merge request: reference, target branch, the pipeline rollup and `failing=`, the count of red jobs including forgiven ones. Triage on `failing=`, not on the rollup.
- **6** → report "Nothing to do" and stop.
- **5** → the search could not be read. Report it and stop.

A merge request is **actionable** when either:

- `failing=` is above zero; or
- it no longer rebases cleanly onto its target branch, which only Step 3 can find out — so with nothing failing anywhere, take the most recently updated one and let the rebase decide.

Skip it when its title ends with ` (Needs Info)` unless the question has been answered:

```bash
bash <this skill's directory>/scripts/check-parked-mr.sh <project> <iid>
```

Act on its exit code:

- **0** → answered; the printed replies are clarification for Step 2. Actionable.
- **6** → nobody has answered yet. Skip it.
- **5** → nothing to measure replies against: either the merge request could not be read, or the suffix was added by hand. Skip it and mention it to the user.

Skip it when the issue behind it is already settled — RTBC means somebody is waiting to commit it and a force-push would reset that, and fixed, closed or postponed means it is not yours to pick up. Take the issue's number from the source fork's path rather than the branch name, which contributors do rename. Only an `issue/` fork carries one; a merge request from a branch on the project itself has no issue to read:

```bash
SOURCE_ID=$(glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>/merge_requests/<iid>" |
    jq -r '.source_project_id')
ISSUE_REF=$(glab api --hostname git.drupalcode.org "projects/$SOURCE_ID" |
    jq -r '.path_with_namespace | if startswith("issue/") then split("-") | last else empty end')
if [ -n "$ISSUE_REF" ]; then
    bash <this skill's directory>/scripts/read-issue.sh <project> "$ISSUE_REF" > <tmp>/issue.json
    jq -r '"\(.source) \(.status) actionable=\(.actionable) writable=\(.writable)"' <tmp>/issue.json
fi
```

Act on the result, per [The issue lives in one of two places](#the-issue-lives-in-one-of-two-places):

- `actionable: false` → skip this merge request and say which status stopped you.
- Exit **6** or **7** → skip it and report why. This is why a Drupal core merge request needs `drupalorg` installed: without it the read fails closed, and failing closed is the point — a silently skipped RTBC check is how a rebase lands on work somebody was about to commit.
- An empty `ISSUE_REF` → there is no issue to check. Carry on, tell the user, and skip the Step 6 handback.

Once you pick one, strip any ` (Needs Info)` suffix from its title and report the URL to the user immediately:

```bash
glab mr update <iid> -R git.drupalcode.org/<namespace>/<project> --title "<original title without the suffix>"
```

> Working on: https://git.drupalcode.org/\<namespace\>/\<project\>/-/merge_requests/\<iid\>

### 2. Understand it

Read the merge request, then the issue behind it — the issue is where the actual requirement is written, and the merge request description is often one line.

```bash
glab mr view <iid> -R git.drupalcode.org/<namespace>/<project>
jq -r '"\(.title)\n\n\(.description)"' <tmp>/issue.json   # written in Step 1
```

Maintainer comments are the instructions to trust. Read them, and any answers Step 1 gathered from a parked run, then [fan out](#sub-agents) sub-agents to investigate what they refer to — one per question, all in one message, file contents kept out of the main thread.

### 3. Rebase it

Each merge request gets its own worktree, so branches can never bleed into each other. The base clone at `~/Projects/drupalcode/<project>` stays put; the worktree lives beside it at `~/Projects/drupalcode/<project>.worktrees/mr-<iid>`.

```bash
WT=$(bash <this skill's directory>/scripts/setup-mr-worktree.sh <project> <iid> | tail -1)
cd "$WT"
```

The script reads both repositories from the API, clones on first use, adds `upstream` and `fork` remotes, recreates the worktree from the fork's branch, and rebases onto the target branch. Read its header for the details.

Act on its exit code:

- **3** — the rebase conflicted and has already been aborted. Resolve it only if the conflict is mechanical and you can say exactly why your resolution is right; a conflict in logic you did not write is a Step 5 park, not a guess. Never keep working in a half-rebased worktree.
- **4** — the branch is checked out by another, still-live worktree. Remove it (`git worktree remove <stale-path> --force`, then `git worktree prune`) and run the script again.
- **5** — the merge request or its fork could not be read. Report it and stop.

To resolve a conflict by hand, rebase inside the worktree, fix the files, and continue:

```bash
git rebase upstream/<target-branch>
# resolve, then:
git add <paths>
GIT_EDITOR=true git rebase --continue
```

### 4. Make every job green

Push the rebase to the **fork**, then verify per-job:

```bash
git push --force-with-lease fork "HEAD:<source-branch>"
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> <iid> "$(git rev-parse HEAD)"
```

`--force-with-lease` is what makes a rebase safe to push: it replaces the rewritten history, and still refuses if somebody else moved the branch meanwhile. Never plain `--force` — issue forks are shared, and another contributor's commits are easy to erase.

Act on the script's exit code:

- **0** → every job passed. Continue.
- **1** → jobs failed, listed with `(allow_failure)` on the forgiven ones. **Fix all of them, forgiven or not.** A forgiven job red on a green pipeline is exactly the failure this skill exists to catch, and leaving it is how it accumulated in the first place. Delegate per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; at most two fix-and-push attempts, then park per Step 5.
- **7** → the pipeline could not be read. Unknown is not passing: report it with the merge request URL and stop.
- **8** → still running after the full wait. Report the pending jobs and the URL, then stop without handing back — a later run picks it up once CI has settled.

Read a failing job's log before guessing from its name, then reproduce it locally. The script prints the pipeline's project and each failing job's id — use that project, not the fork, because the pipeline may have run in the parent:

```bash
glab api --hostname git.drupalcode.org "projects/<pipeline-project>/jobs/<job-id>/trace"
```

Only the change the issue asked for belongs in the commits. A `phpcs` sweep across files the merge request never touched buries the review — fix the jobs for *this* branch's diff, and mention anything broader to the user instead.

### 5. When it's unclear

If the conflict needs judgment you don't have, or CI stays red for a reason a human has to decide, post one short question and park the merge request by appending ` (Needs Info)` to its title, then stop.

Comment first, rename second. The parking rename has to be the newest event you leave behind: Step 1 treats anything posted after it as the reply that un-parks the merge request, so renaming first would make your own question un-park it immediately and loop forever.

```bash
glab mr note create <iid> -R git.drupalcode.org/<namespace>/<project> -m "<one short question>"
glab mr update <iid> -R git.drupalcode.org/<namespace>/<project> --title "<original title> (Needs Info)"
```

Do not change the issue's state labels when parking — the question is the signal.

### 6. Hand it back

Only when Step 1 found an issue and its `writable` was `true`. A drupal.org-only issue has no `/do:` path — its status moves through the web UI — so report the merge request as finished, link the issue's `url`, and tell the user to set it to *Needs review* themselves.

This skill fixes rebases and CI, not review findings. If the merge request has unresolved review threads, they are still somebody's to answer, and moving the issue to needs-review would bury them:

```bash
glab api --hostname git.drupalcode.org --paginate \
    "projects/<namespace>%2F<project>/merge_requests/<iid>/discussions?per_page=100" |
    jq -s 'add | map(select(.notes[0].resolvable and (.notes[0].resolved | not))) | length'
```

Anything above `0` → post nothing. Report the merge request as rebased and green, say how many review threads are still open, and leave the state to the user.

Otherwise, check whether the issue is assigned to you — an Issue Fixer run that stopped on CI leaves it that way — and include `/do:unassign me` only if it is:

```bash
glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>/issues/<issue-id>" |
    jq -r '[.assignees[].username] | join(",")'
```

Then post the handback. The `/do:` lines are drupalbot commands, so post them **verbatim** and do not translate them into GitLab quick actions:

```bash
glab issue note <issue-id> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
Rebased onto the target branch and the pipeline is green.

/do:unassign me
/do:label ~"state::needsReview"
EOF
)"
```

Then remove the worktree and its local branch — the work is pushed, so nothing is lost:

```bash
cd ~/Projects/drupalcode/<project>
git worktree remove ~/Projects/drupalcode/<project>.worktrees/mr-<iid> --force
git branch -D mr-<iid>
```

Report the merge request URL to the user:

> Done: https://git.drupalcode.org/\<namespace\>/\<project\>/-/merge_requests/\<iid\>

## Rules

- Work on exactly one merge request per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run, one run at a time — search results lag behind reality, so a just-finished merge request still appears on an immediate re-run and two overlapping runs would both pick it. Stop early when a run reports "Nothing to do". Within a single run, delegate per [Sub-agents](#sub-agents) and fan independent investigation out concurrently; the main thread keeps orchestration and the git/push/handback steps.
- Push to the `fork` remote, never to `upstream`. A drupal.org project's branches are not yours to rewrite, and `--force-with-lease` is the only acceptable force.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. Every LoachBot skill that clones shares `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org) with its siblings, and one run fetching, resetting or deleting branches under another corrupts both. Runs on different clones may overlap freely, and so may the sub-agents within a run.
<!-- /SHARED: one-run-per-clone -->
- All git operations for a merge request must run inside that merge request's worktree: never run `git checkout`, branch creation, or commits from the base clone.
- Never post comments except the one question that parks a merge request (Step 5) and the handback (Step 6), and skip the handback while review threads are unresolved.
- Never set `state::rtbc`, and never merge. Review and commit belong to the project's maintainers.
- Keep the diff to what the issue asked for. Unrelated lint fixes, formatting sweeps and version bumps do not belong in someone else's merge request.
- Keep commit messages to one concise line. Drupal.org convention is `Issue #<issue-id>: <short description>`.
