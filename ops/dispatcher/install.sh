#!/usr/bin/env bash
#
# SuperDev dispatcher v2 — installer / rollback
#
# Usage:
#   bash ops/dispatcher/install.sh                            # install
#   bash ops/dispatcher/install.sh --dry-run                  # preview only
#   bash ops/dispatcher/install.sh --rollback STAMP=v2-YYYYMMDD-HHMMSS
#
# The installer:
#   1. Runs bash -n on all three v2 source files; aborts on any failure.
#   2. Runs shellcheck on them if available; warns but continues if not found.
#   3. In normal mode: generates a STAMP, backs up current production files
#      as <target>.bak-STAMP, then installs v2 files with install -m 0755.
#   4. Prints systemctl status + next scheduled run, then the STAMP for rollback.
#
# Production targets (in /opt/superxavi/scripts/):
#   run-brief-v2.sh        → run-brief.sh
#   dispatch-queue-v2.sh   → dispatch-queue.sh
#   auto-merge-pr-v2.sh    → auto-merge-pr.sh
#

set -uo pipefail

SCRIPTS_DIR="/opt/superxavi/scripts"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/ops/dispatcher"

DRY_RUN=0
ROLLBACK=0
ROLLBACK_STAMP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --rollback)
      ROLLBACK=1
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --rollback requires STAMP=v2-YYYYMMDD-HHMMSS" >&2
        exit 2
      fi
      ROLLBACK_STAMP="${2#STAMP=}"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run | --rollback STAMP=...]" >&2
      exit 2
      ;;
  esac
done

SRCS=(
  "${SRC_DIR}/run-brief-v2.sh"
  "${SRC_DIR}/dispatch-queue-v2.sh"
  "${SRC_DIR}/auto-merge-pr-v2.sh"
)
TARGETS=(
  "${SCRIPTS_DIR}/run-brief.sh"
  "${SCRIPTS_DIR}/dispatch-queue.sh"
  "${SCRIPTS_DIR}/auto-merge-pr.sh"
)

# ─── Rollback ──────────────────────────────────────────────────────────────
if [[ "$ROLLBACK" -eq 1 ]]; then
  if [[ -z "$ROLLBACK_STAMP" ]]; then
    echo "ERROR: --rollback requires STAMP=v2-YYYYMMDD-HHMMSS" >&2
    exit 2
  fi
  echo "==> Rollback to stamp: ${ROLLBACK_STAMP}"
  for i in "${!TARGETS[@]}"; do
    bak="${TARGETS[$i]}.bak-${ROLLBACK_STAMP}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    [dry-run] cp -p ${bak} → ${TARGETS[$i]}"
    else
      if [[ ! -f "$bak" ]]; then
        echo "ERROR: backup not found: $bak" >&2
        exit 1
      fi
      cp -p "$bak" "${TARGETS[$i]}"
      echo "    restored: $bak → ${TARGETS[$i]}"
    fi
  done
  echo "==> Rollback complete."
  exit 0
fi

# ─── Syntax checks (always run, even in dry-run) ───────────────────────────
echo "==> Checking syntax (bash -n)..."
for src in "${SRCS[@]}"; do
  if bash -n "$src" 2>&1; then
    echo "    OK  ${src##*/}"
  else
    echo "ERROR: syntax check failed: $src" >&2
    exit 1
  fi
done

if command -v shellcheck &>/dev/null; then
  echo "==> Running shellcheck..."
  SC_FAILED=0
  for src in "${SRCS[@]}"; do
    if shellcheck -x "$src" 2>&1; then
      echo "    OK  ${src##*/}"
    else
      echo "    WARN: shellcheck reported issues in ${src##*/} (non-fatal)"
      SC_FAILED=1
    fi
  done
  [[ "$SC_FAILED" -eq 1 ]] && echo "WARN: shellcheck issues found — review before shipping"
else
  echo "WARN: shellcheck not found, skipping (apt install shellcheck for extra checks)"
fi

# ─── Dry-run ──────────────────────────────────────────────────────────────
STAMP="v2-$(date +%Y%m%d-%H%M%S)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "==> DRY-RUN — no files will be changed."
  echo "    STAMP that would be used: ${STAMP}"
  echo ""
  for i in "${!SRCS[@]}"; do
    echo "    cp -p ${TARGETS[$i]} ${TARGETS[$i]}.bak-${STAMP}"
    echo "    install -m 0755 ${SRCS[$i]} ${TARGETS[$i]}"
  done
  echo ""
  echo "    systemctl status superdev-dispatcher.timer"
  echo "    systemctl list-timers superdev-dispatcher.timer"
  echo ""
  echo "Rollback would be: bash ops/dispatcher/install.sh --rollback STAMP=${STAMP}"
  exit 0
fi

# ─── Normal install ────────────────────────────────────────────────────────
echo ""
echo "==> Installing dispatcher v2 (STAMP=${STAMP})"
for i in "${!SRCS[@]}"; do
  bak="${TARGETS[$i]}.bak-${STAMP}"
  echo "    backup : ${TARGETS[$i]} → ${bak}"
  cp -p "${TARGETS[$i]}" "${bak}"
  echo "    install: ${SRCS[$i]} → ${TARGETS[$i]}"
  install -m 0755 "${SRCS[$i]}" "${TARGETS[$i]}"
done

echo ""
echo "==> Installation complete."
echo ""
echo "==> systemctl status superdev-dispatcher.timer:"
systemctl status superdev-dispatcher.timer 2>&1 || true
echo ""
echo "==> Next scheduled execution:"
systemctl list-timers superdev-dispatcher.timer 2>&1 || true
echo ""
echo "STAMP=${STAMP}"
echo "To rollback: bash ops/dispatcher/install.sh --rollback STAMP=${STAMP}"
