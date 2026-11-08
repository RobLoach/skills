---
name: loachbot-gitlab-review
description: Review one drupal.org merge request against the issue it claims to fix and against Drupal's own standards, post the findings as resolvable inline threads plus one summary, and set the issue to needs-work only when a finding blocks. Read-only against git unless asked to apply findings; never approves or merges. Use when the user wants a review of a drupal.org merge request, asks what is wrong with one or how to improve it, wants the findings applied, or asks to "run LoachBot Review", including repeated runs like "review the next three".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-review/SKILL.md
    license: MIT
---
# LoachBot GitLab Merge Request Reviewer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`; the scripts parse JSON with it.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) is on `PATH` for projects whose issues never moved to GitLab, such as Drupal core. Reads need no authentication. Without it, those issues cannot be read.
- Paths assume the `project/` namespace. For sandboxes set `LOACHBOT_GITLAB_NAMESPACE=sandbox`; `LOACHBOT_GITLAB_HOST` points the scripts at another GitLab.

Unless asked to apply its findings (Step 8), this skill never clones, checks out or writes to a branch. It reads through the API, so it needs no worktree and cannot collide with any other LoachBot run, even one on the same merge request.

## Conventions

The `bash` blocks are templates: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`), `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE` when set) and `<iid>`, and adapt anything that doesn't fit.

Scripts live in `scripts/` beside this file, run as `bash <this skill's directory>/scripts/<name>.sh`; each header documents arguments and exit codes.

`<tmp>` is a scratch directory made once per run with `mktemp -d`; runs may overlap, so never use a fixed `/tmp` path.

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
## Workflow

### 1. Pick one merge request

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23`, or `ai_ckeditor!23`), review that one and skip the search.

**If the user named an issue** (`.../-/issues/<n>`, `.../-/work_items/<n>`, `ai_ckeditor#<n>`, or `https://www.drupal.org/i/<n>`), review its open merge request, asking only if there are several:

```bash
# A GitLab issue or work item: <n> is the iid.
glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>/issues/<n>/related_merge_requests" |
    jq -r '.[] | select(.state == "opened") | .references.full'
# A drupal.org node (drupal.org/i/<n>, /node/<n>): if it moved to a work item, use the one named.
drupalorg mr:list <n> --format=llm
```

**Otherwise**, look for merge requests waiting on you:

```bash
MY_ID=$(glab api --hostname git.drupalcode.org user | jq -r '.id')
glab api --hostname git.drupalcode.org \
    "merge_requests?reviewer_id=$MY_ID&state=opened&scope=all&order_by=updated_at&sort=desc&per_page=30" |
    jq -r '.[] | "\(.references.full)\t\(.author.username)\t\(.title)"'
```

Also try `assignee_id` instead of `reviewer_id`, for projects that assign rather than request review. If both are empty, report "Nothing to review" and stop.

If the author is you, review it when asked, but open the summary by saying you wrote it, so nobody mistakes it for an independent sign-off.

### 2. Gather the context

```bash
bash <this skill's directory>/scripts/review-context.sh <project> <iid> > <tmp>/review.json
```

One JSON object: the merge request, its `diff_refs`, the issue number, changed files with diffs, every pipeline job, the failing ones, and existing threads; the header documents the shape. Exit **5** means the merge request could not be read: report it and stop.

Read the existing threads before forming any opinion, so you don't repeat an earlier review:

```bash
jq -r '.discussions[] | "\(.id) \(if .resolved then "resolved" else "open" end) \(.path // "-"):\(.line // "-") \(.author): \(.body)"' <tmp>/review.json
```

Then resolve the issue:

```bash
ISSUE_REF=$(jq -r '.issue_ref // empty' <tmp>/review.json)
[ -n "$ISSUE_REF" ] && bash <this skill's directory>/scripts/read-issue.sh <project> "$ISSUE_REF" > <tmp>/issue.json
```

