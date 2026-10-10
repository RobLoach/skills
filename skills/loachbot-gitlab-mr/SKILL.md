---
name: loachbot-gitlab-mr
description: Autonomous drupal.org merge request maintainer called LoachBot. Rebases one of your open merge requests onto its target branch, resolves conflicts, and makes every CI job green - including the lint jobs drupal.org's pipeline forgives and hides. Use when the user wants to rebase a drupal.org merge request, fix merge conflicts on one, fix pipeline or cspell/phpcs/phpstan/phpunit failures, or asks to "run LoachBot MRs", including repeated runs like "run LoachBot MRs five times" or "until there aren't any left".
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

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`) and `<iid>` before running them, and adapt anything that doesn't fit the merge request in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

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

For anything about `glab` itself — note bodies, threaded replies, `--field` versus `--raw-field` — defer to the `glab` skill rather than guessing.
<!-- /SHARED: drupal-gotchas -->

Two more matter specifically for rebasing:

- **`has_conflicts` and `detailed_merge_status` are unreliable.** They sit at `unchecked` indefinitely and never settle, so filtering on them finds nothing and reports "nothing to do" forever. Conflicts are discovered by rebasing locally, which Step 3 does anyway.
- **The forgiven jobs are most of what this skill is for.** A merge request whose only problem is a red `cspell` — or a red `phpunit` variant, on a project that forgives those — looks finished from every angle except the one that counts.

## Workflow

### 1. Pick one merge request

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23`, or `ai_ckeditor!23`), take it. That is the common case; skip the search entirely.

**Otherwise**, search for your open merge requests, most recently updated first:

```bash
AUTHOR_ID=$(glab api --hostname git.drupalcode.org user | jq -r '.id')
glab api --hostname git.drupalcode.org \
    "merge_requests?author_id=$AUTHOR_ID&state=opened&scope=all&order_by=updated_at&sort=desc&per_page=30" |
    jq -r '.[] | "\(.references.full)\t\(.target_branch)\t\(.title)"'
```

Scope it to one project when the user asked for that, or when the working directory is a drupal.org checkout: add `&target_project_id=<id>`, or filter the output on `project/<project>`.

If nothing comes back, report "Nothing to do" and stop.

