---
name: loachbot-gitlab-planner
description: Plan the next set of issues for a drupal.org project by reading its code, learning its goals, and proposing a prioritized, sequenced plan of issues to file in its GitLab queue. Use when the user wants to plan upcoming work on a drupal.org module or theme, build a roadmap for a contrib project, decide what to tackle next there, or asks to "run LoachBot GitLab Planner" or "plan issues" for a drupal.org project.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-planner/SKILL.md
    license: MIT
---
# LoachBot GitLab Planner

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH` matters only for a project whose issue queue never moved to GitLab — Drupal core among them. There it is the only way to see what the queue already holds, and Step 3 says what to do without it. Reads need no login.
- Paths assume drupal.org's `project/` namespace. Sandboxes live under `sandbox/` instead, so set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for those; `LOACHBOT_GITLAB_HOST` likewise points the scripts at another GitLab.
- SSH access to `git.drupal.org`, which is what the clone in Step 2 uses.
- `~/Projects` is where clones go by default; `LOACHBOT_PROJECTS_DIR` overrides it. It is created if missing, so change it only if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`) before running them, and adapt anything that doesn't fit the project in front of you.

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

## How drupal.org differs

Planning here is not planning for a GitHub repository with different URLs. Four differences change what a plan can contain and where it can land, and each of them fails quietly rather than loudly.

- **Two hostnames, one service.** The API lives at `git.drupalcode.org`; git itself lives at `git.drupal.org`. An API path on the git host and an SSH URL on the API host both fail. Take clone URLs from the API's own `ssh_url_to_repo`, which is what `scripts/sync-project-clone.sh` does rather than composing one from the host.
- **The issue queue is in one of two places.** Most of contrib had its queue migrated into GitLab, where issues are served as *work items* at `/-/work_items/<iid>`. Drupal core and a few others — `eck` among them — never migrated and keep theirs on drupal.org, which has no API to file against. Step 3 settles which before anything is drafted, because it decides whether this skill can file the plan or only hand it over.
- **A release is a branch, not a trunk.** A contrib project carries a branch per minor — `1.4.x`, `1.5.x` — with the default branch out in front of the newest supported one, and a tag per release. So *which branch does this land on* is part of each issue rather than an afterthought: the same fix on `1.4.x` and on the default branch is two different pieces of work, and a plan that never says which one it means is a plan a contributor has to guess at.
- **Issue metadata is the project's own labels.** drupal.org's GitLab uses `category::bug|feature|task|support|plan`, `priority::critical|major|normal|minor`, `state::*` and `why::*` — but which of those a given project has actually defined varies, and so do the spellings. Step 3 reads the real list and Step 7 applies nothing outside it.

And one that is policy rather than mechanics: drupal.org [requires](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) a contribution whose text was substantially generated by an AI tool to say so. An issue filed by this skill is such a contribution, so every one carries an `AI-Generated: Yes` line. It is not a courtesy to drop because the issue came out short.

For anything about `glab` itself — note bodies, `--field` versus `--raw-field`, pagination — defer to the `glab` skill rather than guessing.

## Workflow

### 1. Resolve the project

Determine which drupal.org project to plan for, in this order:

1. A project named in the prompt or skill arguments: a machine name (`ai_ckeditor`), a `https://www.drupal.org/project/<project>` URL, or a `https://git.drupalcode.org/project/<project>` URL. Take the machine name out of it.
2. Otherwise, if the current working directory is a drupal.org checkout, read it off the remote:
    ```bash
    # Last path segment of the first drupal.org remote, minus `.git`, minus the trailing
    # `-<issue-id>` an issue fork carries. Machine names use underscores, never hyphens,
    # so that last substitution cannot eat part of a real one.
    git remote -v |
        awk '/git\.drupal(code)?\.org/ {print $2}' |
        sed -E 's#\.git$##; s#.*/##; s#-[0-9]+$##' |
        head -n 1
    ```
3. Otherwise ask the user for one.

