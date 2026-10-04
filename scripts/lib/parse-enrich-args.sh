#!/usr/bin/env bash
#
# parse-enrich-args.sh — sourced, not executed.
#   parse_enrich_args <arguments>
#   Parses: <issue-number> [--quick]
#   Outputs: "ISSUE=<n>" and "QUICK=yes|no" on separate lines.
#   Returns 1 if issue number is missing or non-numeric; 0 on success.
set -euo pipefail
IFS=$'\n\t'

parse_enrich_args() {
  local args="$1"
  local issue quick

  # Extract issue number: remove flags, strip leading #
  issue=$(echo "$args" | tr ' ' '\n' | grep -v '^--' | tr -d '#' | head -1)

  # Check for --quick flag
  quick=$(echo "$args" | grep -q -- '--quick' && echo yes || echo no)

  # Validate issue is numeric
  if [[ -z "$issue" ]]; then
    echo "ISSUE=" >&2
    echo "QUICK=$quick" >&2
    return 1
  fi

  if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    echo "ISSUE=" >&2
    echo "QUICK=$quick" >&2
    return 1
  fi

  echo "ISSUE=$issue"
  echo "QUICK=$quick"
}
