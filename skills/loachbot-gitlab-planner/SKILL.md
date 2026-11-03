---
name: loachbot-gitlab-planner
description: Plan the next issues for a drupal.org project (module, theme or Drupal core) by reading its code, issue queue, branches and CI, then propose a prioritized, branch-targeted plan and file the approved issues in its GitLab queue. For GitHub repositories use loachbot-github-planner instead. Use when the user wants to plan upcoming work on a drupal.org project, build a roadmap for a contrib module, decide what to work on next there, or asks to "run LoachBot GitLab Planner" or "plan issues" for a drupal.org project.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-planner/SKILL.md
    license: MIT
---
# LoachBot GitLab Planner

## Prerequisites

- `glab` authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` on `PATH`; the scripts parse `glab api` JSON with it.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH`, needed only for projects whose queue never moved to GitLab, such as Drupal core (see Step 3). Reads need no login.
- Paths assume the `project/` namespace. For sandboxes set `LOACHBOT_GITLAB_NAMESPACE=sandbox`; `LOACHBOT_GITLAB_HOST` points the scripts at another GitLab.
- SSH access to `git.drupal.org`, used by the clone in Step 2.
- Clones go in `~/Projects` (created if missing); `LOACHBOT_PROJECTS_DIR` overrides it.

## Conventions

`bash` blocks are templates: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`) and `<namespace>` (`project`, or `LOACHBOT_GITLAB_NAMESPACE` when set), and adapt to the project.

Longer sequences live in `scripts/`, invoked as `bash <this skill's directory>/scripts/<name>.sh`; each header documents arguments and exit codes.

`<tmp>` is a scratch directory made once per run with `mktemp -d`. Runs may overlap, so never use a fixed `/tmp` path.

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

Verify what matters in a report: read the diff or re-run the command.
<!-- /SHARED: sub-agents -->

## How drupal.org differs

Four differences change what a plan can contain and where it lands, and each fails quietly.

- **Two hostnames.** The API is at `git.drupalcode.org`; git is at `git.drupal.org`. Mixing them fails. Take clone URLs from the API's `ssh_url_to_repo`, as `scripts/sync-project-clone.sh` does.
- **The queue is in one of two places.** Most contrib queues migrated into GitLab as *work items* at `/-/work_items/<iid>`. Drupal core and a few others (`eck`) stayed on drupal.org, which has no API to file against. Step 3 settles which, deciding whether this skill can file the plan or only hand it over.
- **A release is a branch.** Contrib carries a branch per minor (`1.4.x`, `1.5.x`), the default branch ahead of the newest supported one, and a tag per release. The same fix on `1.4.x` and on the default branch is two pieces of work, so each issue names its branch.
- **Metadata is the project's own labels.** drupal.org's GitLab uses `category::bug|feature|task|support|plan`, `priority::critical|major|normal|minor`, `state::*` and `why::*`, but which exist and how they are spelled varies. Step 3 reads the real list; Step 7 applies nothing outside it.

