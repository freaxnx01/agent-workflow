#!/usr/bin/env bash
#
# run-autopilot-driver-tests.sh — Layer-1 fixture tests for
# scripts/autopilot.sh (no network, gh mocked). Asserts the driver's guards
# (usage, deps, disable flag, run lock), config-driven repo/issue selection,
# and that a dry run writes nothing.
#
# Usage: tests/run-autopilot-driver-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/autopilot"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $expected | actual: $actual"
  fi
}

DRIVER="$ROOT/scripts/autopilot.sh"

export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$TMPDIR_T/gh.log"
export AUTOPILOT_CACHE_DIR="$TMPDIR_T/cache"
export AUTOPILOT_DISABLE_FLAG="$TMPDIR_T/disabled"

# Config: one allowlisted repo.
printf 'max_per_run=2\nrepo=o/r\n' > "$TMPDIR_T/ap.conf"

# gh responses: an eligible repo and three enrichable issues.
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh.map"
export GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh.map"

section "usage and dependencies"

rc=0; "$DRIVER" --nonsense >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag is a usage error" "2" "$rc"

rc=0; "$DRIVER" --config "$TMPDIR_T/nope.conf" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable config exits 4" "4" "$rc"

out="$("$DRIVER" --help)"
case "$out" in
  *--dry-run*) pass "help documents --dry-run" ;;
  *) fail "help documents --dry-run" "help was: $out" ;;
esac

section "the disable flag"

: > "$AUTOPILOT_DISABLE_FLAG"
: > "$GH_MOCK_LOG"
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" 2>&1)" || rc=$?
assert_eq "disabled exits 0" "0" "$rc"
case "$out" in
  *disabled*) pass "disabled is logged" ;;
  *) fail "disabled is logged" "output was: $out" ;;
esac
assert_eq "disabled makes no gh calls at all" "" "$(cat "$GH_MOCK_LOG")"
rm -f "$AUTOPILOT_DISABLE_FLAG"

section "dry run"

: > "$GH_MOCK_LOG"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"

case "$out" in
  *"o/r#41"*) pass "names the oldest candidate" ;;
  *) fail "names the oldest candidate" "output was: $out" ;;
esac
case "$out" in
  *would:*) pass "dry-run lines are marked 'would:'" ;;
  *) fail "dry-run lines are marked 'would:'" "output was: $out" ;;
esac
assert_eq "dry run honours the cap" "2" "$(printf '%s\n' "$out" | grep -c 'would:')"
case "$out" in
  *"o/r#50"*) fail "cap excludes the third candidate" "50 appeared" ;;
  *) pass "cap excludes the third candidate" ;;
esac

if grep -q 'issue edit' "$GH_MOCK_LOG"; then
  fail "dry run writes no labels" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "dry run writes no labels"
fi
if grep -q 'issue comment' "$GH_MOCK_LOG"; then
  fail "dry run posts no comments" "$(grep 'issue comment' "$GH_MOCK_LOG")"
else
  pass "dry run posts no comments"
fi
# The cache root always exists after any run (acquire_run_lock mkdir -p's it
# to place run.lock) — the real assertion is that the per-repo clone dir was
# never created, i.e. sync_autopilot_clone was never called.
clone_dir="$(AUTOPILOT_CACHE_DIR="$AUTOPILOT_CACHE_DIR" bash -c '. "'"$ROOT"'/scripts/lib/autopilot-clone.sh"; autopilot_clone_dir o/r')"
if [[ -d "$clone_dir" ]]; then
  fail "dry run syncs no clones" "$clone_dir was created"
else
  pass "dry run syncs no clones"
fi

section "--max overrides the config"

out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run --max 1)"
assert_eq "--max 1 yields one line" "1" "$(printf '%s\n' "$out" | grep -c 'would:')"

section "an ineligible repo is skipped with its reason"

{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-no-merge.yml"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-noeligible.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-noeligible.map" "$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run)"
case "$out" in
  *"ai-review-ai-merge"*) pass "logs the eligibility reason verbatim" ;;
  *) fail "logs the eligibility reason verbatim" "output was: $out" ;;
esac
case "$out" in
  *would:*) fail "an ineligible repo yields no candidates" "output was: $out" ;;
  *) pass "an ineligible repo yields no candidates" ;;
esac

section "the run lock"

