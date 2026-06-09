#!/bin/bash
#
# SuperDev — run-brief wrapper · v2 · hardened
# (derived from /opt/superxavi/scripts/run-brief.sh v4, 2026-05-26)
#
# Changes vs v1:
#   1. EXIT/INT/TERM trap: if the wrapper dies before reaching SCRIPT_COMPLETED
#      (signal, OOM, syntax error inside a sourced env file, unexpected `set -u`
#      abort, ...) the brief row is PATCHed to status=blocked with an
#      actionable last_dispatch_error indicating the last stage we reached.
#      Without this, a wrapper crash leaves the row stuck in `running` forever.
#   2. Hard inner timeout (BRIEF_TIMEOUT, default 5400s) around the `claude`
#      invocation, with SIGKILL escalation 30s after SIGTERM and a recursive
#      descendant kill after timeout fires so node/python children don't
#      survive as orphans pinning CPU.
#   3. pr_url is written to the BD AT CREATION TIME — not at end-of-script.
#      Fixes Bug 3: when auto-merge later crashes / hangs, GitHub already had
#      the PR but the BD never recorded it.
#   4. merge_sha and merge_completed_at are written after auto-merge returns,
#      independently of n8n. Belt-and-suspenders against the n8n webhook
#      failing silently (root cause of Bug 3).
#   5. Re-exports GH_TOKEN / SUPABASE_URL / SUPABASE_SERVICE_KEY etc. after
#      sourcing .gh.env / .supabase.env — those env files assign without
#      `export`, so subprocesses (gh, curl piped through Authorization headers)
#      would otherwise see them unset.
#   6. Guard anti tabla rasa (Fix 2, 9-jun-2026): BEFORE git reset --hard and
#      git clean, checks for uncommitted changes or local-only commits. If any
#      are found the brief is marked blocked (exit 6) without touching the tree.
#      Prevents the enlac-notarial data-loss incident from recurring.
#   7. Resultado honesto cuando no hay commits (Fix 1, 9-jun-2026): if Claude
#      exits 0 but produced neither pushed commits nor a PR, the final DB status
#      is partial (not ok). The dispatcher's status=ok PATCH is neutralised
#      because it filters on status=eq.running, which is no longer true once we
#      write partial.
#
# Args:
#   $1 = brief_id
#   $2 = repo (already normalized by dispatcher v2)
# Stdin: brief markdown.
#
# Exit codes (CONTRACT — dispatcher uses these to classify permanent vs
# transient failures):
#   0  OK
#   1  args missing                                    [permanent]
#   2  repo missing                                    [permanent]
#   3  brief empty                                     [permanent]
#   4  git reset/clean failed                          [transient]
#   6  guard_tabla_rasa: local unpushed work           [permanent]
#   124, 137 brief inner-timeout (5400s)               [transient]
#

set -uo pipefail

# ─── Argument parsing must happen before traps need BRIEF_ID ──────────
BRIEF_ID="${1:-}"
REPO="${2:-}"
if [ -z "$BRIEF_ID" ] || [ -z "$REPO" ]; then
  echo "ERROR: faltan args. Uso: run-brief.sh <brief_id> <repo>" >&2
  exit 1
fi

# ─── Crash-handling trap ──────────────────────────────────────────────
# If we reach the end of the script we set SCRIPT_COMPLETED=1; the trap
# becomes a no-op. If we crash earlier, the trap PATCHes status=blocked
# so the row doesn't get stranded in `running`.
SCRIPT_COMPLETED=0
LAST_STAGE="boot"

crash_handler() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$SCRIPT_COMPLETED" -ne 1 ] && [ -n "${SUPABASE_URL:-}" ] \
     && [ -n "${SUPABASE_SERVICE_KEY:-}" ]; then
    local reason="run-brief crash at stage=${LAST_STAGE} rc=${rc}"
    local payload
    payload=$(jq -nc \
      --arg s "blocked" \
      --arg err "$reason" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
      '{status:$s, last_dispatch_error:$err, blocked_at:$ts}' 2>/dev/null \
      || printf '{"status":"blocked","last_dispatch_error":"%s"}' "$reason")
    curl -s --max-time 10 \
      -X PATCH "${SUPABASE_URL}/rest/v1/superdev_briefs?brief_id=eq.${BRIEF_ID}" \
      -H "apikey: ${SUPABASE_SERVICE_KEY}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d "$payload" >/dev/null 2>&1 || true
    echo "$(date -Iseconds) RUNBRIEF_CRASH brief=$BRIEF_ID $reason" >&2
  fi
  # flock auto-releases on FD close; nothing to do here.
  exit "$rc"
}
trap crash_handler EXIT INT TERM