Do not proceed without one. Everything below takes the machine name alone — `ai_ckeditor`, never `project/ai_ckeditor`. An issue fork checkout (`issue/<project>-<id>`) resolves to the same machine name, since the plan belongs to the project rather than to somebody's fork of it.

### 2. Get the latest code

Clone into `~/Projects/drupalcode/<project>` if missing, otherwise reset to the remote default branch:

```bash
CLONE=$(bash <this skill's directory>/scripts/sync-project-clone.sh <project> | tail -1)
cd "$CLONE"
```

Act on its exit code:

- **5** → the clone holds local work: uncommitted changes, or commits the remote default branch does not have. Either way it's notes, an experiment or a stash-in-progress. Report what the script printed and stop, letting the user decide what to do with it. Never clobber it — `~/Projects/drupalcode/<project>` may well be their own working clone rather than a scratch one.
- **6** → the project could not be read. Check the machine name and the namespace (a sandbox needs `LOACHBOT_GITLAB_NAMESPACE=sandbox`), then report it and stop.
- Any other non-zero → the script names the failing git command on stderr. Report it; do not force through it.

The script names the project remote `upstream`, the way `loachbot-gitlab-issue` and `loachbot-gitlab-mr` do, so the three skills can share one clone. It leaves an existing clone's remotes alone.

### 3. Read the queue, the releases and the labels

A plan that re-files what the queue already holds is worse than no plan, so read the queue before reading the code:

```bash
bash <this skill's directory>/scripts/project-context.sh <project> > /tmp/plan-context.json
jq -r '"\(.path) default=\(.default_branch) queue=\(.issue_queue) open=\(.open_issues_count) capped=\(.capped)"' \
    /tmp/plan-context.json
```

Act on its exit code:

- **0** → read. Everything below works from `/tmp/plan-context.json`.
- **6** → the project could not be read on the API host. Report it and stop.

Then branch on `issue_queue`, because it decides where the plan can go:

- `"gitlab"` → the ordinary case. `open_issues`, `recently_closed` and `open_merge_requests` are what Step 6 checks candidates against, and `labels` is the only list Step 7 may apply from.
- `"drupal.org"` → this project's queue never moved to GitLab, so there is nothing to file against through the API. Say so early, and plan anyway: the plan is still worth having, it just gets handed to the user to file. The queue is only readable through the `drupalorg` CLI, which is the one thing standing between the plan and a pile of duplicates:
    ```bash
    drupalorg issue:search <project> "<two or three keywords>" --status=all --limit=20 --format=llm
    ```
    Without `drupalorg` installed, say plainly that no duplicate check was possible and that every item needs checking by hand before filing.

`capped: true` means `open_issues` is one page rather than the whole queue — drupal.org queues run to hundreds. Treat the list as a sample, say so when presenting the plan, and have Step 6 search per candidate rather than trusting it.

`archived: true` is worth raising before going further: planning work into an archived project is usually not what the user meant.

### 4. Get acquainted with the project

