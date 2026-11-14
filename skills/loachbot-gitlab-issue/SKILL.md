---
name: loachbot-gitlab-issue
description: Fix one drupal.org issue end to end - claim it, open a merge request from its issue fork, get every CI job green, and hand it back for review. Works on issues you reported, or any drupal.org issue you name. Use when the user wants to pick up, fix or work on a drupal.org issue, open a merge request for one, or asks to "run LoachBot GitLab Issues", including repeated runs like "three times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-issue/SKILL.md
    license: MIT
---
# LoachBot GitLab Issue Fixer

<!-- SHARED: gitlab-prerequisites -->
## Prerequisites

- `glab auth status --hostname git.drupalcode.org` succeeds; if not, report it and stop (`glab auth login --hostname git.drupalcode.org` fixes it).
- `jq` on `PATH`; the scripts parse JSON with it.
- Paths assume the `project/` namespace; set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for sandboxes. `LOACHBOT_GITLAB_HOST` points the scripts at another GitLab; the commands written out here assume `git.drupalcode.org`.
<!-- /SHARED: gitlab-prerequisites -->
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH` is optional; this skill cannot work on queues that never moved to GitLab (Drupal core among them) either way.
- SSH access to `git.drupal.org`, for pushes to issue forks.
- Clones and worktrees go in `~/Projects` (created if missing); `LOACHBOT_PROJECTS_DIR` overrides it.

<!-- SHARED: gitlab-conventions -->
## Conventions

`bash` blocks are templates: substitute `<project>` (a machine name like `ai_ckeditor`, never `project/ai_ckeditor`), `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE`) and the other `<placeholders>`, and adapt to the case at hand.

Scripts live in `scripts/` beside this file, run as `bash <this skill's directory>/scripts/<name>.sh`; each header documents arguments and exit codes.

`<tmp>` is a per-run `mktemp -d` directory; runs may overlap, so never use a fixed `/tmp` path.
<!-- /SHARED: gitlab-conventions -->

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

<!-- SHARED: drupal-gotchas -->
## How drupal.org differs

- **Two hostnames, one service.** The API is at `git.drupalcode.org`; git is at `git.drupal.org`. Each fails on the other's host, so take remote URLs from the API's `ssh_url_to_repo` instead of composing them.
- **Two repositories per merge request**: it targets `project/<project>`, but its branch lives in the fork `issue/<project>-<issue-id>`; push to the fork.
- **The pipeline may be on the fork or the parent project.** Use `head_pipeline.project_id` from a single-merge-request read (fall back to `source_project_id`); the wrong one returns a flat `404`.
- **A green pipeline can hide red jobs**: never match on job names; read each job's `allow_failure` and treat a forgiven failure as a failure.

### The issue lives in one of two places

Never try both GitLab and drupal.org and keep whichever answers. `read-issue.sh` decides the world first, then interprets the number:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-ref>
```

It returns one JSON object either way (`source`, `title`, `status`, `actionable`, `writable`, `url`, `description`). Act on its exit code:

- **0** → read. `actionable: false` means fixed, closed, postponed or already reviewed-and-tested: leave it alone. `writable: false` means `/do:` cannot be posted, so hand back to the user instead.
- **6** → unreadable in this project's world. Report it; do **not** try the other world.
- **7** → read, but it belongs to a different project, so the number was read in the wrong world. Report it and discard the result.

Two `glab api` habits: `-f` sends a plain string while `-F` types its value and reads `@path` as a file's contents; `--paginate` prints one JSON array per page, so merge them with `jq -s 'add'`.
<!-- /SHARED: drupal-gotchas -->

There are no personal forks: everyone pushes to the issue's one shared fork, and an existing branch there is somebody's work in progress, so Step 4 continues the newest one. Drupalbot's `/do:fork` and `/do:access` create it and grant push access; `ensure-fork.sh` posts and waits.

## Workflow

### 1. Pick one issue

**If the user named one** (`https://git.drupalcode.org/project/ai_ckeditor/-/work_items/3615836` or `ai_ckeditor#3615836`), take it and skip the search. The `/-/work_items/<id>` number is the issue iid the `issues` API reads.

**Otherwise**, list issues you reported. Pass `<project>` if the user asked for one, or the working directory is a drupal.org checkout:

```bash
bash <this skill's directory>/scripts/find-issues.sh [<project>]
```

Act on its exit code:

