#!/usr/bin/env bash
#
# parse-chain.sh — Extract `Blocks:` and `Blocked by:` markers from an
# issue body per ADR-003 conventions.
#
# Reads the body from stdin (or $ISSUE_BODY env var if no stdin). Emits
# two lines on stdout:
#   blocks=<space-separated #N list, or empty>
#   blocked-by=<space-separated #N list, or empty>
#
# Conventions (case-sensitive, native GitHub):
#   Blocks: #42, #43
#   Blocked by: #100
#
# Lines may appear in any order, multiple times (union'd into a set),
# anywhere in the body. Cross-repo refs `org/repo#N` are parsed-and-
# discarded (out of scope per ADR-003 §6).
#
# Required:
#   either stdin or ISSUE_BODY env var (one of the two).
#
# Optional:
#   GITHUB_OUTPUT  When set, lines are also appended to that file.
#
# Exit codes:
#   0  success — output reflects what was found (sets may be empty)
#   2  no body provided
set -euo pipefail
IFS=$'\n\t'

body="${ISSUE_BODY:-}"
if [[ -z "$body" ]]; then
  if [[ ! -t 0 ]]; then
    body="$(cat)"
  fi
fi
if [[ -z "$body" ]]; then
  printf 'error: provide issue body via stdin or ISSUE_BODY\n' >&2
  exit 2
fi

# Extract markers. We grep for the literal labels at line-start,
# capture everything after the colon, then re-extract the numeric
# references with a tighter regex that ignores cross-repo notation.
extract_refs() {
  local label="$1"
  printf '%s\n' "$body" \
    | grep -E "^${label}:[[:space:]]" \
    | sed -E "s/^${label}:[[:space:]]*//" \
    | grep -oE '(^|[^A-Za-z0-9_/])#[0-9]+' \
    | grep -oE '#[0-9]+' \
    | sort -u \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+$//'
}

# `|| true` because grep exits 1 on no match — that's a valid "no
# markers" outcome, not an error.
blocks="$(extract_refs 'Blocks' || true)"
blocked_by="$(extract_refs 'Blocked by' || true)"

printf 'blocks=%s\n'     "$blocks"
printf 'blocked-by=%s\n' "$blocked_by"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'blocks=%s\n'     "$blocks"
    printf 'blocked-by=%s\n' "$blocked_by"
  } >> "$GITHUB_OUTPUT"
fi
