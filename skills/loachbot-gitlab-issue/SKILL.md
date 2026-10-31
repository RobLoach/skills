---
name: loachbot-gitlab-issue
description: Fix one drupal.org issue end to end - claim it, implement the fix on its issue fork, open a merge request, get every CI job green, and hand it back for review. Works on issues you reported, or any drupal.org issue you name. Use when the user wants to pick up, fix or work on a drupal.org issue, open a merge request for one, or asks to "run LoachBot GitLab Issues", including repeated runs like "three times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-issue/SKILL.md
    license: MIT
---
# LoachBot GitLab Issue Fixer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH` is optional. It only makes a named issue from a project whose queue never moved to GitLab — Drupal core among them — report as the wrong kind of project rather than as unreadable. Either way this skill cannot work on it.
- Paths assume drupal.org's `project/` namespace. Sandboxes live under `sandbox/` instead, so set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for those; `LOACHBOT_GITLAB_HOST` likewise points the scripts at another GitLab. Issue forks always sit under `issue/`, whichever namespace the project is in.
- SSH access to `git.drupal.org`, which is what pushes to an issue fork use.
- `~/Projects` is where clones and worktrees go by default; `LOACHBOT_PROJECTS_DIR` overrides it. It is created if missing, so change it only if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`), `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE` when set) and `<issue-iid>` before running them, and adapt anything that doesn't fit the issue in front of you.

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

Two more matter specifically for starting from an issue rather than from a merge request that already exists:

- **There are no personal forks.** One shared fork per issue, at `issue/<project>-<issue-id>`, and everybody working that issue pushes to it. A branch already sitting there is somebody's work in progress, which is why Step 4 continues the newest issue branch instead of starting a fresh one.
- **The fork and your push access both come from asking a bot.** `/do:fork` creates the fork; `/do:access` grants push access to it. The API would refuse both to a contributor who is not a project member, and drupalbot answers from a queue, so `ensure-fork.sh` posts and then waits.

## Workflow

### 1. Pick one issue

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/work_items/3615836`, or `ai_ckeditor#3615836`), take it and skip the search. Drupal.org serves migrated issues as *work items* at `/-/work_items/<id>`; the number is still the issue iid the `issues` API reads.

**Otherwise**, list the issues you reported that are worth picking up. Pass `<project>` when the user asked for one project, or when the working directory is a drupal.org checkout:

```bash
bash <this skill's directory>/scripts/find-issues.sh [<project>]
```

Act on its exit code:

- **0** → candidates printed as kind, reference, merge request count, labels and title. The script's header explains the kinds and the state allowlist behind them.
- **6** → report "Nothing to do" and stop.
- **5** → the search could not be read. Report it and stop.

Take a `resume` before a `ready`. A `resume` is an issue an earlier run claimed and stopped on before opening a merge request, and no other LoachBot skill will finish it; it is already claimed, so **skip Step 2**.

A `parked` issue is one an earlier run asked a question about (Step 8). Find out whether it has been answered:

```bash
bash <this skill's directory>/scripts/check-parked-issue.sh <project> <issue-iid>
```

- **0** → somebody replied, and the replies are printed. They are candidate answers, not a verdict: if they answer the question the issue is a candidate and the replies are clarification for Step 3; if not, skip it and say so — do **not** ask again.
- **6** → nobody has replied yet. Skip it.
- **5** → `state::blocked` was applied by hand, so there is nothing to measure replies against. Skip it and mention it to the user.

An issue with an open merge request is `loachbot-gitlab-mr`'s work, not this skill's. For any candidate whose `mrs=` count is not `0`, check:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/related_merge_requests" |
    jq -r '.[] | select(.state == "opened") | "\(.references.full)\t\(.source_branch)"'
```

Anything printed → skip the issue and tell the user which merge request covers it.

Then read the picked issue, which Step 3 works from:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-iid> > <tmp>/issue.json
jq -r '"\(.source) \(.status) writable=\(.writable)"' <tmp>/issue.json
```