- **0** → candidates printed (kinds and state allowlist in the script's header).
- **6** → report "Nothing to do" and stop.
- **5** → the search could not be read. Report it and stop.

A `resume` is an earlier run's claim with no merge request yet: take it before any `ready`, and **skip Step 2** for it.

A `parked` issue has an unanswered Step 8 question. Check for replies:

```bash
bash <this skill's directory>/scripts/check-parked-issue.sh <project> <issue-iid>
```

- **0** → replies printed. If they answer the question, it is a candidate and they clarify Step 3; if not, skip it and say so — do **not** ask again.
- **6** → no reply yet. Skip it.
- **5** → `state::blocked` was applied by hand, with no question to measure against. Skip it and tell the user.

An issue with an open merge request is `loachbot-gitlab-mr`'s work. For a candidate with `mrs=` not `0`, check:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/related_merge_requests" |
    jq -r '.[] | select(.state == "opened") | "\(.references.full)\t\(.source_branch)"'
```

Anything printed → skip it and tell the user which merge request covers it.

Read the picked issue for Step 3:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-iid> > <tmp>/issue.json
jq -r '"\(.source) \(.status) writable=\(.writable)"' <tmp>/issue.json
```

For a *named* issue, `source: "drupal.org"` or exit **6** means its queue never moved to GitLab and there is no `/do:` path to claim it: say so, point the user at `loachbot-gitlab-mr` for an existing merge request, and stop. A named issue outside `find-issues.sh`'s open-state allowlist is not waiting on code: say so and stop.

If nothing survives, report "Nothing to do" and stop.

If the issue was parked, lift the park first:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
/do:unlabel ~"state::blocked"
EOF
)"
```

### 2. Claim it

Skip for a `resume` or `parked` issue (already yours). Otherwise claim it, by comment, before writing code:

```bash
bash <this skill's directory>/scripts/poll-issue.sh claim <project> <issue-iid>
```

Act on its exit code:

- **0** → it's yours. Continue.
- **7** → claimed by somebody else since the search; nothing posted. Return to Step 1 for the next candidate.
- **6** → posted, but drupalbot never acted. Report it with the issue URL and stop; do not post again or start work.
- **5** → the issue could not be read. Report it and stop.

Report the URL immediately:

> Working on: https://git.drupalcode.org/\<namespace\>/\<project\>/-/work_items/\<issue-iid\>

### 3. Understand it

The issue is the requirement. Read it, then its comments:

```bash
jq -r '"\(.title)\n\n\(.description)"' <tmp>/issue.json
glab api --hostname git.drupalcode.org --paginate \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/notes?sort=asc&order_by=created_at" |
    jq -s -r 'add | .[] | select(.system == false) | "=== \(.author.username) \(.created_at)\n\(.body)\n"'
```

Maintainer comments outrank the issue summary. If Step 1 un-parked it, the replies answer that one question, not open new direction. Investigate what comments refer to per [Sub-agents](#sub-agents).

Settle before editing:

- What does the issue ask for, in one sentence?
- Which branch? Step 4 targets the default branch; a fix said to belong on an older branch is a backport call to raise per Step 8.
- Is it a code change at all? Spot support questions, duplicates and already-fixed issues now.

### 4. Get a fork and a worktree

```bash
bash <this skill's directory>/scripts/ensure-fork.sh <project> <issue-iid> > <tmp>/fork.json
jq -r '"\(.fork_path) id=\(.fork_id) created=\(.created) access_via=\(.access_via)"' <tmp>/fork.json
```

Act on its exit code:

- **0** → fork exists and is writable. Continue.
- **6** → drupalbot never acted, or the fork it made never finished importing. Report it with the issue URL and stop; do not ask again. A later run picks it up as a `resume`.
- **5** → the project, the issue or its fork could not be read; nothing was posted. Report it and stop.

Then take a worktree at `~/Projects/drupalcode/<project>.worktrees/issue-<issue-iid>`:

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <project> issue <issue-iid>)
cd "$WT"
```

Its stderr ends with `remote=fork-issue-<issue-iid>`, `fork_branch=`, `target_branch=` and `resumed=` for Step 6. Act on its exit code:

- **3** — rebase conflicted and was aborted. Resolve only a mechanical conflict you can justify; anything else is a Step 8 park. Never work in a half-rebased worktree.
- **4** — another live worktree (named on stderr) has the branch. Remove it only if it is a LoachBot worktree under `<project>.worktrees/` and `git -C <stale-path> status --short` prints nothing: `git worktree remove <stale-path>`, then `git worktree prune`, and rerun. Otherwise it may hold somebody's uncommitted work: report it and stop.
- Any other non-zero — stderr names what failed. Report it and stop; do not force through it.

`resumed=true` means work already exists: read it (`git log upstream/<target-branch>..HEAD`) and build on it.

### 5. Do the work

Delegate the implementation per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix. Then commit inside `$WT`, after checking `git status --short` and staging only the files the change meant to touch (delete stray artifacts or leave them untracked):

```bash
git add <paths>
if git diff --cached --quiet; then
    echo "nothing staged: no code change was needed"
else
    git commit -m "Issue #<issue-iid>: <short description>"
fi
```

Nothing staged → no empty merge request; park per Step 8, saying what you found.

Keep the diff to what the issue asked; mention broader cleanups to the user instead.

### 6. Open the merge request

```bash
git push --force-with-lease -u fork-issue-<issue-iid> "HEAD:<fork-branch>"
```

Write the description to a file (the shell mangles markdown):

```bash
cat > <tmp>/mr-description.md <<'EOF'
<one short paragraph: what the change does, in the issue's own terms>

Closes #<issue-iid>

AI-Generated: Yes
EOF
```

Find an existing merge request for the branch, or create one **on the fork** with `target_project_id` set to the project (created on the project, it merges the project into itself).

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

Not a draft: reviewers go by the issue's `state::` label, and nobody reviews a draft.

