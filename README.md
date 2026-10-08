# Skills

A collection of AI agent skills focused on developing and maintaining open-source projects. When used in tandem, they streamline the management of multiple repositories across code, issues, and pull requests.

## Features

- [GitHub Planner](#github-planner): Creates issues aligned with project goals
- [GitHub Issue Fixer](#github-issue-fixer): Implements one assigned issue at a time and opens a Pull Request
- [GitHub Pull Request Fixer](#github-pull-request-fixer): Addresses feedback within draft Pull Requests
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

Nothing moves without you: the Planner files only the issues you approve, and a Pull Request only reaches the PR Fixer once you have reviewed it and set it back to **Draft**. Merging is always yours.

The two GitLab skills stand apart from that loop — drupal.org has its own review workflow, driven by `state::` labels on the issue rather than by draft status — but the same bargain holds: the Fixer hands a merge request back for review, the Reviewer hands it back for work, and neither one merges or marks anything ready to commit.

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
   `--all` takes all of them without prompting, and `--scope user` makes them available in every project rather than just the current one. Swap `--agent` for whichever agent you use — `gh skills install --help` lists the supported values, including `opencode`, `codex`, `cursor` and `github-copilot`.

   Or install by hand: copy each `skills/<name>/` folder — `SKILL.md` and the files beside it — into your agent's skills directory, such as `~/.claude/skills/`.

3. You're good to go! Run "Plan some issues for my most popular repo" to try it out.

Each skill also answers to its own name as a slash command — `/loachbot-github-planner`, `/loachbot-github-issue`, `/loachbot-github-pr`, `/loachbot-gitlab-mr`, `/loachbot-gitlab-review` — on agents that support them.

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

### GitLab Merge Request Fixer

Takes one of your open [drupal.org](https://www.drupal.org) merge requests, rebases it onto its target branch in a dedicated worktree, resolves what it safely can, and then makes **every** CI job green before handing the issue back for review with `/do:` commands.

The emphasis on *every* is the point. Drupal.org's CI template marks some jobs `allow_failure: true`, so a merge request shows a green pipeline and a green badge while those jobs are red — `glab ci status` agrees, and so does the merge request page. Which jobs varies by project: the lint jobs usually, but `eslint`, `composer` variants and even `phpunit` variants on some. This skill reads each job's own flag instead of the rollup, and treats a forgiven failure as a failure.

Point it at a merge request and it takes that one; ask without naming one and it searches your open merge requests for a failing job. It pushes to the issue fork, never to the project, and it never merges or sets `state::rtbc` — review and commit stay with the project's maintainers.

**Examples:**

```
Rebase https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23
Fix the merge conflicts and pipeline on ai_image_crop!14
Run LoachBot MRs
Run LoachBot MRs until there aren't any left
```

### GitLab Merge Request Reviewer

Reviews one [drupal.org](https://www.drupal.org) merge request — yours or somebody else's — against the issue it claims to fix and against Drupal's own conventions, then posts its findings as resolvable inline threads plus a single summary.

It starts from the issue rather than the code, because the most common real finding is scope: something the diff does that nobody asked for, or something the issue asked for that the diff never does. It also reads the pipeline per job, so a merge request sitting on a red but forgiven job behind a green badge gets called out.

Entirely read-only against git — no clone, no checkout, no push — so it can run alongside anything else, including the Fixer working on the same merge request. It will set `state::needsWork` when a finding genuinely blocks, and it will never approve, merge, or set `state::rtbc`.

**Examples:**

```
Review https://git.drupalcode.org/project/ai_ckeditor/-/merge_requests/23
What's wrong with ai_image_crop!14?
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

- **Clone location**: base clones go in `~/Projects/<owner>/<repo>` — `~/Projects/drupalcode/<project>` for the GitLab Fixer — and each issue, Pull Request or merge request gets a throwaway worktree beside it in `<base>.worktrees/`, removed once the run finishes. Set `LOACHBOT_PROJECTS_DIR` to put all of that somewhere else. The skills treat that base clone as theirs — the Planner resets it to the remote default branch on every run — so if it is also *your* working clone, point one of the two somewhere else. They stop rather than clobber anything the remote doesn't already have, uncommitted or unpushed, but they will move you back to the default branch. The Reviewer never clones at all.
- **Namespace and host**: the GitLab skills assume drupal.org's `project/` namespace at `git.drupalcode.org`. `LOACHBOT_GITLAB_NAMESPACE` and `LOACHBOT_GITLAB_HOST` override both — use `sandbox` for a drupal.org sandbox project, or point them at another GitLab entirely.
- **Commit style**: inherited from your global settings, for both commit messages and attribution. The GitLab Fixer additionally follows drupal.org's `Issue #<id>: <description>` convention.

The best place to record a change is your agent's own memory or project instructions — tell it "always clone into `~/src` instead", and it will apply that on every run. That survives updates, whereas editing `SKILL.md` directly does not: `gh skills update` re-downloads each skill, and `--force` overwrites locally modified skill files with their original content. If you do edit the files, keep your changes somewhere you can reapply them, or pin the skill with `gh skills install --pin <tag-or-sha>` to opt out of updates entirely.

## Development

Every skill is checked on push and pull request by [`.github/workflows/validate.yml`](.github/workflows/validate.yml). Run the same checks locally before opening a Pull Request:

```bash
python3 .github/scripts/validate-skills.py
```

It validates each `SKILL.md`'s frontmatter, confirms every documented `bash` snippet is valid bash, keeps `scripts/` references and their files in step, checks that shared-marked scripts and sections match across skills, and runs ShellCheck over the scripts. No dependencies beyond `python3` and ShellCheck.

## FAQ

**Why "Loachbot"?**

Your skills directory can get messy, so I've opted to namespace these as `loachbot` so that they're easy to find. Also allows explicit calling out when interacting with your coding agent.

**Why does my issue/PR title end with "(Needs Info)"?**

A run hit something it couldn't resolve autonomously — an unclear task, or CI failures needing human judgment — so it parked the item and stopped. It posts a comment saying what it needs before parking, so start there. Reply with a comment answering it; the next run sees your reply, restores the title, and resumes with your answer as context. Parked items are skipped until someone replies.

**Why does it react with 🚀 instead of resolving my review comments?**

A reaction works on every kind of feedback. Resolving only applies to inline review threads, so regular Pull Request comments and review summaries would end up with no "already handled" marker at all, and the next run would redo them. Reactions also survive a force-push that can leave a resolved thread stale.

One consequence: 🚀 is reserved. LoachBot runs as you, so it cannot tell its own reaction from one you added yourself — a 🚀 you leave on your own review comment hides that comment from every later run. Use any other emoji for emphasis.

**Do the GitLab skills work on Drupal core, whose issues are still on drupal.org?**

Yes. Contrib mostly had its issue queues migrated into GitLab; core and some others — `eck`, for instance — did not, and keep theirs on drupal.org. The skills check which of the two a project uses and read the issue from the right place, so a core merge request gets reviewed against its real requirement rather than against nothing.

Two consequences worth knowing. Reading a drupal.org-only issue needs the `drupalorg` CLI, and without it the skills stop rather than carry on half-informed — the Fixer's refusal to force-push over an RTBC issue depends on that read. And drupal.org moves issue status through its web UI, with no `/do:` equivalent, so for those projects the skills report what status to set and leave it to you.

The reason they check rather than just trying both: the two numbering spaces overlap. `ai_ckeditor`'s GitLab issue 3615852 is about stale toolbar items, while drupal.org's *node* 3615852 is an unrelated core issue about `ConfigManager`. Asking both and keeping whichever answers would hand back a real, confident, wrong requirement.

**My drupal.org pipeline is green. Why do the GitLab skills say a job failed?**

Because the pipeline is lying, and noticing that is half of why these two exist. Drupal.org's CI template marks some jobs `allow_failure: true`, which means they can fail without failing the pipeline. The rollup goes green, the badge goes green, `glab ci status` says `success` — and the job is still red.

Which jobs are forgiven is per-project configuration rather than a fixed list. Observed in the wild: `ai_ckeditor` forgives four lint jobs, `node_menu_placer` fourteen including `eslint`, and `schemata` sixteen including `phpunit` variants — Drupal core forgives `PHPUnit Unit (Core)`. So both skills read each job's own flag and report what they find, marked so you can see which ones the pipeline was forgiving: the Fixer fixes them, the Reviewer raises them as findings.

**Can I point it at a single repository?**

Yes — name the repo and the fixers scope their search to it, e.g. "run LoachBot Issues on RobLoach/skills". Asking from inside a checkout ("fix the next issue on this project") works too. With no repo named, they search your whole account. The GitLab skills take a merge request URL or an `ai_ckeditor!23` reference directly, which is usually quicker than letting them search.

## License

[MIT](LICENSE)
