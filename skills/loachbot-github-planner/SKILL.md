---
name: loachbot-github-planner
description: Plan the next set of GitHub issues for a repository by reading the code, learning the project's goals, and proposing a prioritized, sequenced plan of issues to file. Use when the user wants to plan upcoming work, build a roadmap of issues, decide what to tackle next, or asks to "run LoachBot Planner" or "plan issues" for a GitHub repo.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-planner/SKILL.md
    license: MIT
---

# LoachBot GitHub Planner

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` is where clones go by default. It is created if missing, so change it only if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<owner>` and `<repo>` before running them, and adapt anything that doesn't fit the repository in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

<!-- SHARED: sub-agents -->
## Sub-agents

Delegate by default. The main thread picks the work, runs `gh` and `git`, and reports to the user; sub-agents do the reading, searching and editing.

Spin one up when any one of these holds:

- You would read a file to understand how something works.
- A question needs more than two searches.
- A change needs more than one sentence to describe.
- You would run a build, tests or a linter and react to the output.
- Two pieces of work are independent — launch them in one message so they run concurrently.

Exception: reading a file you already decided to edit. A run with no sub-agents at all almost certainly stretched it.

Types: `Explore` for read-only investigation (say how thorough); `general-purpose` for anything that edits or iterates.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

A report is a claim. Verify what matters: read the diff or re-run the command.
<!-- /SHARED: sub-agents -->

## Workflow

### 1. Resolve the repository

Determine which GitHub repository to plan for, in this order:

1. A repo named in the prompt or skill arguments (URL or `owner/repo`): use it.
2. Otherwise, if the current working directory is a git repo, use its `origin` remote: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
3. Otherwise ask the user for one (URL or `owner/repo`).

Do not proceed without one.

### 2. Get the latest code

Clone into `~/Projects/<owner>/<repo>` if missing, otherwise reset to the remote default branch:

```bash
CLONE=$(bash <this skill's directory>/scripts/sync-clone.sh <owner> <repo> | tail -1)
cd "$CLONE"
```

If it exits **5**, the clone holds local work — uncommitted changes, or commits that the remote default branch does not have. Either way it's notes, an experiment or a stash-in-progress. Report what the script printed to the user and stop, letting them decide what to do with it. Never clobber it: `~/Projects/<owner>/<repo>` may well be the user's own working clone rather than a scratch one.

### 3. Get acquainted with the project

Read enough to plan with real context. At minimum:

- `README.md`, `CONTRIBUTING.md`, `ROADMAP.md`, `docs/` if present
- Manifest files (`package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`, etc.): purpose, deps, scripts
- Top-level source layout: what modules exist, what they do
- `git log --oneline -30`: recent direction and active areas
- `gh release list --repo <owner>/<repo> --limit 10`: release cadence and what's already shipped
- `gh issue list --repo <owner>/<repo> --limit 100 --state all`: what's already tracked, in flight, or recently closed
- `gh pr list --repo <owner>/<repo> --limit 50 --state all`: work in-flight or recently merged (avoid duplicating)
- `gh api repos/<owner>/<repo>/milestones --jq '.[].title'`: existing milestones to slot the plan into

