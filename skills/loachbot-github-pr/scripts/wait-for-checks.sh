#!/usr/bin/env bash
#
# SHARED: each skill installs alone, so every copy must stay identical.
#
# Wait for a Pull Request's CI checks to settle.
#
# Usage: bash scripts/wait-for-checks.sh <owner> <repo> <pr-number> [head-sha]
#
# Right after a push the PR still reports the previous commit's checks, already green,
# so pass the pushed commit (`git rev-parse HEAD`, the full SHA) as head-sha: nothing is
# judged until the PR's head is that commit. Without it, whatever head is current counts.
#
# `gh pr checks` exits 1 for failed checks, for no checks, and for a dropped connection,
# so the verdict comes from `--json bucket` instead; a failed read is retried, not failed.
# A workflow not registered yet looks like no CI, so "no CI" is believed only after
# LOACHBOT_CHECKS_EMPTY_PROBES empty rollups. Polls with `sleep` rather than GNU
# `timeout`, absent on macOS.
#
# A `continue-on-error: true` step fails without failing its job. Unlike drupal.org's
# template-imposed `allow_failure` it is hand-written, usually meaning "known noisy", so
# those steps are listed but leave the exit code alone.
#
# Cancelled and action-required checks (gh files the latter under `fail`) have no
# failure log to fix, so they get their own code instead of sending the caller to edit.
#
# LOACHBOT_CHECKS_CEILING (default 540) bounds the whole wait, checked before every sleep:
# an agent's tool call is killed at 10 minutes, and a killed call hands back no exit code
# at all. A long CI therefore takes several calls, each ending in 8.
#
# Exit codes:
#   0  Checks passed, or the repository has no CI at all. Soft-failed steps, if any, are
#      listed first - passing here means the checks are green, not that nothing failed.
#   8  Unsettled: still pending when the time ran out, the PR head never reached
#      head-sha, or the status could not be read at all (API failure, auth, unexpected
#      output); stderr says which. Unknown is not passing. Run it again.
#   1  At least one check failed.
#   7  Nothing failed, but at least one check was cancelled or is waiting on approval
#      (action required).

set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: bash scripts/wait-for-checks.sh <owner> <repo> <pr-number> [head-sha]" >&2
    exit 64
fi

OWNER=$1
REPO=$2
NUMBER=$3
EXPECTED=${4:-}

# Both end up in API paths and comparisons, where a typo would read as "pending" forever:
# a short SHA never equals the full headRefOid.
case "$NUMBER" in
    '' | *[!0-9]*) echo "<pr-number> must be numeric: $NUMBER" >&2; exit 64 ;;
esac
if [ -n "$EXPECTED" ] && ! [[ $EXPECTED =~ ^[0-9a-f]{40}$ ]]; then
    echo "[head-sha] must be a full 40-character SHA: $EXPECTED" >&2
    exit 64
fi

ATTEMPTS=${LOACHBOT_CHECKS_ATTEMPTS:-30}
INTERVAL=${LOACHBOT_CHECKS_INTERVAL:-60}
EMPTY_PROBES=${LOACHBOT_CHECKS_EMPTY_PROBES:-3}
CEILING=${LOACHBOT_CHECKS_CEILING:-540}

# A non-number would surface mid-wait as a `[` error read as "pending"; 0 skips polling.
for KNOB in "LOACHBOT_CHECKS_ATTEMPTS=$ATTEMPTS" "LOACHBOT_CHECKS_EMPTY_PROBES=$EMPTY_PROBES" \
    "LOACHBOT_CHECKS_CEILING=$CEILING"; do
    case "${KNOB#*=}" in
        '' | *[!0-9]* | 0 | 0*) echo "${KNOB%%=*} must be an integer >= 1" >&2; exit 64 ;;
    esac
done
case "$INTERVAL" in
    '' | *[!0-9]*) echo "LOACHBOT_CHECKS_INTERVAL must be an integer >= 0" >&2; exit 64 ;;
esac

# Per-run, so overlapping runs never read each other's stderr.
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

