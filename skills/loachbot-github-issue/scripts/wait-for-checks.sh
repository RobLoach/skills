#!/usr/bin/env bash
#
# SHARED: duplicated verbatim across skills, because each skill directory is
# installed on its own. Keep every copy identical.
#
# Wait for a Pull Request's CI checks to settle.
#
# Usage: bash scripts/wait-for-checks.sh <owner> <repo> <pr-number>
#
# Checks take a moment to register after a push, so this pauses before probing. A
# repository with no CI has nothing to wait for, but `gh pr checks` exits 1 both when
# checks fail and when none exist - so the status rollup decides which it is, before
# any polling starts.
#
# Polls rather than using `gh pr checks --watch`, so bounding the wait needs nothing
# but `sleep` - no GNU `timeout`, which is absent on stock macOS.
#
# Exit codes:
#   0  Checks passed, or the repository has no CI at all.
#   8  Still pending after the full wait. Leave the item alone; a later run will see
#      the settled result.
#   1  At least one check failed.

set -uo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: bash scripts/wait-for-checks.sh <owner> <repo> <pr-number>" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3

ATTEMPTS=${ATTEMPTS:-30}
INTERVAL=${INTERVAL:-60}

sleep 30

ROLLUP=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" \
    --json statusCheckRollup --jq '.statusCheckRollup | length')

if [ "$ROLLUP" -eq 0 ]; then
    echo "no checks configured; treating as passing" >&2
    exit 0
fi

STATUS=8
for _ in $(seq "$ATTEMPTS"); do
    gh pr checks "$NUMBER" --repo "$OWNER/$REPO"
    STATUS=$?
    # 8 means still pending; anything else is a final verdict.
    [ "$STATUS" -eq 8 ] || break
    sleep "$INTERVAL"
done

exit "$STATUS"