# Hold the lock, then confirm a second run stands down instead of piling on.
lock="$AUTOPILOT_CACHE_DIR/run.lock"
mkdir -p "$AUTOPILOT_CACHE_DIR"
exec 8>"$lock"
flock -n 8
rc=0; out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run 2>&1)" || rc=$?
exec 8>&-
assert_eq "a concurrent run exits 0" "0" "$rc"
case "$out" in
  *"already running"*) pass "a concurrent run says so" ;;
  *) fail "a concurrent run says so" "output was: $out" ;;
esac

section "the log line format"

rm -rf "$AUTOPILOT_CACHE_DIR"
out="$("$DRIVER" --config "$TMPDIR_T/ap.conf" --dry-run | head -1)"
if [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]]; then
  pass "log lines start with an ISO-8601 UTC timestamp"
else
  fail "log lines start with an ISO-8601 UTC timestamp" "line was: $out"
fi

section "the write path"

# A local origin so sync_autopilot_clone works without network.
mkdir -p "$TMPDIR_T/origins/o"
git init --quiet --bare --initial-branch=main "$TMPDIR_T/origins/o/r.git"
git init --quiet --initial-branch=main "$TMPDIR_T/seed"
git -C "$TMPDIR_T/seed" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
git -C "$TMPDIR_T/seed" remote add origin "$TMPDIR_T/origins/o/r.git"
git -C "$TMPDIR_T/seed" push --quiet origin main
export AUTOPILOT_CLONE_URL_BASE="file://$TMPDIR_T/origins"

# ENRICH_CMD stub: records the issues it was asked for, exits $ENRICH_RC.
cat > "$TMPDIR_T/enrich-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$ENRICH_STUB_LOG"
exit "${ENRICH_RC:-0}"
STUB
chmod +x "$TMPDIR_T/enrich-stub.sh"
export ENRICH_CMD="$TMPDIR_T/enrich-stub.sh"
export ENRICH_STUB_LOG="$TMPDIR_T/enrich.log"

# shellcheck disable=SC2120  # every call site here passes no extra args, by design
run_driver() {
  rm -rf "$AUTOPILOT_CACHE_DIR"
  : > "$GH_MOCK_LOG"
  : > "$ENRICH_STUB_LOG"
  "$DRIVER" --config "$TMPDIR_T/ap.conf" --max 1 "$@" 2>&1
}

# --- the happy path: enrich succeeds, no needs-human on the issue ---
printf '{"labels":[{"name":"needs-enrichment"}]}\n' > "$TMPDIR_T/labels-clean.json"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'issue view\t%s\n' "$TMPDIR_T/labels-clean.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-clean.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" run_driver)"
assert_eq "the enrich stub was asked for the oldest issue" "41" "$(cat "$ENRICH_STUB_LOG")"
case "$out" in
  *"o/r#41 enriched"*) pass "a clean enrich logs 'enriched'" ;;
  *) fail "a clean enrich logs 'enriched'" "output was: $out" ;;
esac

edits="$(grep 'issue edit' "$GH_MOCK_LOG" || true)"
assert_eq "exactly one label write" "1" "$(printf '%s\n' "$edits" | grep -c 'issue edit')"
case "$edits" in
  *"--add-label ai-implement,ai-review-ai-merge"*) pass "both labels in one call (#365)" ;;
  *) fail "both labels in one call (#365)" "edits were: $edits" ;;
esac
if grep -q 'enrichment-ongoing' "$GH_MOCK_LOG"; then
  fail "the driver never touches enrichment-ongoing on success" "$(grep enrichment-ongoing "$GH_MOCK_LOG")"
else
  pass "the driver never touches enrichment-ongoing on success"
fi

# --- needs-human: the enrich session labelled it itself ---
printf '{"labels":[{"name":"needs-enrichment"},{"name":"needs-human"}]}\n' > "$TMPDIR_T/labels-human.json"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'issue view\t%s\n' "$TMPDIR_T/labels-human.json"
  printf 'repos/o/r\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-human.map"

out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-human.map" run_driver)"
case "$out" in
  *"o/r#41 needs-human"*) pass "needs-human is logged" ;;
  *) fail "needs-human is logged" "output was: $out" ;;
esac
if grep -q 'ai-implement' "$GH_MOCK_LOG"; then
  fail "needs-human withholds ai-implement" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "needs-human withholds ai-implement"
fi

# --- a failed enrich session ---
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" ENRICH_RC=7 run_driver)"
case "$out" in
  *"failed (enrich exited 7)"*) pass "a failed session is logged with its status" ;;
  *) fail "a failed session is logged with its status" "output was: $out" ;;
