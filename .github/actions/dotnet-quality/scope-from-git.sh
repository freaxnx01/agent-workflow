#!/usr/bin/env bash
#
# Run the diff-scope guard for the current PR/branch.
#
# Resolves a base ref (explicit --base, else origin/$GITHUB_BASE_REF on a PR),
# computes the numstat against it, and pipes it to check-diff-scope.sh. When no
# base ref is available (e.g. a push that is not a PR) the guard is skipped — it
# only makes sense relative to a base.
#
# Usage: scope-from-git.sh [--max N] [--base REF]
set -euo pipefail
IFS=$'\n\t'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
max=800
base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)  [[ -n "${2:-}" ]] || { printf '::error::--max needs a value\n' >&2; exit 2; }; max="$2"; shift 2 ;;
    --base) base="${2:-}"; shift 2 ;;
    *) printf '::error::unknown argument %q\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$base" && -n "${GITHUB_BASE_REF:-}" ]]; then
  git fetch --quiet origin "$GITHUB_BASE_REF" || true
  base="origin/$GITHUB_BASE_REF"
fi

if [[ -z "$base" ]]; then
  printf 'diff-scope guard: no base ref (not a PR); skipping\n'
  exit 0
fi

git diff --numstat "$base"...HEAD | "$here/check-diff-scope.sh" --max "$max"