# ─── Cross-wrapper mutex (kept from v1) ───────────────────────────────
LAST_STAGE="acquire_lock"
exec 201>/var/lock/superxavi-runbrief.lock
flock -w 1800 201 || {
  echo "$(date -Iseconds) FLOCK_TIMEOUT_30min, aborting brief=$BRIEF_ID" >&2
  exit 1
}
echo "$(date -Iseconds) acquired_runbrief_lock for brief=$BRIEF_ID" >&2

# ─── Validate repo / brief ────────────────────────────────────────────
LAST_STAGE="validate_inputs"
REPO_DIR="/opt/superxavi/repos/$REPO"
BRIEF_PATH="/opt/superxavi/prompts/$BRIEF_ID.md"
LOG_PATH="/opt/superxavi/logs/$BRIEF_ID.log"

if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: repo $REPO_DIR no existe" >&2
  exit 2
fi

mkdir -p /opt/superxavi/prompts /opt/superxavi/logs
cat > "$BRIEF_PATH"

if [ ! -s "$BRIEF_PATH" ]; then
  echo "ERROR: brief vacío" >&2
  exit 3
fi

# ─── Load and re-export env ──────────────────────────────────────────
# Env files assign WITHOUT `export` (.gh.env, .supabase.env, .superdev.env).
# We source first, then explicitly export so subprocesses (gh, curl, claude)
# inherit the secrets. Quiet defaults via `:-` so `set -u` doesn't bite later.
LAST_STAGE="load_env"
# shellcheck source=/dev/null
[ -f /home/xavi/.claude_env ]  && source /home/xavi/.claude_env
# shellcheck source=/dev/null
[ -f /home/xavi/.superdev.env ] && source /home/xavi/.superdev.env
# shellcheck source=/dev/null
[ -f /home/xavi/.gh.env ]      && source /home/xavi/.gh.env
# shellcheck source=/dev/null
[ -f /home/xavi/.supabase.env ] && source /home/xavi/.supabase.env

export GH_TOKEN="${GH_TOKEN:-}" \
       SUPABASE_URL="${SUPABASE_URL:-}" \
       SUPABASE_SERVICE_KEY="${SUPABASE_SERVICE_KEY:-}" \
       SUPERDEV_WEBHOOK_TOKEN="${SUPERDEV_WEBHOOK_TOKEN:-}" \
       RESEND_API_KEY="${RESEND_API_KEY:-}" \
       XAVI_EMAIL="${XAVI_EMAIL:-}" \
       ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
       AUTO_MERGE_ENABLED="${AUTO_MERGE_ENABLED:-true}"

# ─── Git identity (Vercel-compatible) ─────────────────────────────────
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Xavi (via SuperDev)}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-268199176+solidrocket1984-ops@users.noreply.github.com}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

MODEL="${CLAUDE_MODEL:-sonnet}"
BRIEF_TIMEOUT="${BRIEF_TIMEOUT:-5400}"

cd "$REPO_DIR"

# ─── Helpers ─────────────────────────────────────────────────────────

# BD PATCH helper. Args: <json_payload>
bd_patch() {
  [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_KEY:-}" ] || return 0
  curl -s --max-time 10 \
    -X PATCH "${SUPABASE_URL}/rest/v1/superdev_briefs?brief_id=eq.${BRIEF_ID}" \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "$1" >/dev/null 2>&1 || true
}

# Recursive descendant kill — used after BRIEF_TIMEOUT trips so node/python
# subprocesses of claude don't survive as orphans pinning CPU. We deliberately
# walk children-of-children (pkill -P only kills direct children).
kill_tree_descendants() {
  local pid="$1" children
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  local c
  for c in $children; do kill_tree_descendants "$c"; done
  for c in $children; do kill -KILL "$c" 2>/dev/null || true; done
}

# ─── Tabla rasa — fetch + checkout ───────────────────────────────────
LAST_STAGE="git_reset"
{
  echo "=========================================="
  echo "BRIEF: $BRIEF_ID"
  echo "REPO: $REPO"
  echo "MODEL: $MODEL"
  echo "BRIEF_TIMEOUT: ${BRIEF_TIMEOUT}s"
  echo "AUTHOR: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
  echo "START: $(date -Iseconds)"
  echo "=========================================="
  echo ""
  echo "--- Preparando repo (fetch + checkout) ---"
} | tee "$LOG_PATH"