The list response is a **summary**: it omits `head_pipeline` entirely. Triage needs a single-merge-request read per candidate, which is a read, so [fan them out](#fan-out) rather than walking the list:

```bash
glab api --hostname git.drupalcode.org "projects/project%2F<project>/merge_requests/<iid>" |
    jq -r '{iid, title, draft, target_branch, source_branch, source_project_id,
            pipeline: .head_pipeline.id, pipeline_status: .head_pipeline.status}'
```

A merge request is **actionable** when it is open, authored by you, and either:

- a job in its pipeline is failing — including an `allow_failure` one, which the rollup hides; or
- it no longer rebases cleanly onto its target branch, which Step 3 finds out.

Skip it when its title ends with ` (Needs Info)` unless the question has been answered:

```bash
bash <this skill's directory>/scripts/check-parked-mr.sh <project> <iid>
```

Act on its exit code:

- **0** → answered; the printed replies are clarification for Step 2. Actionable.
- **6** → nobody has answered yet. Skip it.
- **5** → nothing to measure replies against: either the merge request could not be read, or the suffix was added by hand. Skip it and mention it to the user.

Skip it when the issue behind it is already settled — RTBC means somebody is waiting to commit it and a force-push would reset that, and fixed, closed or postponed means it is not yours to pick up. Take the issue's number from the source fork's path rather than the branch name, which contributors do rename, then read it per [The issue lives in one of two places](#the-issue-lives-in-one-of-two-places):

```bash
ISSUE_REF=$(glab api --hostname git.drupalcode.org "projects/<source-project-id>" |
    jq -r '.path_with_namespace | split("-") | last')
bash <this skill's directory>/scripts/read-issue.sh <project> "$ISSUE_REF" > /tmp/issue.json
jq -r '"\(.source) \(.status) actionable=\(.actionable) writable=\(.writable)"' /tmp/issue.json
```

`actionable: false` → skip this merge request and say which status stopped you. This check is the reason a Drupal core merge request needs `drupalorg` installed: without it the read fails closed with exit **6**, and failing closed is the point — a silently skipped RTBC check is how a rebase lands on top of work somebody was about to commit.

Once you pick one, strip any ` (Needs Info)` suffix from its title and report the URL to the user immediately:

```bash
glab mr update <iid> -R git.drupalcode.org/project/<project> --title "<original title without the suffix>"
```

> Working on: https://git.drupalcode.org/project/\<project\>/-/merge_requests/\<iid\>

### 2. Understand it

Read the merge request, then the issue behind it — the issue is where the actual requirement is written, and the merge request description is often one line.

```bash
glab mr view <iid> -R git.drupalcode.org/project/<project>
jq -r '"\(.title)\n\n\(.description)"' /tmp/issue.json   # written in Step 1
```

Maintainer comments are the instructions to trust. Read them, and any answers Step 1 gathered from a parked run, then [fan out](#fan-out) sub-agents to investigate what they refer to — one per question, all in one message, file contents kept out of the main thread.

Not every project keeps its issues in GitLab. Where they have been migrated — including projects serving them as work items at `/-/work_items/<id>` — the `issues` API path above reads them. Where they have not, that path returns a flat `404` and the issue exists only on drupal.org; Drupal core itself is in this group. Treat the `404` as "no issue record here", review the merge request on its own terms, and tell the user you could not read the issue rather than assuming there isn't one.

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
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> <iid>
```

`--force-with-lease` is what makes a rebase safe to push: it replaces the rewritten history, and still refuses if somebody else moved the branch meanwhile. Never plain `--force` — issue forks are shared, and another contributor's commits are easy to erase.

Act on the script's exit code:

- **0** → every job passed. Continue.
- **1** → jobs failed, listed with `(allow_failure)` on the forgiven ones. **Fix all of them, forgiven or not.** A forgiven job red on a green pipeline is exactly the failure this skill exists to catch, and leaving it is how it accumulated in the first place. Delegate per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; at most two fix-and-push attempts, then park per Step 5.
- **7** → the pipeline could not be read. Unknown is not passing: report it with the merge request URL and stop.
- **8** → still running after the full wait. Report the pending jobs and the URL, then stop without handing back — a later run picks it up once CI has settled.

Reproduce lint failures locally rather than guessing from a job name; read the trace first:

```bash
glab api --hostname git.drupalcode.org "projects/<source-project-id>/jobs/<job-id>/trace"
```

Only the change the issue asked for belongs in the commits. A `phpcs` sweep across files the merge request never touched buries the review — fix the jobs for *this* branch's diff, and mention anything broader to the user instead.

### 5. When it's unclear

If the conflict needs judgment you don't have, or CI stays red for a reason a human has to decide, post one short question and park the merge request by appending ` (Needs Info)` to its title, then stop.

Comment first, rename second. The parking rename has to be the newest event you leave behind: Step 1 treats anything posted after it as the reply that un-parks the merge request, so renaming first would make your own question un-park it immediately and loop forever.

```bash
glab mr note create <iid> -R git.drupalcode.org/project/<project> -m "<one short question>"
glab mr update <iid> -R git.drupalcode.org/project/<project> --title "<original title> (Needs Info)"
```

Do not change the issue's state labels when parking — the question is the signal.

### 6. Hand it back

With every job green, move the issue to needing review. On drupal.org the `/do:` lines in an issue comment are what drive this; they are bot commands, so post them **verbatim** and do not translate them into GitLab quick actions:

```bash
glab issue note <issue-id> -R git.drupalcode.org/project/<project> -m "$(cat <<'EOF'
Rebased onto the target branch and the pipeline is green.

/do:unassign me
/do:label ~"state::needsReview"
EOF
)"
```

Only when `writable` was `true` in Step 1. A drupal.org-only issue has no `/do:` path at all — its status moves through the web UI — so do not attempt this and do not retry it elsewhere. Report the merge request as finished, link the issue's `url`, and tell the user to set it to *Needs review* themselves.

Then remove the worktree and its local branch — the work is pushed, so nothing is lost:

```bash
cd ~/Projects/drupalcode/<project>
git worktree remove ~/Projects/drupalcode/<project>.worktrees/mr-<iid> --force
git branch -D mr-<iid>
```

Report the merge request URL to the user:

> Done: https://git.drupalcode.org/project/\<project\>/-/merge_requests/\<iid\>

## Rules

- Work on exactly one merge request per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run, one run at a time — search results lag behind reality, so a just-finished merge request still appears on an immediate re-run and two overlapping runs would both pick it. Stop early when a run reports "Nothing to do". Within a single run, delegate per [Sub-agents](#sub-agents) and fan independent investigation out concurrently; the main thread keeps orchestration and the git/push/handback steps.
- Push to the `fork` remote, never to `upstream`. A drupal.org project's branches are not yours to rewrite, and `--force-with-lease` is the only acceptable force.
- Runs collide only through the base clone they share, so that is what the limit is about. Two runs against the same clone must not overlap: one fetching, deleting branches or resetting it underneath the other corrupts both. Runs against *different* clones are independent and may overlap freely — this skill clones to `~/Projects/drupalcode/<project>`, so it can never collide with a GitHub LoachBot run at `~/Projects/<owner>/<repo>`, and the two may run side by side. This bounds whole runs, not the sub-agents within one, which fan out per [Fan out](#fan-out).
- All git operations for a merge request must run inside that merge request's worktree: never run `git checkout`, branch creation, or commits from the base clone.
- Never post comments except the one question that parks a merge request (Step 5) and the handback (Step 6).
- Never set `state::rtbc`, and never merge. Review and commit belong to the project's maintainers.
- Keep the diff to what the issue asked for. Unrelated lint fixes, formatting sweeps and version bumps do not belong in someone else's merge request.
- Keep commit messages to one concise line. Drupal.org convention is `Issue #<issue-id>: <short description>`.
