# Skills

A collection of AI agent skills focused on developing and maintaining open-source projects. When used in tandem, they streamline the management of multiple repositories across code, issues, and pull requests.

## Features

- [GitHub Planner](#github-planner): Creates issues aligned with project goals
- [GitHub Issue Fixer](#github-issue-fixer): Implements one assigned issue at a time and opens a Pull Request
- [GitHub Pull Request Fixer](#github-pull-request-fixer): Addresses feedback within draft Pull Requests

## The loop

The three skills chain together through GitHub itself — self-assignment is the handoff, and you are the review step in the middle:

```
Planner       files the issues you approve, assigned to you
                  │
Issue Fixer       picks one up, opens a Pull Request, assigned to you
                  │
You               review it, leave inline comments, set it back to Draft
                  │
PR Fixer          addresses the comments, marks it ready for review
                  │
You               merge it
```

Nothing moves without you: the Planner files only the issues you approve, and a Pull Request only reaches the PR Fixer once you have reviewed it and set it back to **Draft**. Merging is always yours.

## Installation

1. Ensure you have the dependencies available:
   - Coding agent like [OpenCode](https://opencode.ai/) or [Claude Code](https://claude.com/claude-code)
   - [GitHub CLI](https://cli.github.com/) (`gh`), authenticated `gh auth status`
   - `git`

2. Install all three skills with `gh`:
   ```bash
   gh skills install robloach/skills --scope user --agent claude-code --all
   ```
   `--all` takes all three without prompting, and `--scope user` makes them available in every project rather than just the current one. Swap `--agent` for whichever agent you use — `gh skills install --help` lists the supported values, including `opencode`, `codex`, `cursor` and `github-copilot`.

   Or install by hand: copy each `skills/<name>/` folder — `SKILL.md` and the files beside it — into your agent's skills directory, such as `~/.claude/skills/`.

3. You're good to go! Run "Plan some issues for my most popular repo" to try it out.

Each skill also answers to its own name as a slash command — `/loachbot-github-planner`, `/loachbot-github-issue`, `/loachbot-github-pr` — on agents that support them.

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

A Pull Request has to be **open**, a **draft**, **authored by you** and **assigned to you** to be picked up. The Issue Fixer self-assigns the PRs it opens, so the handoff works on its own — but a Pull Request you opened by hand stays invisible until you assign it to yourself.

**Examples:**

```
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

The skills bake in a few defaults, so feel free to bend them to your own workflow:

- **Clone location**: base clones go in `~/Projects/<owner>/<repo>`, and each issue or Pull Request gets a throwaway worktree beside it in `~/Projects/<owner>/<repo>.worktrees/`, removed once the run finishes. The skills treat that base clone as theirs — the Planner resets it to the remote default branch on every run — so if it is also *your* working clone, point one of the two somewhere else. They stop rather than clobber anything the remote doesn't already have, uncommitted or unpushed, but they will move you back to the default branch.
- **Commit style**: inherited from your global settings, for both commit messages and attribution

The best place to record a change is your agent's own memory or project instructions — tell it "always clone into `~/src` instead", and it will apply that on every run. That survives updates, whereas editing `SKILL.md` directly does not: `gh skills update` re-downloads each skill, and `--force` overwrites locally modified skill files with their original content. If you do edit the files, keep your changes somewhere you can reapply them, or pin the skill with `gh skills install --pin <tag-or-sha>` to opt out of updates entirely.

## Development

Every skill is checked on push and pull request by [`.github/workflows/validate.yml`](.github/workflows/validate.yml). Run the same checks locally before opening a Pull Request:

```bash
python3 .github/scripts/validate-skills.py
```

It validates each `SKILL.md`'s frontmatter, confirms every documented `bash` snippet is valid bash, keeps `scripts/` references and their files in step, and runs ShellCheck over the scripts. No dependencies beyond `python3` and ShellCheck.

## FAQ

**Why "Loachbot"?**

Your skills directory can get messy, so I've opted to namespace these as `loachbot` so that they're easy to find. Also allows explicit calling out when interacting with your coding agent.

**Why does my issue/PR title end with "(Needs Info)"?**

A run hit something it couldn't resolve autonomously — an unclear task, or CI failures needing human judgment — so it parked the item and stopped. It posts a comment saying what it needs before parking, so start there. Reply with a comment answering it; the next run sees your reply, restores the title, and resumes with your answer as context. Parked items are skipped until someone replies.

**Why does it react with 🚀 instead of resolving my review comments?**

A reaction works on every kind of feedback. Resolving only applies to inline review threads, so regular Pull Request comments and review summaries would end up with no "already handled" marker at all, and the next run would redo them. Reactions also survive a force-push that can leave a resolved thread stale.

One consequence: 🚀 is reserved. LoachBot runs as you, so it cannot tell its own reaction from one you added yourself — a 🚀 you leave on your own review comment hides that comment from every later run. Use any other emoji for emphasis.

**Can I point it at a single repository?**

Yes — name the repo and both fixers scope their search to it, e.g. "run LoachBot Issues on RobLoach/skills". Asking from inside a checkout ("fix the next issue on this project") works too. With no repo named, they search your whole account.

## License

[MIT](LICENSE)
