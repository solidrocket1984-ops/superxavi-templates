#!/usr/bin/env bash
#
# SuperDev auto-merge · v2-hardened
# Source file for ops/dispatcher/ — installed to /opt/superxavi/scripts/auto-merge-pr.sh
# by ops/dispatcher/install.sh.
#
# Improvements over v1:
#   • gh_retry shim: every gh CLI call retries once on GitHub 5xx (502/503/504)
#     after a configurable sleep (AUTO_MERGE_GH_RETRY_SLEEP, default 5s). This
#     is the single most common cause of false needs_attention escalations.
#   • All other logic (poll loop, update-branch, safeguards, BD writes, email)
#     is unchanged from the well-tested v1 baseline.
#
# Usage:
#   auto-merge-pr.sh <pr_number> <repo_slug> <brief_id> [max_wait_seconds]
#
# Tunables (env):
#   AUTO_MERGE_ENABLED            default true   — set to anything else to skip
#   AUTO_MERGE_POLL_INTERVAL      default 30s    — seconds between poll iterations
#   AUTO_MERGE_MAX_UPDATE_ATTEMPTS default 2     — max gh pr update-branch calls
#   AUTO_MERGE_UPDATE_GRACE       default 300s   — extra timeout after update-branch
#   AUTO_MERGE_GH_RETRY_SLEEP     default 5s     — pause before gh 5xx retry
#   AUTO_MERGE_TEST_MODE          default 0      — if 1, uses AUTO_MERGE_TEST_SLEEP
#   AUTO_MERGE_TEST_SLEEP         default 0      — sleep override in test mode
#

set -uo pipefail

PR_NUMBER="${1:-}"
REPO_SLUG="${2:-}"
BRIEF_ID="${3:-}"
MAX_WAIT_SECONDS="${4:-600}"

if [ -z "$PR_NUMBER" ] || [ -z "$REPO_SLUG" ] || [ -z "$BRIEF_ID" ]; then
  echo "ERROR: usage: auto-merge-pr.sh <pr_number> <repo_slug> <brief_id> [max_wait_seconds]" >&2
  exit 2
fi

if [ "${AUTO_MERGE_ENABLED:-true}" != "true" ]; then
  echo "auto-merge: AUTO_MERGE_ENABLED=${AUTO_MERGE_ENABLED:-}, skipping (PR #$PR_NUMBER)"
  exit 0
fi

# Load env. .gh.env / .supabase.env assign without `export`; we re-export so
# gh CLI subprocesses inherit them.
# shellcheck source=/dev/null
[ -f /home/xavi/.gh.env ]       && source /home/xavi/.gh.env
# shellcheck source=/dev/null
[ -f /home/xavi/.supabase.env ] && source /home/xavi/.supabase.env
export GH_TOKEN="${GH_TOKEN:-}" SUPABASE_URL="${SUPABASE_URL:-}" SUPABASE_SERVICE_KEY="${SUPABASE_SERVICE_KEY:-}"

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_SERVICE_KEY:-}" ]; then
  echo "ERROR: SUPABASE_URL / SUPABASE_SERVICE_KEY required" >&2
  exit 2
fi
if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN required for gh CLI" >&2
  exit 2
fi

POLL_INTERVAL="${AUTO_MERGE_POLL_INTERVAL:-30}"
XAVI_EMAIL_TO="${XAVI_EMAIL:-xavi@respondeya.es}"
FROM_EMAIL="${AUTO_MERGE_FROM_EMAIL:-superdev@respondeya.es}"
MAX_UPDATE_ATTEMPTS="${AUTO_MERGE_MAX_UPDATE_ATTEMPTS:-2}"
UPDATE_GRACE="${AUTO_MERGE_UPDATE_GRACE:-300}"
UPDATE_ATTEMPTS=0
GH_RETRY_SLEEP="${AUTO_MERGE_GH_RETRY_SLEEP:-5}"

log() {
  printf '%s auto-merge[%s] %s\n' "$(date -Iseconds)" "$BRIEF_ID" "$1" >&2
}

_sleep() {
  if [ "${AUTO_MERGE_TEST_MODE:-0}" = "1" ]; then
    sleep "${AUTO_MERGE_TEST_SLEEP:-0}"
  else
    sleep "$1"
  fi
}

