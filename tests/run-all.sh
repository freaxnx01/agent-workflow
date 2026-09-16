#!/usr/bin/env bash
#
# run-all.sh — the definition of the Layer-1 test set.
#
# Discovers every `run-*-tests.sh` next to this file and runs it. Both
# `just test` and the CI `test` job call this, so the two cannot list different
# runners — which is exactly what they did before (#354: the recipe named 7 of 9,
# CI ran none, so two runners were run by nothing at all).
#
# Discovery is by `find`, not a hand-kept list and not a `**` glob: a glob needs
# `globstar` to recurse and silently skips otherwise, and a list is the thing
# that drifted. `-maxdepth 1` keeps it to this directory — tests/fixtures/ and
# tests/mocks/ hold inputs and stubs, not runners.
#
# Env:
#   TESTS_DIR  directory to discover runners in. Defaults to this script's own
#              directory. Exists so run-all-discovery-tests.sh can drive this
#              script against a fixture dir — pointing it at the real tests/
#              would re-enter this script through its own test and recurse.
#
# Exit codes:
#   0  every discovered runner passed
#   1  at least one runner failed
#   2  no runners discovered, or TESTS_DIR is not a directory — a broken
#      discovery must not look like success
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${TESTS_DIR:-$HERE}"

if [[ ! -d "$TESTS_DIR" ]]; then
  printf 'error: TESTS_DIR %q is not a directory\n' "$TESTS_DIR" >&2
  exit 2
fi

mapfile -t runners < <(
  find "$TESTS_DIR" -maxdepth 1 -type f -name 'run-*-tests.sh' | sort
)

if (( ${#runners[@]} == 0 )); then
  printf 'error: no run-*-tests.sh found in %q\n' "$TESTS_DIR" >&2
  exit 2
fi

failed=()
for runner in "${runners[@]}"; do
  name="$(basename "$runner")"
  printf '\n=== %s ===\n' "$name"
  # Deliberately tolerant of a non-zero exit: one broken runner must not hide
  # the results of every runner after it, which is what `set -e` would do.
  if bash "$runner"; then
    printf -- '--- %s: OK\n' "$name"
  else
    printf -- '--- %s: FAILED\n' "$name"
    failed+=("$name")
  fi
done

printf '\n===============================\n'
printf 'runners: %d   failed: %d\n' "${#runners[@]}" "${#failed[@]}"
if (( ${#failed[@]} > 0 )); then
  printf 'failed:\n'
  for name in "${failed[@]}"; do printf -- '  - %s\n' "$name"; done
  exit 1
fi
exit 0
