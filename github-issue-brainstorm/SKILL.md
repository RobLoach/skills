---
name: github-issue-brainstorm
description: Brainstorm new GitHub issues for a repository by cloning it, learning the project's goals, and proposing actionable issue ideas. Use when the user wants to generate issue ideas, plan future work, find gaps, or asks to "brainstorm issues" or "suggest improvements" for a GitHub repo.
---

# GitHub Issue Brainstorm

Help the user generate fresh, well-scoped GitHub issue ideas for a repository by reading the code, understanding the project's goals, and proposing concrete issues — then optionally filing the approved ones.

## Workflow

### 1. Ask for the repository

Ask the user for a GitHub repository (URL or `owner/repo`). Do not proceed without one.

### 2. Get the latest code

Clone with SSH into `~/Projects/<repo>` if missing, otherwise reset to the remote default branch and pull.

```bash
# Fresh clone:
gh repo clone <owner>/<repo> ~/Projects/<repo> -- --recurse-submodules

# Already cloned — sync to latest:
cd ~/Projects/<repo>
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name)
git fetch origin --prune
git checkout "$DEFAULT"
git reset --hard "origin/$DEFAULT"
git clean -fd
git submodule update --init --recursive
```

### 3. Get acquainted with the project

Read enough to form a real opinion. At minimum:

- `README.md`, `CONTRIBUTING.md`, `ROADMAP.md`, `docs/` if present
- Manifest files (`package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`, etc.) — purpose, deps, scripts
- Top-level source layout — what modules exist, what they do
- `git log --oneline -30` — recent direction and active areas
- `gh release list --repo <owner>/<repo> --limit 10` — recent releases to understand cadence and what's already shipped
- `gh issue list --repo <owner>/<repo> --limit 100 --state all` — what's already tracked or recently closed
- `gh pr list --repo <owner>/<repo> --limit 50 --state all` — work in-flight or recently merged (avoid duplicating)

Use the `Explore` subagent if the repo is large.

### 4. Identify project goals

Summarize for the user in 3–5 bullets:

- What the project does and who it's for
- Stated goals (from README/roadmap) and implied goals (from recent commits)
- Current pain points visible in code, TODOs, or stale issues

### 5. Brainstorm issues

Propose **5–10** concrete issue ideas across these categories (skip categories that don't fit):

- **Bugs** — real defects spotted in code, edge cases, broken paths
- **Features** — gaps aligned with stated goals
- **Tech debt / refactor** — duplication, dead code, brittle patterns
- **Tests** — uncovered critical paths
- **Docs** — missing setup, API, or contributor docs
- **DX / tooling** — CI, linting, release automation
- **Performance / accessibility / security** — when relevant

For each idea, write a draft in this shape:

```
Title: <imperative, under 70 chars>
Labels: <suggested labels>
Body:
  <what's wrong or missing, with file references>
  ## Suggested Implementation
  <how it could be addressed>
  ## QA
  <how we'd know it's done>
```

For each idea you draft, check it against the list of existing issues and open PRs from step 3. Drop the idea if any existing item:

- addresses the same root cause or code location
- has the same fix or refactor goal, even under a different title
- is already merged or in a PR that would make it redundant

Only surface ideas with **no existing overlap**. If all ideas in a category are covered, omit that category entirely.

### 6. Ask which to file

Present the list and ask the user which ideas to file. Do **not** create any issue without explicit approval. For each approved idea:

```bash
gh issue create --repo <owner>/<repo> --title "<title>" --body "<body>" --assignee @me
```

Only pass `--label` if the label already exists in the repo (`gh label list --repo <owner>/<repo>`). Omit it otherwise — labels can be added manually after filing.

Report each created issue URL back to the user. Leave the rest unfiled.

## Rules

- Never push branches, open PRs, or modify the repo during brainstorming — this skill is read-only against the codebase.
- Never file issues the user did not explicitly approve.
- Prefer specificity over volume: five sharp ideas beat ten vague ones.
- Ground each idea in something concrete (a file path, a commit, a TODO, a missing test). No generic suggestions like "add more tests."
- Never propose an idea that overlaps with an existing issue or PR, even partially. When in doubt, drop the idea rather than propose a near-duplicate.