{
  git fetch origin --prune
  git checkout main
} 2>&1 | tee -a "$LOG_PATH"
FETCH_EXIT=${PIPESTATUS[0]}

# ─── Guard anti tabla rasa ────────────────────────────────────────────
# Prevents data loss: abort if the local repo has uncommitted changes or
# commits not yet pushed to origin/main. Fixes the enlac-notarial incident
# of 9-jun-2026 where a reset wiped in-progress work.
LAST_STAGE="guard_tabla_rasa"
if [ "${FETCH_EXIT:-0}" -eq 0 ]; then
  _DIRTY=$(git status --porcelain 2>/dev/null || true)
  _UNPUSHED=$(git rev-list origin/main..main 2>/dev/null || true)
  if [ -n "$_DIRTY" ] || [ -n "$_UNPUSHED" ]; then
    _UNPUSHED_LOG=$(git log --oneline origin/main..main 2>/dev/null | head -10 || true)
    {
      echo "BLOCKED: repo tiene trabajo local no pusheado. Cancelando tabla rasa para prevenir pérdida de datos."
      [ -n "$_DIRTY" ] && printf "Archivos con cambios locales:\n%s\n" "$_DIRTY"
      [ -n "$_UNPUSHED_LOG" ] && printf "Commits locales no pusheados:\n%s\n" "$_UNPUSHED_LOG"
    } | tee -a "$LOG_PATH"
    _DIRTY_SHORT=$(printf '%s' "$_DIRTY" | head -5 | tr '\n' ';')
    _BLOCK_MSG="guard_tabla_rasa: repo local tiene trabajo no pusheado. Archivos=[${_DIRTY_SHORT}] Commits=[${_UNPUSHED_LOG}]"
    bd_patch "$(jq -nc \
      --arg s   "blocked" \
      --arg err "$_BLOCK_MSG" \
      --arg ts  "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
      '{status:$s, last_dispatch_error:$err, blocked_at:$ts}')"
    SCRIPT_COMPLETED=1
    exit 6
  fi
fi

# ─── Tabla rasa — reset + clean ───────────────────────────────────────
{
  echo "--- Aplicando tabla rasa (reset + clean) ---"
  git reset --hard origin/main
  git clean -fdx -e node_modules -e .next
  git config user.email "$GIT_AUTHOR_EMAIL"
  git config user.name  "$GIT_AUTHOR_NAME"
  git status --short
} 2>&1 | tee -a "$LOG_PATH"
RESET_EXIT=${PIPESTATUS[0]}

if [ "${FETCH_EXIT:-0}" -ne 0 ] || [ "$RESET_EXIT" -ne 0 ]; then
  echo "ERROR: git fetch/reset falló (fetch_exit=${FETCH_EXIT:-?} reset_exit=$RESET_EXIT)" | tee -a "$LOG_PATH" >&2
  EXIT_CODE=4
  DURATION=0
else
  # ─── Claude run (with hard inner timeout) ───────────────────────────
  LAST_STAGE="claude_run"
  {
    echo ""
    echo "--- Ejecutando Claude Code (model=$MODEL, timeout=${BRIEF_TIMEOUT}s) ---"
  } | tee -a "$LOG_PATH"

  START_TS=$(date +%s)

  # `timeout --foreground` ensures signals propagate when run from a script
  # without a controlling tty. --kill-after gives claude 30s to flush state
  # before SIGKILL. Tree cleanup below catches any node/python descendants
  # that survive the SIGTERM (rare but observed).
  timeout --foreground --kill-after=30s "${BRIEF_TIMEOUT}s" \
    claude \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --add-dir "$REPO_DIR" \
      -p "$(cat "$BRIEF_PATH")" 2>&1 | tee -a "$LOG_PATH"

  EXIT_CODE=${PIPESTATUS[0]}
  END_TS=$(date +%s)
  DURATION=$((END_TS - START_TS))

  if [ "$EXIT_CODE" -eq 124 ] || [ "$EXIT_CODE" -eq 137 ]; then
    echo "WARN: brief hit BRIEF_TIMEOUT (${BRIEF_TIMEOUT}s); reaping descendants" \
      | tee -a "$LOG_PATH"
    kill_tree_descendants $$
  fi
