#!/usr/bin/env bash
#
# Diff-scope guard: fail when a change adds more C# lines than allowed.
#
# Reads `git diff --numstat` on stdin and sums the *added* lines for `*.cs`
# files only (non-C# churn — lock files, generated code, docs — is ignored so
# the guard targets hand-written source growth). Exits non-zero when the total
# strictly exceeds the limit.
#
# The line-counting logic lives here, separate from any `git` invocation, so it
# can be unit-tested by piping synthetic numstat fixtures in (see
# gate-tests/scope-guard/). Real callers do:
#
#   git diff --numstat "$BASE...$HEAD" | check-diff-scope.sh --max 800
#
# Exit codes: 0 within limit · 1 over limit · 2 usage error.
set -euo pipefail
IFS=$'\n\t'

max=800
case "${1:-}" in
  --max)
    [[ -n "${2:-}" ]] || { printf '::error::--max requires a value\n' >&2; exit 2; }
    max="$2"
    ;;
  "") ;;
  *) printf '::error::usage: check-diff-scope.sh [--max N] < numstat\n' >&2; exit 2 ;;
esac

if ! [[ "$max" =~ ^[0-9]+$ ]]; then
  printf '::error::--max must be a non-negative integer, got %q\n' "$max" >&2
  exit 2
fi

total=0
while IFS=$'\t' read -r added _deleted path; do
  [[ -n "${path:-}" ]] || continue
  [[ "$added" == "-" ]] && continue   # binary file: numstat shows '-'
  [[ "$path" == *.cs ]] || continue
  total=$(( total + added ))
done

if (( total > max )); then
  printf '::error::diff-scope guard: %d added C# line(s) exceed the limit of %d\n' "$total" "$max"
  exit 1
fi

printf 'diff-scope guard passed: %d added C# line(s) within limit of %d\n' "$total" "$max"