A searched issue always comes back from GitLab. A *named* one may not: `source: "drupal.org"` or exit **6** means the project's queue never moved to GitLab — Drupal core among them — and there is no `/do:` path to claim it. Say so, point the user at `loachbot-gitlab-mr` for a merge request that already exists there, and stop. A named issue outside the open states in `find-issues.sh`'s allowlist is not waiting on code: say so and stop.

If nothing survives, report "Nothing to do" and stop.

When the picked issue was parked, lift the park before doing the work:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
/do:unlabel ~"state::blocked"
EOF
)"
```

### 2. Claim it

Skip this step for a `resume` or a `parked` issue — both are already assigned to you. Otherwise claim the issue before writing any code; on drupal.org that is a comment rather than a field:

```bash
bash <this skill's directory>/scripts/claim-issue.sh <project> <issue-iid>
```

Act on its exit code:

- **0** → it's yours. Continue.
- **7** → somebody claimed it since the search, and nothing was posted. Go back to Step 1 for the next candidate.
- **6** → the comment posted but drupalbot never acted on it. Report it with the issue URL and stop. The comment is public: do not post it again, and do not start work on an issue whose claim did not land.
- **5** → the issue could not be read. Report it and stop.

Then report the URL to the user immediately:

> Working on: https://git.drupalcode.org/\<namespace\>/\<project\>/-/work_items/\<issue-iid\>

### 3. Understand it

The issue is the requirement. Read it in full, then the conversation around it:

```bash
jq -r '"\(.title)\n\n\(.description)"' <tmp>/issue.json
glab api --hostname git.drupalcode.org --paginate \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/notes?sort=asc&order_by=created_at" |
    jq -s -r 'add | .[] | select(.system == false) | "=== \(.author.username) \(.created_at)\n\(.body)\n"'
