---
name: loachbot-github-planner
description: Plan the next set of GitHub issues for a GitHub repository by reading its code, issues, PRs and releases, then propose a prioritized, sequenced plan and file the approved issues assigned to you. For drupal.org projects use loachbot-gitlab-planner instead. Use when the user wants to plan upcoming work or build a roadmap of issues for a GitHub repo, or asks to "run LoachBot Planner" or "plan issues" for one.
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-github-planner/SKILL.md
    license: MIT
---

# LoachBot GitHub Planner

<!-- SHARED: prerequisites -->
## Prerequisites

- Run `gh auth status` first; if it fails, report that and stop.
- Clones and worktrees go in `~/Projects` (created if missing), or in `LOACHBOT_PROJECTS_DIR` if the user prefers another directory.
<!-- /SHARED: prerequisites -->

<!-- SHARED: conventions -->
## Conventions

The `bash` blocks below are templates: substitute `<owner>`, `<repo>` and `<number>`, and adapt them to the repository.

Longer sequences live in `scripts/` beside this `SKILL.md`, run as `bash <this skill's directory>/scripts/<name>.sh`; each header documents arguments and exit codes.
<!-- /SHARED: conventions -->

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

## Workflow

### 1. Resolve the repository

Use, in order:

1. A repo named in the prompt or skill arguments (URL or `owner/repo`).
2. A repo planned earlier in this conversation, on a re-run or "fresh pass".
3. If the working directory is a git repo, its `origin`: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
4. Otherwise ask the user. Do not proceed without one.

For several repos, run Steps 2-5 once per repo and present the plans together in Step 6.

### 2. Get the latest code

Clone into `~/Projects/<owner>/<repo>`, or reset an existing clone to the remote default branch:

```bash
CLONE=$(bash <this skill's directory>/scripts/sync-clone.sh <owner> <repo>)
cd "$CLONE"
```

If it exits **5**, the clone holds local work (uncommitted changes, or commits the remote default branch lacks). Report what the script printed and stop. Never clobber it: it may be the user's own working clone.

### 3. Get acquainted with the project

At minimum, read:

- `README.md`, `CONTRIBUTING.md`, `ROADMAP.md`, `docs/` if present
- Manifests (`package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`, etc.): purpose, deps, scripts
- Top-level source layout: modules and what they do
- `git log --oneline -30`: recent direction
- `gh release list --repo <owner>/<repo> --limit 10`: cadence and what shipped
- `gh issue list --repo <owner>/<repo> --limit 100 --state all`: tracked, in flight, recently closed
- `gh pr list --repo <owner>/<repo> --limit 50 --state all`: in flight or recently merged
- `gh api repos/<owner>/<repo>/milestones --jq '.[].title'`: milestones to slot the plan into

Fan these out across concurrent sub-agents per [Sub-agents](#sub-agents) and plan from their summaries, keeping raw file contents out of the main thread.

The issue and PR lists are capped. Compare against the real total:

```bash
gh api "search/issues?q=repo:<owner>/<repo>+is:issue&per_page=1" --jq '.total_count'
```

If the total exceeds what the list returned, treat the list as a sample, say so when presenting the plan, and search per candidate in Step 5.

Optionally triage the open queue: issues that look done or obsolete (fixed by a merged PR or commit, code since removed), and open issues worth prioritizing alongside the new plan.

### 4. Establish goals and current state

Show one line per Step 3 sub-agent with what it found, then summarize:

```
Project: <title for the project>
Goal: <description of what the project does>
Status: <where the project stands today. Active workstreams, recent releases, the biggest gaps or risks between now and its goals>
```

### 5. Build the plan

Pick **3-10** issues that move the project toward its goals, from these areas (skip any that don't apply):

- **Bugs**: real defects, edge cases, broken paths
- **Features**: gaps aligned with stated goals
- **Refactor**: tech debt, duplication, dead code, brittle patterns blocking future work
- **Tests**: uncovered critical paths
- **Docs**: missing setup, API, or contributor docs
- **Tooling**: developer experience, CI, linting, release automation
- **Performance / Accessibility / Security**: when relevant

Prioritize each against the goals and gaps from step 4, and right-size each to a single coherent unit of work, splitting epics into sub-issues. Draft each as:

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

Check each against the issues and PRs from step 3. If the lists were capped, also search per candidate:

```bash
# Omit `--state`: it only accepts open|closed; leaving it off searches both.
gh search issues --repo <owner>/<repo> --limit 10 "<two or three keywords from the candidate>" \
    --json number,title,state,url --jq '.[] | "#\(.number) [\(.state)] \(.title)"'
```

Drop the candidate if any existing item:

- addresses the same root cause or code location
- has the same fix or goal, even under a different title
- is already merged or in a PR that would make it redundant

When in doubt, drop it rather than file a near-duplicate. On a fresh pass, also drop anything already proposed in this conversation.

Keep the candidates that missed the cut: a follow-up "anything else?" draws from them first.

### 6. Present the plan and ask what to do

Present the plan ordered by return on investment. Number every list shown to the user; across repos, prefix IDs per repo (`P1`, `F1`). List any triage findings from Step 3 after it. Then ask which items to:

1. **File as issues** (below).
2. **Fix directly** on the default branch.
3. **Open PRs** for.

Do **not** act on any item without explicit approval. Close a triaged issue only when approved, with a comment saying why (`gh issue close <number> --repo <owner>/<repo> --comment "<why>"`).

To fix or open PRs, give each item its own worktree off the default branch (`git -C "$CLONE" worktree add -b plan-<id> "$CLONE.worktrees/plan-<id>" origin/<default-branch>`), removed once done. Make one commit each, pass the project's checks, push (to the default branch, or a branch plus `gh pr create`), wait for CI green, and report the commit or PR URL.

#### Filing issues

Make each approved issue self-contained, needing nothing from this session: the grounding from step 3 (paths, line references, commits, links), the reason from step 4, and dependencies on issues filed earlier in this run by number (`Blocked by #12`). Include facts from your memory or notes only if fit for a public tracker: no client or personal details, credentials or internal URLs.

Create them in plan order so later issues can reference earlier ones. Assign with `--assignee @me` unless the user said to assign someone else or leave it unassigned:

```bash
gh issue create --repo <owner>/<repo> --title "<title>" --body-file <tmp file> --assignee @me
```

Pass `--label` only if the label exists (`gh label list --repo <owner>/<repo>`), and `--milestone` only if the milestone exists.

Report each created issue URL in plan order. Leave the rest unfiled.

## Rules

- Never push, open PRs, close issues, or edit the project's code until the user picks that path for named items in Step 6. Until then, nothing beyond Step 2's reset is written locally or to the remote.
<!-- SHARED: one-run-per-clone -->
- One run per base clone at a time. LoachBot skills share `~/Projects/<owner>/<repo>` (GitHub) or `~/Projects/drupalcode/<project>` (drupal.org); two runs fetching, resetting or deleting branches in one clone corrupt each other. Different clones, and sub-agents within a run, may overlap.
<!-- /SHARED: one-run-per-clone -->
- A plan is ordered and justified, not a pile of ideas: every issue has a priority and a place in the sequence.
- Prefer five sharp issues over ten vague ones. Ground each in something concrete (a file path, a commit, a TODO, a missing test); no generic items like "add more tests."
