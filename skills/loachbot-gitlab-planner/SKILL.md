---
name: loachbot-gitlab-planner
description: Plan the next issues for a drupal.org project (module, theme or Drupal core) by reading its code, issue queue, branches and CI, then propose a prioritized, branch-targeted plan and file the approved issues in its GitLab queue. For GitHub repositories use loachbot-github-planner instead. Use when the user wants to plan upcoming work on a drupal.org project, build a roadmap for a contrib module, decide what to work on next there, or asks to "run LoachBot GitLab Planner" or "plan issues" for a drupal.org project.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-planner/SKILL.md
    license: MIT
---
# LoachBot GitLab Planner

<!-- SHARED: gitlab-prerequisites -->
## Prerequisites

- `glab auth status --hostname git.drupalcode.org` succeeds; if not, report it and stop (`glab auth login --hostname git.drupalcode.org` fixes it).
- `jq` on `PATH`; the scripts parse JSON with it.
- Paths assume the `project/` namespace; set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for sandboxes. `LOACHBOT_GITLAB_HOST` points the scripts at another GitLab; the commands written out here assume `git.drupalcode.org`.
<!-- /SHARED: gitlab-prerequisites -->
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH`, needed only for projects whose queue never moved to GitLab, such as Drupal core (see Step 3); reads need no login.
- SSH access to `git.drupal.org`, used by the clone in Step 2.
- Clones go in `~/Projects` (created if missing); `LOACHBOT_PROJECTS_DIR` overrides it.

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

## How drupal.org differs

- **Two hostnames.** The API is at `git.drupalcode.org`; git is at `git.drupal.org`. Mixing them fails. Take clone URLs from the API's `ssh_url_to_repo`.
- **The queue is in one of two places.** Most contrib queues migrated into GitLab as *work items* at `/-/work_items/<iid>`. Drupal core and a few others (`eck`) stayed on drupal.org, which has no API to file against. Step 3 settles which.
- **A release is a branch.** Contrib carries a branch per minor (`1.4.x`, `1.5.x`), the default branch ahead of the newest supported one, and a tag per release. The same fix on `1.4.x` and on the default branch is two pieces of work, so each issue names its branch.
- **Metadata is the project's own labels.** drupal.org's GitLab uses `category::bug|feature|task|support|plan`, `priority::critical|major|normal|minor`, `state::*` and `why::*`, but which exist and how they are spelled varies. Step 3 reads the real list; Step 7 applies nothing outside it.

`glab api`: `-f` sends a plain string, `-F` reads `@path` as file contents.

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

Do not proceed without one.

### 2. Get the latest code

Read the default branch from a detached worktree beside the shared clone at `~/Projects/drupalcode/<project>`:

```bash
WT=$(bash <this skill's directory>/scripts/setup-plan-worktree.sh <project>)
cd "$WT"
```

Act on its exit code:

- **6** → the project could not be read. Check the machine name and namespace (a sandbox needs `LOACHBOT_GITLAB_NAMESPACE=sandbox`), then report it and stop.
- Any other non-zero → report the failing git command from stderr and stop.

When the run ends, `git -C "$WT" worktree remove --force "$WT"` (git runs it from the base clone).

### 3. Read the queue, the releases and the labels

Read the queue before the code, so the plan does not re-file what it already holds:

```bash
bash <this skill's directory>/scripts/project-context.sh <project> > <tmp>/plan-context.json
jq -r '"\(.path) default=\(.default_branch) queue=\(.issue_queue) open=\(.open_issues_count) capped=\(.capped)"' \
    <tmp>/plan-context.json
```

Act on its exit code:

- **6** → the project could not be read on the API host. Report it and stop.

Then branch on `issue_queue`:

- `"gitlab"` → the ordinary case.
- `"drupal.org"` → nothing to file against through the API. Say so early and plan anyway; the plan is handed to the user to file. The queue is readable only through the `drupalorg` CLI, the sole duplicate check:
    ```bash
    drupalorg issue:search <project> "<two or three keywords>" --status=all --limit=20 --format=llm
    ```
    Without `drupalorg`, say plainly that no duplicate check was possible and every item needs checking by hand before filing.

`capped: true` means `open_issues` is a sample: say so when presenting, and search per candidate in Step 6.

If `archived: true`, raise it before going further.

### 4. Get acquainted with the project

Fan the reads out across concurrent sub-agents per [Sub-agents](#sub-agents) and plan from their summaries, keeping file contents out of the main thread. Beyond the obvious (README, `src/`, tests, recent log on each branch in `branches`), look for:

- Config changes without a `hook_update_N` or `*.post_update.php`, and config keys missing from `config/schema`.
- Test types Drupal expects (`tests/src/Unit`, `Kernel`, `Functional`, `FunctionalJavascript`) missing for a critical path.

Three drupal.org-specific sources of well-scoped issues:

- **Core compatibility.** `core_version_requirement` against the current and next Drupal major, plus `@deprecated` usage. A module that stops installing on the next major is the biggest risk.
- **Forgiven CI jobs that are red.** The CI template marks `phpcs`, `phpstan`, `cspell` and `eslint` `allow_failure: true`, so a green pipeline can hide them. Read the newest default-branch pipeline job by job; each red one is a ready-made issue.
- **Release hygiene.** Compare `tags` with the default branch: far ahead of the newest tag means unreleased work, a plan item of its own.

### 5. Establish goals and current state

Summarize for the user:

```
Project: <machine name and human title>
Goal: <what the project does, and for whom>
Status: <where it stands today. Supported branches and the newest release, active workstreams from the queue and the open merge requests, the biggest gaps or risks between now and its goals>
```

### 6. Build the plan

Aim for **3-10** issues that move the project toward its goals, each one coherent unit of work (split epics), with a title under 70 characters, a category, a priority justified by Step 5, an effort and impact, and a branch from `branches`. "The default branch" is an answer, not a default: name why when it is another.

Check each candidate against `open_issues`, `recently_closed` and `open_merge_requests`, and when `capped`, search:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues?search=<two or three keywords>&in=title,description&per_page=20" |
    jq -r '.[] | "#\(.iid) [\(.state)] \(.title)"'
```

Drop any candidate an existing item, open or closed as fixed, or an open merge request already covers, by root cause or goal rather than title; when in doubt, drop it.

### 7. Present the plan and file what is approved

Present the plan as an ordered list, highest return on investment first, each with its title, branch, category, priority, effort, impact and a one-line summary, and ask which issues to file. Do **not** file anything without explicit approval.

Make each approved issue self-contained: carry Step 4's grounding (paths, line references, commits, links), Step 5's reason, and dependencies on issues filed earlier in this run by number (`Blocked by #3615838`). Include facts from memory or notes only if fit for a public queue: no client or personal details, credentials or internal URLs.

Write the body to a file (the shell mangles markdown backticks and newlines), using drupal.org's issue summary headings. It ends with `AI-Generated: Yes`: drupal.org [requires the disclosure](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal), and a maintainer may decline an issue without it.

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
    jq -r '"\(.web_url) iid=\(.iid) labels=\(.labels | join(","))"'
```

GitLab silently drops labels a non-member may not set, so check the `labels=` it echoes. Apply any missing ones through drupalbot, one verbatim `/do:` line each, as the other LoachBot skills do:

```bash
glab issue note <new-iid> -R git.drupalcode.org/<namespace>/<project> -m "$(cat <<'EOF'
/do:label ~"category::bug"
/do:label ~"priority::normal"
EOF
)"
```

- **Labels only from Step 3's `labels` list**, for category and priority. An undefined label is created on filing, a near-duplicate spelling in the queue; omit rather than guess. Never a `state::` label: triage is the maintainers', and `loachbot-gitlab-issue` reads none as ready.
- **No assignee.** A claim is a `/do:assign me` comment; pre-assigning claims work you have not started.

When Step 3 reported `issue_queue: "drupal.org"`, there is nothing to POST to. Hand the approved issues to the user as ready-to-paste summaries and point them at the form:

> `https://www.drupal.org/node/add/project-issue/<project>`

Then report, in plan order, each filed issue's URL or drafted body, and what is left: maintainer triage (component, version, `state::accepted`), after which `loachbot-gitlab-issue` can pick them up. Do not list unapproved items as pending.

## Rules

- Write nothing to drupal.org except the issues the user explicitly approved, plus a `/do:label` note when filing dropped their labels: no other comments or `/do:` commands, no labels on existing items, no branches, no merge requests, no code edits.
- Never file into a queue you could not check for duplicates without saying so first.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
- Prefer specificity over volume: five sharp issues beat ten vague ones. Ground each in something concrete (a file path, a commit, a red-but-forgiven CI job, a missing test); no generic items like "add more tests".
