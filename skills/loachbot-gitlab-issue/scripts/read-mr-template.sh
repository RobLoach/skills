#!/usr/bin/env bash
#
# Print the merge request template a drupal.org project expects its contributors to use,
# if it has one.
#
# Usage: bash scripts/read-mr-template.sh <project>
#
# <project> is the project's machine name - "ai_ckeditor", not "project/ai_ckeditor".
#
# Most drupal.org projects have no template and a plain description is correct for them.
# The ones that do have a template usually use it to ask for things no description
# written from scratch would include - testing instructions, a reviewer checklist, and
# on `ai` and its satellites a required AI disclosure with specific options to choose
# between. Filling in a project's own form is the difference between a disclosure that
# counts and a sentence in the wrong place, so this looks before writing.
#
# GitLab applies `Default.md` automatically in its web UI, so that is the one a
# contributor using the website would get and the one preferred here. A project with
# several templates and no Default.md has made no such choice, so the first is taken and
# the rest are named on stderr for the caller to reconsider.
#
# File paths in the API are URL-encoded, and dots have to be encoded along with the
# slashes - `.gitlab/x.md` reads as `%2Egitlab%2Fx%2Emd` - or the path resolves to
# nothing.
#
# Exit codes:
#   0  The template is on stdout, and its path is named on stderr.
#   5  The project could not be read.
#   6  The project has no merge request template. This is the common case and not an
#      error: write the description in the skill's own format instead.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: bash scripts/read-mr-template.sh <project>" >&2
    exit 64
fi

HOST=${LOACHBOT_GITLAB_HOST:-git.drupalcode.org}
# drupal.org keeps contrib under project/, but its sandboxes live under sandbox/.
NAMESPACE=${LOACHBOT_GITLAB_NAMESPACE:-project}
PROJECT=$1

TEMPLATE_DIR=".gitlab/merge_request_templates"

api() { glab api --hostname "$HOST" "$@"; }

# Dots as well as slashes; see the header.
encode() { printf '%s' "$1" | jq -sRr '@uri' | sed 's/\./%2E/g'; }

if ! REF=$(api "projects/$NAMESPACE%2F$PROJECT" 2>/dev/null | jq -r '.default_branch // empty') ||
    [ -z "$REF" ]; then
    echo "cannot read $NAMESPACE/$PROJECT on $HOST" >&2
    exit 5
fi

# A project without the directory answers 404, which is the ordinary case rather than a
# failure, so the read is taken in two steps to keep `set -e` out of it.
TREE=''
TREE=$(api "projects/$NAMESPACE%2F$PROJECT/repository/tree?path=$(encode "$TEMPLATE_DIR")&ref=$REF" \
    2>/dev/null) || TREE=''

NAMES=$(printf '%s' "${TREE:-null}" | jq -r '
    if type == "array" then
        [.[] | select(.type == "blob") | .name] | sort | .[]
    else empty end
')

if [ -z "$NAMES" ]; then
    echo "$NAMESPACE/$PROJECT has no $TEMPLATE_DIR on $REF" >&2
    exit 6
fi

CHOSEN=$(printf '%s\n' "$NAMES" | grep -ix 'Default.md' || true)
if [ -z "$CHOSEN" ]; then
    CHOSEN=$(printf '%s\n' "$NAMES" | head -1)
    OTHERS=$(printf '%s\n' "$NAMES" | tail -n +2 | paste -sd ',' -)
    if [ -n "$OTHERS" ]; then
        echo "no Default.md; using $CHOSEN, but these also exist: $OTHERS" >&2
    fi
fi

PATH_ENC=$(encode "$TEMPLATE_DIR/$CHOSEN")

if ! BODY=$(api "projects/$NAMESPACE%2F$PROJECT/repository/files/$PATH_ENC/raw?ref=$REF" 2>/dev/null); then
    echo "cannot read $TEMPLATE_DIR/$CHOSEN on $REF" >&2
    exit 5
fi

echo "template=$TEMPLATE_DIR/$CHOSEN (ref $REF)" >&2
printf '%s\n' "$BODY"
