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
# A repository whose workflow has not registered yet is indistinguishable from one
# with no CI at all, so the rollup is probed several times before "no CI" is believed.
# Getting that wrong would mark an item done with its CI never verified, which is the
# one outcome this script exists to prevent.
#
# Polls rather than using `gh pr checks --watch`, so bounding the wait needs nothing
# but `sleep` - no GNU `timeout`, which is absent on stock macOS.
#
# Exit codes:
#   0  Checks passed, or the repository has no CI at all.
#   8  Still pending after the full wait. Leave the item alone; a later run will see
#      the settled result.
#   7  The check status could not be read at all (API failure, unexpected output).
#      Unknown is not the same as passing: report it and stop.
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
# Consecutive empty rollups that together mean "this repository really has no CI",
# rather than "the workflow has not appeared yet".
EMPTY_PROBES=${EMPTY_PROBES:-3}

sleep 30

SEEN_CHECKS=0
for PROBE in $(seq "$EMPTY_PROBES"); do
    if ! ROLLUP=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" \
        --json statusCheckRollup --jq '.statusCheckRollup | length' 2>/tmp/loachbot-rollup-err); then
        cat /tmp/loachbot-rollup-err >&2
        echo "could not read the status check rollup; not treating that as passing" >&2
        exit 7
    fi

    # An empty or non-numeric rollup means the query silently returned nothing useful.
    # Without `set -e` an unguarded `[ "$ROLLUP" -eq 0 ]` would print an error here and
    # fall through into polling, so name the case instead.
    case "$ROLLUP" in
        '' | *[!0-9]*)
            echo "unexpected status check rollup: '$ROLLUP'" >&2
            exit 7
            ;;
    esac

    if [ "$ROLLUP" -gt 0 ]; then
        SEEN_CHECKS=1
        break
    fi

    # Nothing registered yet. Give a slow workflow another interval to appear, unless
    # this was the last probe.
    if [ "$PROBE" -lt "$EMPTY_PROBES" ]; then
        sleep "$INTERVAL"
    fi
done

if [ "$SEEN_CHECKS" -eq 0 ]; then
    echo "no checks registered across $EMPTY_PROBES probes; treating as passing" >&2
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
