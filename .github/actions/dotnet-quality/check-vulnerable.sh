#!/usr/bin/env bash
#
# Vulnerable-package guard.
#
# `dotnet list package --vulnerable` exits 0 even when it finds vulnerabilities
# (it is informational), so the exit code alone is useless as a gate. We inspect
# its output instead: the phrase "following vulnerable packages" is printed only
# when at least one vulnerable package is present; a clean project prints
# "has no vulnerable packages". (Pattern verified against real CLI output.)
#
# Usage: check-vulnerable.sh <solution-or-project>
# Exit codes: 0 no vulnerabilities · 1 vulnerable package(s) found · 2 usage.
set -euo pipefail
IFS=$'\n\t'

target="${1:-}"
[[ -n "$target" ]] || { printf '::error::usage: check-vulnerable.sh <solution-or-project>\n' >&2; exit 2; }

out=$(dotnet list "$target" package --vulnerable --include-transitive 2>&1)
printf '%s\n' "$out"

if printf '%s\n' "$out" | grep -q "following vulnerable packages"; then
  printf '::error::vulnerable package(s) detected in %s\n' "$target"
  exit 1
fi

printf 'vulnerability scan passed: no vulnerable packages in %s\n' "$target"
