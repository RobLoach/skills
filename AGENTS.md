# Working on this repository

Every skill here is a `SKILL.md` plus the scripts beside it, under `skills/<name>/`. CI
runs one check on push and pull request, and it is worth running first rather than last:

```bash
python3 .github/scripts/validate-skills.py
```

No dependencies beyond `python3`, plus ShellCheck when it is installed — CI installs the
real thing and asserts it separately, so a laptop without it passes a weaker check than
the pull request will.

## The invariants it enforces

Most of these are not guessable from reading one skill, which is why they are written
down here rather than left to be rediscovered:

- **`name` matches the directory, and `homepage` points at the skill itself.** Both are in
  the frontmatter. The `github-*` metadata keys you may see in an installed copy are added
  by `gh skills install`; do not commit them.
- **Every `bash` block must parse.** The validator substitutes `<placeholders>` and runs
  `bash -n`, so a snippet can be a template but not a fragment.
- **Every `scripts/*.sh` must be referenced from its `SKILL.md`, and every referenced
  script must exist.** An unreferenced script is dead weight the agent will never run.
- **A script marked `# SHARED:` must be byte-identical in every skill that carries a
  copy.** Sharing is opt-in, by that marker, rather than inferred from the filename — two
  skills can legitimately each have their own `setup-worktree.sh`. If you change one copy,
  change all of them in the same commit.
- **A `<!-- SHARED: name -->` … `<!-- /SHARED: name -->` section must be identical
  wherever it appears.** Same reasoning: the skills are standalone copies rather than
  includes, so shared guidance drifts a sentence at a time unless something holds it
  together.
- **A script's `# Exit codes:` block must list exactly the codes it really exits with.**
  Not more, not fewer. `64` for usage and `0` for success are exempt.
- **`SKILL.md` must say what the agent should do about every code a script can hand
  back.** The exit code exists only to steer the agent, so one with no instruction beside
  it is a branch met at runtime with nothing to go on. "Any other non-zero" in that
  section satisfies the check for everything unlisted.
- **Scripts start with a shebang and pass ShellCheck.**

## Conventions the validator cannot check

- **Exit codes are the interface.** A script hands control back to the agent through its
  exit code and its stderr; the `SKILL.md` turns each one into a decision. Prefer a new
  code over a new output format.
- **A read whose absence is meaningful is taken in two steps.** `gh` and `glab` exit
  non-zero on a 404, and under `set -euo pipefail` that ends the run before it can act on
  what it found. Assign first, then test — never `X=$(api … | jq …)` where a missing `X`
  is the case you care about.
- **Configuration is `LOACHBOT_`-prefixed.** `LOACHBOT_PROJECTS_DIR`,
  `LOACHBOT_GITLAB_HOST`, `LOACHBOT_CHECKS_INTERVAL` and so on. A bare `INTERVAL` collides
  with whatever the caller happens to have exported.
- **Comment why, not what.** The headers here explain the trap that made the code look
  the way it does — two hostnames for one service, a green pipeline hiding red jobs, a
  `201` that silently dropped a comment's position. That is the part a reader cannot
  recover from the code.
- **Say what a run must not do.** Each skill's `Rules` section bounds it: what it may post,
  what it may push to, what it may never set. New behaviour usually needs a new rule.
- **Parking is per-skill and not shared.** The GitHub skills and `loachbot-gitlab-mr` park
  by renaming to ` (Needs Info)`; `loachbot-gitlab-issue` parks with a `state::blocked`
  label, because an issue in somebody else's queue is not a title to rewrite. The three
  share a 0/5/6 contract but not an implementation. Each script's header says which it is.

## Adding a skill

Copy the nearest existing skill and work from it — `loachbot-github-issue` for a GitHub
workflow, `loachbot-gitlab-issue` for a drupal.org one — then run the validator. Add the
skill to `README.md`: the feature list, its own section with examples, and the slash
command list under Installation.
