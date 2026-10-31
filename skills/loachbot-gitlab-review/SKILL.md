---
name: loachbot-gitlab-review
description: Review one drupal.org merge request against the issue it claims to fix and against Drupal's own standards, post the findings as resolvable inline threads plus one summary, and set the issue to needs-work only when a finding blocks. Read-only against git; never approves or merges. Use when the user wants a review of a drupal.org merge request, asks what is wrong with one or how to improve it, or asks to "run LoachBot Review", including repeated runs like "review the next three".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-review/SKILL.md
    license: MIT
---
# LoachBot GitLab Merge Request Reviewer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) is on `PATH` for projects whose issues never moved to GitLab — Drupal core among them. Reads need no authentication. Without it, those merge requests can still be worked on, but the issue behind them cannot be read.
- Paths assume drupal.org's `project/` namespace. Sandboxes live under `sandbox/` instead, so set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for those; `LOACHBOT_GITLAB_HOST` likewise points the scripts at another GitLab.

This skill never clones, never checks anything out and never writes to a branch. It reads the diff and individual files through the API, so it needs no worktree and cannot collide with any other LoachBot run — including one working on the very merge request it is reviewing.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`), `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE` when set) and `<iid>` before running them, and adapt anything that doesn't fit the merge request in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

`<tmp>` is a scratch directory made once per run with `mktemp -d`. Runs may overlap, so never use a fixed `/tmp` path.

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
## Workflow

### 1. Pick one merge request

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23`, or `ai_ckeditor!23`), review that one. This is the common case; skip the search.

**Otherwise**, look for merge requests waiting on you:

```bash
MY_ID=$(glab api --hostname git.drupalcode.org user | jq -r '.id')
glab api --hostname git.drupalcode.org \
    "merge_requests?reviewer_id=$MY_ID&state=opened&scope=all&order_by=updated_at&sort=desc&per_page=30" |
    jq -r '.[] | "\(.references.full)\t\(.author.username)\t\(.title)"'
```

Swap `reviewer_id` for `assignee_id` to catch the projects that assign rather than request review. If both come back empty, report "Nothing to review" and stop.

Never review your own merge request without saying so. If the author is you, review it anyway when asked — a second pass on your own work is useful — but open the summary with the fact that you wrote it, so nobody mistakes it for an independent sign-off.

### 2. Gather the context

```bash
bash <this skill's directory>/scripts/review-context.sh <project> <iid> > <tmp>/review.json
```

One JSON object: the merge request, its `diff_refs`, the issue's number, the changed files with their diffs, every pipeline job and the failing ones separately, and the threads already on the merge request. Read its header for the shape. Exit **5** means the merge request could not be read — report it and stop.

Read the existing threads now, before forming any opinion, so this review does not repeat one an earlier review already left:

```bash
jq -r '.discussions[] | "\(.id) \(if .resolved then "resolved" else "open" end) \(.path // "-"):\(.line // "-") \(.author): \(.body)"' <tmp>/review.json
```

Then resolve that number to the actual issue, which may be in GitLab or on drupal.org:

```bash
ISSUE_REF=$(jq -r '.issue_ref // empty' <tmp>/review.json)
[ -n "$ISSUE_REF" ] && bash <this skill's directory>/scripts/read-issue.sh <project> "$ISSUE_REF" > <tmp>/issue.json
```

