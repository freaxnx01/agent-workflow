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
#   1  a closed stdout after at least one write — a truncated run that
#      already mutated something. Two routes land here: the process gets
#      SIGPIPE (the PIPE trap), or a `printf` log write hits EPIPE directly
#      and returns non-zero without the process ever taking the signal (a
#      clean, no-write closed stdout still exits 0 either way)
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
# shellcheck source=scripts/lib/gh-retry.sh disable=SC1091
source "$ROOT/scripts/lib/gh-retry.sh"

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

# The `printf` builtin can fail on a closed stdout (EPIPE) without the
# process ever taking a SIGPIPE signal — bash still delivers the signal, but
# the write() call underneath printf can return the error synchronously
# first, and printf reports "write error: Broken pipe" and returns non-zero.
# That would otherwise hit `set -e` and die with an unhandled status instead
# of the documented 0/1 contract, so every log write routes a failed printf
# into the same handler the PIPE trap uses.
log() { printf '%s %s\n' "$(now)" "$1" || handle_sigpipe; }
log_repo() { printf '%s %s %s\n' "$(now)" "$1" "$2" || handle_sigpipe; }
log_issue() { printf '%s %s#%s %s\n' "$(now)" "$1" "$2" "$3" || handle_sigpipe; }

# Ensures the labels dispatch and escalation depend on — ai-implement,
# ai-review-ai-merge, needs-human, and the rest of ensure-issue-labels.sh's
# registry — exist on $1 before this repo's first dispatch this run. That
# script's own create() already treats "label exists" as success (a
# per-label `gh label create` failure is swallowed by design, so a
# consumer's customized color survives unchanged), so calling it once per
# eligible repo with candidates is safe and cheap next to the nested session
# it gates.
#
# Because per-label failures are swallowed inside ensure-issue-labels.sh,
# this can only ever fail for something that breaks the whole call — REPO
# unset, the script missing or unreadable, the shell dying unexpectedly.
# That is exactly what must stop THIS repo cold: proceeding to enrich an
# issue we then cannot label is the live #380 failure — a paid nested
# session spent on an issue that comes back enriched with zero labels and no
# human flagged.
ensure_repo_labels() {
  local repo="$1"
  REPO="$repo" bash "$ROOT/scripts/ensure-issue-labels.sh" >/dev/null 2>&1
}

# Holds the lock for the life of the process via fd 9. In the driver rather
# than the unit on purpose: this protects a manual shell run as well as a timer
# run, and systemd knows nothing about the former.
acquire_run_lock() {
  mkdir -p "$CACHE_DIR"
  exec 9>"$CACHE_DIR/run.lock"
  flock -n 9
}

