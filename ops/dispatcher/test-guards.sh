#!/bin/bash
#
# test-guards.sh — Validates the guard anti tabla rasa logic and syntax
# of the v2 dispatcher scripts.
#
# Each test creates an isolated temporary git repo so no real state is touched.
# Exit 0 if all tests pass, non-zero otherwise.
#
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# assert_guard_blocked <repo_dir> <description>
# The guard fires when git status --porcelain is non-empty OR
# git rev-list origin/main..main is non-empty.
assert_guard_blocked() {
  local dir="$1" desc="$2"
  (
    cd "$dir" || exit 1
    DIRTY=$(git status --porcelain 2>/dev/null || true)
    UNPUSHED=$(git rev-list origin/main..main 2>/dev/null || true)
    [ -n "$DIRTY" ] || [ -n "$UNPUSHED" ]
  ) && _pass "$desc (correctly BLOCKED)" || _fail "$desc (expected BLOCKED but guard would not fire)"
}

# assert_guard_clean <repo_dir> <description>
assert_guard_clean() {
  local dir="$1" desc="$2"
  (
    cd "$dir" || exit 1
    DIRTY=$(git status --porcelain 2>/dev/null || true)
    UNPUSHED=$(git rev-list origin/main..main 2>/dev/null || true)
    [ -z "$DIRTY" ] && [ -z "$UNPUSHED" ]
  ) && _pass "$desc (correctly PASSES)" || _fail "$desc (expected PASS but guard would fire)"
}

# ─── Build temporary git environment ─────────────────────────────────
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT

ORIGIN="$TMPBASE/origin.git"
git init --bare "$ORIGIN" -b main >/dev/null 2>&1

# Seed origin with an initial commit
SEED="$TMPBASE/seed"
git clone "$ORIGIN" "$SEED" >/dev/null 2>&1
git -C "$SEED" config user.email "test@test.com"
git -C "$SEED" config user.name  "Test"
echo "hello" > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -m "initial" >/dev/null 2>&1
git -C "$SEED" push origin main >/dev/null 2>&1

echo "--- Guard logic tests ---"

# Test 1: repo limpio → debe pasar (guard no debe disparar)
REPO_CLEAN="$TMPBASE/repo-clean"
git clone "$ORIGIN" "$REPO_CLEAN" >/dev/null 2>&1
assert_guard_clean "$REPO_CLEAN" "repo limpio: sin cambios ni commits locales"

# Test 2: working tree sucio → debe bloquear
REPO_DIRTY="$TMPBASE/repo-dirty"
git clone "$ORIGIN" "$REPO_DIRTY" >/dev/null 2>&1
echo "cambio no commiteado" >> "$REPO_DIRTY/README.md"
assert_guard_blocked "$REPO_DIRTY" "working tree sucio: archivo modificado no commiteado"

# Test 3: commits locales no pusheados → debe bloquear
REPO_UNPUSHED="$TMPBASE/repo-unpushed"
git clone "$ORIGIN" "$REPO_UNPUSHED" >/dev/null 2>&1
git -C "$REPO_UNPUSHED" config user.email "test@test.com"
git -C "$REPO_UNPUSHED" config user.name  "Test"
echo "trabajo sin push" >> "$REPO_UNPUSHED/README.md"
git -C "$REPO_UNPUSHED" add README.md
git -C "$REPO_UNPUSHED" commit -m "unpushed work" >/dev/null 2>&1
assert_guard_blocked "$REPO_UNPUSHED" "commits locales no pusheados: commit local sin push"

# Test 4: repo con commits empujados (limpio después de push) → debe pasar
REPO_PUSHED="$TMPBASE/repo-pushed"
git clone "$ORIGIN" "$REPO_PUSHED" >/dev/null 2>&1
git -C "$REPO_PUSHED" config user.email "test@test.com"
git -C "$REPO_PUSHED" config user.name  "Test"
echo "trabajo pusheado" >> "$REPO_PUSHED/README.md"
git -C "$REPO_PUSHED" add README.md
git -C "$REPO_PUSHED" commit -m "pushed work" >/dev/null 2>&1
git -C "$REPO_PUSHED" push origin main >/dev/null 2>&1
assert_guard_clean "$REPO_PUSHED" "repo limpio después de push: commits pusheados no bloquean"

echo ""
echo "--- Syntax check (bash -n) ---"
for script in run-brief-v2.sh dispatch-queue-v2.sh; do
  if bash -n "$SCRIPT_DIR/$script" 2>&1; then
    _pass "bash -n $script"
  else
    _fail "bash -n $script"
  fi
done

echo ""
echo "--- Results: ${PASS} passed, ${FAIL} failed ---"
[ "$FAIL" -eq 0 ]
