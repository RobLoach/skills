---
name: loachbot-gitlab-issue
description: Autonomous drupal.org issue fixer called LoachBot. Picks up one open drupal.org GitLab issue, claims it by commenting /do:assign me, implements the fix on the issue's shared fork, opens a merge request, and hands the issue back at state::needsReview with a short summary. Use when the user wants to pick up or fix a drupal.org issue, open a merge request for one, or asks to "run LoachBot GitLab Issues", including repeated runs like "run LoachBot GitLab Issues three times" or "until there aren't any left".
metadata:
    author: RobLoach
    homepage: https://github.com/RobLoach/skills/blob/main/skills/loachbot-gitlab-issue/SKILL.md
    license: MIT
---
# LoachBot GitLab Issue Fixer

## Prerequisites

- `glab` is authenticated against drupal.org: run `glab auth status --hostname git.drupalcode.org` first; if it fails, report that and stop. `glab auth login --hostname git.drupalcode.org` fixes it.
- `jq` is on `PATH`. `glab api` has no built-in filter, so the scripts beside this file parse JSON with `jq`.
- [`drupalorg`](https://github.com/mglaman/drupalorg-cli) on `PATH` is useful but not required. This skill only works on projects whose issues live in GitLab, and without `drupalorg` a project whose queue never moved there reports as unreadable rather than as the wrong kind of project — the same stop either way, just less clearly explained. Reads need no authentication.
- Paths assume drupal.org's `project/` namespace. Sandboxes live under `sandbox/` instead, so set `LOACHBOT_GITLAB_NAMESPACE=sandbox` for those; `LOACHBOT_GITLAB_HOST` likewise points the scripts at another GitLab. Issue forks always sit under `issue/`, whichever namespace the project is in.
- SSH access to `git.drupal.org`, which is what pushes to an issue fork use.
- `~/Projects` is where clones and worktrees go by default; `LOACHBOT_PROJECTS_DIR` overrides it. It is created if missing, so change it only if the user prefers another directory.

## Conventions

The `bash` blocks below are templates, not literals: substitute `<project>` (a machine name such as `ai_ckeditor`, never `project/ai_ckeditor`) and `<issue-iid>` before running them, and adapt anything that doesn't fit the issue in front of you.

The longer sequences live in `scripts/` next to this `SKILL.md`, invoked as `bash <this skill's directory>/scripts/<name>.sh`. Each script's header documents its arguments and exit codes.

<!-- SHARED: sub-agents -->
## Sub-agents

Delegate by default. The main thread picks the work, runs `gh`/`glab` and `git`, and reports to the user; sub-agents do the reading, searching and editing.

Spin one up when any one of these holds:

- You would read a file to understand how something works.
- A question needs more than two searches.
- A change needs more than one sentence to describe.
- You would run a build, tests or a linter and react to the output.

Exception: reading a file you already decided to edit. A run with no sub-agents at all almost certainly stretched it.

Types: `Explore` for read-only investigation (say how thorough); `general-purpose` for anything that edits or iterates.

### Fan out

Independent work goes out in one message, not one after another.

Read-only investigation is always independent. Nothing two `Explore` sub-agents do can collide, however much they overlap, so asking three questions about one repository means three sub-agents launched together — never one, then the next once it reports back. Staggering reads buys no safety; it only costs wall-clock.

The sequential rules under [Rules](#rules) govern *writes*: whole repeated runs, and anything touching the shared base clone or a worktree. They are not a general ban on concurrency, and they do not reach the sub-agents inside a single run.

What does have to stay sequential:

- Anything that writes — `git` in any form, builds that drop artefacts, formatters, codegen.
- A sub-agent whose prompt needs an earlier one's answer.

Otherwise, ask what two sub-agents would fight over. If the answer is nothing, they go out together.

Sub-agents start empty, so every prompt carries:

1. The absolute path to work in.
2. The outcome, not a hint.
3. Constraints the code does not show.
4. The command that proves the work; iterate until it passes.
5. What to report: files touched, output, anything left undone.
6. "Do not commit, push, or open a Pull Request."

A report is a claim. Verify what matters: read the diff or re-run the command.
<!-- /SHARED: sub-agents -->

<!-- SHARED: drupal-gotchas -->
## How drupal.org differs

Four things here are not what a GitLab habit expects. Each one fails quietly rather than loudly, so they are worth knowing before the first API call rather than after.

- **Two hostnames, one service.** The API lives at `git.drupalcode.org`; git itself lives at `git.drupal.org`. An API path on the git host and an SSH URL on the API host both fail. Take remote URLs from the API's own `ssh_url_to_repo` instead of composing them.
- **Two repositories per merge request.** It targets `project/<project>`, but its branch lives in a per-issue fork at `issue/<project>-<issue-id>`. Pushes go to the fork.
- **The pipeline runs on the fork.** Ask the target project for it and you get a flat `404`. Use the merge request's `source_project_id`.
- **A green pipeline can hide red jobs.** Drupal.org's CI template marks jobs `allow_failure: true`, so they fail without failing the pipeline — and the pipeline, the badge and `glab ci status` all then report success while those jobs are red. *Which* jobs is per-project configuration, not a fixed set: the lint jobs usually (`cspell`, `phpcs`, `phpstan`, `stylelint`), but `eslint`, `composer` variants and even `phpunit` variants carry it on some projects. So never match on a list of names — read each job's own `allow_failure` and treat a forgiven failure as a failure.

### The issue lives in one of two places

A merge request's issue number is the tail of its fork's path: `issue/ai_ckeditor-3615852` means `3615852`. What that number *means* depends on the project — a GitLab issue iid where the queue was migrated, a drupal.org node id where it never was (Drupal core and `eck` among them) — and the two numbering spaces overlap, so reading it in the wrong world returns a real but unrelated issue rather than nothing.

Never try both and keep whichever answers. One script decides the world first and then interprets the number; `read-issue.sh`'s header explains why that order matters:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-ref>
```

It returns one JSON object either way — `source`, `title`, `status`, `actionable`, `writable`, `url`, `description` — so nothing downstream has to care which world it came from. Act on its exit code:

- **0** → read. `actionable: false` means the issue is fixed, closed, postponed or already reviewed-and-tested: leave it alone. `writable: false` means `/do:` cannot be posted, so any handback goes to the user instead.
- **6** → unreadable in the world this project belongs to. Report it; do **not** try the other world.
- **7** → read, but it belongs to a different project, so the number was interpreted in the wrong world. Report it and discard the result.

For anything about `glab` itself — note bodies, threaded replies, `--field` versus `--raw-field` — defer to the `glab` skill rather than guessing.
<!-- /SHARED: drupal-gotchas -->

Three more matter specifically for starting from an issue rather than from a merge request that already exists:

- **There are no personal forks.** One shared fork per issue, at `issue/<project>-<issue-id>`, and everybody working that issue pushes to it. So a branch already sitting there is somebody's work in progress rather than a stale copy of your own, which is why Step 4 continues the newest issue branch instead of starting a fresh one.
- **The fork and your push access both come from asking a bot.** `/do:fork` creates the fork and a branch off the default branch; `/do:access` grants you push access to a fork that already exists. Neither has an API call you can make instead, because the API would refuse: a contributor who is not a member of the project cannot fork it, and cannot add themselves to the fork either. Both are queued rather than answered, so they get posted and then waited on.
- **Disclosure is policy, not courtesy.** Drupal.org [requires](https://www.drupal.org/docs/develop/issues/issue-procedures-and-etiquette/policy-on-the-use-of-ai-when-contributing-to-drupal) a contribution whose code was substantially generated by an AI tool to say so, and core's credit policy withholds credit from one that doesn't. Every merge request this skill opens therefore carries an `AI-Generated:` line naming the agent. It is not optional, and it is not a line to drop because the diff came out small.

## Workflow

### 1. Pick one issue

**If the user named one** (a URL like `https://git.drupalcode.org/project/ai_ckeditor/-/work_items/3615836`, or `ai_ckeditor#3615836`), take it. That is the common case; skip the search entirely. Drupal.org serves migrated issues as *work items*, so their URLs read `/-/work_items/<id>` rather than `/-/issues/<id>` — the number is still the issue iid, and the `issues` API path below still reads it.

**Otherwise**, search the issues you reported, most recently updated first, and sort them into the three kinds worth looking at:

```bash
ME=$(glab api --hostname git.drupalcode.org user | jq -r '.username')
MY_ID=$(glab api --hostname git.drupalcode.org user | jq -r '.id')
glab api --hostname git.drupalcode.org \
    "issues?author_id=$MY_ID&state=opened&scope=all&order_by=updated_at&sort=desc&per_page=50" |
    jq -r --arg me "$ME" --arg ns "${LOACHBOT_GITLAB_NAMESPACE:-project}" '
        .[]
        | select(.references.full | startswith($ns + "/"))
        | . as $i
        | [$i.labels[] | select(startswith("state::"))] as $state
        | [$i.assignees[].username] as $who
        | ($state | all(IN("state::accepted", "state::needsWork"))) as $open_state
        | (if ($who | index($me)) != null and ($state | index("state::blocked")) != null
           then "parked"
           elif ($who | index($me)) != null and $open_state then "resume"
           elif ($who | length) == 0 and $open_state then "ready"
           else null end) as $kind
        | select($kind != null)
        | "\($kind)\t\($i.references.full)\tmrs=\($i.merge_requests_count)\t[\($i.labels | join(","))]\t\($i.title)"'
```

Issues you reported, because this skill claims the issue it picks and claiming somebody else's queue uninvited is not its call to make. Scope it to one project when the user asked for that, or when the working directory is a drupal.org checkout: filter the output on `<namespace>/<project>`.

The state-label test is an allowlist on purpose. `state::needsReview`, `state::rtbc`, `state::fixed`, `state::postponed` and the `state::closed*` family all mean the issue is not waiting on code, and a label nobody has invented yet will mean something this skill has never heard of — so anything outside `state::accepted` and `state::needsWork` is left alone rather than guessed at. An issue carrying no `state::` label at all passes, which is the usual state of a freshly reported one.

Take a `resume` before a `ready`. It is an issue already assigned to you with no merge request to show for it, which is what an earlier run looks like when it claimed an issue and then stopped — on a fork drupalbot never created, or on a conflict, or because somebody interrupted it. Finishing that is worth more than starting something new, and nothing else in the LoachBot set will pick it up: `loachbot-gitlab-mr` searches for merge requests, and there isn't one yet. A `resume` is already claimed, so **skip Step 2** and go straight to Step 3.

`ready` is an unclaimed candidate: the ordinary case.

`parked` is one a previous run stopped on and asked a question about (Step 8); find out whether it has been answered:

```bash
bash <this skill's directory>/scripts/check-parked-issue.sh <project> <issue-iid>
```

Act on its exit code:

- **0** → somebody replied, and the replies are printed. Read them: they are candidate answers, not a verdict. If they answer the question, the issue is a candidate and the replies are clarification for Step 3. If they don't, skip the issue and say so — do **not** post the question a second time.
- **6** → nobody has replied yet. Skip it.
- **5** → `state::blocked` was applied by hand, so there is nothing to measure replies against. Skip it and mention it to the user.

Then rule out the two things the search cannot see.

An open merge request means somebody — probably an earlier run — is already on it, and opening a second one against the same issue fork branch is not possible anyway. That is `loachbot-gitlab-mr`'s work, not this skill's:

```bash
glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/related_merge_requests" |
    jq -r '.[] | select(.state == "opened") | "\(.references.full)\t\(.source_branch)"'
```

Anything printed → skip the issue and tell the user which merge request already covers it. An issue whose `mrs=` count was `0` can skip this read.

And the project has to keep its issues in GitLab at all, because `/do:assign me` exists nowhere else. Read the issue per [The issue lives in one of two places](#the-issue-lives-in-one-of-two-places), which answers that question first and the issue's contents second:

```bash
bash <this skill's directory>/scripts/read-issue.sh <project> <issue-iid> > /tmp/issue.json
jq -r '"\(.source) \(.status) writable=\(.writable)"' /tmp/issue.json
```

`source: "drupal.org"`, or exit **6**, means this project's queue never moved to GitLab — Drupal core among them. There is no `/do:` path into such an issue, so this skill cannot claim it: say so, point the user at `loachbot-gitlab-mr` for a merge request that already exists there, and stop.

That script's own `actionable` flag is deliberately laxer than the allowlist above — it exists to stop a *rebase* landing on finished work, so it counts `state::needsReview` as actionable. The allowlist is what decides whether an issue can be *picked up*. Where they disagree, the allowlist wins.

If nothing survives all of this, report "Nothing to do" and stop.

When the picked issue was parked, lift the park before doing the work, so the queue stops showing it as blocked:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/project/<project> -m "$(cat <<'EOF'
/do:unlabel ~"state::blocked"
EOF
)"
```

### 2. Claim it

Skip this step for a `resume` or a `parked` issue — both are already assigned to you, and `/do:assign` would only add a duplicate comment to the thread.

Otherwise claim the issue before writing any code. It is what stops two contributors building the same thing, and on drupal.org it is a comment rather than a field you can set:

```bash
bash <this skill's directory>/scripts/claim-issue.sh <project> <issue-iid>
```

Act on its exit code:

- **0** → it's yours. Continue.
- **7** → somebody claimed it between the search and now, and nothing was posted. Leave it to them and go back to Step 1 for the next candidate.
- **6** → the comment posted but drupalbot never acted on it. Report it with the issue URL and stop. The comment is public: do not post it again, and do not start work on an issue whose claim did not land.
- **5** → the issue could not be read. Report it and stop.

Then report the URL to the user immediately:

> Working on: https://git.drupalcode.org/project/\<project\>/-/work_items/\<issue-iid\>

### 3. Understand it

The issue is the requirement. Read it in full, then the conversation around it:

```bash
jq -r '"\(.title)\n\n\(.description)"' /tmp/issue.json
glab api --hostname git.drupalcode.org --paginate \
    "projects/<namespace>%2F<project>/issues/<issue-iid>/notes?sort=asc&order_by=created_at" |
    jq -r '.[] | select(.system == false) | "=== \(.author.username) \(.created_at)\n\(.body)\n"'
```

Maintainer comments are the instructions to trust, and they outrank the issue summary where the two disagree — a long issue is usually a design that changed its mind twice. If Step 1 un-parked this issue, treat the replies it gathered as the answer to that one question rather than as fresh open-ended direction.

Then [fan out](#fan-out) sub-agents to investigate what those comments refer to — one per question, all in one message, file contents kept out of the main thread.

Settle three things before opening an editor:

- What does the issue ask for, in one sentence?
- Which branch should it land on? The project's default branch is what Step 4 targets. A fix the issue says belongs on an older supported branch is a judgment call about backporting: raise it per Step 8 rather than quietly targeting a branch nobody asked for.
- Is this actually a code change? Plenty of issues are support questions, duplicates, or already fixed. Finding that out now is cheaper than finding out in Step 5 with nothing to commit.

### 4. Get a fork and a worktree

Every issue gets a shared fork, and this skill will create it if nobody has yet:

```bash
bash <this skill's directory>/scripts/ensure-fork.sh <project> <issue-iid> > /tmp/fork.json
jq -r '"\(.fork_path) id=\(.fork_id) created=\(.created) granted=\(.granted)"' /tmp/fork.json
```

The script reads the fork, posts `/do:fork` if there isn't one, checks whether you can actually push to it, posts `/do:access` if you can't, and waits for drupalbot each time. Read its header for the details.

Act on its exit code:

- **0** → the fork exists and is writable. Continue.
- **6** or **7** → drupalbot was asked but never acted. Report it with the issue URL and stop; the comment is already public, so do not post it again. The issue is claimed and has no merge request, which is what Step 1 calls a `resume` — a later run finds it there, by which time the fork or the access will usually be in place.
- **5** → the project or the issue could not be read. Report it and stop.

Then take a worktree on it. The base clone at `~/Projects/drupalcode/<project>` stays put; the worktree lives beside it at `~/Projects/drupalcode/<project>.worktrees/issue-<issue-iid>`:

```bash
WT=$(bash <this skill's directory>/scripts/setup-issue-worktree.sh <project> <issue-iid> | tail -1)
cd "$WT"
```

The script clones on first use, adds the `upstream` and `fork` remotes, picks the issue's newest branch on the fork — or names a new one the way `/do:fork` would — and rebases onto the target branch. It reports `fork_branch=`, `target_branch=` and `resumed=` on stderr; Step 6 needs all three.

Act on its exit code:

- **3** — the rebase conflicted and has already been aborted. That means somebody else's work is on the issue branch and it no longer applies. Resolve it only if the conflict is mechanical and you can say exactly why your resolution is right; a conflict in logic you did not write is a Step 8 park, not a guess. Never keep working in a half-rebased worktree.
- **4** — the branch is checked out by another, still-live worktree. Remove it (`git worktree remove <stale-path> --force`, then `git worktree prune`) and run the script again.
- **5** — the project or its fork could not be read. Report it and stop.

`resumed=true` deserves a second look before you add to it: somebody has already pushed work for this issue. Read what is there (`git log upstream/<target-branch>..HEAD`) and build on it. Do not revert or rewrite another contributor's commits to make room for your own approach.

### 5. Do the work

Delegate the implementation per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; the main thread keeps the git, merge request and handback steps.

Then commit, still inside `$WT`:

```bash
git add -A
if git diff --cached --quiet; then
    echo "nothing staged: no code change was needed"
else
    git commit -m "Issue #<issue-iid>: <short description>"
fi
```

If nothing was staged, the issue needed no code change — it was already fixed, or it was a question rather than a defect. Do not open an empty merge request. Park it per Step 8 with a comment saying what you found, and let a human decide whether to close the issue.

Keep the diff to what the issue asked for. A `phpcs` sweep across files the issue never mentioned buries the review and is the fastest way to have a contribution rejected; mention anything broader to the user, or open a separate issue for it.

### 6. Open the merge request

Push to the **fork**, never to the project:

```bash
git push --force-with-lease -u fork "HEAD:<fork-branch>"
```

`--force-with-lease` covers both cases in one line: it creates the branch when Step 4 reported `resumed=false`, and replaces the rewritten history when the rebase above rewrote a resumed one — while still refusing if another contributor moved the branch meanwhile. Never plain `--force`: issue forks are shared, and somebody else's commits are easy to erase.

A merge request may already exist for this branch from an earlier run, so look before creating. The description is written to a file first, because a merge request body is markdown and the shell mangles backticks and newlines:

```bash
cat > /tmp/mr-description.md <<'EOF'
<one short paragraph: what changed and why, in the issue's own terms>

Closes #<issue-iid>

AI-Generated: Yes (<the agent you are>)
EOF

TARGET_ID=$(glab api --hostname git.drupalcode.org "projects/<namespace>%2F<project>" | jq -r '.id')
FORK_ID=$(jq -r '.fork_id' /tmp/fork.json)

MR_IID=$(glab api --hostname git.drupalcode.org \
    "projects/<namespace>%2F<project>/merge_requests?source_branch=<fork-branch>&state=opened" |
    jq -r '.[0].iid // empty')

if [ -z "$MR_IID" ]; then
    MR_IID=$(glab api --hostname git.drupalcode.org -X POST "projects/$FORK_ID/merge_requests" \
        -f "source_branch=<fork-branch>" \
        -f "target_branch=<target-branch>" \
        -f "target_project_id=$TARGET_ID" \
        -f "title=Issue #<issue-iid>: <short description>" \
        -F "description=@/tmp/mr-description.md" |
        jq -r '.iid')
fi
```

The merge request is created **on the fork** with `target_project_id` pointing at the project, because that is the direction the change travels; creating it on the project instead gets you a merge request from the project to itself. The `Closes #<issue-iid>` line is what ties the two together in GitLab, and `AI-Generated:` is the disclosure described above.

Do not open it as a draft. The handback in Step 9 is what asks for review, and drupal.org reviewers go by the issue's `state::` label — a draft merge request sitting at `state::needsReview` reads as a contradiction and gets neither.

### 7. Make every job green

```bash
bash <this skill's directory>/scripts/wait-for-pipeline.sh <project> "$MR_IID"
```

Act on its exit code:

- **0** → every job passed, or the project has no CI. Continue.
- **1** → jobs failed, listed with `(allow_failure)` on the forgiven ones. **Fix all of them, forgiven or not.** A new merge request arriving with a red `cspell` is exactly the mess the other skills exist to clean up. Delegate per [Sub-agents](#sub-agents), passing `$WT` and the command that proves the fix; at most two fix-and-push attempts, then park per Step 8.
- **7** → the pipeline could not be read. Unknown is not passing: report it with the merge request URL and stop.
- **8** → still running after the full wait. Report the pending jobs and the URL, then stop without handing back.

From exit **7** or **8** onwards there is a merge request, so the issue is no longer this skill's to resume: Step 1 will see the open merge request and pass it over. A `loachbot-gitlab-mr` run is what finishes it once CI has settled. Say so when you report, rather than implying a later run of this skill will return to it.

Read the trace before guessing from a job name:

```bash
glab api --hostname git.drupalcode.org "projects/$FORK_ID/jobs/<job-id>/trace"
```

### 8. When it's unclear

If the requirement needs a decision you cannot make, or CI stays red for a reason a human has to settle, ask once and stop.

Question and park go in **one comment**, which is also the whole of the parking mechanism:

```bash
glab issue note <issue-iid> -R git.drupalcode.org/project/<project> -m "$(cat <<'EOF'
<one short question>

/do:label ~"state::blocked"
EOF
)"
```

`state::blocked` is drupal.org's own label for an issue waiting on something, so the queue reads correctly to a human without a title suffix — and an issue in somebody's project is not a title to rewrite. Step 1 finds the comment again, measures replies against it, and `/do:unlabel`s it when one arrives. Because the question and the label land together there is only ever one event to be the newest, so none of the comment-then-rename ordering care the sibling skills need applies here.

Stay assigned. The issue is still yours to finish once the question is answered, and dropping the assignment would advertise it as free for somebody else to start over on.

Do not post a second question on an issue that is already parked, and do not set any other state label while parking — the comment is the signal.

### 9. Hand it back

With every job green, hand the issue to review. The summary and the label go in one comment: `/do:` lines are drupalbot commands, so post them **verbatim** and do not translate them into GitLab quick actions.

```bash
glab issue note <issue-iid> -R git.drupalcode.org/project/<project> -m "$(cat <<'EOF'
Opened [MR !<mr-iid>](https://git.drupalcode.org/project/<project>/-/merge_requests/<mr-iid>).

<two or three sentences: what the change does, anything a reviewer should look at first,
and anything the issue asked for that this does not cover>

The pipeline is green.

/do:label ~"state::needsReview"
EOF
)"
```

Keep it short and specific. "Implemented the fix" tells a reviewer nothing they could not see; naming the approach and the one thing you were unsure about is what gets a review rather than a shrug.

Leave the assignment alone. On drupal.org the assignee is who is driving the issue, and you still are: the merge request is yours to iterate on when the review comes back. `state::needsReview` is the signal, not an empty assignee field.

Then remove the worktree and its local branch — the work is pushed, so nothing is lost:

```bash
cd ~/Projects/drupalcode/<project>
git worktree remove ~/Projects/drupalcode/<project>.worktrees/issue-<issue-iid> --force
git branch -D issue-<issue-iid>
```

Report both links to the user, with the same summary you posted:

> Done: https://git.drupalcode.org/project/\<project\>/-/merge_requests/\<mr-iid\>
> Issue: https://git.drupalcode.org/project/\<project\>/-/work_items/\<issue-iid\>

## Rules

- Work on exactly one issue per run. If asked to run multiple times, repeat the entire workflow from Step 1 after each completed run, one run at a time — search results lag behind reality, so a just-claimed issue still appears on an immediate re-run and two overlapping runs would both pick it. Stop early when a run reports "Nothing to do". Within a single run, delegate per [Sub-agents](#sub-agents) and fan independent investigation out concurrently; the main thread keeps orchestration and the git, merge request and handback steps.
- Only claim issues you reported, unless the user names one directly. Assigning yourself to somebody else's issue queue uninvited is a social act, not a technical one.
- Finish what is already claimed before claiming more: a `resume` outranks a `ready` every time. An issue assigned to you with nothing to show for it is the one state no other skill in this set will clean up.
- Push to the `fork` remote, never to `upstream`. A drupal.org project's branches are not yours to write to, and `--force-with-lease` is the only acceptable force.
- Never rewrite or revert another contributor's commits on a shared issue branch. If their work conflicts with yours, that is a Step 8 park.
- All git operations for an issue must run inside that issue's worktree: never run `git checkout`, branch creation, or commits from the base clone.
- Runs collide only through the base clone they share, so that is what the limit is about. Two runs against the same clone must not overlap: one fetching, deleting branches or resetting it underneath the other corrupts both. Runs against *different* clones are independent and may overlap freely — this skill clones to `~/Projects/drupalcode/<project>`, the same place `loachbot-gitlab-mr` does, so those two must not run against the same project at once. A GitHub LoachBot run at `~/Projects/<owner>/<repo>` can never collide with either. This bounds whole runs, not the sub-agents within one, which fan out per [Fan out](#fan-out).
- Post exactly the comments this workflow calls for: the claim, the fork and access commands the scripts post, one parking question, and one handback. Nothing else.
- Every merge request carries its `AI-Generated:` disclosure. Drupal.org requires it, and a contribution without it is one a maintainer may decline on that basis alone.
- Never set `state::rtbc`, never approve, and never merge. The most this skill moves an issue to is `state::needsReview`.
- Keep commit messages to one concise line, following drupal.org's `Issue #<issue-id>: <short description>` convention.