Read enough to plan with real context. Fan these out across concurrent sub-agents per [Sub-agents](#sub-agents) and plan from their summaries, keeping file contents out of the main thread.

What a Drupal project keeps where, and what each one tells a planner:

- `README.md`, `*.info.yml` (`core_version_requirement`, `dependencies`, `package`), `composer.json` — what it claims to support, and what it depends on
- `src/` — plugins under `src/Plugin/`, services declared in `*.services.yml`, forms, entities, event subscribers
- `*.module`, `*.install`, `*.post_update.php` — hook implementations, and whether config changes ever shipped a `hook_update_N`
- `config/install` and `config/schema` — unschemaed config keys are a common, well-scoped gap
- `tests/src/Unit`, `tests/src/Kernel`, `tests/src/Functional`, `tests/src/FunctionalJavascript` — what is covered, and which critical path is not
- `*.libraries.yml`, `js/`, `css/`, `templates/` — front-end surface, and anything an admin UI does by hand that Form API already does
- `.gitlab-ci.yml` — which drupal.org CI template it includes, and which jobs it marks `allow_failure: true`
- `phpcs.xml.dist`, `phpstan.neon.dist`, `cspell.json` — the standards the project has opted into, and the ones it has not
- `git log --oneline -30` on the default branch, plus a shorter log on each other branch from `branches`, for where the work actually is

Three sources of real, well-scoped issues are specific to drupal.org and easy to miss:

- **Core compatibility.** `core_version_requirement` against the current and next Drupal major, plus use of anything `@deprecated`. A module that silently stops installing on the next major is the project's biggest risk, and it is visible from here.
- **Forgiven CI jobs that are actually red.** Drupal.org's CI template marks jobs `allow_failure: true`, so the pipeline, the badge and `glab ci status` all report success while `phpcs`, `phpstan`, `cspell` or `eslint` sit red. Read the newest pipeline on the default branch, job by job rather than from the rollup, and each red-but-forgiven job is a candidate issue with its work already enumerated for it.
- **Release hygiene.** `tags` against the default branch: a default branch a long way ahead of the newest tag means unreleased work, which is a plan item of its own.

### 5. Establish goals and current state

Summarize for the user, in this shape:

```
Project: <machine name and human title>
Goal: <what the project does, and for whom>
Status: <where it stands today. Supported branches and the newest release, active workstreams from the queue and the open merge requests, the biggest gaps or risks between now and its goals>
```

### 6. Build the plan

Identify the work that moves the project toward its goals, then organize it into a plan, not a scattershot list. Aim for **3-10** issues drawn from these areas (skip any that don't apply):

- **Bugs**: real defects spotted in code, edge cases, broken paths
- **Features**: gaps aligned with stated goals
- **Core compatibility**: deprecated API use, the next Drupal major, dependency version ranges
- **Refactor**: tech debt, duplication, dead code, brittle patterns that block future work
- **Tests**: uncovered critical paths, and the test type Drupal expects for each (unit, kernel, functional)
- **Docs**: missing README sections, the project page, contributor docs
- **Tooling**: the CI jobs the pipeline forgives, `phpcs`/`phpstan` levels, release automation
- **Performance / Accessibility / Security**: when relevant

Then turn that work into a plan:

- **Prioritize** each issue, justified by the goals and gaps from Step 5.
- **Right-size** each issue so it's a single coherent unit of work, not an epic. Split anything too large.
- **Target a branch** for each issue, from `branches` and `default_branch`. The default branch unless there is a reason, and name the reason when there is one.

Draft each planned issue in this shape:

```
# <Title, under 70 chars>
Branch: <which branch it lands on>
Category: <bug/feature/task/plan>
Priority: <critical/major/normal/minor>
Effort: <Small/Medium/Large>
Impact: <Low/Medium/High>
Body: <what's wrong or missing, with file references>
## Proposed resolution
<how it could be addressed>
## Remaining tasks
<the steps a contributor would take>
## How to test
<how we'd know it's done>
```

Check each candidate against `open_issues`, `recently_closed` and `open_merge_requests` from Step 3. When `capped` was true, search the queue per candidate as well, so a duplicate older than the sample still gets caught:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues?search=<two or three keywords>&in=title,description&per_page=20" |
    jq -r '.[] | "#\(.iid) [\(.state)] \(.title)"'
```

Drop the candidate if any existing item:

- addresses the same root cause or code location
- has the same fix or goal, even under a different title
- is already closed as fixed, or covered by an open merge request that would make it redundant

Only keep issues with **no existing overlap** — when in doubt, drop it rather than file a near-duplicate into somebody's queue.

### 7. Present the plan and file what is approved

Present the plan as an ordered list, most return-on-investment first, then ask which issues to file. Do **not** file anything without explicit approval.

Before filing, make each approved issue self-contained: the body must carry all the context a reader needs, because nobody reading the queue in six months saw this planning session. Fold in:

- Concrete grounding from Step 4: file paths and line references, code snippets, related commits, tags, and links to related issues or merge requests
- The priority, sequencing and dependencies from the plan, plus the goals from Step 5 that explain *why* this matters and *when* it should land; reference a dependency filed earlier in this run by number (`Blocked by #3615838`)
- Relevant facts from any persistent memory or project notes your harness keeps — but only facts fit for a public issue queue: no client or personal details, credentials, or internal URLs

Write the body to a file rather than inlining it, because an issue description is markdown and the shell mangles backticks and newlines. Use drupal.org's own issue summary headings, which is what a reviewer there expects to find:

```bash
cat > /tmp/planned-issue.md <<'EOF'
### Problem/Motivation

<what is wrong or missing, with file references, and why it matters for the project's goals>

### Proposed resolution

<how it could be addressed, and which branch it lands on>

### Remaining tasks

<the steps a contributor would take>

### How to test

<how we would know it is done>

AI-Generated: Yes
EOF
```

Then file it. Issues are created in plan order, so a later one can reference the earlier ones it depends on by number:

```bash
glab api --hostname git.drupalcode.org -X POST "projects/<namespace>%2F<project>/issues" \
    -f "title=<title>" \
    -f "labels=<comma-separated labels>" \
    -F "description=@/tmp/planned-issue.md" |
    jq -r '.web_url'
```

Two things that look like omissions and are not:

- **`labels` carries only names from Step 3's `labels` list**, matched to the plan's category and priority — `category::bug`, `priority::normal`. A label the project has not defined is created by filing against it, which litters the queue with a near-duplicate of a label that already exists under another spelling. Omit the flag entirely rather than guess, and never set a `state::` label: triage is the maintainers' to do, and `loachbot-gitlab-issue` reads an issue carrying none as ready to pick up.
- **No assignee.** On drupal.org a claim is a `/do:assign me` comment rather than a field, and an unclaimed issue is what the rest of the queue — and `loachbot-gitlab-issue` — reads as available. Filing an issue pre-assigned to yourself claims work you have not started.

When Step 3 reported `issue_queue: "drupal.org"`, there is nothing to POST to. Hand the approved issues to the user instead, each as a ready-to-paste summary, and point them at the form:

> `https://www.drupal.org/node/add/project-issue/<project>`

Then report, in plan order: each filed issue's URL, or each drafted body for the user to file. Close with what is left for them — the triage only a maintainer can do (component, version, `state::accepted`), and that `loachbot-gitlab-issue` is what picks these up once they are in the queue. Leave every unapproved item unfiled, and do not list it as though it were pending.

## Rules

- Planning writes nothing to drupal.org except the issues the user explicitly approved. No comments, no `/do:` commands, no labels on anything that already exists, no branches, no merge requests, no edits to the project's code.
- Never file an issue the user did not explicitly approve, and never file one into a queue you could not check for duplicates without saying so first.
- File issues unassigned and with no `state::` label. A claim on drupal.org is a comment, and triage belongs to the project's maintainers.
- Only apply labels the project has already defined. Filing against an undefined label creates it.
- Every filed issue carries `AI-Generated: Yes`. Drupal.org requires the disclosure, and an issue without it is one a maintainer may decline on that basis alone.
- Every issue in the plan names the branch it lands on. A contrib project has several supported at once, and "the default branch" is an answer, not a default.
- Runs collide only through the base clone they share, so that is what the limit is about. Step 2 resets the clone at `~/Projects/drupalcode/<project>`, which `loachbot-gitlab-issue` and `loachbot-gitlab-mr` build their worktrees from, so no other run may be using that same clone at the time. Runs against *different* projects are independent and may overlap freely, as can a GitHub LoachBot run at `~/Projects/<owner>/<repo>`. This bounds whole runs, not the sub-agents within one, which fan out per [Fan out](#fan-out).
- A plan is ordered and justified, not a pile of ideas — every issue carries a priority, a branch and a place in the sequence.
- Prefer specificity over volume: five sharp, well-sequenced issues beat ten vague ones. Ground each in something concrete (a file path, a commit, a red-but-forgiven CI job, a missing test) — no generic items like "add more tests".
- Delegate the Step 4 gathering per [Sub-agents](#sub-agents), launching the independent reads together rather than in sequence; reserve the main thread for plan synthesis and the approve/file steps.
