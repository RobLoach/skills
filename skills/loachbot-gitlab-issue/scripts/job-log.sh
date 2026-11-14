#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Print one CI job's log as plain text.
#
# Usage: bash scripts/job-log.sh <pipeline-project> <job-id>
#
# <pipeline-project> is the project the pipeline ran in - often the parent rather than
# the fork. ANSI codes, section markers and drupal.org's per-line timestamps break grep
# and diff; they are stripped with $'...' escapes, since BSD sed does not read `\x1b`.
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

if ! LOG=$(glab api --hostname "$HOST" "projects/$1/jobs/$2/trace" 2>/dev/null); then
    echo "cannot read the log of job $2 in project $1" >&2
    exit 7
fi

printf '%s\n' "$LOG" |
    sed -E "s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z [0-9a-fA-F]{2}[OE]\+? ?//
        s/section_(start|end):[0-9]+:[^$CR]*$CR//g; s/$ESC\[[0-9;?]*[A-Za-z]//g" |
    tr -d '\r'