fi

# ─── Detectar branch + commits ahead ──────────────────────────────────
LAST_STAGE="discover_branch"
RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
COMMITS_AHEAD=$(git rev-list --count HEAD ^origin/main 2>/dev/null || echo "0")
REPO_SLUG=$(git remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]||; s|\.git$||' | head -1)

# ─── Create PR ───────────────────────────────────────────────────────
LAST_STAGE="pr_create"
PR_URL=""
PR_NUMBER=""
if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1 \
   && [ "$COMMITS_AHEAD" -gt 0 ] && [ "$RESULT_BRANCH" != "main" ] \
   && [ "$EXIT_CODE" -eq 0 ]; then
  {
    echo ""
    echo "--- Push + crear PR vía gh ---"
  } | tee -a "$LOG_PATH"

  git push origin "$RESULT_BRANCH" 2>&1 | tee -a "$LOG_PATH" || true

  PR_TITLE="$BRIEF_ID"
  # printf with %s placeholders — avoids the heredoc-with-backticks trap
  # documented in the 28-may-2026 lessons file (an unquoted heredoc would
  # evaluate the backtick spans for `superdev-reports/...` as commands).
  PR_BODY=$(printf 'Brief: %s\nRepo: %s\nModel: %s\nDuration: %ss\nCommits: %s\n\nGenerated autonomously by SuperDev. Review the changes before merging.\n\nReporte completo: `superdev-reports/*-%s.md`\nLog: `%s`\n' \
    "$BRIEF_ID" "$REPO" "$MODEL" "$DURATION" "$COMMITS_AHEAD" "$BRIEF_ID" "$LOG_PATH")

  PR_URL=$(gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base main \
    --head "$RESULT_BRANCH" 2>&1 \
    | tee -a "$LOG_PATH" \
    | grep -oP 'https://github.com/\S+' | head -1)

  if [ -n "$PR_URL" ]; then
    PR_NUMBER=$(echo "$PR_URL" | grep -oP '/pull/\K\d+')
  fi
fi

# ─── Fallback PR discovery (Claude-via-worktree scenario) ────────────
# Claude Code uses git worktrees internally; main repo HEAD stays on main
# with COMMITS_AHEAD=0 even when Claude opened a PR. Query GitHub by title.
LAST_STAGE="pr_discover_fallback"
if [ -z "$PR_URL" ] && [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1 \
   && [ "$EXIT_CODE" -eq 0 ] && [ -n "$REPO_SLUG" ]; then
  {
    echo ""
    echo "--- Buscando PR creado por Claude via worktree (COMMITS_AHEAD=$COMMITS_AHEAD) ---"
  } | tee -a "$LOG_PATH"

  FOUND=$(gh pr list --repo "$REPO_SLUG" --state all \
    --json number,url,headRefName,title --limit 50 \
    --jq ".[] | select(.title == \"$BRIEF_ID\")" \
    2>/dev/null | head -1)

  if [ -n "$FOUND" ]; then
    PR_URL=$(echo "$FOUND" | jq -r '.url // ""')
    PR_NUMBER=$(echo "$FOUND" | jq -r '.number // ""')
    RESULT_BRANCH=$(echo "$FOUND" | jq -r '.headRefName // "unknown"')
    COMMITS_AHEAD=$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
      --json commits -q '.commits | length' 2>/dev/null || echo "1")
    echo "Discovered PR via worktree: $PR_URL (branch=$RESULT_BRANCH commits=$COMMITS_AHEAD)" \
      | tee -a "$LOG_PATH"
  else
    echo "No PR found matching title='$BRIEF_ID' in $REPO_SLUG" | tee -a "$LOG_PATH"
  fi
fi

if [ -n "$PR_URL" ]; then
  [ -z "$PR_NUMBER" ] && PR_NUMBER=$(printf '%s' "$PR_URL" | grep -oP '/pull/\K[0-9]+')
  [ -z "$REPO_SLUG" ] && REPO_SLUG=$(printf '%s' "$PR_URL" | grep -oP 'github\.com/\K[^/]+/[^/]+')
fi

