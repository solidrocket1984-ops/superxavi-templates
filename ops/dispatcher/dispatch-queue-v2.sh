#!/bin/bash
#
# SuperDev Auto-Dispatcher · v2 · hardened
# (derived from /opt/superxavi/scripts/dispatch-queue.sh v1, 2026-05-23)
#
# Changes vs v1 — addressing known bugs:
#   1. Repo normalization (basename) BEFORE forking the worker. Briefs that
#      arrive with "org/repo" format are accepted; a missing repo dir is
#      classified as PERMANENT and the row is marked status=blocked at the
#      first attempt with an actionable last_dispatch_error — no 3-retry storm.
#   2. Permanent vs. transient error classification:
#        permanent (status=blocked, no retry): repo dir missing, brief_md empty,
#                  suspicious shell content, wrapper exit in {1,2,3,6}
#        transient (existing mark_dispatch_failed RPC, cap = 3): wrapper exit 4
#                  (git failed), network/curl errors, generic non-zero exit
#   3. Cycle heartbeat: at the end of every dispatcher run we upsert
#      system_config.dispatcher_heartbeat = {ts, cycle_result} via Supabase
#      REST. Best-effort: any failure is logged and ignored.
#   4. Stale lock cleanup: /var/lock/superxavi-runbrief.lock with mtime > 30 min
#      AND no current process holding it is removed. Safe because flock is by
#      inode — removing an unheld file is cosmetic; removing a held file is
#      refused (we test with fuser).
#   5. Worktree GC: once per hour we prune stale git worktrees across
#      /opt/superxavi/repos/* (worktrees with mtime > 14 days OR whose branch
#      is already merged into origin/main) plus /tmp/*-worktree leftovers.
#   6. Exit code 6 (guard_tabla_rasa): run-brief-v2.sh already patched
#      status=blocked with full detail before exiting. Worker only updates
#      timing fields; does not override the detailed last_dispatch_error.
#
# Same security model as v1: never logs SUPABASE_SERVICE_KEY, secrets passed
# via curl -K config file, worker body uses a QUOTED heredoc delimiter to
# avoid dispatcher-time expansion.
#
set -uo pipefail
set +x

LOCK_FILE="/var/lock/superdev-dispatch.lock"
RUNBRIEF_LOCK="/var/lock/superxavi-runbrief.lock"
LOG_DIR="/opt/superxavi/logs"
LOG="${LOG_DIR}/dispatch.log"
TMP_DIR="/opt/superxavi/tmp/dispatch"
STATE_DIR="/opt/superxavi/tmp/dispatcher-state"
REPOS_ROOT="/opt/superxavi/repos"
WORKTREE_GC_STAMP="${STATE_DIR}/last-worktree-gc"

# Knobs (env overridable).
RUNBRIEF_LOCK_MAX_AGE="${RUNBRIEF_LOCK_MAX_AGE:-1800}"   # 30 min
WORKTREE_MAX_AGE_DAYS="${WORKTREE_MAX_AGE_DAYS:-14}"
WORKTREE_GC_INTERVAL="${WORKTREE_GC_INTERVAL:-3600}"     # 1 h
BRIEF_TIMEOUT="${BRIEF_TIMEOUT:-5400}"                   # passed through to wrapper

mkdir -p "$LOG_DIR" "$TMP_DIR" "$STATE_DIR"
chmod 700 "$TMP_DIR"

log() {
  printf '%s %s %s\n' "$(date -Iseconds)" "$1" "$2" >> "$LOG"
}

# ---- Single-instance lock ----
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  if [ "$(( 10#$(date +%M) % 10 ))" -eq 0 ]; then
    log "[INFO]" "Another dispatcher instance running, skip"
  fi
  exit 0
fi

# ---- Load env ----
# .supabase.env / .superdev.env / .gh.env assign without `export`; we re-export
# below so curl, jq, and any child processes inherit them reliably.
# shellcheck source=/dev/null
[ -f /home/xavi/.supabase.env ] && source /home/xavi/.supabase.env
# shellcheck source=/dev/null
[ -f /home/xavi/.superdev.env ] && source /home/xavi/.superdev.env
# shellcheck source=/dev/null
[ -f /home/xavi/.gh.env ]       && source /home/xavi/.gh.env

