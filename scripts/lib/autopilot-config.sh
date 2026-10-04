#!/usr/bin/env bash
#
# autopilot-config.sh — sourced, not executed.
#   load_autopilot_config [file]
#
# Reads the autopilot config and sets:
#   AUTOPILOT_MAX_PER_RUN     global cap on issues enriched per run (default 3)
#   AUTOPILOT_ENRICH_TIMEOUT  per-issue timeout in seconds (default 1800)
#   AUTOPILOT_REPOS           array of allowlisted owner/name repos
#   AUTOPILOT_GATES           assoc array, owner/name -> its test-gate workflow file
#
# Each allowlisted repo is declared as:
#   repo=<owner/name>:<test-gate workflow file>
# e.g.
#   repo=freaxnx01/agent-action-sandbox:ci.yml
#
# The gate is named HERE, not in the consumer's own agent.yml: that reusable
# workflow (.github/workflows/agent-implement.yml) does not declare a
# `autopilot-test-gate` input, and GitHub Actions hard-fails a `workflow_call`
# job on an undeclared input — so there is no legal place in a consumer
# workflow to carry this key. The allowlist already lives host-side, so the
# gate lives right next to it.
#
# With no argument, reads $AUTOPILOT_CONFIG, else
# ~/.config/agent-workflow/autopilot.conf. The real file is host-local and not
# in git: the allowlist is host policy ("which repos do I let merge AI PRs
# unattended"), and agent-workflow is a public repo. setup/autopilot.conf.example
# documents the shape.
#
# Validation is fail-fast on purpose. A silently-defaulted allowlist is the one
# failure mode that could aim an unattended lane at a repo nobody approved, so
# an unknown key, a bad value or a missing file is an error — never a default.
#
# Returns 0 on success; prints 'error: <file>:<line>: …' to stderr and returns 1
# otherwise.
set -euo pipefail
IFS=$'\n\t'

load_autopilot_config() {
  local file="${1:-${AUTOPILOT_CONFIG:-$HOME/.config/agent-workflow/autopilot.conf}}"
  local line key value lineno=0

  AUTOPILOT_MAX_PER_RUN=3
  AUTOPILOT_ENRICH_TIMEOUT=1800
  AUTOPILOT_REPOS=()
  # A bare `declare -A` here would be local to this function and vanish the
  # moment it returns — `-g` is what makes it survive back to the caller that
  # sourced this file, exactly like AUTOPILOT_REPOS does implicitly as a
  # global array. Reset on every call so a second load can't inherit a stale
  # entry from a prior one.
  declare -gA AUTOPILOT_GATES
  AUTOPILOT_GATES=()

  if [[ ! -r "$file" ]]; then
    printf 'error: config not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"                              # strip comments
    line="${line#"${line%%[![:space:]]*}"}"         # ltrim
    line="${line%"${line##*[![:space:]]}"}"         # rtrim
    [[ -z "$line" ]] && continue

    if [[ "$line" != *=* ]]; then
      printf 'error: %s:%d: not a key=value line: %s\n' "$file" "$lineno" "$line" >&2
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$key" in
      max_per_run)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
          printf 'error: %s:%d: max_per_run must be a positive integer: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        # shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
        AUTOPILOT_MAX_PER_RUN="$value"
        ;;
      enrich_timeout)
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
          printf 'error: %s:%d: enrich_timeout must be a positive integer: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        # shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
        AUTOPILOT_ENRICH_TIMEOUT="$value"
        ;;
      repo)
        if [[ "$value" != *:* ]]; then
          printf 'error: %s:%d: repo needs a :<test-gate workflow file>: %s\n' "$file" "$lineno" "$value" >&2
          return 1
        fi
        local repo_name="${value%%:*}" gate="${value#*:}"
        if ! [[ "$repo_name" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
          printf 'error: %s:%d: repo must be owner/name: %s\n' "$file" "$lineno" "$repo_name" >&2
          return 1
        fi
        # ^[A-Za-z0-9._-]+\.ya?ml$ also closes a path-traversal hole: an
        # unvalidated gate is interpolated straight into a
        # repos/<repo>/actions/workflows/<gate>/runs API URL, so `../..`
        # could point the gate lookup at another repo's green workflow.
        if ! [[ "$gate" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
          printf 'error: %s:%d: gate must be a bare workflow filename: %s\n' "$file" "$lineno" "$gate" >&2
          return 1
        fi
        AUTOPILOT_REPOS+=("$repo_name")
        # shellcheck disable=SC2034  # consumed by the caller after sourcing, not in this file
        AUTOPILOT_GATES["$repo_name"]="$gate"
        ;;
      *)
        printf 'error: %s:%d: unknown key: %s\n' "$file" "$lineno" "$key" >&2
        return 1
        ;;
    esac
  done < "$file"

  if (( ${#AUTOPILOT_REPOS[@]} == 0 )); then
    printf 'error: %s: no repo= lines — an empty allowlist would do nothing\n' "$file" >&2
    return 1
  fi

  return 0
}