See [The issue lives in one of two places](#the-issue-lives-in-one-of-two-places) for the exit codes and why the two must never be tried interchangeably. A null `issue_ref`, or exit **6**, means you are reviewing without the requirement — do it anyway, and say so in the summary, because "does this match the issue" is the first question below and you will not have been able to answer it. Exit **7** means the number resolved to a different project's issue: discard it and treat the requirement as unavailable rather than reviewing against the wrong one.

### 3. Read what was actually asked

The issue is the requirement; the merge request description is usually one line. Before judging the code, settle what the change is *for*:

- What does the issue ask for, in one sentence?
- What does the diff do that the issue did not ask for?
- What does the issue ask for that the diff does not do?

```bash
jq -r '"\(.source) · \(.status)\n\n\(.title)\n\n\(.description)"' <tmp>/issue.json
```

Scope is the most common real finding and the easiest to miss once you are reading code. Answer these three before opening a single file.

### 4. Review the diff

The diff is already in `<tmp>/review.json`. Fetch whole files only when the hunks are not enough — nothing here clones:

```bash
jq -r '.files[] | "=== \(.new_path)\n\(.diff)"' <tmp>/review.json

# A whole file as the branch leaves it. <path> is URL-encoded: dots become %2E and
# slashes %2F.
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/repository/files/<path>/raw?ref=<head-sha>"
```

Split the review across sub-agents by *concern*, not by file, and launch them together per [Sub-agents](#sub-agents) — they are all reads. One each for correctness, Drupal API conventions, tests and security is a reasonable default; give each the diff and the issue summary from Step 3.

What to look for, beyond ordinary code review:

- **Scope** — changes the issue did not ask for. Unrelated lint fixes, formatting sweeps and version bumps belong in their own issue, and saying so is a legitimate review finding.
- **`*.info.yml`** — `core_version_requirement` covers the target branch; dependencies use the `project:module` form; no `version` key in a contrib module (drupal.org adds it on packaging).
- **`composer.json`** — constraints agree with `core_version_requirement`, and anything new is actually required.
- **Services** — constructor injection, not `\Drupal::` in classes that can take a container. New services declared in `*.services.yml` with their dependencies.
- **Translation** — user-facing strings go through `t()` or `StringTranslationTrait`; no concatenation inside the translatable string, placeholders instead.
- **Access and input** — routes carry `_permission`, `_entity_access` or `_custom_access`; database queries are parameterized; no user input reaching `#markup` unescaped.
- **Render and cache** — render arrays over raw markup, with `#cache` contexts and tags that match what the output actually varies on.
- **Config** — new config keys have schema in `config/schema/`; a change to the shape of existing config comes with a `hook_update_N`.
- **Hooks** — correct implementation name, and the `#[Hook]` attribute where the target branch supports it.
- **Tests** — new behaviour is covered, and the test extends the right base class for what it touches.
- **Deprecations** — nothing the target branch has deprecated, and nothing removed in the next major.
- **Leftovers** — no `dpm()`, `kint()`, `var_dump()`, `dd()`, commented-out blocks or stray `@todo` without an issue number.

### 5. Read the pipeline, not the badge

`failing_jobs` from Step 2 is the authoritative list. A merge request can show a green pipeline with forgiven jobs red — which jobs varies by project, and includes test suites on some — so check that array rather than the rollup, and raise a forgiven failure as a finding like any other.

```bash
jq -r '.failing_jobs[] | "\(.name): \(.status)\(if .allow_failure then " (forgiven by the pipeline)" else "" end) job=\(.id)"' <tmp>/review.json
```

Read a job's log before attributing a failure to the change — a job can be red for reasons that predate the branch. Read it from `pipeline_project_id`, not the fork, because the pipeline may have run in the parent:

```bash
PIPELINE_PROJECT=$(jq -r '.pipeline_project_id' <tmp>/review.json)
glab api --hostname git.drupalcode.org "projects/$PIPELINE_PROJECT/jobs/<job-id>/trace"
```

### 6. Post the findings

A finding tied to a line goes inline, as a resolvable thread. Write the body to a file — review comments are markdown, and the shell mangles backticks and newlines:

```bash
printf '%s\n' "This runs on every request; consider caching it." > <tmp>/finding.md
bash <this skill's directory>/scripts/post-inline-comment.sh <project> <iid> <path> <new-line> <tmp>/finding.md
```

Exit **1** covers both ways this goes wrong:

- GitLab rejected the position outright — most often a context line passed without its old-side line number. A line that exists on both sides of the diff needs both: pass the old line as the sixth argument. The hunk header (`@@ -4,5 +4,6 @@`) carries the pair.
- GitLab accepted it but dropped the position, leaving an ordinary thread in the Overview tab rather than a comment on the line. The script checks for this and treats it as a failure, because the API returns `201` either way.

Either way, do not retry with a guessed line number — that lands a comment on the wrong code, which is worse than not commenting. Fix the line pair or move the point into the summary.

Exit **5** means the merge request could not be read at all this time, even though Step 2 managed it — so almost always a transient API failure rather than anything about the position. Retry that one comment once; if it fails again, move the point into the summary and say there that the inline comment could not be posted.

A finding an existing thread already raises gets a reply in that thread, not a new one:

```bash
glab api --hostname git.drupalcode.org -X POST \
    "projects/<namespace>%2F<project>/merge_requests/<iid>/discussions/<discussion-id>/notes" \
    -F "body=@<tmp>/finding.md"
```

Then one summary note, and only one:

```bash
glab mr note create <iid> -R git.drupalcode.org/<namespace>/<project> < <tmp>/summary.md
```

The summary says, in this order: whether the change does what the issue asked, anything out of scope, the findings that block, the findings that are suggestions, and the pipeline state. Separate *blocking* from *nice to have* explicitly — an unordered pile of twelve comments reads as a rejection even when ten of them are optional.

Say plainly when the change is good. A review that only ever lists problems trains people to ignore it.

### 7. Hand it back

Only when something blocks, move the issue to needs-work. The `/do:` lines are drupal.org bot commands, so post them **verbatim**:

```bash
glab issue note <issue-id> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
Reviewed, comments inline.

/do:label ~"state::needsWork"
EOF
)"
```

Only when `writable` was `true` in Step 2. A drupal.org-only issue has no `/do:` path — its status moves through the web UI — so do not attempt this. Report the findings, link the issue's `url`, and leave the status change to the user.

When nothing blocks, **stop**. Do not set `state::rtbc`, do not approve, do not merge: say the review found nothing blocking and let the user decide. Marking somebody else's work ready to commit is not a call this skill gets to make.

## Rules

- Review exactly one merge request per run. If asked to review several, repeat the whole workflow per merge request, and keep each review's comments to its own merge request.
- Read-only against git: never clone, check out, push, rebase or merge. Everything comes through the API. This is also why this skill may run alongside any other LoachBot run, including on the same project.
- Never approve, never set `state::rtbc`, never merge. The most this skill does to a state is `state::needsWork`, and only when a finding genuinely blocks.
- Post inline comments only on lines the diff actually touches, and only one summary note per run. Do not re-post a finding an existing thread already raises (Step 2); reply in that thread instead (Step 6).
- Separate blocking findings from suggestions, every time.
- Judge the change against the issue and the target branch, not against how you would have written it. Style preferences that `phpcs` does not enforce are not findings.