### 7. Make every job green

```bash
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> "$MR_IID" "$(git rev-parse HEAD)"
```

<!-- SHARED: gitlab-wait-for-pipeline -->
Run it with a 600000 ms tool timeout: it waits up to `LOACHBOT_PIPELINE_TIMEOUT` (7 minutes) plus the comparison, and a shorter limit kills it before it can exit with a code.

Act on its exit code:

- **0** → every job passed, or the commit configures no CI. Continue.
- **1** → `new:` lists what this branch introduced. **Fix all of it, forgiven or not.** Delegate per [Sub-agents](#sub-agents), passing `$WT` and the proving command; at most two fix-and-push attempts, then park per *When it's unclear*. `+` lines are a log diff with numbers masked: a lead, not a verdict.
- **2** → every failure also fails on the target branch. Fix nothing and work around nothing (skipped tests, baseline entries, `allow_failure` edits); name them as pre-existing in the handback instead of "the pipeline is green".
- **7** → the pipeline could not be read. Unknown is not passing: report it with the URL and stop.
- **8** → still running, or no pipeline has appeared yet, when the call ended. Run it again; after three runs, report the pending jobs and URL, then stop without handing back.

The split comes from `scripts/compare-to-target.sh`: its **1**, **6** (no target pipeline) and **7** all surface here as **1**.

Read a failing job's log before guessing from its name, from the pipeline project the wait prints (it may be the parent, not the fork):

```bash
bash <this skill's directory>/scripts/job-log.sh <pipeline-project> <job-id>
```

Exit **7** means the wrong project or job id: check both. Then reproduce it locally before pushing a guess.
<!-- /SHARED: gitlab-wait-for-pipeline -->

After **7** or **8**, tell the user a `loachbot-gitlab-mr` run finishes it once CI settles (Step 1 now skips it).

<!-- SHARED: local-tests -->
#### Running tests locally

- **DDEV** (`ddev` on `PATH`): in the worktree, `ddev config --project-type=drupal --docroot=web --project-name="<project>-$(basename "$WT")" && ddev add-on get ddev/ddev-drupal-contrib && ddev start && ddev poser && ddev symlink-project`, then `ddev phpunit`, `ddev phpcs`, `ddev phpstan` or `ddev eslint` mirror the CI jobs.
- **Without DDEV**, unit tests need nothing more. Kernel and functional tests need a database, and Drupal 11 refuses SQLite older than 3.45; check PHP's own with `php -r 'echo (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn();'`. Older, use a container: `docker run -d --rm -p 3306:3306 -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=db mariadb:lts` with `SIMPLETEST_DB=mysql://root:root@127.0.0.1/db`.
- Never commit the harness: add `.ddev/`, `web/`, `vendor/` and `composer.contrib.*` to `$(git rev-parse --git-common-dir)/info/exclude`, which every worktree shares, so they never show up as untracked.
<!-- /SHARED: local-tests -->

### 8. When it's unclear

If it needs a decision you cannot make, or CI stays red for a human reason, ask once and stop, in **one comment**:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
<one short question>

/do:label ~"state::blocked"
EOF
)"
```

Stay assigned and set no other state label; `check-parked-issue.sh` finds the comment again in Step 1.

### 9. Hand it back

With every job green, hand back in **one comment**. Post the `/do:` drupalbot lines **verbatim**, not as GitLab quick actions, so it works without a project role.

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

Name the approach and what you were unsure of; "Implemented the fix" tells a reviewer nothing.

Confirm drupalbot acted:

```bash
bash <this skill's directory>/scripts/poll-issue.sh handback <project> <issue-iid>
```

- **0** → unassigned and at `state::needsReview`. Continue.
- **6** → not both within the wait. Tell the user and point at the issue; do **not** post again.
- **5** → your own user could not be read, so nothing was confirmed. Tell the user to check the issue by hand; do **not** post again.
- **7** → never raised by `handback`; treat it like **6**.

Remove the worktree and local branch:

```bash
cd "${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/<project>"
git worktree remove "$WT" --force
git branch -D issue-<issue-iid>
git remote remove fork-issue-<issue-iid>
```

### 10. Tell the user what is left

Reply (not on the issue) with the links, the posted summary, and a human todo list. Credit is always on it: there is no `/do:` or API for it.

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

List only what is outstanding; only the first two appear every run.

## Rules

- One issue per run; for more, see [Repeated runs](#repeated-runs).
- Push to the issue's `fork-issue-<issue-iid>` remote, never to `upstream`, and never with a force other than `--force-with-lease`.
- Never rewrite or revert another contributor's commits; a conflict with their work is a Step 8 park.
- All git operations run in the issue's worktree, never the base clone.
- Post only: the claim, the un-park, the scripts' fork and access commands, one parking question, one handback.
- A run ends parked (assigned, `state::blocked`, a question) or handed back (unassigned, `state::needsReview`, a merge request) — never in between, except when CI is unreadable or still running (Step 7).
- Never drop `AI-Generated: Yes` from a merge request description: drupal.org's [AI policy](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) requires disclosure.
- Never set `state::rtbc`, never approve, and never merge.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
