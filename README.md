# LoachBot Skills

A collection of agent skills for automating GitHub workflows, the **LoachBot** family. Each skill teaches your coding agent a repeatable, end-to-end process for working with GitHub issues and handling pull requests, letting you direct, while it handles the details.

## Features

- GitHub Planner: Creates issues aligned with project goals
- GitHub Issue Fixer: Tackles some of the issues in Pull Requests
- GitHub Pull Request Fixer: Address feedback within Pull Requests

### 1. [GitHub Planner](loachbot-github-planner/SKILL.md)

Reads a repository, learns its goals, and proposes a **prioritized, sequenced plan** of GitHub issues, then files the approved ones.

**Examples:**

```
Run LoachBot Planner
plan issues
Plan some issues for my most popular repo
```

### 2. [GitHub Issue Fixer](loachbot-github-issue/SKILL.md)

Picks the most-recently-updated issue *created by and assigned to you*, implements the fix in a dedicated git worktree, opens a Pull Request, verifies CI, then un-assigns. It relies on you to review/merge the Pull Requests. If you have feedback on a PR, post the comments inline on GitHub, and set the PRs to Draft, to be actioned by the *Pull Request Fixer below*.

**Examples:**

```
run LoachBot Issues
Run LoachBot Issues six times
LoachBot Issue fixes until there aren't any more left
```

### 3. [GitHub Pull Request Fixer](loachbot-github-pr/SKILL.md)

Finds your draft Pull Requests, addresses your reviewed comments in a dedicated worktree, reacts with 🚀 to each comment that was handled, verifies that the CI passes, then marks the PR back to ready for review.

**Examples:**

```
/loachbot-github-pr
Run LoachBot Pull Requests review
Run LoachBot Pull Requets until there aren't any left
```

## Requirements

- A coding agent, like [OpenCode](https://opencode.ai/) or [Claude Code](https://claude.com/claude-code)
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated `gh auth status`
- `git`

## Installation

Use your favourite SKILL installation method, like copy/paste, or `gh`:

```bash
gh skills install robloach/skills
```

To update it, copy the SKILL.md files to your coding agent, or use:

```bash
gh skills update --all
```

## Customization

The skills bake in a few defaults, feel free to change them to more closely match your workflow, either by editing`SKILL.md` directly, or asking it to remember your own workflows...

- **Clone Location**: Repositories and worktrees will default to `~/Projects/`
- **Commit Style**: Rely on your global settings for commit messages and attribution

## License

[MIT](LICENSE)
