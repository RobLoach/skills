#!/usr/bin/env bash
#
# Post one inline review comment on a merge request's diff, as a resolvable thread.
#
# Usage: bash scripts/post-inline-comment.sh <project> <mr-iid> <path> <new-line> <body-file> [old-line]
#
# The body comes from a file rather than an argument: review comments are markdown, and
# passing them through the shell mangles backticks, newlines and quotes. A body that
# begins with `@` must come from a file too - `glab api -F` reads a leading `@` as a
# filename - which is the other reason this takes no inline body.
#
# Uses the discussions API rather than `glab mr note create --file/--line`, which glab
# still labels an experiment that "might be unstable or removed at any time".
#
# Positions are the fiddly part, so they are assembled here from the merge request's own
# `diff_refs`:
#   * An *added* line exists only on the new side: pass <new-line>, omit [old-line].
#   * A *context* line exists on both sides and GitLab rejects it unless both are given:
#     pass [old-line] as well. Diff hunk headers (@@ -a,b +c,d @@) carry both numbers.
#   * <path> is the new path. A renamed file needs its old path too; this script does not
#     cover that case - comment on it at file level instead.
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
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
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

# `position` is a nested object, and `--field`/`--raw-field` cannot express one: they
# send `position[base_sha]` as a literal key name, which GitLab silently ignores. The
# POST then succeeds, returns 201, and creates an ordinary comment in the Overview tab
# with no position at all - the worst outcome available, because nothing reports an
# error. So the body goes as real JSON through `--input`, with the Content-Type that
# `--input` does not set on its own.
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

if ! RESPONSE=$(printf '%s' "$PAYLOAD" | api --method POST \
    -H "Content-Type: application/json" --input - \
    "projects/$NAMESPACE%2F$PROJECT/merge_requests/$IID/discussions" 2>&1); then
    printf '%s\n' "$RESPONSE" >&2
    echo "GitLab rejected the inline position for $PATH_NEW:$LINE_NEW" >&2
    exit 1
fi

# 201 is not proof. A dropped position yields a DiscussionNote rather than a DiffNote,
# so the thread exists but sits in the Overview tab instead of on the line - which reads
# as success to anything that only checks the exit status. Confirm what was created.
if [ "$(printf '%s' "$RESPONSE" | jq -r '[.notes[]? | select(.type == "DiffNote")] | length')" = "0" ]; then
    printf '%s\n' "$RESPONSE" >&2
    echo "the thread was created without a position, so it is not on the diff:" \
        "delete it and fall back to a summary comment" >&2
    exit 1
fi

printf '%s' "$RESPONSE" | jq -r '.id // empty'