# ─── gh wrapper with single retry on GitHub 5xx ──────────────────────────
# Transient 5xx (502 Bad Gateway, 503, 504) from api.github.com is the most
# common cause of false needs_attention escalations. We retry exactly once
# after a short pause; persistent 5xx still surfaces the failure normally.
gh_retry() {
  local out rc
  out=$(gh "$@" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && echo "$out" | grep -qE 'HTTP (50[0-9])|status code 50[0-9]|502 Bad Gateway|503 Service Unavailable|504 Gateway Time'; then
    log "gh ${1:-?}: GitHub 5xx (rc=$rc), retrying once after ${GH_RETRY_SLEEP}s"
    _sleep "$GH_RETRY_SLEEP"
    out=$(gh "$@" 2>&1)
    rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

# ─── BD helper ───────────────────────────────────────────────────────────
update_brief_bd() {
  local new_status="$1" detail="$2" now_iso payload url
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  if [ "$new_status" = "merged" ]; then
    payload=$(jq -nc --arg s "$new_status" --arg sha "$detail" --arg ts "$now_iso" \
      '{status:$s, merge_sha:$sha, merge_completed_at:$ts}')
  else
    payload=$(jq -nc --arg s "$new_status" --arg reason "$detail" --arg ts "$now_iso" \
      '{status:$s, needs_attention_reason:$reason, needs_attention_at:$ts}')
  fi
  url="${SUPABASE_URL}/rest/v1/superdev_briefs?brief_id=eq.${BRIEF_ID}"
  curl -s --max-time 10 \
    -X PATCH "$url" \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "$payload" >/dev/null 2>&1 || log "WARN: BD PATCH failed (status=$new_status)"
}

notify_xavi() {
  local subject="$1" reason="$2" pr_url="$3" detail="${4:-}"
  if [ -z "${RESEND_API_KEY:-}" ]; then
    log "RESEND_API_KEY missing, skipping email (reason=$reason)"
    return 0
  fi
  local action_items
  case "$reason" in
    checks_failed) action_items='<li>Open the PR and inspect the failing check logs.</li><li>Push a fix to the branch, or close the PR if the brief was wrong.</li>' ;;
    conflicts)     action_items='<li>The branch conflicts with main or is blocked.</li><li>Rebase the branch or resolve conflicts manually, then re-merge.</li>' ;;
    timeout)       action_items='<li>Checks did not finish within the timeout window.</li><li>Decide whether to wait, re-run the failing job, or merge manually.</li>' ;;
    safeguard)     action_items='<li>An auto-merge safeguard skipped the merge.</li><li>Review the PR and merge by hand if appropriate.</li>' ;;
    *)             action_items='<li>Open the PR and decide next steps.</li>' ;;
  esac
  local html
  html=$(cat <<HTML
<h2>SuperDev auto-merge needs attention</h2>
<p><strong>Brief:</strong> <code>${BRIEF_ID}</code></p>
<p><strong>PR:</strong> <a href="${pr_url}">${pr_url}</a></p>
<p><strong>Reason:</strong> ${reason}</p>
$( [ -n "$detail" ] && printf '<p><strong>Detail:</strong> %s</p>' "$detail" )
<h3>Next steps</h3>
<ul>${action_items}</ul>
<hr/>
<p style="color:#888;font-size:12px">Sent by auto-merge-pr.sh v2 — repo ${REPO_SLUG}</p>
HTML
)
  local payload
  payload=$(jq -nc \
    --arg from "$FROM_EMAIL" --arg to "$XAVI_EMAIL_TO" \
    --arg subject "$subject" --arg html "$html" \
    '{from:$from, to:[$to], subject:$subject, html:$html}')
  curl -s --max-time 10 \
    -X POST "https://api.resend.com/emails" \
    -H "Authorization: Bearer ${RESEND_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || log "WARN: Resend POST failed (reason=$reason)"
}

try_update_branch() {
  if [ "$UPDATE_ATTEMPTS" -ge "$MAX_UPDATE_ATTEMPTS" ]; then
    log "update-branch: attempts exhausted ($UPDATE_ATTEMPTS/$MAX_UPDATE_ATTEMPTS), giving up"
    return 1
  fi
  UPDATE_ATTEMPTS=$((UPDATE_ATTEMPTS + 1))
  log "update-branch: calling gh pr update-branch (attempt $UPDATE_ATTEMPTS/$MAX_UPDATE_ATTEMPTS)"
  local out rc
  out=$(gh_retry pr update-branch "$PR_NUMBER" --repo "$REPO_SLUG")
  rc=$?
  if [ "$rc" -eq 0 ]; then
    log "update-branch: success — main merged into PR head; awaiting CI"
    return 0
  fi
  if echo "$out" | grep -qiE 'merge conflict|conflicts? with|cannot be (auto-?)?merged|not mergeable'; then
    log "update-branch: CONFLICT — branch left untouched. raw: $(echo "$out" | tr '\n' ' ' | head -c 300)"
    return 2
  fi
  log "update-branch: transient failure (rc=$rc). raw: $(echo "$out" | tr '\n' ' ' | head -c 300)"
  return 3
}

