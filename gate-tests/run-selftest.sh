#!/usr/bin/env bash
#
# Gate self-test: prove every quality gate can actually FAIL.
#
# A gate that has never been seen to go red is indistinguishable from a no-op.
# This script feeds each gate a known-bad fixture and asserts it returns
# non-zero (inverting the exit code). If any gate fails to fire, this script
# exits non-zero — that is what gate-selftest.yml asserts on every push.
#
# Run locally:  bash gate-tests/run-selftest.sh
# Requires: dotnet SDK, python3, and dotnet-stryker on PATH.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GT="$ROOT/gate-tests"
ACT="$ROOT/.github/actions/dotnet-quality"
export PATH="$PATH:$HOME/.dotnet/tools"

fail=0
note() { printf '\n=== %s ===\n' "$1"; }

# A build fixture must FAIL, and fail specifically on its target rule (so it is
# not passing for some unrelated reason and silently leaving the gate dead).
assert_build_fires() {
  local proj="$1" rule="$2"
  note "build fixture must fail on $rule"
  local out code=0
  out=$(dotnet build "$GT/$proj" -c Release --nologo -v q 2>&1) || code=$?
  if (( code == 0 )); then
    printf '::error::%s did NOT fire — build succeeded; the gate is dead\n' "$rule"
    fail=1; return
  fi
  if ! grep -q "$rule" <<<"$out"; then
    printf '::error::%s fixture failed, but not on %s (another error masked it)\n' "$proj" "$rule"
    grep -E 'error' <<<"$out" | head -5
    fail=1; return
  fi
  printf 'OK: %s fired (build exit %d)\n' "$rule" "$code"
}

# A command must exit with exactly the expected non-zero (or zero) code.
assert_exit() {
  local expected="$1" label="$2"; shift 2
  note "$label (expect exit $expected)"
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  if (( code != expected )); then
    printf '::error::%s: expected exit %d, got %d\n' "$label" "$expected" "$code"
    fail=1; return
  fi
  printf 'OK: %s exited %d as expected\n' "$label" "$code"
}

# A command must exit non-zero (any code) — used where the exact code varies.
assert_nonzero() {
  local label="$1"; shift
  note "$label (expect non-zero)"
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  if (( code == 0 )); then
    printf '::error::%s: expected non-zero, got 0; the gate is dead\n' "$label"
    fail=1; return
  fi
  printf 'OK: %s exited %d as expected\n' "$label" "$code"
}

# --- 1-3. Analyzer build gates (CA1502 / CA1506 / IDE0005) ------------------
assert_build_fires "build-failures/Complexity/Complexity.csproj" "CA1502"
assert_build_fires "build-failures/Coupling/Coupling.csproj"     "CA1506"
assert_build_fires "build-failures/UnusedUsing/UnusedUsing.csproj" "IDE0005"

# --- 4. Method-size metrics script -----------------------------------------
assert_exit 1 "method-size over-limit (41 > 40)" \
  python3 "$ACT/check-method-size.py" --max 40 "$GT/metrics-script/over-limit.xml"
assert_exit 1 "method-size zero-methods guard (garbage XML)" \
  python3 "$ACT/check-method-size.py" --max 40 "$GT/metrics-script/garbage.xml"

# --- 5. Diff-scope guard ----------------------------------------------------
scope_over()  { "$ACT/check-diff-scope.sh" --max 800 < "$GT/scope-guard/numstat-over.txt"; }
scope_under() { "$ACT/check-diff-scope.sh" --max 800 < "$GT/scope-guard/numstat-under.txt"; }
assert_exit 1 "diff-scope guard trips at 901 added C# lines" scope_over
assert_exit 0 "diff-scope guard passes at 800 added C# lines" scope_under

# --- 6. Vulnerable-package scan --------------------------------------------
assert_exit 1 "vulnerable-package scan (Newtonsoft.Json 12.0.1)" \
  "$ACT/check-vulnerable.sh" "$GT/vulnerable-package/Vuln.csproj"

# --- 7. Mutation testing (Stryker break threshold) -------------------------
run_stryker() { ( cd "$GT/mutation" && dotnet-stryker ); }
assert_nonzero "mutation gate breaks below score threshold" run_stryker

# --- 8. actionlint (workflow YAML) -----------------------------------------
# The bad fixture lives OUTSIDE .github/workflows/ (GitHub would execute a valid
# workflow there), so actionlint is pointed at it explicitly. Prefer a local
# actionlint binary; fall back to the pinned Docker image.
actionlint_fixture() {
  local rel="gate-tests/actionlint/bad-workflow.yml"
  if command -v actionlint >/dev/null 2>&1; then
    ( cd "$ROOT" && actionlint -no-color "$rel" )
  else
    docker run --rm -v "$ROOT:/repo" -w /repo \
      rhysd/actionlint:1.7.7 -no-color "$rel"
  fi
}
assert_nonzero "actionlint rejects the bad workflow fixture" actionlint_fixture

# --- Verdict ----------------------------------------------------------------
note "VERDICT"
if (( fail != 0 )); then
  printf '::error::gate self-test FAILED — at least one gate did not fire\n'
  exit 1
fi
printf 'gate self-test PASSED — every gate fired on its known-bad fixture\n'