# ─── Bug 3 fix: persist pr_url + branch + commits to BD IMMEDIATELY ──
# v1 only did this at end-of-script. If auto-merge crashed or hung, the BD
# was blind to the PR's existence. We write now, then again at the end as
# belt-and-suspenders.
if [ -n "$PR_URL" ]; then
  LAST_STAGE="bd_pr_url_write"
  echo "--- BD sync: pr_url at creation ---" | tee -a "$LOG_PATH"
  EARLY_BD_BODY=$(jq -nc \
    --arg branch "$RESULT_BRANCH" \
    --argjson commits "$COMMITS_AHEAD" \
    --arg pr_url "$PR_URL" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    '{branch:$branch, commits:$commits, pr_url:$pr_url, pr_created_at:$ts}')
  bd_patch "$EARLY_BD_BODY"
fi

# ─── Auto-merge loop ──────────────────────────────────────────────────
LAST_STAGE="auto_merge"
AUTO_MERGE_EXIT=""
if [ -n "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ] \
   && [ "${AUTO_MERGE_ENABLED:-true}" = "true" ]; then
  {
    echo ""
    echo "--- Auto-merge: starting poll for PR #$PR_NUMBER ---"
  } | tee -a "$LOG_PATH"

  AUTO_MERGE_MAX_WAIT="${AUTO_MERGE_MAX_WAIT:-600}"
  AUTO_MERGE_SCRIPT="$(dirname "$0")/auto-merge-pr.sh"
  [ -x "$AUTO_MERGE_SCRIPT" ] || AUTO_MERGE_SCRIPT="/opt/superxavi/scripts/auto-merge-pr.sh"

  if [ -x "$AUTO_MERGE_SCRIPT" ]; then
    bash "$AUTO_MERGE_SCRIPT" \
      "$PR_NUMBER" "$REPO_SLUG" "$BRIEF_ID" "$AUTO_MERGE_MAX_WAIT" \
      2>&1 | tee -a "$LOG_PATH"
    AUTO_MERGE_EXIT="${PIPESTATUS[0]}"
    echo "--- Auto-merge exit code: $AUTO_MERGE_EXIT ---" | tee -a "$LOG_PATH"

    # Bug 3 belt-and-suspenders: re-read merge state from GitHub and persist
    # merge_sha + merge_completed_at directly. auto-merge-pr.sh already does
    # this on success, but a crash between merge and PATCH would lose it.
    if [ "$AUTO_MERGE_EXIT" = "0" ] && [ -n "${GH_TOKEN:-}" ]; then
      LAST_STAGE="bd_merge_sha_write"
      MERGE_INFO=$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
        --json mergeCommit,mergedAt,state 2>/dev/null || echo "{}")
      MERGE_SHA=$(echo "$MERGE_INFO" | jq -r '.mergeCommit.oid // ""')
      MERGED_AT=$(echo "$MERGE_INFO" | jq -r '.mergedAt // ""')
      if [ -n "$MERGE_SHA" ]; then
        MERGE_BODY=$(jq -nc \
          --arg sha "$MERGE_SHA" \
          --arg at "${MERGED_AT:-$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)}" \
          '{merge_sha:$sha, merge_completed_at:$at}')
        bd_patch "$MERGE_BODY"
        echo "--- BD sync: merge_sha=$MERGE_SHA merged_at=$MERGED_AT ---" \
          | tee -a "$LOG_PATH"
      fi
    fi
  else
    echo "WARN: auto-merge-pr.sh not found at $AUTO_MERGE_SCRIPT, skipping" | tee -a "$LOG_PATH"
  fi
fi

# ─── Final log block ─────────────────────────────────────────────────
LAST_STAGE="finalize"
{
  echo ""
  echo "--- Finalizado ---"
  echo "EXIT_CODE: $EXIT_CODE"
  echo "DURATION_SECONDS: $DURATION"
  echo "RESULT_BRANCH: $RESULT_BRANCH"
  echo "COMMITS_AHEAD: $COMMITS_AHEAD"
  echo "PR_URL: ${PR_URL:-not_created}"
  echo "AUTO_MERGE_EXIT: ${AUTO_MERGE_EXIT:-skipped}"
  echo "END: $(date -Iseconds)"
} | tee -a "$LOG_PATH"

# ─── n8n notification ────────────────────────────────────────────────
LAST_STAGE="notify_n8n"
NOTIFY_STATUS="ok"
[ "$EXIT_CODE" -ne 0 ] && NOTIFY_STATUS="blocked"
# Fix 1: si Claude terminó con exit=0 pero sin commits pusheados ni PR, el
# resultado es partial. El dispatcher intentará status=ok WHERE status=eq.running,
# pero bd_partial_sync (abajo) ya habrá escrito partial, neutralizando ese PATCH.
if [ "$NOTIFY_STATUS" = "ok" ] && [ "${COMMITS_AHEAD:-0}" -eq 0 ] && [ -z "${PR_URL:-}" ]; then
  NOTIFY_STATUS="partial"