fetch_pr_state() {
  local out
  out=$(gh_retry pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
    --json baseRefName,title,mergeable,mergeStateStatus,statusCheckRollup,labels,isDraft \
    -q '{
      baseRef:.baseRefName,
      title:.title,
      mergeable:.mergeable,
      mergeState:.mergeStateStatus,
      isDraft:.isDraft,
      checks:[.statusCheckRollup[]?.conclusion],
      labels:[.labels[]?.name],
      checksAvailable:true
    }' 2>/dev/null)
  if [ -n "$out" ] && [ "$out" != "null" ]; then
    echo "$out"; return 0
  fi
  out=$(gh_retry pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
    --json baseRefName,title,mergeable,mergeStateStatus,labels,isDraft \
    -q '{
      baseRef:.baseRefName,
      title:.title,
      mergeable:.mergeable,
      mergeState:.mergeStateStatus,
      isDraft:.isDraft,
      checks:[],
      labels:[.labels[]?.name],
      checksAvailable:false
    }' 2>/dev/null)
  if [ -n "$out" ] && [ "$out" != "null" ]; then
    echo "$out"; return 0
  fi
  echo ""
}

PR_URL="https://github.com/${REPO_SLUG}/pull/${PR_NUMBER}"

# ─── Pre-flight safeguards ───────────────────────────────────────────────
initial_state=$(fetch_pr_state)
if [ -z "$initial_state" ] || [ "$initial_state" = "null" ]; then
  log "ERROR: could not fetch PR state for #$PR_NUMBER on $REPO_SLUG"
  update_brief_bd "needs_attention" "pr_fetch_failed"
  notify_xavi "SuperDev: PR #$PR_NUMBER fetch failed" "safeguard" "$PR_URL" \
    "gh pr view returned no data — check repo slug and GH_TOKEN scope."
  exit 1
fi

BASE_REF=$(echo "$initial_state" | jq -r '.baseRef // ""')
PR_TITLE=$(echo "$initial_state" | jq -r '.title // ""')
IS_DRAFT=$(echo "$initial_state" | jq -r '.isDraft // false')
LABELS_CSV=$(echo "$initial_state" | jq -r '.labels // [] | join(",")')

if [ "$BASE_REF" != "main" ]; then
  log "safeguard: base=$BASE_REF (not main), skipping auto-merge"
  notify_xavi "SuperDev: PR #$PR_NUMBER targets $BASE_REF, not main" "safeguard" "$PR_URL" \
    "Auto-merge only runs against main. Merge manually if intentional."
  exit 0
fi
if echo "$PR_TITLE" | grep -qE '\[WIP\]|\[DRAFT\]'; then
  log "safeguard: title marked WIP/DRAFT, skipping"
  notify_xavi "SuperDev: PR #$PR_NUMBER marked WIP/DRAFT" "safeguard" "$PR_URL" \
    "Title contains [WIP] or [DRAFT]. Auto-merge skipped."
  exit 0
fi
if [ "$IS_DRAFT" = "true" ]; then
  log "safeguard: PR is in draft state, skipping"
  notify_xavi "SuperDev: PR #$PR_NUMBER is a draft" "safeguard" "$PR_URL" \
    "PR is in draft state. Mark ready for review to enable auto-merge."
  exit 0
fi
if echo ",${LABELS_CSV}," | grep -qE ',(do-not-merge|needs-review),'; then
  log "safeguard: blocking label (labels=$LABELS_CSV), skipping"
  notify_xavi "SuperDev: PR #$PR_NUMBER has blocking label" "safeguard" "$PR_URL" \
    "Labels: ${LABELS_CSV}. Remove do-not-merge/needs-review to enable auto-merge."
  exit 0
fi

# ─── Poll loop ───────────────────────────────────────────────────────────
log "starting poll (max ${MAX_WAIT_SECONDS}s, every ${POLL_INTERVAL}s)"