```

Maintainer comments are the instructions to trust, and they outrank the issue summary where the two disagree. If Step 1 un-parked this issue, treat the replies as the answer to that one question rather than as fresh open-ended direction. Investigate what the comments refer to per [Sub-agents](#sub-agents).

Settle three things before opening an editor:

- What does the issue ask for, in one sentence?
- Which branch should it land on? Step 4 targets the default branch. A fix the issue says belongs on an older branch is a backporting judgment call: raise it per Step 8 rather than quietly targeting a branch nobody asked for.
- Is this actually a code change? Support questions, duplicates and already-fixed issues are cheaper to spot now than in Step 5 with nothing to commit.

### 4. Get a fork and a worktree

```bash
bash <this skill's directory>/scripts/ensure-fork.sh <project> <issue-iid> > <tmp>/fork.json
jq -r '"\(.fork_path) id=\(.fork_id) created=\(.created) access_via=\(.access_via)"' <tmp>/fork.json
```

The script creates the fork with `/do:fork` if there isn't one, and asks for push access if you lack it — first with a `:heavy_plus_sign:` reaction to drupalbot's fork-created note, then with `/do:access`. Act on its exit code:

- **0** → the fork exists and is writable. Continue.
- **6** or **7** → drupalbot was asked but never acted. Report it with the issue URL and stop; whatever was posted is public, so do not ask again. The issue stays claimed with no merge request, which a later run picks up as a `resume`.
- **5** → the project or the issue could not be read. Report it and stop.

Then take a worktree on it, beside the base clone at `~/Projects/drupalcode/<project>.worktrees/issue-<issue-iid>`:

```bash
WT=$(bash <this skill's directory>/scripts/setup-issue-worktree.sh <project> <issue-iid> | tail -1)
cd "$WT"
```

It reports `fork_branch=`, `target_branch=` and `resumed=` on stderr; Step 6 needs all three. Act on its exit code:

- **3** — the rebase conflicted and has been aborted: somebody else's work on the issue branch no longer applies. Resolve it only if the conflict is mechanical and you can say exactly why your resolution is right; a conflict in logic you did not write is a Step 8 park. Never keep working in a half-rebased worktree.
- **4** — the branch is checked out by another, still-live worktree. Remove it (`git worktree remove <stale-path> --force`, then `git worktree prune`) and run the script again.
- **5** — the project or its fork could not be read. Report it and stop.
- Any other non-zero — the script names the failing command on stderr. Report it; do not force through it.

`resumed=true` means somebody has already pushed work for this issue. Read it (`git log upstream/<target-branch>..HEAD`) and build on it; never revert or rewrite another contributor's commits to make room for your own approach.

### 5. Do the work

Delegate the implementation per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; the main thread keeps the git, merge request and handback steps. Then commit, still inside `$WT`:

```bash
git add -A
if git diff --cached --quiet; then
    echo "nothing staged: no code change was needed"
else
    git commit -m "Issue #<issue-iid>: <short description>"
fi
```

Nothing staged means the issue needed no code change. Do not open an empty merge request: park it per Step 8 with a comment saying what you found.

Keep the diff to what the issue asked for. A `phpcs` sweep across files the issue never mentioned buries the review; mention anything broader to the user instead.

### 6. Open the merge request

Push to the **fork**, never to the project:

```bash
git push --force-with-lease -u fork "HEAD:<fork-branch>"
```

`--force-with-lease` creates the branch on a first push and replaces history a rebase rewrote, while refusing if another contributor moved the branch meanwhile. Never plain `--force`: issue forks are shared.

Write the description to a file, because the shell mangles markdown's backticks and newlines. Three parts and nothing else — what the change does, the link to the issue, and the disclosure:

```bash
cat > <tmp>/mr-description.md <<'EOF'
<one short paragraph: what the change does, in the issue's own terms>

Closes #<issue-iid>

AI-Generated: Yes
EOF
```

Then create the merge request, or find the one an earlier run already opened for this branch. It is created **on the fork** with `target_project_id` pointing at the project; created on the project, it would merge the project into itself.

```bash
TARGET_ID=$(glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>" | jq -r '.id')
FORK_ID=$(jq -r '.fork_id' <tmp>/fork.json)

MR_IID=$(glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/merge_requests?source_branch=<fork-branch>&state=opened" |
    jq -r '.[0].iid // empty')

if [ -z "$MR_IID" ]; then
    MR_IID=$(glab api --hostname git.drupalcode.org -X POST "projects/$FORK_ID/merge_requests" \
        -f "source_branch=<fork-branch>" \
        -f "target_branch=<target-branch>" \
        -f "target_project_id=$TARGET_ID" \
        -f "title=Issue #<issue-iid>: <short description>" \
        -F "description=@<tmp>/mr-description.md" |
        jq -r '.iid')
fi
```

Do not open it as a draft: drupal.org reviewers go by the issue's `state::` label, and a draft at `state::needsReview` gets reviewed by nobody.

### 7. Make every job green

```bash
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> "$MR_IID" "$(git rev-parse HEAD)"
```

Act on its exit code:

- **0** → every job passed, or the project has no CI. Continue.
- **1** → jobs failed, listed with `(allow_failure)` on the forgiven ones. **Fix all of them, forgiven or not.** Delegate per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; at most two fix-and-push attempts, then park per Step 8.
- **7** → the pipeline could not be read. Unknown is not passing: report it with the merge request URL and stop.
- **8** → still running after the full wait. Report the pending jobs and the URL, then stop without handing back.

From exit **7** or **8** onwards there is a merge request, so Step 1 will pass this issue over; tell the user a `loachbot-gitlab-mr` run is what finishes it once CI has settled.

Read a failing job's log before guessing from its name. The script prints the pipeline's project and each failing job's id — use that project, not the fork, because the pipeline may have run in the parent:

```bash
glab api --hostname git.drupalcode.org "projects/<pipeline-project>/jobs/<job-id>/trace"
```

### 8. When it's unclear

If the requirement needs a decision you cannot make, or CI stays red for a reason a human has to settle, ask once and stop. Question and park go in **one comment**:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
<one short question>

/do:label ~"state::blocked"
EOF
)"
```

`state::blocked` is drupal.org's own label for an issue waiting on something; `check-parked-issue.sh`'s header explains how Step 1 finds the comment again. Stay assigned — the issue is still yours once the question is answered — and set no other state label.

### 9. Hand it back

With every job green, hand the issue to review in **one comment**. The `/do:` lines are drupalbot commands: post them **verbatim**, not as GitLab quick actions, so the handback works the same whether or not you hold a project role.

```bash
glab issue note <issue-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
Opened [MR !<mr-iid>](https://git.drupalcode.org/<namespace>/<project>/-/merge_requests/<mr-iid>).

<two or three sentences: the approach, anything a reviewer should look at first,
and anything the issue asked for that this does not cover>

The pipeline is green.

/do:unassign me
/do:label ~"state::needsReview"
EOF
)"
```

"Implemented the fix" tells a reviewer nothing; naming the approach and the one thing you were unsure about is what gets a review.

Confirm drupalbot acted:

```bash
bash <this skill's directory>/scripts/confirm-handback.sh <project> <issue-iid>
```

- **0** → unassigned and at `state::needsReview`. Continue.
- **6** → not both within the wait. Say so and point the user at the issue. Do **not** post the comment again.

Then remove the worktree and its local branch — the work is pushed:

```bash
cd ~/Projects/drupalcode/<project>
git worktree remove ~/Projects/drupalcode/<project>.worktrees/issue-<issue-iid> --force
git branch -D issue-<issue-iid>
```

### 10. Tell the user what is left

Close with the links, the summary you posted, and a todo list of what only a human can do. This goes in your reply, not on the issue.

Contribution credit is always on it: drupal.org grants credit from an attribution record reached through the issue's "Issue tools" link, with no `/do:` command and no API, and a merge request committed without one earns the user nothing.

> Done: https://git.drupalcode.org/\<namespace\>/\<project\>/-/merge_requests/\<mr-iid\>
> Issue: https://git.drupalcode.org/\<namespace\>/\<project\>/-/work_items/\<issue-iid\>
>
> \<the summary you posted on the issue\>
>
> **Over to you:**
> - [ ] Record your contribution for credit, from the issue's "Issue tools" links
> - [ ] Review the merge request — nobody else has looked at it yet
> - \<one line per thing you noticed and deliberately left out of scope\>
> - \<the backport question, if Step 3 raised one\>

Keep the list to things that are actually outstanding; the first two are the only entries that appear every run.

## Rules

- Work on exactly one issue per run. If asked to run multiple times, repeat the whole workflow from Step 1 after each run, one at a time — search results lag, so overlapping runs would both pick the same issue. Stop early when a run reports "Nothing to do".
- Only claim issues you reported, unless the user names one directly. Assigning yourself into somebody else's queue uninvited is a social act, not a technical one.
- Finish what is already claimed before claiming more: a `resume` outranks a `ready`.
- Push to the `fork` remote, never to `upstream`, and never with a force other than `--force-with-lease`.
- Never rewrite or revert another contributor's commits on a shared issue branch. If their work conflicts with yours, that is a Step 8 park.
- All git operations for an issue run inside that issue's worktree, never in the base clone.
- Post exactly the comments this workflow calls for: the claim, the un-park, the fork and access commands the scripts post, one parking question, and one handback.
- A run ends parked (assigned, `state::blocked`, a question) or handed back (unassigned, `state::needsReview`, a merge request) — never in between, except when CI is unreadable or still running (Step 7).
- Every merge request description is one short paragraph, `Closes #<issue-iid>`, and `AI-Generated: Yes`. Drupal.org [requires the disclosure](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) of AI-generated contributions and withholds credit from those without it, so it is never dropped, however small the diff.
- Every run ends with the Step 10 todo list, contribution credit first.
- Never set `state::rtbc`, never approve, and never merge.
- Commit messages are one line: `Issue #<issue-id>: <short description>`.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. Every LoachBot skill that clones shares `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org) with its siblings, and one run fetching, resetting or deleting branches under another corrupts both. Runs on different clones may overlap freely, and so may the sub-agents within a run.
<!-- /SHARED: one-run-per-clone -->
