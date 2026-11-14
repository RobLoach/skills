---
name: loachbot-gitlab-mr
description: Rebase a drupal.org merge request onto its target branch, resolve conflicts, and make every CI job green - including the lint jobs drupal.org's pipeline forgives behind a green badge - then hand it back for review. Takes the merge request you name, or searches your own open ones. Use when the user wants to rebase a drupal.org merge request, fix merge conflicts on one, fix pipeline or cspell/phpcs/phpstan/phpunit failures, or asks to "run LoachBot MRs", including repeated runs like "five times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-mr/SKILL.md
    license: MIT
---
# LoachBot GitLab Merge Request Fixer

<!-- SHARED: gitlab-prerequisites -->
## Prerequisites

- `glab auth status --hostname git.drupalcode.org` succeeds; if not, report it and stop (`glab auth login --hostname git.drupalcode.org` fixes it).
- `jq` on `PATH`; the scripts parse JSON with it.
- Paths assume the `project/` namespace; set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for sandboxes. `LOACHBOT_GITLAB_HOST` points the scripts at another GitLab; the commands written out here assume `git.drupalcode.org`.
<!-- /SHARED: gitlab-prerequisites -->
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH` for projects whose issues never moved to GitLab, Drupal core among them; reads need no login. Without it, the issue behind those merge requests cannot be read.
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

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents read, search and edit. Delegate whenever you would read a file to learn how something works, run more than two searches, make a change that needs more than a sentence to describe, or run a build, tests or a linter and react to its output.

Use read-only investigators for questions and editing agents for changes. Launch read-only ones together in one message; they cannot collide. Keep sequential only writes (`git`, builds, formatters, codegen) and sub-agents that need an earlier answer.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

Verify what matters in a report: read the diff or re-run the command. Wait for every sub-agent you launched before reporting, and tell sub-agents that launch their own helpers to do the same: a report sent while helpers still run is unfinished work.
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

Four things here break GitLab habits, quietly. Know them before the first API call.

- **Two hostnames, one service.** The API is at `git.drupalcode.org`; git is at `git.drupal.org`. Each fails on the other's host, so take remote URLs from the API's `ssh_url_to_repo` instead of composing them.
- **Two repositories per merge request.** It targets `project/<project>`, but its branch lives in the per-issue fork `issue/<project>-<issue-id>`. Push to the fork.
- **The pipeline is on the fork, except when it isn't.** GitLab runs a fork's merge request pipeline in the *parent* project when the author can push there: a maintainer's runs on the project, a contributor's on the fork. The wrong one returns a flat `404`. Read `head_pipeline.project_id` from a single-merge-request read; fall back to `source_project_id` only if it is missing.
- **A green pipeline can hide red jobs.** Drupal.org's CI template sets `allow_failure: true` on some jobs, so they fail while the pipeline, badge and `glab ci status` report success. Which jobs varies per project: usually the lint jobs (`cspell`, `phpcs`, `phpstan`, `stylelint`), sometimes `eslint`, `composer` or even `phpunit` variants. Never match on job names: read each job's `allow_failure` and treat a forgiven failure as a failure.

### The issue lives in one of two places

A merge request's issue number is the tail of its fork path: `issue/ai_ckeditor-3615852` means `3615852`. It is a GitLab issue iid where the queue was migrated, a drupal.org node id where it wasn't (Drupal core and `eck` among them). The numbering spaces overlap, so the wrong world returns a real but unrelated issue.

Never try both and keep whichever answers. `read-issue.sh` decides the world first, then interprets the number; its header explains why:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-ref>
```

It returns one JSON object either way (`source`, `title`, `status`, `actionable`, `writable`, `url`, `description`). Act on its exit code:

- **0** → read. `actionable: false` means fixed, closed, postponed or already reviewed-and-tested: leave it alone. `writable: false` means `/do:` cannot be posted, so hand back to the user instead.
- **6** → unreadable in this project's world. Report it; do **not** try the other world.
- **7** → read, but it belongs to a different project, so the number was read in the wrong world. Report it and discard the result.

