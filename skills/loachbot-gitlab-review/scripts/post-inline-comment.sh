#!/usr/bin/env bash
#
# Post one inline review comment on a merge request's diff, as a resolvable thread.
#
# Usage: bash scripts/post-inline-comment.sh <project> <mr-iid> <path> <new-line> <body-file> [old-line]
#
# The body comes from a file: markdown mangles through the shell, and `glab api -F` reads
# a leading `@` as a filename. Uses the discussions API because glab still labels
# `glab mr note create --file/--line` experimental.
#
# An *added* line needs only <new-line>. A *context* line exists on both sides and GitLab
# rejects it without [old-line] too; the hunk header (@@ -a,b +c,d @@) has both. Renamed
# files are not covered - comment on those at file level.
#
# Exit codes:
#   0  Posted. The discussion id is printed.
#   1  GitLab rejected the position - usually a context line given without [old-line], or
#      a line that is not part of the diff at all. The error is printed; fall back to a
#      file-level or summary comment rather than guessing at another line number.
#   5  The merge request could not be read.

set -euo pipefail

if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
    echo "usage: bash scripts/post-inline-comment.sh <project> <mr-iid> <path> <new-line> <body-file> [old-line]" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1
IID=$2
PATH_NEW=$3
LINE_NEW=$4
BODY_FILE=$5
LINE_OLD=${6:-}

if [ ! -r "$BODY_FILE" ]; then
    echo "body file not readable: $BODY_FILE" >&2
    exit 64
fi

api() { glab api --hostname "$HOST" "$@"; }

if ! MR=$(api "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID" 2>/dev/null) ||
    [ "$(printf '%s' "$MR" | jq -r '.diff_refs.head_sha // empty')" = "" ]; then
    echo "cannot read merge request !$IID in $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

BASE_SHA=$(printf '%s' "$MR" | jq -r '.diff_refs.base_sha')
START_SHA=$(printf '%s' "$MR" | jq -r '.diff_refs.start_sha')
HEAD_SHA=$(printf '%s' "$MR" | jq -r '.diff_refs.head_sha')

# `--field position[base_sha]=...` is sent as a literal key that GitLab ignores, so the
# POST returns 201 with an unpositioned Overview comment and no error. Send real JSON
# through `--input`, with the Content-Type it does not set on its own.
PAYLOAD=$(jq -n \
    --rawfile body "$BODY_FILE" \
    --arg base_sha "$BASE_SHA" \
    --arg start_sha "$START_SHA" \
    --arg head_sha "$HEAD_SHA" \
    --arg path "$PATH_NEW" \
    --argjson new_line "$LINE_NEW" \
    --arg old_line "$LINE_OLD" \
    '{
        body: $body,
        position: ({
            base_sha: $base_sha,
            start_sha: $start_sha,
            head_sha: $head_sha,
            position_type: "text",
            new_path: $path,
            old_path: $path,
            new_line: $new_line
        } + (if $old_line == "" then {} else {old_line: ($old_line | tonumber)} end))
    }')

# glab's stderr is kept apart: a warning on success would make the JSON unparseable,
# read as a failure, and be retried into a duplicate thread.
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
if ! RESPONSE=$(printf '%s' "$PAYLOAD" | api --method POST \
    -H "Content-Type: application/json" --input - \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/discussions" 2>"$ERR"); then
    cat "$ERR" >&2
    printf '%s\n' "$RESPONSE" >&2
    echo "GitLab rejected the inline position for $PATH_NEW:$LINE_NEW" >&2
    exit 1
fi

# 201 is not proof: a dropped position yields a DiscussionNote, not a DiffNote.
if [ "$(printf '%s' "$RESPONSE" | jq -r '[.notes[]? | select(.type == "DiffNote")] | length')" = "0" ]; then
    printf '%s\n' "$RESPONSE" >&2
    echo "the thread was created without a position, so it is not on the diff:" \
        "delete it and fall back to a summary comment" >&2
    exit 1
fi

printf '%s' "$RESPONSE" | jq -r '.id // empty'