export SUPABASE_URL="${SUPABASE_URL:-}" \
       SUPABASE_SERVICE_KEY="${SUPABASE_SERVICE_KEY:-}" \
       SUPERDEV_WEBHOOK_TOKEN="${SUPERDEV_WEBHOOK_TOKEN:-}" \
       GH_TOKEN="${GH_TOKEN:-}"

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_SERVICE_KEY:-}" ]; then
  log "[ERROR]" "SUPABASE_URL or SUPABASE_SERVICE_KEY missing"
  exit 1
fi

# ---- Headers config file (keeps key out of argv) ----
HEADERS_FILE="${TMP_DIR}/.headers-$$-$(date +%s).curl"
umask 077
{
  printf 'header = "apikey: %s"\n' "$SUPABASE_SERVICE_KEY"
  printf 'header = "Authorization: Bearer %s"\n' "$SUPABASE_SERVICE_KEY"
  printf 'header = "Content-Type: application/json"\n'
} > "$HEADERS_FILE"
chmod 600 "$HEADERS_FILE"
trap 'rm -f "$HEADERS_FILE"' EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────

# normalize_repo "org/repo" -> "repo"
# normalize_repo "repo"     -> "repo"
# (rejects empty input by echoing nothing)
normalize_repo() {
  local raw="${1:-}"
  [ -z "$raw" ] && return 0
  printf '%s' "${raw##*/}"
}

# mark_blocked <brief_id> <reason>
# Permanent failures bypass the dispatch_attempts retry path entirely.
mark_blocked() {
  local brief_id="$1"
  local reason="$2"
  local now_iso payload
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  payload=$(jq -nc \
    --arg s "blocked" \
    --arg err "$reason" \
    --arg ts "$now_iso" \
    '{status:$s, last_dispatch_error:$err, blocked_at:$ts}')
  curl -s --max-time 10 -K "$HEADERS_FILE" \
    -X PATCH "${SUPABASE_URL}/rest/v1/superdev_briefs?brief_id=eq.${brief_id}" \
    -H "Prefer: return=minimal" \
    -d "$payload" >/dev/null 2>&1 \
    || log "[WARN]" "BD PATCH(blocked) failed for $brief_id"
  log "[BLOCKED]" "$brief_id -> $reason"
}

# heartbeat <cycle_result>
# Upserts system_config.dispatcher_heartbeat. Silent best-effort.
heartbeat() {
  local result="$1"
  local now_iso payload
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  payload=$(jq -nc \
    --arg ts "$now_iso" \
    --arg r "$result" \
    '{key:"dispatcher_heartbeat", value:{ts:$ts, cycle_result:$r}}')
  curl -s --max-time 5 -K "$HEADERS_FILE" \
    -X POST "${SUPABASE_URL}/rest/v1/system_config?on_conflict=key" \
    -H "Prefer: resolution=merge-duplicates,return=minimal" \
    -d "$payload" >/dev/null 2>&1 || true
}

# release_stale_runbrief_lock
# Removes the runbrief flock file when older than RUNBRIEF_LOCK_MAX_AGE AND
# no process currently holds it. Safe by design: fuser refuses to lie about
# in-use files, so we never yank the lock out from under a live wrapper.
release_stale_runbrief_lock() {
  [ -f "$RUNBRIEF_LOCK" ] || return 0
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$RUNBRIEF_LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -le "$RUNBRIEF_LOCK_MAX_AGE" ] && return 0
  if fuser "$RUNBRIEF_LOCK" >/dev/null 2>&1; then
    log "[WARN]" "runbrief.lock old (age=${age}s) but still held; leaving in place"
    return 0
  fi
  rm -f "$RUNBRIEF_LOCK"
  log "[INFO]" "removed stale runbrief.lock (age=${age}s)"
}