Fan these reads out across concurrent sub-agents per [Sub-agents](#sub-agents) and plan from their summaries, keeping raw file contents out of the main thread.

The issue and PR lists above are capped, so on a busy repository they show only the newest slice. Compare the cap against the real total:

```bash
gh api "search/issues?q=repo:<owner>/<repo>+is:issue&per_page=1" --jq '.total_count'
```

If the total exceeds what the list returned, treat the list as a sample rather than the full picture and say so when presenting the plan — Step 5 then has to search per candidate to catch the duplicates the sample missed.

### 4. Establish goals and current state

Summarize for the user, in this shape:

```
Project: <title for the project>
Goal: <description of what the project does>
Status: <where the project stands today. Active workstreams, recent releases, the biggest gaps or risks between now and its goals>
```

### 5. Build the plan

Identify the work that moves the project toward its goals, then organize it into a plan, not a scattershot list. Aim for **3-10** issues drawn from these areas (skip any that don't apply):

- **Bugs**: real defects spotted in code, edge cases, broken paths
- **Features**: gaps aligned with stated goals
- **Refactor**: cleaning up tech debt, duplication, dead code, brittle patterns that block future work
- **Tests**: uncovered critical paths
- **Docs**: missing setup, API, or contributor docs
- **Tooling**: Developer experience, CI, linting, release automation
- **Performance / Accessibility / Security**: when relevant

Then turn that work into a plan:

- **Prioritize** each issue justified by the goals and gaps from step 4.
- **Right-size** each issue so it's a single coherent unit of work, not an epic. Split anything too large into sub-issues.

Draft each planned issue in this shape:

```
# <Title, under 70 chars>
Effort: <Small/Medium/Large>
Impact: <Low/Medium/High>
Body: <what's wrong or missing, with file references>
## Suggested Implementation
<how it could be addressed>
## QA
<how we'd know it's done>
```

For each planned issue, check it against the existing issues and open PRs from step 3. When step 3 showed the lists were capped, search the repository per candidate as well, so a duplicate older than the sample still gets caught:

```bash
# Omit `--state`: it only accepts open|closed, and leaving it off searches both.
gh search issues --repo <owner>/<repo> --limit 10 "<two or three keywords from the candidate>" \
    --json number,title,state,url --jq '.[] | "#\(.number) [\(.state)] \(.title)"'
```

Drop the candidate if any existing item:

- addresses the same root cause or code location
- has the same fix or goal, even under a different title
- is already merged or in a PR that would make it redundant

Only keep issues with **no existing overlap** — when in doubt, drop it rather than file a near-duplicate.

### 6. Present the plan and ask which to file

Present the plan as an ordered list of what you think is the most return-on-investment, then ask the user which issues to create. Do **not** create any issue without explicit approval.

Before filing, make each approved issue self-contained: the body must include **all memory and content relevant to the issue**, so a reader needs no outside context. Fold in:

- Relevant facts from any persistent memory or project notes your harness keeps that bear on the issue — but only facts fit for a public issue tracker: no client or personal details, credentials, or internal URLs
- Concrete grounding gathered in step 3: file paths and line references, code snippets, related commits, releases, and links to related issues or PRs
- The priority, sequencing, and dependencies from the plan, plus the goals from step 4 that explain *why* this matters and *when* it should land; when a dependency was already filed earlier in this run, reference it by number (e.g. `Blocked by #12`)

Do not leave context implicit or assume the reader has seen the planning session. Create the approved issues in plan order, so a later issue can reference the earlier ones it depends on by number. For each approved issue: self-assigned with `--assignee @me` by default, unless the user told you to assign it to someone else or leave it unassigned:

```bash
gh issue create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
```

Only pass `--label` if the label already exists in the repo (`gh label list --repo <owner>/<repo>`). Omit it otherwise — labels can be added manually after filing. Likewise, only pass `--milestone` if the milestone already exists.

Report each created issue URL back to the user, in plan order. Leave the rest unfiled.

## Rules

- Never push branches, open PRs, or edit the project's code while planning. Step 2 resets the clone to the remote default branch; nothing beyond that is written, and nothing is written to the remote.
- Only one LoachBot skill at a time may run against a given repository. Step 2 resets the base clone at `~/Projects/<owner>/<repo>`, which the two fixer skills build their worktrees from, so a concurrent run there would be pulled out from under them. If the user asks for overlapping runs, do them one after another.
- Never file issues the user did not explicitly approve.
- A plan is ordered and justified, not a pile of ideas — every issue carries a priority and a place in the sequence.
- Prefer specificity over volume: five sharp, well-sequenced issues beat ten vague ones. Ground each in something concrete (a file path, a commit, a TODO, a missing test) — no generic items like "add more tests."
- Delegate the step-3 gathering per [Sub-agents](#sub-agents); reserve the main thread for plan synthesis and the approve/file steps.
