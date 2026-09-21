#!/usr/bin/env bash
#
# autopilot.sh — the unattended enrich lane (#373).
#
# Selects needs-enrichment issues in allowlisted repos, quick-enriches each in
# its own nested headless Claude session, and dispatches the ones that came out
# clean with ai-implement + ai-review-ai-merge. Anything it cannot decide gets
# needs-human and a human.
#
# A systemd timer runs a process, not a slash command, which is why the driver
# is a shell script and /autopilot is only a thin wrapper over its --dry-run.
#
# This script owns every write. Config parsing, eligibility and candidate
# selection are query-only libs so they stay fixture-testable with no network.
#
# Usage:
#   autopilot.sh                     # a real run
#   autopilot.sh --dry-run           # print what a real run would do
#   autopilot.sh --config path.conf  # an explicit config file
#   autopilot.sh --max 1             # override max_per_run
#
# Env:
#   AUTOPILOT_CONFIG        config path. Default ~/.config/agent-workflow/autopilot.conf
#   AUTOPILOT_CACHE_DIR     clone cache + run lock. Default ~/.cache/agent-workflow/autopilot
#   AUTOPILOT_DISABLE_FLAG  kill switch. Default ~/.config/agent-workflow/autopilot.disabled
#   AUTOPILOT_LOG_DIR       nested session logs. Default $AUTOPILOT_CACHE_DIR/logs
#   ENRICH_CMD              per-issue enrich command. Default scripts/lib/agent-cmd-enrich.sh
#   MODEL                   passed through to the nested session
#
# Exit codes:
#   0  ran (including "disabled" and "already running" — neither is an error)
#   2  usage error
#   3  missing dependency
#   4  config invalid or unreadable
set -euo pipefail
IFS=$'\n\t'

# A caller piping our stdout through something like `head -1` closes the pipe
# early on purpose — that's not an error, so exit clean instead of dying by
# signal (128+13) when a later log write hits the closed pipe. But that is
# only honest while nothing has been mutated yet: once a run has written to an
# issue, a signal-killed process is a truncated-but-mutating run, not a clean
# no-op, and reporting it as exit 0 would hide a partial run behind a success
# code. AUTOPILOT_WROTE is set immediately before the FIRST mutating `gh` call
# in a run (before the call, not after — if the process dies mid-call the
# write may still have landed), so the trap can tell the two cases apart.
AUTOPILOT_WROTE=0

handle_sigpipe() {
  if (( AUTOPILOT_WROTE )); then
    exit 1
  fi
  exit 0
}
trap handle_sigpipe PIPE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib/autopilot-config.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-config.sh"
# shellcheck source=scripts/lib/autopilot-eligible.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-eligible.sh"
# shellcheck source=scripts/lib/autopilot-candidates.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-candidates.sh"
# shellcheck source=scripts/lib/autopilot-clone.sh disable=SC1091
source "$ROOT/scripts/lib/autopilot-clone.sh"

DRY_RUN=0
CONFIG_FILE=''
MAX_OVERRIDE=''