# cleanup_worktrees
# Once per WORKTREE_GC_INTERVAL: for every repo under REPOS_ROOT, prune
# git's stale worktree registrations, then remove worktrees whose backing
# tree is older than WORKTREE_MAX_AGE_DAYS OR whose branch is already merged
# into origin/main. Also reaps /tmp/*-worktree leftovers (used by Claude's
# internal worktrees) with the same age policy.
cleanup_worktrees() {
  local now stamp_age
  now=$(date +%s)
  if [ -f "$WORKTREE_GC_STAMP" ]; then
    stamp_age=$(( now - $(stat -c %Y "$WORKTREE_GC_STAMP" 2>/dev/null || echo 0) ))
    [ "$stamp_age" -lt "$WORKTREE_GC_INTERVAL" ] && return 0
  fi
  touch "$WORKTREE_GC_STAMP"
  log "[INFO]" "worktree GC starting (max_age=${WORKTREE_MAX_AGE_DAYS}d)"

  local cutoff_secs=$(( WORKTREE_MAX_AGE_DAYS * 86400 ))
  local removed=0

  # Per-repo cleanup
  for repo_dir in "$REPOS_ROOT"/*/; do
    [ -d "$repo_dir/.git" ] || continue
    (
      cd "$repo_dir" || exit 0
      git worktree prune 2>/dev/null || true

      # Build the set of merged branches once (cheap on small repos).
      local merged_branches
      merged_branches=$(git branch -r --merged origin/main 2>/dev/null \
        | sed -E 's|^[[:space:]]*origin/||' | grep -v '^HEAD' || true)

      local wt_dir base_name age branch is_merged
      for wt_dir in .claude/worktrees/*/ /tmp/*-worktree/; do
        [ -d "$wt_dir" ] || continue
        # /tmp/*-worktree resolves to literal pattern when no matches → skip
        case "$wt_dir" in '/tmp/*-worktree/') continue;; esac
        age=$(( $(date +%s) - $(stat -c %Y "$wt_dir" 2>/dev/null || echo 0) ))
        branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        is_merged=0
        if [ -n "$branch" ] && printf '%s\n' "$merged_branches" | grep -qx "$branch"; then
          is_merged=1
        fi
        if [ "$age" -gt "$cutoff_secs" ] || [ "$is_merged" -eq 1 ]; then
          base_name=$(basename "$wt_dir")
          # Try clean removal first; fall back to force; last resort rm -rf.
          if git worktree remove "$wt_dir" 2>/dev/null \
             || git worktree remove --force "$wt_dir" 2>/dev/null; then
            : # ok
          else
            rm -rf "$wt_dir" 2>/dev/null || true
          fi
          echo "removed $base_name (age=${age}s merged=${is_merged} branch=${branch:-?})"
        fi
      done
    ) 2>&1 | while read -r line; do
      log "[GC]" "$(basename "$repo_dir"): $line"
      removed=$((removed + 1))
    done
  done

  log "[INFO]" "worktree GC complete (events=$removed)"
}

# ─────────────────────────────────────────────────────────────────────
# Per-cycle housekeeping (runs every minute, but GC is rate-limited)
# ─────────────────────────────────────────────────────────────────────
release_stale_runbrief_lock
cleanup_worktrees

# ─────────────────────────────────────────────────────────────────────
# Pick next brief — same dual-path strategy as v1
# ─────────────────────────────────────────────────────────────────────
PICK_URL="${SUPABASE_URL}/rest/v1/rpc/pick_next_queued_brief"
RESPONSE=$(curl -s --max-time 10 -K "$HEADERS_FILE" -X POST "$PICK_URL" -d '{}' 2>/dev/null)
CURL_EXIT=$?

if [ $CURL_EXIT -ne 0 ]; then
  log "[ERROR]" "curl pick_next_queued_brief failed (exit $CURL_EXIT)"
  heartbeat "network_error"
  exit 2
fi

USED_FALLBACK="no"
if echo "$RESPONSE" | jq -e 'type=="object" and .code=="42702"' >/dev/null 2>&1; then
  USED_FALLBACK="yes"
  SELECT_URL="${SUPABASE_URL}/rest/v1/superdev_briefs?status=eq.queued&order=created_at.asc&limit=1&select=id,brief_id,repo,model,brief_md,dispatch_attempts"
  SELECT_RESP=$(curl -s --max-time 10 -K "$HEADERS_FILE" "$SELECT_URL" 2>/dev/null)
  if [ -z "$SELECT_RESP" ] || [ "$SELECT_RESP" = "null" ] || [ "$SELECT_RESP" = "[]" ]; then
    if [ "$(( 10#$(date +%M) % 10 ))" -eq 0 ]; then
      log "[INFO]" "queue empty (fallback path)"
    fi
    heartbeat "queue_empty"
    exit 0
  fi
  ROW_ID=$(echo "$SELECT_RESP" | jq -r '.[0].id // empty')
  CURR_ATTEMPTS=$(echo "$SELECT_RESP" | jq -r '.[0].dispatch_attempts // 0')
  if [ -z "$ROW_ID" ]; then
    log "[ERROR]" "fallback SELECT returned no id"
    heartbeat "error"
    exit 2
  fi
  NEW_ATTEMPTS=$((CURR_ATTEMPTS + 1))
  NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  PATCH_BODY=$(jq -nc \
    --arg now "$NOW_ISO" \
    --argjson attempts "$NEW_ATTEMPTS" \
    '{status:"running", picked_up_at:$now, started_at:$now, dispatch_attempts:$attempts}')
  PATCH_URL="${SUPABASE_URL}/rest/v1/superdev_briefs?id=eq.${ROW_ID}&status=eq.queued"
  RESPONSE=$(curl -s --max-time 10 -K "$HEADERS_FILE" \
    -X PATCH "$PATCH_URL" \
    -H "Prefer: return=representation" \
    -d "$PATCH_BODY" 2>/dev/null)
  if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "[]" ] || [ "$RESPONSE" = "null" ]; then
    log "[INFO]" "fallback PATCH returned 0 rows (race)"
    heartbeat "race_lost"
    exit 0
  fi
fi

if [ "$RESPONSE" = "[]" ] || [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
  if [ "$(( 10#$(date +%M) % 10 ))" -eq 0 ]; then
    log "[INFO]" "queue empty"
  fi
  heartbeat "queue_empty"
  exit 0
fi

if echo "$RESPONSE" | jq -e 'type=="object" and has("code")' >/dev/null 2>&1; then
  ERR_MSG=$(echo "$RESPONSE" | jq -r '.message // "unknown"')
  log "[ERROR]" "Supabase RPC error: $ERR_MSG"
  heartbeat "rpc_error"
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────
# Parse picked brief
# ─────────────────────────────────────────────────────────────────────
BRIEF_ID=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].brief_id else .brief_id end // empty')
REPO_RAW=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].repo else .repo end // empty')
MODEL=$(echo "$RESPONSE"   | jq -r 'if type=="array" then .[0].model else .model end // "sonnet"')
BRIEF_MD=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].brief_md else .brief_md end // empty')
ATTEMPTS=$(echo "$RESPONSE" | jq -r 'if type=="array" then .[0].dispatch_attempts else .dispatch_attempts end // 1')

if [ -z "$BRIEF_ID" ]; then
  log "[ERROR]" "malformed brief data (missing brief_id)"
  heartbeat "malformed"
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────
# Pre-flight validation — PERMANENT failures bypass the retry path
# ─────────────────────────────────────────────────────────────────────
REPO=$(normalize_repo "$REPO_RAW")

if [ -z "$REPO" ]; then
  mark_blocked "$BRIEF_ID" "brief.repo is empty"
  heartbeat "blocked_invalid"
  exit 0
fi

REPO_DIR="${REPOS_ROOT}/${REPO}"
if [ ! -d "$REPO_DIR" ]; then
  reason="repo dir not found: ${REPO_DIR} (raw=\"${REPO_RAW}\", normalized=\"${REPO}\"). "
  reason+="Brief used long-form 'org/repo' — only short repo names are accepted. "
  reason+="Available repos: $(ls -1 "$REPOS_ROOT" 2>/dev/null | head -20 | tr '\n' ',' | sed 's/,$//')"
  mark_blocked "$BRIEF_ID" "$reason"
  heartbeat "blocked_repo_missing"
  exit 0
fi

if [ -z "$BRIEF_MD" ]; then
  mark_blocked "$BRIEF_ID" "brief_md is empty — nothing to dispatch"
  heartbeat "blocked_empty_brief"
  exit 0
fi

# Suspicious shell content gate (kept from v1).
SUSPICIOUS_PATTERN='rm[[:space:]]+-rf[[:space:]]+/|curl[[:space:]]+[^|]+\|[[:space:]]*(bash|sh)([[:space:]]|$)|wget[[:space:]]+[^|]+\|[[:space:]]*(bash|sh)([[:space:]]|$)'
if printf '%s' "$BRIEF_MD" | grep -qE "$SUSPICIOUS_PATTERN"; then
  log "[SECURITY]" "brief=$BRIEF_ID contains suspicious shell pattern"
  mark_blocked "$BRIEF_ID" "suspicious shell content (rm -rf / | bash) detected by dispatcher"
  heartbeat "blocked_security"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# Write brief to transient file (avoids heredoc-quoting traps)
# ─────────────────────────────────────────────────────────────────────
BRIEF_FILE="${TMP_DIR}/${BRIEF_ID}-$(date +%s).md"
printf '%s' "$BRIEF_MD" > "$BRIEF_FILE"
chmod 600 "$BRIEF_FILE"

log "[INFO]" "Dispatching brief=$BRIEF_ID repo=$REPO model=$MODEL attempt=$ATTEMPTS fallback=$USED_FALLBACK"

WORKER_HEADERS_FILE="${TMP_DIR}/.worker-headers-${BRIEF_ID}-$(date +%s).curl"
cp -p "$HEADERS_FILE" "$WORKER_HEADERS_FILE"

WRAPPER_LOG="${LOG_DIR}/dispatch-${BRIEF_ID}-$(date +%s).log"

# Secrets and config flow to the worker via environment (private; visible only
# in /proc/<pid>/environ, mode 0600). They are NOT substituted into the bash
# -c body — that would expose them in /proc/<pid>/cmdline.
export CLAUDE_MODEL="$MODEL"
export DISPATCH_BRIEF_ID="$BRIEF_ID"
export DISPATCH_REPO="$REPO"
export DISPATCH_BRIEF_FILE="$BRIEF_FILE"
export DISPATCH_WRAPPER_LOG="$WRAPPER_LOG"
export DISPATCH_HEADERS_FILE="$WORKER_HEADERS_FILE"
export DISPATCH_LOG_FILE="$LOG"
export BRIEF_TIMEOUT
# SUPABASE_URL / SUPABASE_SERVICE_KEY already exported above.

# IMPORTANT: heredoc delimiter is QUOTED ('WORKER_BODY_END') — nothing in the
# body is expanded at dispatcher time. Every $VAR expands at worker runtime
# via the inherited environment. This was bug-fix territory in May 2026; do
# not rewrite as `bash -c '...'` with single-quote outer.
#
# Wrapper exit-code classification:
#   0       -> status=ok  (dispatcher patches timing + status=ok WHERE status=eq.running)
#   6       -> guard_tabla_rasa blocked (run-brief already patched blocked; only timing updated)
#   1,2,3   -> PERMANENT (args / repo missing / brief empty) -> status=blocked
#   any !=0 -> TRANSIENT -> mark_dispatch_failed RPC (existing 3-retry cap)
WORKER_BODY=$(cat <<'WORKER_BODY_END'
set -uo pipefail
set +x

START_TS=$(date +%s)
# The wrapper enforces its own BRIEF_TIMEOUT around the claude call; the outer
# 8h fence here is a hard ceiling against runaway shells / forks.
cat "$DISPATCH_BRIEF_FILE" | timeout 8h /opt/superxavi/scripts/run-brief.sh \
  "$DISPATCH_BRIEF_ID" "$DISPATCH_REPO" \
  > "$DISPATCH_WRAPPER_LOG" 2>&1
WRAPPER_EXIT=$?
END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

TIMING_BODY=$(jq -nc \
  --arg ts "$NOW_ISO" \
  --argjson dur "$DURATION" \
  --arg log "$DISPATCH_WRAPPER_LOG" \
  '{completed_at:$ts, duration_seconds:$dur, log_path:$log}')

if [ "$WRAPPER_EXIT" -eq 0 ]; then
  curl -s --max-time 10 -K "$DISPATCH_HEADERS_FILE" \
    -X PATCH "$SUPABASE_URL/rest/v1/superdev_briefs?brief_id=eq.$DISPATCH_BRIEF_ID" \
    -d "$TIMING_BODY" >/dev/null 2>&1
  # status=ok only if the row is still in running; run-brief may have written
  # partial already (Fix 1), in which case this PATCH finds 0 rows and is a no-op.
  curl -s --max-time 10 -K "$DISPATCH_HEADERS_FILE" \
    -X PATCH "$SUPABASE_URL/rest/v1/superdev_briefs?brief_id=eq.$DISPATCH_BRIEF_ID&status=eq.running" \
    -d '{"status":"ok"}' >/dev/null 2>&1
  echo "$(date -Iseconds) [INFO] wrapper ok for $DISPATCH_BRIEF_ID (duration=${DURATION}s)" >> "$DISPATCH_LOG_FILE"
elif [ "$WRAPPER_EXIT" -eq 6 ]; then
  # guard_tabla_rasa blocked: run-brief-v2.sh already patched status=blocked
  # with a detailed last_dispatch_error. Only update timing — do not override.
  curl -s --max-time 10 -K "$DISPATCH_HEADERS_FILE" \
    -X PATCH "$SUPABASE_URL/rest/v1/superdev_briefs?brief_id=eq.$DISPATCH_BRIEF_ID" \
    -d "$TIMING_BODY" >/dev/null 2>&1
  echo "$(date -Iseconds) [BLOCKED] guard_tabla_rasa exit 6 for $DISPATCH_BRIEF_ID (${DURATION}s)" >> "$DISPATCH_LOG_FILE"
elif [ "$WRAPPER_EXIT" -eq 1 ] || [ "$WRAPPER_EXIT" -eq 2 ] || [ "$WRAPPER_EXIT" -eq 3 ]; then
  # Permanent: args missing / repo missing / brief empty. Pre-flight should
  # have caught these, but the wrapper may also reject for the same reasons
  # if a worker race / stale row sneaks past.
  REASON_TXT="wrapper exit $WRAPPER_EXIT (permanent: args/repo/brief invalid) after ${DURATION}s"
  BLOCK_BODY=$(jq -nc --arg s "blocked" --arg err "$REASON_TXT" --arg ts "$NOW_ISO" \
    '{status:$s, last_dispatch_error:$err, blocked_at:$ts}')
  curl -s --max-time 10 -K "$DISPATCH_HEADERS_FILE" \
    -X PATCH "$SUPABASE_URL/rest/v1/superdev_briefs?brief_id=eq.$DISPATCH_BRIEF_ID" \
    -H "Prefer: return=minimal" \
    -d "$BLOCK_BODY" >/dev/null 2>&1
  echo "$(date -Iseconds) [BLOCKED] wrapper exit $WRAPPER_EXIT for $DISPATCH_BRIEF_ID (permanent)" >> "$DISPATCH_LOG_FILE"
else
  # Transient (git failed, claude infrastructure error, timeout, ...). Existing
  # RPC enforces the 3-retry cap.
  FAIL_BODY=$(jq -nc \
    --arg id "$DISPATCH_BRIEF_ID" \
    --arg err "wrapper exit $WRAPPER_EXIT after ${DURATION}s (log $DISPATCH_WRAPPER_LOG)" \
    '{p_brief_id:$id, p_error:$err}')
  curl -s --max-time 10 -K "$DISPATCH_HEADERS_FILE" \
    -X POST "$SUPABASE_URL/rest/v1/rpc/mark_dispatch_failed" \
    -d "$FAIL_BODY" >/dev/null 2>&1
  echo "$(date -Iseconds) [ERROR] wrapper exit $WRAPPER_EXIT for $DISPATCH_BRIEF_ID (transient)" >> "$DISPATCH_LOG_FILE"
fi

rm -f "$DISPATCH_BRIEF_FILE" "$DISPATCH_HEADERS_FILE"
WORKER_BODY_END
)

nohup bash -c "$WORKER_BODY" >/dev/null 2>&1 < /dev/null &
BG_PID=$!
disown 2>/dev/null || true
log "[INFO]" "dispatched $BRIEF_ID (background PID $BG_PID, log $WRAPPER_LOG)"

heartbeat "dispatched"
exit 0