ELAPSED=0
STATE="$initial_state"
while :; do
  MERGEABLE=$(echo "$STATE" | jq -r '.mergeable // "UNKNOWN"')
  MERGE_STATE=$(echo "$STATE" | jq -r '.mergeState // "UNKNOWN"')
  CHECKS_AVAILABLE=$(echo "$STATE" | jq -r '.checksAvailable // true')
  CHECKS_FAILED=$(echo "$STATE" | jq -r '[.checks[]? | select(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED")] | length')
  CHECKS_PENDING=$(echo "$STATE" | jq -r '[.checks[]? | select(. == null or . == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS")] | length')
  CHECKS_TOTAL=$(echo "$STATE" | jq -r '.checks // [] | length')

  log "poll t=${ELAPSED}s mergeable=$MERGEABLE state=$MERGE_STATE checks(fail=$CHECKS_FAILED pending=$CHECKS_PENDING total=$CHECKS_TOTAL avail=$CHECKS_AVAILABLE)"

  if [ "$CHECKS_FAILED" -gt 0 ]; then
    log "checks failed, marking needs_attention"
    update_brief_bd "needs_attention" "checks_failed"
    notify_xavi "SuperDev: PR #$PR_NUMBER checks failing" "checks_failed" "$PR_URL" \
      "${CHECKS_FAILED} of ${CHECKS_TOTAL} checks failed."
    exit 1
  fi

  if [ "$MERGE_STATE" = "DIRTY" ] || \
     { [ "$MERGE_STATE" = "BLOCKED" ] && [ "$CHECKS_AVAILABLE" = "true" ]; }; then
    log "merge state=$MERGE_STATE, marking needs_attention"
    update_brief_bd "needs_attention" "conflicts"
    notify_xavi "SuperDev: PR #$PR_NUMBER blocked or has conflicts" "conflicts" "$PR_URL" \
      "GitHub mergeStateStatus=${MERGE_STATE}. Rebase the branch or resolve conflicts manually."
    exit 1
  fi

  if [ "$MERGE_STATE" = "BEHIND" ]; then
    try_update_branch
    UPDATE_RC=$?
    case "$UPDATE_RC" in
      0)
        MAX_WAIT_SECONDS=$((MAX_WAIT_SECONDS + UPDATE_GRACE))
        log "update-branch ok — extended max_wait by ${UPDATE_GRACE}s (new=${MAX_WAIT_SECONDS}s)"
        _sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        STATE=$(fetch_pr_state)
        [ -z "$STATE" ] || [ "$STATE" = "null" ] && STATE='{}'
        continue
        ;;
      1)
        log "update-branch attempts exhausted ($UPDATE_ATTEMPTS), marking needs_attention"
        update_brief_bd "needs_attention" "behind_update_exhausted"
        notify_xavi "SuperDev: PR #$PR_NUMBER still BEHIND after $UPDATE_ATTEMPTS update attempts" \
          "conflicts" "$PR_URL" \
          "Tried gh pr update-branch ${UPDATE_ATTEMPTS} time(s) but main keeps advancing. Rebase manually."
        exit 1
        ;;
      2)
        log "update-branch reported real conflict — marking needs_attention (no force-push)"
        update_brief_bd "needs_attention" "conflicts_during_update"
        notify_xavi "SuperDev: PR #$PR_NUMBER has real conflicts with main" "conflicts" "$PR_URL" \
          "gh pr update-branch could not merge main into the PR head (real conflict). Rebase and resolve manually. The branch was NOT modified."
        exit 1
        ;;
      *)
        log "update-branch transient failure, will retry on next poll if still BEHIND"
        ;;
    esac
  fi

  READY_TO_MERGE=0
  if [ "$MERGEABLE" = "MERGEABLE" ]; then
    if [ "$CHECKS_AVAILABLE" = "true" ]; then
      [ "$CHECKS_PENDING" -eq 0 ] && READY_TO_MERGE=1
    else
      case "$MERGE_STATE" in
        CLEAN|UNSTABLE|HAS_HOOKS) READY_TO_MERGE=1 ;;
      esac
    fi
  fi
  if [ "$READY_TO_MERGE" -eq 1 ]; then
    log "ready to merge — running gh pr merge --squash"
    MERGE_OUTPUT=$(gh_retry pr merge "$PR_NUMBER" --repo "$REPO_SLUG" --squash --delete-branch) || {
      log "ERROR: gh pr merge failed: $MERGE_OUTPUT"
      update_brief_bd "needs_attention" "merge_command_failed"
      notify_xavi "SuperDev: PR #$PR_NUMBER merge command failed" "conflicts" "$PR_URL" \
        "gh pr merge --squash returned non-zero. Output: ${MERGE_OUTPUT}"
      exit 1
    }
    MERGE_SHA=$(gh_retry pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json mergeCommit \
      -q '.mergeCommit.oid // ""' 2>/dev/null || echo "")
    update_brief_bd "merged" "$MERGE_SHA"
    log "merged successfully (sha=${MERGE_SHA:-unknown})"
    echo "PR #$PR_NUMBER merged sha=${MERGE_SHA:-unknown}"
    exit 0
  fi

  if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
    log "timeout after ${ELAPSED}s, marking needs_attention"
    update_brief_bd "needs_attention" "timeout"
    notify_xavi "SuperDev: PR #$PR_NUMBER timed out waiting for checks" "timeout" "$PR_URL" \
      "Waited ${ELAPSED}s. checks(fail=$CHECKS_FAILED pending=$CHECKS_PENDING total=$CHECKS_TOTAL) mergeable=$MERGEABLE state=$MERGE_STATE."
    exit 1
  fi

  _sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  STATE=$(fetch_pr_state)
  if [ -z "$STATE" ] || [ "$STATE" = "null" ]; then
    log "WARN: empty PR state on re-poll, retrying"
    STATE='{}'
  fi
done
