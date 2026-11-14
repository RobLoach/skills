# Skills

A collection of AI agent skills focused on developing and maintaining open-source projects. When used in tandem, they streamline the management of multiple repositories across code, issues, and pull requests.

## Features

- [GitHub Planner](#github-planner): Creates issues aligned with project goals
- [GitHub Issue Fixer](#github-issue-fixer): Implements one assigned issue at a time and opens a Pull Request
- [GitHub Pull Request Fixer](#github-pull-request-fixer): Addresses feedback within draft Pull Requests
- [GitLab Planner](#gitlab-planner): Plans issues for a drupal.org project and files the approved ones
- [GitLab Issue Fixer](#gitlab-issue-fixer): Claims one drupal.org issue and opens a merge request for it
- [GitLab Merge Request Fixer](#gitlab-merge-request-fixer): Rebases one drupal.org merge request and makes every CI job green
- [GitLab Merge Request Reviewer](#gitlab-merge-request-reviewer): Reviews one drupal.org merge request and posts its findings inline

## The loop

The three GitHub skills chain together through GitHub itself — self-assignment is the handoff, and you are the review step in the middle:

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

Nothing moves without you: the Planner files only what you approve, a PR reaches the PR Fixer only once you set it back to **Draft**, and merging is yours.

The four GitLab skills chain the same way, with a `state::` label on the issue as the handoff:

```
Planner           files the issues you approve, unassigned in the project's queue
                      │
Issue Fixer       claims an issue, opens a merge request, unassigns, state::needsReview
                      │
Reviewer          reads it against the issue, comments inline, state::needsWork
                      │
You               decide what the findings are worth, and address them
                      │
MR Fixer          rebases onto the target branch, makes every CI job green, state::needsReview
                      │
A maintainer      reviews and commits it
```

None of the four merges, approves, or sets `state::rtbc` — review and commit belong to the project's maintainers.

## Installation

1. Ensure you have the dependencies available:
   - Coding agent like [OpenCode](https://opencode.ai/) or [Claude Code](https://claude.com/claude-code)
   - [GitHub CLI](https://cli.github.com/) (`gh`), authenticated `gh auth status`
   - `git`
   - For the GitLab skills only: [GitLab CLI](https://gitlab.com/gitlab-org/cli) (`glab`), authenticated `glab auth status --hostname git.drupalcode.org`, and [`jq`](https://jqlang.org/)
   - Also for the GitLab skills, if you work on projects whose issues never moved to GitLab — Drupal core among them: [`drupalorg`](https://github.com/mglaman/drupalorg-cli). Reads need no login.

2. Install every skill with `gh`:
   ```bash
   gh skills install robloach/skills --scope user --agent claude-code --all
   ```
   Swap `--agent` for your agent (`gh skills install --help` lists them, e.g. `opencode`, `codex`, `cursor`). `gh skills` is in preview, so check `--help` if the flags have changed.

   Or copy each `skills/<name>/` folder into your agent's skills directory, such as `~/.claude/skills/`.

3. You're good to go! Run "Plan some issues for my most popular repo" to try it out.

Each skill also answers to its own name as a slash command — `/loachbot-github-planner`, `/loachbot-github-issue`, `/loachbot-github-pr`, `/loachbot-gitlab-planner`, `/loachbot-gitlab-issue`, `/loachbot-gitlab-mr`, `/loachbot-gitlab-review` — on agents that support them.

## Skills

### GitHub Planner

Reads a repository, learns its goals, and proposes a numbered, prioritized plan. Pick items to file as issues, fix directly on the default branch, or open as Pull Requests. It can also triage the existing issue queue, and plan several repositories at once.

**Examples:**

```
Run LoachBot Planner
plan issues for this project
LoachBot, can you plan some issues for MyAwesomeProject?
Plan some issues for my most popular repo
Plan pntr_physfs and pntr_pixelfont, then make PRs for P1 and F2
```

### GitHub Issue Fixer

Picks the most-recently-updated issue *created by and assigned to you*, implements the fix in a git worktree, opens a Pull Request, and verifies CI. For feedback, comment inline and set the PR back to Draft for the *Pull Request Fixer*.

**Examples:**

```
run LoachBot Issues
Run LoachBot Issues six times
Fix the most recent github issue assigned to me
LoachBot Issue fixes until there aren't any more left
```

### GitHub Pull Request Fixer

Finds your draft Pull Requests, addresses your reviewed inline comments in a dedicated worktree, reacts with 🚀 to each comment that was handled, verifies that the CI passes, then marks the PR back to ready for review.

A Pull Request has to be **open**, a **draft**, **authored by you** and **assigned to you** to be picked up; assign PRs you opened by hand to yourself.

**Examples:**

```
Run LoachBot Pull Requests
Address the feedback on my recent pull request
Run LoachBot Pull Requests until there aren't any left
```

### GitLab Planner

Reads a [drupal.org](https://www.drupal.org) project, learns its goals, and proposes a set of issues to file in its GitLab queue.

Every issue names the branch it lands on and uses only the project's existing `category::` and `priority::` labels. It also plans from drupal.org-specific signals: `core_version_requirement` against the next Drupal major, red-but-forgiven CI jobs, and a default branch far ahead of its newest release.

Everything it files is unassigned, carries the `AI-Generated: Yes` disclosure, and waits for your explicit approval first. For a project whose queue never moved to GitLab — Drupal core among them — it hands you the plan to file by hand.

**Examples:**

```
Run LoachBot GitLab Planner
Plan some issues for ai_ckeditor
What should I work on next in ai_image_crop?
Plan issues for https://www.drupal.org/project/ai_ckeditor
```

### GitLab Issue Fixer

Picks up one open [drupal.org](https://www.drupal.org) issue you reported, claims it by commenting `/do:assign me`, implements the fix on the issue's shared fork, opens a merge request, then unassigns itself and sets `state::needsReview` with a short summary of what it did. Merge request descriptions are one short paragraph, a `Closes #<id>` line, and `AI-Generated: Yes`, because drupal.org's [AI policy](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) requires disclosure.

It only claims issues **you reported**, unless you name one directly, and skips anything with an open merge request or already at `state::needsReview` or beyond. Drupal core and other projects whose queue never moved to GitLab are out of scope.

Each run ends with a todo list of what it could not do for you: recording your contribution credit, reviewing the merge request, anything it noticed and left out of scope.

**Examples:**

```
Work on https://git.drupalcode.org/project/ai_ckeditor/-/work_items/3615836
Pick up the next drupal.org issue on ai_image_crop
Run LoachBot GitLab Issues
Run LoachBot GitLab Issues until there aren't any left
```

### GitLab Merge Request Fixer

Takes one of your open [drupal.org](https://www.drupal.org) merge requests, rebases it onto its target branch, resolves what it safely can, and makes **every** CI job green before handing the issue back for review.

That includes jobs the pipeline forgives behind a green badge (see the [FAQ](#faq)) — but only failures this branch introduces; ones already failing on the target branch are reported, not worked around.

Name a merge request, or let it search yours for a failing job. It pushes only to the issue fork, and while review threads are unresolved it leaves the issue's state alone and tells you.

**Examples:**

```
Rebase https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23
Fix the merge conflicts and pipeline on ai_image_crop!14
Make a new MR that does what ai!33 does, but targets 2.x
Run LoachBot MRs
Run LoachBot MRs until there aren't any left
```

### GitLab Merge Request Reviewer

Reviews one [drupal.org](https://www.drupal.org) merge request — yours or somebody else's — against the issue it claims to fix and against Drupal's own conventions, then posts its findings as resolvable inline threads plus a single summary.

It starts from the issue, since the most common finding is scope, and reads the pipeline per job so forgiven failures get called out. It is read-only against git by default, so it can run alongside the Fixer. Ask for the review "here" to get a numbered list without posting, or ask it to fix findings afterwards. It sets `state::needsWork` only when a finding blocks.

**Examples:**

```
Review https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23
What's wrong with ai_image_crop!14?
Review the MR for https://www.drupal.org/i/3586558, just give me the review here
Run LoachBot Review
Review the merge requests waiting on me
```

## Update

To update them, use `gh`:
```bash
gh skills update --all
```

## Customization

The skills bake in a few defaults, so feel free to bend them to your own workflow:

- **Clone location**: base clones go in `~/Projects/<owner>/<repo>` (`~/Projects/drupalcode/<project>` for GitLab), with throwaway worktrees beside them in `<base>.worktrees/`. Set `LOACHBOT_PROJECTS_DIR` to move them. The skills treat the base clone as theirs and will check out the default branch in it, so don't share it with your own working clone; they stop rather than discard unpushed work.
- **Namespace and host**: the GitLab skills assume drupal.org's `project/` namespace at `git.drupalcode.org`. `LOACHBOT_GITLAB_NAMESPACE` and `LOACHBOT_GITLAB_HOST` override both — use `sandbox` for a drupal.org sandbox project, or point them at another GitLab entirely.
- **Commit style**: inherited from your global settings, for both commit messages and attribution. The GitLab skills additionally follow drupal.org's `Issue #<id>: <description>` convention.

Record changes in your agent's memory or project instructions (e.g. "always clone into `~/src` instead") rather than editing `SKILL.md`, which `gh skills update` overwrites — or pin with `gh skills install --pin <tag-or-sha>`.

## Development

Every skill is checked on push and pull request by [`.github/workflows/validate.yml`](.github/workflows/validate.yml). Run the same checks locally before opening a Pull Request:

```bash
python3 .github/scripts/validate-skills.py
```

See [`AGENTS.md`](AGENTS.md) for what it checks and the conventions it cannot, before adding a skill.

## FAQ

**Why "Loachbot"?**

A namespace, so they're easy to find and to call out by name.

**Why does my issue/PR title end with "(Needs Info)"?**

A run hit something needing your judgment, so it posted a comment saying what it needs and parked the item. Reply to that comment; the next run restores the title and resumes with your answer. The *GitLab Issue Fixer* parks with a `state::blocked` label instead of renaming, and leaves alone any issue you blocked yourself.

**Does it record my drupal.org contribution credit?**

No — there is no API for it, only the page the DrupalBot comment links to. The *GitLab Issue Fixer* reminds you as the first item of its closing todo list.

**Why does it react with 🚀 instead of resolving my review comments?**

A reaction works on every kind of feedback, not just inline threads, and survives force-pushes. Since LoachBot runs as you, a 🚀 you add yourself hides that comment from later runs — use another emoji.

**Do the GitLab skills work on Drupal core, whose issues are still on drupal.org?**

Mostly. The skills detect where a project's issues live and read them with the `drupalorg` CLI (required; they stop without it). The MR Fixer and Reviewer work normally; the Planner hands you its plan to file by hand; the Issue Fixer can't claim with `/do:assign me` there, so it stops. Status changes on those projects are left to you.

**My drupal.org pipeline is green. Why do the GitLab skills say a job failed?**

Drupal.org's CI template marks some jobs `allow_failure: true`, so they fail without failing the pipeline: the badge and `glab ci status` say `success` while the job is red. Which jobs varies by project (lint usually, sometimes `eslint` or `phpunit`). The skills read each job's own flag: the Fixers fix them, the Reviewer raises them, and the Planner files issues for standing ones.

**Can I point it at a single repository?**

Yes — name the repo and the fixers scope their search to it, e.g. "run LoachBot Issues on RobLoach/skills". Asking from inside a checkout ("fix the next issue on this project") works too. With no repo named, they search your whole account. The GitLab skills take a reference directly, which is usually quicker than letting them search: a merge request URL or `ai_ckeditor!23` for the MR skills, an issue URL or `ai_ckeditor#3615836` for the Issue Fixer, and a project — `ai_ckeditor`, or either of its URLs — for the Planner.

## License

[MIT](LICENSE)
