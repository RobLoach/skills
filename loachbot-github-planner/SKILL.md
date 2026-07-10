---
name: loachbot-github-planner
description: Plan the next set of GitHub issues for a repository by reading the code, learning the project's goals, and proposing a prioritized, sequenced plan of issues to file. Use when the user wants to plan upcoming work, build a roadmap of issues, decide what to tackle next, or asks to "run LoachBot Planner" or "plan issues" for a GitHub repo.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/loachbot-github-planner/SKILL.md
    license: MIT
---

# LoachBot GitHub Planner

Help the user turn a repository's goals into a concrete, prioritized plan of GitHub issues. Read the code, understand where the project is headed, then propose a sequenced plan: what to do, in what order, and why: and optionally file the approved issues.

## What it does

1. Read the repository and learn the project's goals
2. Propose a prioritized, sequenced plan of GitHub issues
3. File the issues the user approves, self-assigned

## Prerequisites

- `gh` is authenticated: run `gh auth status` first; if it fails, report that and stop.
- `~/Projects` exists and is writable: the default location for clones; adjust if the user prefers another directory.

## Workflow

### 1. Ask for the repository

Ask the user for a GitHub repository (URL or `owner/repo`). Do not proceed without one.

### 2. Get the latest code

Clone into `~/Projects/<owner>/<repo>` if missing, otherwise reset to the remote default branch and pull.

```bash
# Fresh clone:
gh repo clone <owner>/<repo> ~/Projects/<owner>/<repo> -- --recurse-submodules

# Already cloned: sync to latest:
cd ~/Projects/<owner>/<repo>
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin --prune
git checkout "$DEFAULT"
git reset --hard "origin/$DEFAULT"
git clean -fd
git submodule sync --recursive
git submodule update --init --recursive
```

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

If your harness provides a code-exploration subagent (such as Claude Code's `Explore`), use it when the repo is large; otherwise read the key files directly.

### 4. Establish goals and current state

Summarize for the user...

Project: <title for the project>
Goal: <description of what the project does>
Status: <where the project stands today. Active workstreams, recent releases, the biggest gaps or risks between now and its goals>

### 5. Build the plan

Identify the work that moves the project toward its goals, then organize it into a plan: not a scattershot list. Aim for **3-10** issues drawn from these areas (skip any that don't apply):

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

For each planned issue, check it against the existing issues and open PRs from step 3. Drop it if any existing item:

- addresses the same root cause or code location
- has the same fix or goal, even under a different title
- is already merged or in a PR that would make it redundant

Only keep issues with **no existing overlap**: when in doubt, drop it rather than file a near-duplicate.

### 6. Present the plan and ask which to file

Present the plan as an ordered list of what you think is the most return-on-investment, then ask the user which issues to create. Do **not** create any issue without explicit approval.

Before filing, make each approved issue self-contained: the body must include **all memory and content relevant to the issue**, so a reader needs no outside context. Fold in:

- Relevant facts from any persistent memory or project notes your harness keeps that bear on the issue
- Concrete grounding gathered in step 3: file paths and line references, code snippets, related commits, releases, and links to related issues or PRs
- The priority, sequencing, and dependencies from the plan, plus the goals from step 4 that explain *why* this matters and *when* it should land; when a dependency was already filed earlier in this run, reference it by number (e.g. `Blocked by #12`)

Do not leave context implicit or assume the reader has seen the planning session. Create the approved issues in plan order, so a later issue can reference the earlier ones it depends on by number. For each approved issue: self-assigned with `--assignee @me` by default, unless the user told you to assign it to someone else or leave it unassigned:

```bash
gh issue create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
```

Only pass `--label` if the label already exists in the repo (`gh label list --repo <owner>/<repo>`). Omit it otherwise: labels can be added manually after filing. Likewise, only pass `--milestone` if the milestone already exists.

Report each created issue URL back to the user, in plan order. Leave the rest unfiled.

## Rules

- Never push branches, open PRs, or modify the repo while planning: this skill is read-only against the codebase.
- Never file issues the user did not explicitly approve.
- A plan is ordered and justified, not a pile of ideas: every issue carries a priority and a place in the sequence.
- Prefer specificity over volume: five sharp, well-sequenced issues beat ten vague ones. Ground each in something concrete (a file path, a commit, a TODO, a missing test): no generic items like "add more tests."
