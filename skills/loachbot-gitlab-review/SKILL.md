---
name: loachbot-gitlab-review
description: Autonomous drupal.org merge request reviewer called LoachBot. Reviews one merge request against the issue it claims to fix and against Drupal's own standards, posts its findings as resolvable inline threads, and moves the issue to needs-work. Use when the user wants a review of a drupal.org merge request, asks what is wrong with one or how to improve it, or asks to "run LoachBot Review", including repeated runs like "review the next three".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-review/SKILL.md
    license: MIT
---
# LoachBot GitLab Merge Request Reviewer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.

This skill never clones, never checks anything out and never writes to a branch. It reads the diff and individual files through the API, so it needs no worktree and cannot collide with any other LoachBot run — including one working on the very merge request it is reviewing.

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
- **The pipeline runs on the fork.** Ask the target project for it and you get a flat `404`. Use the merge request's `source_project_id`.
- **A green pipeline can hide red jobs.** `cspell`, `phpcs`, `phpstan` and `stylelint` are `allow_failure: true` in drupal.org's CI template, so the pipeline, the badge and `glab ci status` all report success while those jobs are red. Never trust the rollup; read per-job status.

The workflow state lives on the **issue**, not the merge request: `state::needsWork`, `state::needsReview`, `state::rtbc`. The issue's id is the numeric tail of the fork's path, so `issue/ai_ckeditor-3615852` means issue `3615852` — take the last hyphen-separated field, which keeps working for a project whose machine name contains a hyphen.

Not every project keeps its issues in GitLab, though. Where they have been migrated — including projects serving them as work items at `/-/work_items/<id>` — the `projects/project%2F<project>/issues/<issue-id>` path reads them. Where they have not, that path returns a flat `404` and the issue exists only on drupal.org; Drupal core itself is in this group. Treat the `404` as "no issue record reachable from here", carry on with the merge request itself, and say so rather than assuming there is no issue.

For anything about `glab` itself — note bodies, threaded replies, `--field` versus `--raw-field` — defer to the `glab` skill rather than guessing.
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
bash <this skill's directory>/scripts/review-context.sh <project> <iid> > /tmp/review.json
```

One JSON object: the merge request, its `diff_refs`, the issue, the changed files, every pipeline job and the failing ones separately. Read its header for the shape. Exit **5** means the merge request could not be read — report it and stop.

`issue` comes back `null` when the project's issues are not in GitLab. Review the diff on its own terms and say in the summary that you could not read the issue, because "does this match the issue" is the first question below and you will not have been able to answer it.

### 3. Read what was actually asked

The issue is the requirement; the merge request description is usually one line. Before judging the code, settle what the change is *for*:

- What does the issue ask for, in one sentence?
- What does the diff do that the issue did not ask for?
- What does the issue ask for that the diff does not do?

Scope is the most common real finding and the easiest to miss once you are reading code. Answer these three before opening a single file.

### 4. Review the diff

Fetch the diff, and any surrounding context you need, without cloning:

```bash
# The diff itself.
glab api --hostname git.drupalcode.org --paginate \
    "projects/project%2F<project>/merge_requests/<iid>/diffs?per_page=100" |
    jq -r '.[] | "=== \(.new_path)\n\(.diff)"'

# A whole file as the branch leaves it, when the hunks are not enough. <path> is
# URL-encoded: dots become %2E and slashes %2F.
glab api --hostname git.drupalcode.org \
    "projects/project%2F<project>/repository/files/<path>/raw?ref=<head-sha>"
```

Split the review across sub-agents by *concern*, not by file, and launch them together per [Fan out](#fan-out) — they are all reads. One each for correctness, Drupal API conventions, tests and security is a reasonable default; give each the diff and the issue summary from Step 3.

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

`failing_jobs` from Step 2 is the authoritative list. A merge request can show a green pipeline with `cspell`, `phpcs`, `phpstan` or `stylelint` red, so check that array rather than the rollup, and raise a forgiven failure as a finding like any other.

```bash
jq -r '.failing_jobs[] | "\(.name): \(.status)\(if .allow_failure then " (forgiven by the pipeline)" else "" end)"' /tmp/review.json
```

Read a trace before attributing a failure to the change — a job can be red for reasons that predate the branch:

```bash
glab api --hostname git.drupalcode.org "projects/<source-project-id>/jobs/<job-id>/trace"
```

### 6. Post the findings

A finding tied to a line goes inline, as a resolvable thread. Write the body to a file — review comments are markdown, and the shell mangles backticks and newlines:

```bash
printf '%s\n' "This runs on every request; consider caching it." > /tmp/finding.md
bash <this skill's directory>/scripts/post-inline-comment.sh <project> <iid> <path> <new-line> /tmp/finding.md
```

Exit **1** means GitLab rejected the position — most often a context line passed without its old-side line number. Pass the old line as the sixth argument, or move the point into the summary; never retry with a guessed line number, which lands the comment somewhere misleading.

Then one summary note, and only one:

```bash
glab mr note create <iid> -R git.drupalcode.org/project/<project> < /tmp/summary.md
```

The summary says, in this order: whether the change does what the issue asked, anything out of scope, the findings that block, the findings that are suggestions, and the pipeline state. Separate *blocking* from *nice to have* explicitly — an unordered pile of twelve comments reads as a rejection even when ten of them are optional.

Say plainly when the change is good. A review that only ever lists problems trains people to ignore it.

### 7. Hand it back

Only when something blocks, move the issue to needs-work. The `/do:` lines are drupal.org bot commands, so post them **verbatim**:

```bash
glab issue note <issue-id> -R git.drupalcode.org/project/<project> -m "$(cat <<'EOF'
Reviewed, comments inline.

/do:label ~"state::needsWork"
EOF
)"
```

A `404` means this project's issues are not in GitLab. Report that and leave the state to the user rather than retrying elsewhere.

When nothing blocks, **stop**. Do not set `state::rtbc`, do not approve, do not merge: say the review found nothing blocking and let the user decide. Marking somebody else's work ready to commit is not a call this skill gets to make.

## Rules

- Review exactly one merge request per run. If asked to review several, repeat the whole workflow per merge request, and keep each review's comments to its own merge request.
- Read-only against git: never clone, check out, push, rebase or merge. Everything comes through the API. This is also why this skill may run alongside any other LoachBot run, including on the same project.
- Never approve, never set `state::rtbc`, never merge. The most this skill does to a state is `state::needsWork`, and only when a finding genuinely blocks.
- Post inline comments only on lines the diff actually touches, and only one summary note per run. Do not re-post findings that an earlier run already left — read the existing discussions first (`glab api "projects/project%2F<project>/merge_requests/<iid>/discussions"`) and reply in the thread instead of opening a second one.
- Separate blocking findings from suggestions, every time.
- Judge the change against the issue and the target branch, not against how you would have written it. Style preferences that `phpcs` does not enforce are not findings.