fi

if [ -n "${SUPERDEV_WEBHOOK_TOKEN:-}" ]; then
  echo "--- Notificando webhook superdev-done ---" | tee -a "$LOG_PATH"
  NOTIFY_PAYLOAD=$(jq -n \
    --arg brief_id "$BRIEF_ID" \
    --arg status "$NOTIFY_STATUS" \
    --arg branch "$RESULT_BRANCH" \
    --argjson commits "$COMMITS_AHEAD" \
    --argjson duration "$DURATION" \
    --arg report_path "superdev-reports/*-$BRIEF_ID.md" \
    --arg log_path "$LOG_PATH" \
    --arg pr_url "${PR_URL:-}" \
    --arg model "$MODEL" \
    --arg repo "$REPO" \
    --argjson exit_code "$EXIT_CODE" \
    --arg auto_merge_exit "${AUTO_MERGE_EXIT:-skipped}" \
    '{brief_id:$brief_id, status:$status, branch:$branch, repo:$repo, commits:$commits, duration_seconds:$duration, report_path:$report_path, log_path:$log_path, pr_url:$pr_url, model:$model, exit_code:$exit_code, auto_merge_exit:$auto_merge_exit}' 2>/dev/null \
    || printf '{"brief_id":"%s","status":"%s","branch":"%s","commits":%s,"duration_seconds":%d,"pr_url":"%s","model":"%s","exit_code":%d,"auto_merge_exit":"%s"}' \
      "$BRIEF_ID" "$NOTIFY_STATUS" "$RESULT_BRANCH" "$COMMITS_AHEAD" "$DURATION" "${PR_URL:-}" "$MODEL" "$EXIT_CODE" "${AUTO_MERGE_EXIT:-skipped}")

  curl -s -X POST "https://n8n.maind.live/webhook/superdev-done" \
    -H "Content-Type: application/json" \
    -H "x-superdev-token: $SUPERDEV_WEBHOOK_TOKEN" \
    -d "$NOTIFY_PAYLOAD" 2>&1 | tee -a "$LOG_PATH"
  echo "" | tee -a "$LOG_PATH"
else
  echo "WARN: SUPERDEV_WEBHOOK_TOKEN no disponible, no se notifica" | tee -a "$LOG_PATH"
fi

# ─── End-of-script BD sync (last-write-wins on pr_url / branch / commits) ─
LAST_STAGE="bd_final_sync"
if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_KEY:-}" ]; then
  echo "--- Sincronizando BD final: pr_url + commits + branch ---" | tee -a "$LOG_PATH"
  BD_SYNC_PAYLOAD=$(jq -nc \
    --arg branch "$RESULT_BRANCH" \
    --argjson commits "$COMMITS_AHEAD" \
    --arg pr_url "${PR_URL:-}" \
    '{branch:$branch, commits:$commits, pr_url:(if $pr_url == "" then null else $pr_url end)}')
  bd_patch "$BD_SYNC_PAYLOAD"
  echo "" | tee -a "$LOG_PATH"
fi

# ─── Partial result BD sync ───────────────────────────────────────────
# Fix 1: escribe status=partial ANTES de exit para neutralizar el
# status=ok WHERE status=eq.running que hará el dispatcher (no encontrará
# la fila porque el status ya no será running).
LAST_STAGE="bd_partial_sync"
if [ "$NOTIFY_STATUS" = "partial" ]; then
  _PARTIAL_REPORT="Claude ejecutó (exit=0) sin producir commits pusheados ni PR. branch=$RESULT_BRANCH commits_ahead=$COMMITS_AHEAD. Puede haber trabajo local no commiteado o el brief no requería cambios de código."
  bd_patch "$(jq -nc \
    --arg s   "partial" \
    --arg rpt "$_PARTIAL_REPORT" \
    --arg ts  "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    '{status:$s, last_dispatch_error:$rpt, completed_at:$ts}')"
  echo "--- BD sync: status=partial (sin commits ni PR) ---" | tee -a "$LOG_PATH"
fi

SCRIPT_COMPLETED=1
exit "$EXIT_CODE"
