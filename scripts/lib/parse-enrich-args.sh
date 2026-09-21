#!/usr/bin/env bash
#
# parse-enrich-args.sh — sourced, not executed.
#   parse_enrich_args <arguments>
#   Parses: <issue-number> [--quick] [--headless]
#   Outputs: "ISSUE=<n>", "QUICK=yes|no" and "HEADLESS=yes|no" on separate lines.
#   --headless implies --quick.
#   Returns 1 if issue number is missing or non-numeric; 0 on success.
set -euo pipefail
IFS=$'\n\t'

parse_enrich_args() {
  local args="$1"
  local issue quick headless

  # Extract issue number: remove flags, strip leading #
  issue=$(echo "$args" | tr ' ' '\n' | grep -v '^--' | tr -d '#' | head -1)

  # Check for --quick flag
  quick=$(echo "$args" | grep -q -- '--quick' && echo yes || echo no)

  # Check for --headless flag
  headless=$(echo "$args" | grep -q -- '--headless' && echo yes || echo no)

  # --headless implies --quick. Headless cannot answer the approval gate, so
  # the non-quick combination would block forever with nobody there to unblock
  # it; making it unrepresentable is cheaper than detecting it later.
  [[ "$headless" == yes ]] && quick=yes

  # Validate issue is numeric
  if [[ -z "$issue" ]] || ! [[ "$issue" =~ ^[0-9]+$ ]]; then
    echo "ISSUE=" >&2
    echo "QUICK=$quick" >&2
    echo "HEADLESS=$headless" >&2
    return 1
  fi

  echo "ISSUE=$issue"
  echo "QUICK=$quick"
  echo "HEADLESS=$headless"
}
