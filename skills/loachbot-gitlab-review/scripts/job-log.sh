#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Print one CI job's log as plain text.
#
# Usage: bash scripts/job-log.sh <pipeline-project> <job-id>
#
# <pipeline-project> is the project id the pipeline ran in, as wait-for-pipeline.sh or
# review-context.sh print it. It is often the parent project rather than the fork, and
# asking the wrong one is a flat 404.
#
# The raw trace is full of ANSI colour codes, collapsible-section markers
# (`section_start:<ts>:<name>\r\e[0K`) and, on drupal.org's runners, a timestamp and
# stream tag on every line, all of which break grep and diff. They are stripped with
# plain sed and $'...' escapes rather than `\x1b`, which BSD sed on macOS does not read.
#
# Exit codes:
#   7  The log could not be read: wrong project, or the job has no trace yet.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: bash scripts/job-log.sh <pipeline-project> <job-id>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
ESC=$'\033'
CR=$'\r'

# Two steps, so a 404 is reported rather than ending the run under `set -e`.
if ! LOG=$(glab api --hostname "$HOST" "projects/$1/jobs/$2/trace" 2>/dev/null); then
    echo "cannot read the log of job $2 in project $1" >&2
    exit 7
fi

printf '%s\n' "$LOG" |
    sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z [0-9a-fA-F]{2}[OE]\+? ?//
        s/section_(start|end):[0-9]+:[^$CR]*$CR//g; s/$ESC\[[0-9;?]*[A-Za-z]//g" |
    tr -d '\r'