# Three-way read of whether the issue currently carries $3: 0 = present,
# 1 = absent, 2 = could not determine (gh failed, or the JSON was unreadable).
# The enrich session labels the issue itself, so the issue — not this script's
# memory, and not the session's exit code — is the source of truth. That also
# means a driver killed mid-run leaves the state where the next run can read
# it. Callers MUST treat 2 as "do not dispatch" — a transient `gh` blip here
# must never be read as "label absent", or an issue the enrich session flagged
# needs-human could fall through into unattended auto-merge.
issue_label_state() {
  local repo="$1" n="$2" want="$3" out has
  out="$(gh issue view "$n" --repo "$repo" --json labels 2>/dev/null)" || return 2
  has="$(printf '%s' "$out" | jq -r --arg want "$want" '[.labels[].name] | index($want) != null' 2>/dev/null)" || return 2
  case "$has" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     return 2 ;;
  esac
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
    # leaving the issue unlabelled (#365). It's retried via gh-retry.sh because
    # a transient blip on this exact call is the one failure mode that defeats
    # the whole anti-poison-issue design: needs-human never lands,
    # enrichment-ongoing (set by /enrich before it crashed) stays set, and
    # autopilot-candidates.sh excludes issues carrying enrichment-ongoing — so
    # the issue silently drops out of the lane for good.
    local reason escalate_rc=0
    if (( rc == 124 )); then
      reason="failed (enrich timed out after ${AUTOPILOT_ENRICH_TIMEOUT}s)"
    else
      reason="failed (enrich exited $rc)"
    fi
    AUTOPILOT_WROTE=1
    with_backoff gh issue edit "$n" --repo "$repo" \
      --add-label needs-human --remove-label enrichment-ongoing >/dev/null 2>&1 || escalate_rc=$?
    if (( escalate_rc != 0 )); then
      log_issue "$repo" "$n" \
        "$reason; ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set"
    else
      log_issue "$repo" "$n" "$reason"
    fi
    return 0
  fi

  # Re-read every gating label after the nested session returns. rc == 0 from
  # `claude --print` only means the model produced text — it is NOT evidence
  # the issue was enriched (a prose-only reply, a denied tool call, or a
  # graceful no-op all exit 0 too). So dispatch requires POSITIVE evidence:
  # needs-enrichment must be gone (that removal happens only on a genuine
  # `/enrich` success — see commands/enrich.md), needs-human must be absent
  # (the session may have escalated instead of enriching), and parked must
  # be absent (a human may have parked the issue during the up-to-30-minute
  # nested session). Every arm below is explicit — state 1 (absent) is the
  # ONLY state that proceeds, and every other state, including one the case
  # statement doesn't expect, refuses via the catch-all. The most
  # safety-critical branch in this script must be default-closed.

  local human_state=0
  issue_label_state "$repo" "$n" needs-human || human_state=$?
  case "$human_state" in
    1) : ;; # absent — proceed
    0) log_issue "$repo" "$n" "needs-human"; return 0 ;;
    *) log_issue "$repo" "$n" "skipped (could not read labels — not dispatching)"; return 0 ;;
  esac

  local enrich_state=0
  issue_label_state "$repo" "$n" needs-enrichment || enrich_state=$?
  case "$enrich_state" in
    1) : ;; # absent — /enrich completed and cleared it, proceed
    0) log_issue "$repo" "$n" \
         "skipped (enrich did not complete — needs-enrichment still present)"; return 0 ;;
    *) log_issue "$repo" "$n" "skipped (could not read labels — not dispatching)"; return 0 ;;
  esac

  local parked_state=0
  issue_label_state "$repo" "$n" 'parked' || parked_state=$?
  case "$parked_state" in
    1) : ;; # absent — proceed
    0) log_issue "$repo" "$n" "skipped (parked during enrich — not dispatching)"; return 0 ;;
    *) log_issue "$repo" "$n" "skipped (could not read labels — not dispatching)"; return 0 ;;
  esac

  # Both labels in ONE call. Two calls spawn two workflow runs that race and can
  # cancel each other's review job (#365). Retried via gh-retry.sh for the same
  # reason as the crash escalation above: a transient blip on this exact call
  # would otherwise leave the issue fully enriched (needs-enrichment already
  # gone) with no needs-human and no dispatch labels — invisible to both the
  # lane (autopilot_candidates requires needs-enrichment) and a human.
  AUTOPILOT_WROTE=1
  if ! with_backoff gh issue edit "$n" --repo "$repo" \
        --add-label ai-implement,ai-review-ai-merge >/dev/null 2>&1; then
    local dispatch_escalate_rc=0
    with_backoff gh issue edit "$n" --repo "$repo" \
      --add-label needs-human >/dev/null 2>&1 || dispatch_escalate_rc=$?
    if (( dispatch_escalate_rc != 0 )); then
      log_issue "$repo" "$n" \
        "failed (dispatch labels not applied); ESCALATION FAILED: needs-human not applied"
    else
      log_issue "$repo" "$n" \
        "failed (dispatch labels not applied); escalated to needs-human"
    fi
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
    if ! reason="$(repo_eligible "$repo" "${AUTOPILOT_GATES[$repo]}")"; then
      log_repo "$repo" "skipped ($reason)"
      continue
    fi

    local candidates_out candidates_rc=0
    candidates_out="$(autopilot_candidates "$repo" "$remaining")" || candidates_rc=$?
    if (( candidates_rc != 0 )); then
      log_repo "$repo" "skipped (candidate query failed)"
      continue
    fi

    issues=()
    if [[ -n "$candidates_out" ]]; then
      mapfile -t issues <<< "$candidates_out"
    fi
    if (( ${#issues[@]} == 0 )); then
      log_repo "$repo" "no candidates"
      continue
    fi

    # Bootstrap the pipeline's own labels before the first dispatch write of
    # this repo this run (#380) — never in --dry-run, which must make no
    # `gh label create` call at all, only say what it would ensure.
    if (( DRY_RUN )); then
      log_repo "$repo" "dry-run: would ensure pipeline labels exist, no gh calls made"
    elif ! ensure_repo_labels "$repo"; then
      log_repo "$repo" "skipped (label ensure failed)"
      continue
    fi

    for n in "${issues[@]}"; do
      [[ -n "$n" ]] || continue
      process_issue "$repo" "$n"
      # Decremented once per attempt regardless of outcome, including one that
      # never reached a nested session (a clone-sync failure). It's not "every
      # attempt costs a session" — it's that a broken repo or a poison issue
      # must not be retried indefinitely within one run; capping attempts is
      # what keeps that deterministic, whether or not a session ever spawned.
      remaining=$((remaining - 1))
    done
  done
}

# Guarded so tests/run-autopilot-driver-tests.sh can `source` this file to
# call process_issue directly (Fix 5's catch-all coverage needs a stubbed
# issue_label_state, which only works against the sourced function) without
# a real run firing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