esac
edits="$(grep 'issue edit' "$GH_MOCK_LOG" || true)"
case "$edits" in
  *"--add-label needs-human"*) pass "a failed session escalates to needs-human" ;;
  *) fail "a failed session escalates to needs-human" "edits were: $edits" ;;
esac
case "$edits" in
  *"--remove-label enrichment-ongoing"*) pass "a failed session releases the lock" ;;
  *) fail "a failed session releases the lock" "edits were: $edits" ;;
esac
assert_eq "the failure escalation is a single call" "1" "$(printf '%s\n' "$edits" | grep -c 'issue edit')"
if grep -q 'ai-implement' "$GH_MOCK_LOG"; then
  fail "a failed session withholds ai-implement" "$edits"
else
  pass "a failed session withholds ai-implement"
fi

# --- a timeout, which is exit 124 from `timeout` ---
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" ENRICH_RC=124 run_driver)"
case "$out" in
  *"timed out"*) pass "a timeout is logged as a timeout, not a bare exit code" ;;
  *) fail "a timeout is logged as a timeout, not a bare exit code" "output was: $out" ;;
esac

# --- a clone that cannot be synced ---
printf 'max_per_run=1\nrepo=o/missing\n' > "$TMPDIR_T/ap-missing.conf"
{
  printf 'contents/.github/workflows/agent.yml\t%s\n' "$FIX/agent-yml-good.yml"
  printf 'actions/workflows/\t%s\n' "$FIX/runs-one.json"
  printf 'issue list\t%s\n' "$FIX/issues-mixed.json"
  printf 'repos/o/missing\t%s\n' "$FIX/repo-meta.json"
} > "$TMPDIR_T/gh-missing.map"
rm -rf "$AUTOPILOT_CACHE_DIR"; : > "$GH_MOCK_LOG"; : > "$ENRICH_STUB_LOG"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-missing.map" "$DRIVER" --config "$TMPDIR_T/ap-missing.conf" --max 1 2>&1)"
case "$out" in
  *"failed (clone sync)"*) pass "a clone-sync failure is logged" ;;
  *) fail "a clone-sync failure is logged" "output was: $out" ;;
esac
assert_eq "a clone-sync failure runs no enrich" "" "$(cat "$ENRICH_STUB_LOG")"
if grep -q 'issue edit' "$GH_MOCK_LOG"; then
  fail "a clone-sync failure touches no labels" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "a clone-sync failure touches no labels"
fi

section "SIGPIPE re-scoping: partial-but-mutating runs must not report success"

# Deterministic SIGPIPE, no scheduling involved: fd 3 is wired to a pipe whose
# read end belongs to a process-substitution subshell running `:`. We `wait`
# for that subshell by its PID before writing a single byte, so the read end
# is already closed before the driver's first write attempt — every run here
# gets a real, reproducible SIGPIPE on its very first byte of output, not a
# maybe-it-lands-maybe-it-doesn't race against a real reader.
run_with_dead_stdout() {
  local rc
  exec 3> >(:)
  wait "$!" 2>/dev/null || true
  "$@" >&3 2>&1
  rc=$?
  exec 3>&-
  return "$rc"
}

# --- nothing written yet: a dry run never mutates, so its first (and only,
#     --max 1) log write is the one that eats the SIGPIPE. Must exit 0. ---
rc=0
run_with_dead_stdout "$DRIVER" --config "$TMPDIR_T/ap.conf" --max 1 --dry-run || rc=$?
assert_eq "SIGPIPE before any write exits 0" "0" "$rc"

# --- something already written: the clean-enrich run's ONLY stdout line is
#     its final 'enriched' log line, emitted strictly after the dispatch
#     gh issue edit already landed — so this SIGPIPE always lands post-write.
#     Must exit non-zero: a truncated run that already mutated an issue is not
#     a success. ---
rm -rf "$AUTOPILOT_CACHE_DIR"; : > "$GH_MOCK_LOG"; : > "$ENRICH_STUB_LOG"
rc=0
GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-clean.map" \
  run_with_dead_stdout "$DRIVER" --config "$TMPDIR_T/ap.conf" --max 1 || rc=$?
assert_eq "the issue edit before the SIGPIPE really landed" "1" \
  "$(grep -c 'issue edit' "$GH_MOCK_LOG")"
if [[ "$rc" == "0" ]]; then
  fail "SIGPIPE after a write exits non-zero" "rc was 0"
else
  pass "SIGPIPE after a write exits non-zero"
fi

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