Every filed issue ends with `AI-Generated: Yes`; see [Rules](#rules).

`glab api`: `-f` sends a plain string, `-F` types its value and reads `@path` as file contents; `--paginate` prints one JSON array per page, so merge with `jq -s 'add'`.

## Workflow

### 1. Resolve the project

In this order:

1. A project in the prompt or arguments: a machine name (`ai_ckeditor`), a `https://www.drupal.org/project/<project>` URL, or a `https://git.drupalcode.org/<namespace>/<project>` URL. Extract the machine name.
2. Otherwise, if the working directory is a drupal.org checkout, read it off the remote:
    ```bash
    # Strip `.git` and an issue fork's `-<issue-id>`; machine names never contain hyphens.
    git remote -v |
        awk '/git\.drupal(code)?\.org/ {print $2}' |
        sed -E 's#\.git$##; s#.*/##; s#-[0-9]+$##' |
        head -n 1
    ```
3. Otherwise ask the user.

Do not proceed without one. An issue fork (`issue/<project>-<id>`) resolves to the project's machine name; the plan belongs to the project.

### 2. Get the latest code

Clone into `~/Projects/drupalcode/<project>` if missing, otherwise reset to the remote default branch:

```bash
CLONE=$(bash <this skill's directory>/scripts/sync-project-clone.sh <project> | tail -1)
cd "$CLONE"
```

Act on its exit code:

- **5** → the clone holds local work (uncommitted changes or commits the remote default branch lacks). Report what the script printed and stop; the user decides. Never clobber it — it may be their own working clone.
- **6** → the project could not be read. Check the machine name and namespace (a sandbox needs `LOACHBOT_GITLAB_NAMESPACE=sandbox`), then report it and stop.
- Any other non-zero → the script names the failing git command on stderr. Report it; do not force through it.

The script names the project remote `upstream`, like `loachbot-gitlab-issue` and `loachbot-gitlab-mr`, so the three share one clone. It leaves an existing clone's remotes alone.

### 3. Read the queue, the releases and the labels

Read the queue before the code, so the plan does not re-file what it already holds:

```bash
bash <this skill's directory>/scripts/project-context.sh <project> > <tmp>/plan-context.json
jq -r '"\(.path) default=\(.default_branch) queue=\(.issue_queue) open=\(.open_issues_count) capped=\(.capped)"' \
    <tmp>/plan-context.json
```

Act on its exit code:

- **0** → read. Everything below works from `<tmp>/plan-context.json`.
- **6** → the project could not be read on the API host. Report it and stop.

Then branch on `issue_queue`:

- `"gitlab"` → the ordinary case. Step 6 checks candidates against `open_issues`, `recently_closed` and `open_merge_requests`; Step 7 applies only from `labels`.
- `"drupal.org"` → nothing to file against through the API. Say so early and plan anyway; the plan is handed to the user to file. The queue is readable only through the `drupalorg` CLI, the sole duplicate check:
    ```bash
    drupalorg issue:search <project> "<two or three keywords>" --status=all --limit=20 --format=llm
    ```
    Without `drupalorg`, say plainly that no duplicate check was possible and every item needs checking by hand before filing.

`capped: true` means `open_issues` is one page, not the whole queue. Treat it as a sample, say so when presenting the plan, and search per candidate in Step 6.

If `archived: true`, raise it before going further: planning into an archived project is usually not what the user meant.

### 4. Get acquainted with the project

Fan these reads out across concurrent sub-agents per [Sub-agents](#sub-agents) and plan from their summaries, keeping file contents out of the main thread:

- `README.md`, `*.info.yml` (`core_version_requirement`, `dependencies`, `package`), `composer.json` — claimed support and dependencies
- `src/` — plugins under `src/Plugin/`, services in `*.services.yml`, forms, entities, event subscribers
- `*.module`, `*.install`, `*.post_update.php` — hooks, and whether config changes shipped a `hook_update_N`
- `config/install` and `config/schema` — unschemaed config keys are a common, well-scoped gap
- `tests/src/Unit`, `tests/src/Kernel`, `tests/src/Functional`, `tests/src/FunctionalJavascript` — coverage, and which critical path lacks it
- `*.libraries.yml`, `js/`, `css/`, `templates/` — front-end surface, and admin UI hand-rolling what Form API does
- `.gitlab-ci.yml` — which drupal.org CI template it includes, and which jobs are `allow_failure: true`
- `phpcs.xml.dist`, `phpstan.neon.dist`, `cspell.json` — standards opted into, and not
- `git log --oneline -30` on the default branch, plus a shorter log on each other branch from `branches`

Three drupal.org-specific sources of well-scoped issues:

- **Core compatibility.** `core_version_requirement` against the current and next Drupal major, plus `@deprecated` usage. A module that stops installing on the next major is the biggest risk.
- **Forgiven CI jobs that are red.** The CI template marks jobs `allow_failure: true`, so the pipeline, badge and `glab ci status` report success while `phpcs`, `phpstan`, `cspell` or `eslint` fail. Read the newest default-branch pipeline job by job; each red-but-forgiven job is a candidate issue with its work already enumerated.
- **Release hygiene.** Compare `tags` with the default branch: far ahead of the newest tag means unreleased work, a plan item of its own.

### 5. Establish goals and current state

Summarize for the user:

```
Project: <machine name and human title>
Goal: <what the project does, and for whom>
Status: <where it stands today. Supported branches and the newest release, active workstreams from the queue and the open merge requests, the biggest gaps or risks between now and its goals>
```

### 6. Build the plan

Identify work that moves the project toward its goals and organize it into a plan, not a scattershot list. Aim for **3-10** issues from these areas (skip any that don't apply):

- **Bugs**: real defects, edge cases, broken paths
- **Features**: gaps aligned with stated goals
- **Core compatibility**: deprecated API use, the next Drupal major, dependency ranges
- **Refactor**: tech debt, duplication, dead code, brittle patterns blocking future work
- **Tests**: uncovered critical paths, with the test type Drupal expects (unit, kernel, functional)
- **Docs**: README sections, the project page, contributor docs
- **Tooling**: forgiven CI jobs, `phpcs`/`phpstan` levels, release automation
- **Performance / Accessibility / Security**: when relevant

For each issue:

- **Prioritize** it, justified by Step 5's goals and gaps.
- **Right-size** it to one coherent unit of work, not an epic. Split anything too large.
- **Target a branch** from `branches` and `default_branch`: the default branch unless there is a reason, which you name.

Draft each in this shape:

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

Check each candidate against `open_issues`, `recently_closed` and `open_merge_requests` from Step 3. When `capped` was true, also search per candidate to catch duplicates outside the sample:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues?search=<two or three keywords>&in=title,description&per_page=20" |
    jq -r '.[] | "#\(.iid) [\(.state)] \(.title)"'
```

Drop the candidate if any existing item:

- addresses the same root cause or code location
- has the same fix or goal, even under a different title
- is closed as fixed, or covered by an open merge request that makes it redundant

Keep only issues with **no existing overlap**; when in doubt, drop it.

### 7. Present the plan and file what is approved

Present the plan as an ordered list, highest return on investment first, and ask which issues to file. Do **not** file anything without explicit approval.

Make each approved issue self-contained: carry Step 4's grounding (paths, line references, commits, links), Step 5's reason, and dependencies on issues filed earlier in this run by number (`Blocked by #3615838`). Include facts from memory or notes only if fit for a public queue: no client or personal details, credentials or internal URLs.

Write the body to a file (the shell mangles markdown backticks and newlines), using drupal.org's issue summary headings:

```bash
cat > <tmp>/planned-issue.md <<'EOF'
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

File in plan order, so later issues can reference earlier ones by number:

```bash
glab api --hostname git.drupalcode.org -X POST "projects/<namespace>%2F<project>/issues" \
    -f "title=<title>" \
    -f "labels=<comma-separated labels>" \
    -F "description=@<tmp>/planned-issue.md" |
    jq -r '.web_url'
```

Deliberate omissions:

- **`labels` carries only names from Step 3's `labels` list**, matching the category and priority (`category::bug`, `priority::normal`). Filing against an undefined label creates it, littering the queue with a near-duplicate spelling. Omit the flag rather than guess, and never set a `state::` label: triage is the maintainers', and `loachbot-gitlab-issue` reads an issue with none as ready to pick up.
- **No assignee.** On drupal.org a claim is a `/do:assign me` comment, and an unclaimed issue is what the queue and `loachbot-gitlab-issue` read as available. Pre-assigning claims work you have not started.

When Step 3 reported `issue_queue: "drupal.org"`, there is nothing to POST to. Hand the approved issues to the user as ready-to-paste summaries and point them at the form:

> `https://www.drupal.org/node/add/project-issue/<project>`

Then report, in plan order, each filed issue's URL or each drafted body. Close with what is left: maintainer triage (component, version, `state::accepted`), and that `loachbot-gitlab-issue` picks these up once queued. Leave unapproved items unfiled, and do not list them as pending.

## Rules

- Write nothing to drupal.org except the issues the user explicitly approved: no comments, no `/do:` commands, no labels on existing items, no branches, no merge requests, no code edits.
- Never file an issue the user did not explicitly approve, nor into a queue you could not check for duplicates without saying so first.
- File issues unassigned and with no `state::` label. A claim is a comment, and triage belongs to the maintainers.
- Only apply labels the project has already defined. Filing against an undefined label creates it.
- Every filed issue carries `AI-Generated: Yes`. Drupal.org [requires the disclosure](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) of AI-generated contributions, and a maintainer may decline one without it.
- Every issue names the branch it lands on; "the default branch" is an answer, not a default.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
- A plan is ordered and justified: every issue carries a priority, a branch and a place in the sequence.
- Prefer specificity over volume: five sharp issues beat ten vague ones. Ground each in something concrete (a file path, a commit, a red-but-forgiven CI job, a missing test); no generic items like "add more tests".
- Delegate Step 4 per [Sub-agents](#sub-agents), launching independent reads together; reserve the main thread for synthesis and approve/file steps.