CACHE_DIR="${AUTOPILOT_CACHE_DIR:-$HOME/.cache/agent-workflow/autopilot}"
DISABLE_FLAG="${AUTOPILOT_DISABLE_FLAG:-$HOME/.config/agent-workflow/autopilot.disabled}"
ENRICH_CMD="${ENRICH_CMD:-$ROOT/scripts/lib/agent-cmd-enrich.sh}"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=1; shift ;;
      --config)    [[ $# -ge 2 ]] || die "--config needs a value"; CONFIG_FILE="$2"; shift 2 ;;
      --max)       [[ $# -ge 2 ]] || die "--max needs a value"; MAX_OVERRIDE="$2"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown option: $1" ;;
    esac
  done
  if [[ -n "$MAX_OVERRIDE" ]] && ! [[ "$MAX_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
    die "--max must be a positive integer (got: $MAX_OVERRIDE)"
  fi
}

require_tools() {
  local tool
  for tool in gh jq git flock timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "missing dependency: $tool" 3
  done
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { printf '%s %s\n' "$(now)" "$1"; }
log_repo() { printf '%s %s %s\n' "$(now)" "$1" "$2"; }
log_issue() { printf '%s %s#%s %s\n' "$(now)" "$1" "$2" "$3"; }

# Holds the lock for the life of the process via fd 9. In the driver rather
# than the unit on purpose: this protects a manual shell run as well as a timer
# run, and systemd knows nothing about the former.
acquire_run_lock() {
  mkdir -p "$CACHE_DIR"
  exec 9>"$CACHE_DIR/run.lock"
  flock -n 9
}

# True iff the issue currently carries $3. The enrich session labels the issue
# itself, so the issue — not this script's memory, and not the session's exit
# code — is the source of truth. That also means a driver killed mid-run leaves
# the state where the next run can read it.
issue_has_label() {
  local repo="$1" n="$2" want="$3" out
  out="$(gh issue view "$n" --repo "$repo" --json labels 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e --arg want "$want" '[.labels[].name] | index($want) != null' >/dev/null
}

process_issue() {
  local repo="$1" n="$2" dir rc
  dir="$(autopilot_clone_dir "$repo")"

  if (( DRY_RUN )); then
    log_issue "$repo" "$n" "would: enrich headless, then dispatch (clone $dir)"
    return 0
  fi

  if ! sync_autopilot_clone "$repo"; then
    log_issue "$repo" "$n" "failed (clone sync)"
    return 0
  fi

  rc=0
  ( cd "$dir" && timeout "$AUTOPILOT_ENRICH_TIMEOUT" "$ENRICH_CMD" "$n" ) || rc=$?

  if (( rc != 0 )); then
    # A crash escalates to a human, not just to the log. Without this, an issue
    # that reliably kills the enrich session re-spawns a paid nested session on
    # every run, forever. One call, so a failure cannot release the lock while
    # leaving the issue unlabelled (#365).
    AUTOPILOT_WROTE=1
    gh issue edit "$n" --repo "$repo" \
      --add-label needs-human --remove-label enrichment-ongoing >/dev/null 2>&1 || true
    if (( rc == 124 )); then
      log_issue "$repo" "$n" "failed (enrich timed out after ${AUTOPILOT_ENRICH_TIMEOUT}s)"
    else
      log_issue "$repo" "$n" "failed (enrich exited $rc)"
    fi
    return 0
  fi

  if issue_has_label "$repo" "$n" needs-human; then
    log_issue "$repo" "$n" "needs-human"
    return 0
  fi

  # Both labels in ONE call. Two calls spawn two workflow runs that race and can
  # cancel each other's review job (#365).
  AUTOPILOT_WROTE=1
  if ! gh issue edit "$n" --repo "$repo" \
        --add-label ai-implement,ai-review-ai-merge >/dev/null 2>&1; then
    log_issue "$repo" "$n" "failed (dispatch labels not applied)"
    return 0
  fi

  log_issue "$repo" "$n" "enriched"
}

main() {
  parse_args "$@"
  require_tools

  if ! acquire_run_lock; then
    log "already running — exiting"
    exit 0
  fi

  if [[ -e "$DISABLE_FLAG" ]]; then
    log "disabled: $DISABLE_FLAG present"
    exit 0
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    load_autopilot_config "$CONFIG_FILE" || exit 4
  else
    load_autopilot_config || exit 4
  fi
  [[ -n "$MAX_OVERRIDE" ]] && AUTOPILOT_MAX_PER_RUN="$MAX_OVERRIDE"

  export AUTOPILOT_LOG_DIR="${AUTOPILOT_LOG_DIR:-$CACHE_DIR/logs}"

  local remaining="$AUTOPILOT_MAX_PER_RUN"
  local repo reason issues n

  for repo in "${AUTOPILOT_REPOS[@]}"; do
    (( remaining > 0 )) || break

    reason=''
    if ! reason="$(repo_eligible "$repo")"; then
      log_repo "$repo" "skipped ($reason)"
      continue
    fi

    issues=()
    mapfile -t issues < <(autopilot_candidates "$repo" "$remaining" || true)
    if (( ${#issues[@]} == 0 )); then
      log_repo "$repo" "no candidates"
      continue
    fi

    for n in "${issues[@]}"; do
      [[ -n "$n" ]] || continue
      process_issue "$repo" "$n"
      # Every attempt costs a nested session, so every attempt spends budget —
      # including one that ends in needs-human or a failure.
      remaining=$((remaining - 1))
    done
  done
}

main "$@"