Exit codes are in [The issue lives in one of two places](#the-issue-lives-in-one-of-two-places). A null `issue_ref`, or exit **6**, means reviewing without the requirement: do it anyway, and say in the summary that you could not check it against the issue. Exit **7** means a different project's issue: discard it and treat the requirement as unavailable.

### 3. Read what was actually asked

The issue is the requirement; the merge request description is usually one line. Before opening any file, answer:

- What does the issue ask for, in one sentence?
- What does the diff do that the issue did not ask for?
- What does the issue ask for that the diff does not do?

```bash
jq -r '"\(.source) · \(.status)\n\n\(.title)\n\n\(.description)"' <tmp>/issue.json
```

Scope is the most common real finding and the easiest to miss once reading code.

### 4. Review the diff

The diff is in `<tmp>/review.json`. Fetch whole files only when the hunks are not enough:

```bash
jq -r '.files[] | "=== \(.new_path)\n\(.diff)"' <tmp>/review.json

# <path> is URL-encoded: dots become %2E, slashes %2F.
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/repository/files/<path>/raw?ref=<head-sha>"
```

Split the review across sub-agents by *concern*, not file, launched together per [Sub-agents](#sub-agents). A reasonable default is one each for correctness, Drupal API conventions, tests and security, each given the diff and the Step 3 summary.

Beyond ordinary code review, check:

- **Scope**: unrelated lint fixes, formatting sweeps and version bumps belong in their own issue; saying so is a legitimate finding.
- **`*.info.yml`**: `core_version_requirement` covers the target branch; dependencies use `project:module`; no `version` key in contrib (drupal.org adds it on packaging).
- **`composer.json`**: constraints agree with `core_version_requirement`; anything new is actually required.
- **Services**: constructor injection, not `\Drupal::` in classes that can take a container; new services declared in `*.services.yml` with their dependencies.
- **Translation**: user-facing strings go through `t()` or `StringTranslationTrait`, with placeholders, not concatenation.
- **Access and input**: routes carry `_permission`, `_entity_access` or `_custom_access`; queries are parameterized; no user input reaches `#markup` unescaped.
- **Render and cache**: render arrays over raw markup, with `#cache` contexts and tags matching what the output varies on.
- **Config**: new keys have schema in `config/schema/`; a shape change to existing config comes with a `hook_update_N`.
- **Hooks**: correct implementation name, and the `#[Hook]` attribute where the target branch supports it.
- **Tests**: new behaviour is covered, extending the right base class.
- **Deprecations**: nothing the target branch has deprecated or the next major removes.
- **Leftovers**: no `dpm()`, `kint()`, `var_dump()`, `dd()`, commented-out blocks or `@todo` without an issue number.

### 5. Read the pipeline, not the badge

`failing_jobs` from Step 2 is authoritative, not the rollup. A forgiven failure counts like any other.

```bash
jq -r '.failing_jobs[] | "\(.name): \(.status)\(if .allow_failure then " (forgiven by the pipeline)" else "" end) job=\(.id)"' <tmp>/review.json
```

A failure can predate the branch, so compare with the target branch before blaming the change:

```bash
bash <this skill's directory>/scripts/compare-to-target.sh <project> <iid>
```

- **1** → `new:` failures are this branch's: findings. `+` lines are a log diff with numbers masked, so read the log before citing one.
- **0** → all pre-existing: mention them in the summary as not this branch's, not as findings.
- **6** → no target pipeline to compare: treat failures as findings and say they could not be checked.
- **7** → jobs unreadable: say so in the summary.

Read a log from `pipeline_project_id`, not the fork:

```bash
bash <this skill's directory>/scripts/job-log.sh "$(jq -r '.pipeline_project_id' <tmp>/review.json)" <job-id>
```

Exit **7** means the wrong project or job id: check both.

### 6. Post the findings

**Report here only** when the user asked for the review in chat, or not to post it: post nothing to GitLab and skip Step 7. Reply with the findings as a numbered list, blocking first, each with `path:line` and the fix, then the pipeline state.

A finding tied to a line goes inline as a resolvable thread. Write the body to a file, since the shell mangles markdown backticks and newlines:

```bash
printf '%s\n' "This runs on every request; consider caching it." > <tmp>/finding.md
bash <this skill's directory>/scripts/post-inline-comment.sh <project> <iid> <path> <new-line> <tmp>/finding.md
```

Exit **1** means one of:

- GitLab rejected the position, usually a context line without its old-side number. A line on both sides of the diff needs both: pass the old line as the sixth argument. The hunk header (`@@ -4,5 +4,6 @@`) carries the pair.
- GitLab returned `201` but dropped the position, leaving a plain Overview thread; the script detects this and fails.

Never retry with a guessed line number; a comment on the wrong code is worse than none. Fix the line pair or move the point into the summary.

Exit **5** means the merge request could not be read, almost always a transient API failure since Step 2 succeeded. Retry once; if it fails again, move the point into the summary and note the inline comment could not be posted.

A finding an existing thread already raises gets a reply there, not a new thread:

```bash
glab api --hostname git.drupalcode.org -X POST \
    "projects/<namespace>%2F<project>/merge_requests/<iid>/discussions/<discussion-id>/notes" \
    -F "body=@<tmp>/finding.md"
```

Then exactly one summary note:

```bash
glab mr note create <iid> -R git.drupalcode.org/<namespace>/<project> < <tmp>/summary.md
```

In order: whether the change does what the issue asked, anything out of scope, blocking findings, suggestions, and the pipeline state. Separate *blocking* from *nice to have* explicitly; an unordered pile reads as a rejection even when most are optional.

Say plainly when the change is good. A review that only lists problems trains people to ignore it.

### 7. Hand it back

Only when something blocks, and only when `writable` was `true` in Step 2, move the issue to needs-work. The `/do:` lines are drupal.org bot commands, so post them **verbatim**:

```bash
glab issue note <issue-id> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
Reviewed, comments inline.

/do:label ~"state::needsWork"
EOF
)"
```

A drupal.org-only issue has no `/do:` path, so do not attempt this: report the findings, link the issue's `url`, and leave the status change to the user.

When nothing blocks, **stop**. Do not set `state::rtbc`, approve or merge: say nothing blocks and let the user decide.

### 8. Fix it, when asked

Only when the user asks to apply findings to the merge request. This leaves the read-only review: use `loachbot-gitlab-mr`'s Steps 3-4 and rules (`setup-mr-worktree.sh` for a worktree on the fork's branch, `--force-with-lease` to `fork`, then `wait-for-pipeline.sh` and `compare-to-target.sh`). Without that skill: clone the project, add the source fork as a remote, work in a worktree of its branch, push with `--force-with-lease`, and check every job.

Fix only the findings the user picked, by their review number, delegating per [Sub-agents](#sub-agents). One commit per finding when asked, each `Issue #<issue-id>: <the finding, briefly>`.

Once pushed and green, reply on and resolve each fixed finding's thread, passing the commit that fixed it:

```bash
bash <this skill's directory>/scripts/resolve-threads.sh <project> <iid> <commit-sha> <discussion-id>...
```

- **0** → resolved. Report the commits.
- **1** → the threads named on stderr were not resolved; resolving needs the author or a maintainer. Report them.
- **5** → the merge request could not be read. Report it.

## Rules

- Review exactly one merge request per run; for more, see [Repeated runs](#repeated-runs).
- Read-only against git: never clone, check out, push, rebase or merge. Everything goes through the API, which is why this may run alongside any other LoachBot run. The one exception is Step 8, on request, under `loachbot-gitlab-mr`'s rules.
- Never approve, set `state::rtbc` or merge. The most this skill sets is `state::needsWork`, and only when a finding genuinely blocks.
- Post inline comments only on lines the diff touches, and one summary note per run; nothing in report-here-only mode. Reply in an existing thread rather than re-posting its finding (Steps 2 and 6).
- Separate blocking findings from suggestions, every time.
- Judge the change against the issue and the target branch, not how you would have written it. Style preferences `phpcs` does not enforce are not findings.