Two `glab api` habits: `-f` sends a plain string while `-F` types its value and reads `@path` as a file's contents; `--paginate` prints one JSON array per page, so merge them with `jq -s 'add'`.
<!-- /SHARED: drupal-gotchas -->

Two more matter for rebasing:

- **`has_conflicts` and `detailed_merge_status` are unreliable.** They sit at `unchecked` indefinitely, so filtering on them finds nothing. Step 3's local rebase discovers conflicts.
- **The forgiven jobs are most of what this skill is for.** A merge request whose only problem is a red `cspell`, or a forgiven `phpunit` variant, looks finished from every angle but the one that counts.

## Workflow

### 1. Pick one merge request

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23`, or `ai_ckeditor!23`), take it and skip the search. Issue forks are shared, so it may be somebody else's: say whose when you report, and change nothing of theirs beyond the rebase and CI fixes.

**Otherwise**, list your open merge requests. Pass `<project>` when the user asked for one, or when the working directory is a drupal.org checkout:

```bash
bash <this skill's directory>/scripts/find-mrs.sh [<project>]
```

Act on its exit code:

- **0** → candidates printed. Triage on `failing=` (red jobs, forgiven ones included), not the pipeline rollup.
- **6** → report "Nothing to do" and stop.
- **5** → the search could not be read. Report it and stop.

A merge request is **actionable** when `failing=` is above zero and Step 4 does not call every failure pre-existing, or when it no longer rebases cleanly, which only Step 3 finds out. With nothing failing anywhere, take the most recently updated one and let the rebase decide.

Skip it when its title ends with ` (Needs Info)` unless the question has been answered:

```bash
bash <this skill's directory>/scripts/check-parked-mr.sh <project> <iid>
```

Act on its exit code:

- **0** → answered; the printed replies are clarification for Step 2. Actionable.
- **6** → nobody has answered yet. Skip it.
- **5** → the merge request could not be read, or the suffix was added by hand. Skip it and tell the user.

Skip it when its issue is settled: RTBC means somebody is waiting to commit and a force-push would reset that; fixed, closed or postponed means it is not yours. Take the issue number from the source fork's path, not the branch name, which contributors rename. Only an `issue/` fork carries one:

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

- `actionable: false` → skip it and say which status stopped you.
- Exit **6** or **7** → skip it and report why. This is why Drupal core needs `drupalorg`: the read fails closed, so an RTBC check is never silently skipped.
- Empty `ISSUE_REF` → no issue to check. Carry on, tell the user, and skip the Step 6 handback.

Once picked, strip any ` (Needs Info)` suffix and report the URL immediately:

```bash
glab mr update <iid> -R git.drupalcode.org/<namespace>/<project> --title "<original title without the suffix>"
```

> Working on: https://git.drupalcode.org/\<namespace\>/\<project\>/-/merge_requests/\<iid\>

### 2. Understand it

Read the merge request, then its issue, where the real requirement is written:

```bash
glab mr view <iid> -R git.drupalcode.org/<namespace>/<project>
jq -r '"\(.title)\n\n\(.description)"' <tmp>/issue.json   # written in Step 1
```

Trust maintainer comments as instructions. Read them and any Step 1 answers, then [fan out](#sub-agents) sub-agents, one per question in one message, keeping file contents out of the main thread.

### 3. Rebase it

Each merge request gets its own worktree at `~/Projects/drupalcode/<project>.worktrees/mr-<iid>`, beside the untouched base clone `~/Projects/drupalcode/<project>`.

```bash
WT=$(bash <this skill's directory>/scripts/setup-worktree.sh <project> mr <iid>)
cd "$WT"
```

Its stderr ends with `remote=fork-mr-<iid>`, the merge request's own remote for its fork. Act on its exit code:

- **3** → the rebase conflicted and was aborted. Resolve it only if the conflict is mechanical and you can say exactly why your resolution is right; conflicting logic you did not write is a Step 5 park. Never keep working in a half-rebased worktree.
- **4** → another live worktree (named on stderr) has the branch. Remove it only if it is a LoachBot worktree under `<project>.worktrees/` and `git -C <stale-path> status --short` prints nothing: `git worktree remove <stale-path>`, then `git worktree prune`, and rerun. Otherwise it may hold somebody's uncommitted work: report it and stop.
- Any other non-zero → stderr names what failed. Report it and stop.

To resolve a conflict by hand:

```bash
git rebase upstream/<target-branch>
git add <paths>
GIT_EDITOR=true git rebase --continue
```

### 4. Make every job green

Push, then verify per job:

```bash
git push --force-with-lease fork-mr-<iid> "HEAD:<source-branch>"
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> <iid> "$(git rev-parse HEAD)"
```

Run it with a 600000 ms tool timeout: it waits up to `LOACHBOT_PIPELINE_TIMEOUT` (7 minutes) plus the comparison, and a shorter limit kills it before it can exit with a code.

Act on its exit code:

- **0** → every job passed, or the commit configures no CI. Continue.
- **1** → `new:` lists what this branch introduced. **Fix all of it, forgiven or not.** Delegate per [Sub-agents](#sub-agents), passing `$WT` and the proving command; at most two fix-and-push attempts, then park per Step 5. `+` lines are a log diff with numbers masked: a lead, not a verdict.
- **2** → every failure also fails on the target branch. Fix nothing; name them as pre-existing in the handback.
- **7** → the pipeline could not be read. Unknown is not passing: report it with the URL and stop.
- **8** → still running, or no pipeline has appeared yet, when the call ended. Run it again; after three runs, report the pending jobs and URL, then stop without handing back; a later run picks it up.

The split comes from `scripts/compare-to-target.sh`: its **1**, **6** (no target pipeline) and **7** all surface here as **1**.

Read a failing job's log before guessing from its name, from the pipeline project the wait prints (not always the fork):

```bash
bash <this skill's directory>/scripts/job-log.sh <pipeline-project> <job-id>
```

Exit **7** means the wrong project or job id: check both. Then reproduce it locally, per [Running tests locally](#running-tests-locally).

<!-- SHARED: local-tests -->
#### Running tests locally

- **DDEV** (`ddev` on `PATH`): in the worktree, `ddev config --project-type=drupal --docroot=web --project-name="<project>-$(basename "$WT")" && ddev add-on get ddev/ddev-drupal-contrib && ddev start && ddev poser && ddev symlink-project`, then `ddev phpunit`, `ddev phpcs`, `ddev phpstan` or `ddev eslint` mirror the CI jobs.
- **Without DDEV**, unit tests need nothing more. Kernel and functional tests need a database, and Drupal 11 refuses SQLite older than 3.45; check PHP's own with `php -r 'echo (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn();'`. Older, use a container: `docker run -d --rm -p 3306:3306 -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=db mariadb:lts` with `SIMPLETEST_DB=mysql://root:root@127.0.0.1/db`.
- Never commit the harness: add `.ddev/`, `web/`, `vendor/` and `composer.contrib.*` to `$(git rev-parse --git-common-dir)/info/exclude`, which every worktree shares, so they never show up as untracked.
<!-- /SHARED: local-tests -->

### 5. When it's unclear

If a conflict needs judgment you lack, or CI stays red for a reason a human must decide, post one short question, then park by appending ` (Needs Info)` to the title, and stop.

Comment first, rename second: Step 1 treats anything after the rename as the reply, so renaming first would un-park it with your own question.

```bash
glab mr note create <iid> -R git.drupalcode.org/<namespace>/<project> -m "<one short question>"
glab mr update <iid> -R git.drupalcode.org/<namespace>/<project> --title "<original title> (Needs Info)"
```

Do not change the issue's state labels when parking.

### 6. Hand it back

Only when Step 1 found an issue with `writable: true`. A drupal.org-only issue has no `/do:` path: report the merge request as finished, link the issue's `url`, and tell the user to set *Needs review* themselves.

Unresolved review threads are still somebody's to answer, and needs-review would bury them:

```bash
glab api --hostname git.drupalcode.org --paginate \
    "projects/<namespace>%2F<project>/merge_requests/<iid>/discussions?per_page=100" |
    jq -s 'add | map(select(.notes[0].resolvable and (.notes[0].resolved | not))) | length'
```

Above `0` → post nothing. Report it as rebased and green, say how many threads are open, and leave the state to the user.

Otherwise, include `/do:unassign me` only if the issue is assigned to you (a stalled Issue Fixer run leaves it so):

```bash
glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>/issues/<issue-id>" |
    jq -r '[.assignees[].username] | join(",")'
```

Post the handback, replacing "the pipeline is green" with the failing jobs' names when Step 4 left only pre-existing ones. The `/do:` lines are drupalbot commands: post them **verbatim**, not as GitLab quick actions:

```bash
glab issue note <issue-id> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
Rebased onto the target branch and the pipeline is green.

/do:unassign me
/do:label ~"state::needsReview"
EOF
)"
```

Remove the worktree and its local branch; the work is pushed:

```bash
cd "${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/<project>"
git worktree remove "$WT" --force
git branch -D mr-<iid>
git remote remove fork-mr-<iid>
```

Report the URL:

> Done: https://git.drupalcode.org/\<namespace\>/\<project\>/-/merge_requests/\<iid\>

## Porting a merge request

For "a new merge request doing what !\<iid\> does, but targeting \<branch\>", or a forward-port. Run Steps 1-2 on the original, then let its setup prepare the remotes, and branch from the target instead:

```bash
bash <this skill's directory>/scripts/setup-worktree.sh <project> mr <iid> >/dev/null || [ $? -eq 3 ] || exit
cd "${LOACHBOT_PROJECTS_DIR:-$HOME/Projects}/drupalcode/<project>"
WT="$PWD.worktrees/port-<iid>-<branch>"
git worktree add -b port-<iid>-<branch> "$WT" upstream/<branch>
cd "$WT"
git cherry-pick -x <oldest-sha>^..<newest-sha>
```

Resolve conflicts by Step 3's rule: mechanical only, else ask per Step 5. Then push and open the merge request **on the fork** (`$SOURCE_ID` from Step 1), targeting the project:

```bash
git push -u fork-mr-<iid> "HEAD:<issue-id>-<branch>"
printf 'Port of !%s to %s.\n\nAI-Generated: Yes\n' <iid> <branch> > <tmp>/mr-description.md
glab api --hostname git.drupalcode.org -X POST "projects/$SOURCE_ID/merge_requests" \
    -f "source_branch=<issue-id>-<branch>" -f "target_branch=<branch>" \
    -f "target_project_id=$(glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>" | jq -r '.id')" \
    -f "title=<original title> (<branch>)" -F "description=@<tmp>/mr-description.md" | jq -r '.web_url'
```

Then Steps 4 and 6 on the new merge request, still pushing to `fork-mr-<iid>`: the original's remote, on the same fork.

For a big forward-port, first triage the candidate commits (already on the target, applies cleanly, needs adapting, not applicable) in parallel read-only [sub-agents](#sub-agents), one per slice, then cherry-pick only what they cleared.

## Rules

- One merge request per run; for more, see [Repeated runs](#repeated-runs). Within a run, delegate per [Sub-agents](#sub-agents); the main thread keeps orchestration, git, push and handback.
- Push to the merge request's `fork-mr-<iid>` remote, never `upstream`. `--force-with-lease` is the only acceptable force.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
- Run every git operation inside the merge request's worktree, never `git checkout` or commits in the base clone. Creating a worktree branch from it (`git worktree add -b`), as the setup script and porting do, is fine.
- Post only the parking question (Step 5), the handback (Step 6) and a port's new merge request, and skip the handback while review threads are unresolved.
- Never set `state::rtbc`, and never merge.
- Keep the diff to what the issue asked for: no unrelated lint fixes, formatting sweeps or version bumps, and no workarounds for failures the target branch already has.
- One-line commit messages: `Issue #<issue-id>: <short description>`.
