# Skills

A collection of AI agent skills focused on developing and maintaining open-source projects. When used in tandem, they streamline the management of multiple repositories across code, issues, and pull requests.

## Features

- [GitHub Planner](#github-planner): Creates issues aligned with project goals
- [GitHub Issue Fixer](#github-issue-fixer): Implements one assigned issue at a time and opens a Pull Request
- [GitHub Pull Request Fixer](#github-pull-request-fixer): Addresses feedback within draft Pull Requests

## Installation

1. Ensure you have the dependencies available:
   - Coding agent like [OpenCode](https://opencode.ai/) or [Claude Code](https://claude.com/claude-code)
   - [GitHub CLI](https://cli.github.com/) (`gh`), authenticated `gh auth status`
   - `git`

2. Download the folders into `~/.claude/skills`, or use your favourite SKILL installation method, like `gh`:
   ```bash
   gh skills install robloach/skills --scope user
   ```

3. You're good to go! Run "Plan some issues for my most popular repo" to try it out.

## Skills

### GitHub Planner

Reads a repository, learns its goals, and proposes a set of GitHub issues to create within the repository itself.

**Examples:**

```
Run LoachBot Planner
plan issues for this project
LoachBot, can you plan some issues for MyAwesomeProject?
Plan some issues for my most popular repo
```

### GitHub Issue Fixer

Picks the most-recently-updated issue *created by and assigned to you*, implements the fix in a dedicated git worktree, opens a Pull Request, and verifies CI. It relies on you to review/merge the Pull Requests. If you have feedback on a PR, post the comments inline on GitHub, and set the PRs to Draft, to be actioned by the *Pull Request Fixer below*.

**Examples:**

```
run LoachBot Issues
Run LoachBot Issues six times
Fix the most recent github issue assigned to me
LoachBot Issue fixes until there aren't any more left
```

### GitHub Pull Request Fixer

Finds your draft Pull Requests, addresses your reviewed inline comments in a dedicated worktree, reacts with 🚀 to each comment that was handled, verifies that the CI passes, then marks the PR back to ready for review.

**Examples:**

```
/loachbot-github-pr
Run LoachBot Pull Requests
Address the feedback on my recent pull request
Run LoachBot Pull Requests until there aren't any left
```

## Update

To update them, use `gh`:
```bash
gh skills update --all
```

## Customization

The skills bake in a few defaults, feel free to change them to more closely match your workflow, either by editing `SKILL.md` directly, or asking it to remember your own workflows...

- **Clone Location**: Repositories and worktrees default to `~/Projects/<owner>/<repo>`
- **Commit Style**: Rely on your global settings for commit messages and attribution

## FAQ

**Why "Loachbot"?**
: Your skills directory can get messy, so I've opted to namespace these as `loachbot` so that they're easy to find. Also allows explicit calling out when interacting with your coding agent.

## License

[MIT](LICENSE)