# Would sleeping $1 more seconds still end before the ceiling?
fits() { [ $((SECONDS + $1)) -lt "$CEILING" ]; }

! fits 30 || sleep 30

STATUS=8
EMPTY=0
SEEN=0
PROBLEM=
ATTEMPT=0
OUT_OF_TIME=0
while [ "$ATTEMPT" -lt "$ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$ATTEMPT" -gt 1 ]; then
        if ! fits "$INTERVAL"; then
            OUT_OF_TIME=1
            break
        fi
        sleep "$INTERVAL"
    fi
    PROBLEM=

    # Cleared once matched: the checks read below then belong to the expected commit.
    if [ -n "$EXPECTED" ]; then
        HEAD_SHA=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" \
            --json headRefOid --jq '.headRefOid' 2>"$ERR") || HEAD_SHA=
        if [ "$HEAD_SHA" != "$EXPECTED" ]; then
            PROBLEM="PR head is ${HEAD_SHA:-unreadable}, not yet the pushed $EXPECTED"
            continue
        fi
        EXPECTED=
    fi

    if BUCKETS=$(gh pr checks "$NUMBER" --repo "$OWNER/$REPO" --json bucket,state \
        --jq '[.[] | if .state == "ACTION_REQUIRED" then "action" else .bucket end]
              | unique | join(" ")' 2>"$ERR"); then
        case " $BUCKETS " in
            *" fail "*) STATUS=1; break ;;
            *" cancel "* | *" action "*) STATUS=7; break ;;
            *" pending "*) SEEN=1; continue ;;
            "  ") ;; # No checks yet; fall through to the empty-probe count.
            *) STATUS=0; break ;;
        esac
    fi

    # `gh pr checks` also fails when no checks exist, so the rollup tells "none
    # registered" apart from a read that failed.
    if ROLLUP=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" \
        --json statusCheckRollup --jq '.statusCheckRollup | length' 2>>"$ERR") &&
        [ "$ROLLUP" = 0 ]; then
        if [ "$SEEN" -eq 0 ]; then
            EMPTY=$((EMPTY + 1))
            if [ "$EMPTY" -ge "$EMPTY_PROBES" ]; then
                echo "no checks registered across $EMPTY_PROBES probes; treating as passing" >&2
                exit 0
            fi
        fi
        continue
    fi

    # Anything else is unknown: keep waiting, and say why if it never clears.
    EMPTY=0
    PROBLEM=$(cat "$ERR")
done

if [ "$STATUS" -eq 8 ]; then
    if [ -n "$PROBLEM" ]; then
        printf '%s\n' "$PROBLEM" >&2
        echo "could not read the checks; not treating that as passing" >&2
    elif [ "$OUT_OF_TIME" -eq 1 ]; then
        echo "checks still pending at the ${CEILING}s ceiling; run this again" >&2
    else
        echo "checks still pending after the full wait" >&2
    fi
fi

SOFT=
SHA=$(gh pr view "$NUMBER" --repo "$OWNER/$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null)
if [ -n "$SHA" ]; then
    SOFT=$(gh api "repos/$OWNER/$REPO/actions/runs?head_sha=$SHA&per_page=50" \
        --jq '.workflow_runs[].id' 2>/dev/null |
        while read -r RUN_ID; do
            # shellcheck disable=SC2016  # $job is a jq binding, not a shell one.
            gh api "repos/$OWNER/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" \
                --jq '.jobs[]
                      | select(.conclusion == "success")
                      | .name as $job
                      | .steps[]?
                      | select(.conclusion == "failure")
                      | "  \($job) > \(.name)"' 2>/dev/null
        done)
fi

if [ -n "$SOFT" ]; then
    echo "soft-failed steps (continue-on-error, so the checks above stayed green):" >&2
    printf '%s\n' "$SOFT" >&2
fi

# The human-readable table, for the caller to read; its exit code is not the verdict.
gh pr checks "$NUMBER" --repo "$OWNER/$REPO" 2>&1
exit "$STATUS"
