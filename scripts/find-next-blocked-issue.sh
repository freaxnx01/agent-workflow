#!/usr/bin/env bash
#
# find-next-blocked-issue.sh — When a chained issue closes, find the
# successors that just became eligible.
#
# Per ADR-003: a successor is eligible iff
#   1. it carries `ai-chain` (per-issue opt-in), AND
#   2. every entry in its `Blocked by:` list resolves to a closed
#      issue, AND
#   3. it is itself still open.
#
# Required environment variables:
#   CLOSED_ISSUE_NUMBER  Number of the issue whose closure triggered
#                        the chain check.
#   REPO                 owner/repo (default: $GITHUB_REPOSITORY).
#   GH_TOKEN             (or ambient gh auth).
#
# Safety configuration (ADR-003 §5 — fail closed on both):
#   MAX_CHAIN_DEPTH      Refuse dispatch when the current chain depth
#                        reaches this cap (default 5). Eligible
#                        candidates become `decision=capped` instead.
#   CHAIN_DEPTH          The current chain depth (default 1 — i.e. the
#                        closed issue is the first link). Test seam.
#                        Production callers compute via a backwards
#                        walk on `Blocked by:` markers.
#
# Kill switch (ADR-003 §4):
#   KILL_SWITCH_OPEN     `true|false`. Default: probe via
#                        `gh issue list --search 'ai:chain-paused
#                        in:title' --state open`. When true, every
#                        eligible candidate becomes `decision=paused`.
#
# Optional environment variables (test seams):
#   CLOSED_ISSUE_BODY    Skip `gh issue view` for the closed issue.
#   CANDIDATES_JSON      Skip `gh issue list --label ai-chain ...`;
#                        provide the candidate list directly. JSON
#                        array of {number, body, labels} objects.
#                        Each label entry is {name: "..."}.
#   ISSUE_STATE_<N>      For each candidate's blocker #N, override the
#                        state lookup. Value must be `open` or `closed`.
#                        When unset, the script falls back to
#                        `gh issue view <N> --json state`.
#
# Output (stdout AND, if set, $GITHUB_OUTPUT):
#   Per eligible candidate, one line:
#     candidate=<N> decision=<dispatched|capped|paused> depth=<k>
#   And three summary lines:
#     successor-count=<dispatched count>
#     successors=<space-separated list of dispatched #N>
#     decision-summary=<dispatched=A capped=B paused=C>
#
# Exit codes:
#   0  success (count may be 0)
#   2  required env missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${CLOSED_ISSUE_NUMBER:-}" ]]; then
  printf 'error: CLOSED_ISSUE_NUMBER must be set\n' >&2
  exit 2
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_CHAIN="$SCRIPT_DIR/parse-chain.sh"

MAX_CHAIN_DEPTH="${MAX_CHAIN_DEPTH:-5}"
CHAIN_DEPTH="${CHAIN_DEPTH:-1}"

# --- kill switch ---------------------------------------------------------
#
# An open issue titled EXACTLY `ai:chain-paused` halts all chain
# dispatch (ADR-003 §4). Match is `==`, not `contains`, so an issue
# titled "Add ai:chain-paused to docs" doesn't trip the switch.

kill_switch_open="${KILL_SWITCH_OPEN:-}"
if [[ -z "$kill_switch_open" ]]; then
  paused_count="$(gh issue list \
    --repo "$REPO" \
    --state open \
    --search 'ai:chain-paused in:title' \
    --json title \
    --jq '[.[] | select(.title == "ai:chain-paused")] | length' \
    --limit 5 2>/dev/null || printf '0')"
  if [[ "${paused_count:-0}" -gt 0 ]]; then
    kill_switch_open=true
  else
    kill_switch_open=false
  fi
fi

# --- fetch candidate issues ----------------------------------------------

if [[ -z "${CANDIDATES_JSON:-}" ]]; then
  # `--search "label:ai-chain label:ai-implement state:open"` would be
  # cleaner but `gh issue list --label` already AND-combines, plus
  # `--state open` is explicit. Limit to a modest page — a chain
  # of >50 in-flight open issues is itself a smell.
  CANDIDATES_JSON="$(gh issue list \
    --repo "$REPO" \
    --label ai-chain \
    --label ai-implement \
    --state open \
    --json number,body,labels \
    --limit 50 2>/dev/null || printf '[]')"
fi

# --- evaluate each candidate ---------------------------------------------

# Helper: look up a single issue's state (open|closed). Uses
# ISSUE_STATE_<N> env override when present; otherwise calls gh.
issue_state() {
  local n="$1" var_name override
  var_name="ISSUE_STATE_${n}"
  override="${!var_name:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  gh issue view "$n" --repo "$REPO" --json state \
    --jq '.state | ascii_downcase' 2>/dev/null || printf 'unknown'
}

dispatched=()
capped=()
paused=()
candidate_count="$(printf '%s' "$CANDIDATES_JSON" | jq -r 'length')"

for ((i = 0; i < candidate_count; i++)); do
  num="$(printf '%s' "$CANDIDATES_JSON" | jq -r ".[$i].number")"
  body="$(printf '%s' "$CANDIDATES_JSON" | jq -r ".[$i].body // \"\"")"

  # ai-chain label presence is implicit (we filtered on it via
  # --label), but a future caller may bypass that filter via the
  # CANDIDATES_JSON seam, so re-verify here.
  has_ai_chain="$(printf '%s' "$CANDIDATES_JSON" \
    | jq -r ".[$i].labels[]?.name" \
    | grep -Fx 'ai-chain' || true)"
  [[ -z "$has_ai_chain" ]] && continue

  # Parse `Blocked by:` set.
  parse_out="$(printf '%s' "$body" | ISSUE_BODY='' bash "$PARSE_CHAIN" 2>/dev/null || true)"
  blocked_by_line="$(printf '%s' "$parse_out" | grep '^blocked-by=' | head -1)"
  blocked_by="${blocked_by_line#blocked-by=}"

  # Empty `Blocked by:` set is degenerate — the chain dispatcher
  # should not pick up an issue with no declared blockers as a
  # "successor" to the closed one; only issues explicitly blocked by
  # the chain are candidates. Skip.
  if [[ -z "${blocked_by// /}" ]]; then
    continue
  fi

  # The closed issue must actually appear in this candidate's
  # Blocked-by list — otherwise we have no reason to evaluate it as a
  # successor of the closed one.
  closed_ref="#${CLOSED_ISSUE_NUMBER}"
  if ! printf '%s\n' "$blocked_by" | tr ' ' '\n' | grep -qFx "$closed_ref"; then
    continue
  fi

  # Every blocker (other than the just-closed one) must also be
  # closed.
  all_closed=true
  # `read` skips the last line when there's no trailing newline — the
  # `|| [[ -n "$ref" ]]` pattern handles that final read.
  while IFS= read -r ref || [[ -n "$ref" ]]; do
    [[ -z "$ref" ]] && continue
    blocker_num="${ref#\#}"
    if [[ "$blocker_num" == "$CLOSED_ISSUE_NUMBER" ]]; then
      # The trigger — known closed.
      continue
    fi
    state="$(issue_state "$blocker_num")"
    if [[ "$state" != "closed" ]]; then
      all_closed=false
      break
    fi
  done < <(printf '%s' "$blocked_by" | tr ' ' '\n')

  if [[ "$all_closed" != true ]]; then
    continue
  fi

  # The candidate is eligible by ADR-002-style gates. Now apply the
  # ADR-003 §4 + §5 safety overlays. Order matters: kill switch is
  # the highest-precedence "stop" (operator decision); depth cap is
  # a safety net.
  if [[ "$kill_switch_open" == true ]]; then
    paused+=("$num")
  elif (( CHAIN_DEPTH >= MAX_CHAIN_DEPTH )); then
    capped+=("$num")
  else
    dispatched+=("$num")
  fi
done

# --- emit output ---------------------------------------------------------
#
# GITHUB_OUTPUT carries summary fields only (Actions step outputs are
# single-valued). Per-candidate `candidate=<N> decision=<d> depth=<k>`
# lines on stdout are the audit surface — the workflow's audit-
# comment step consumes them. `successors=<list>` is the load-bearing
# dispatch list (only `dispatched` entries).

join_space() {
  local out='' n
  for n in "$@"; do
    [[ -z "$n" ]] && continue
    out="${out:+$out }$n"
  done
  printf '%s' "$out"
}

dispatched_joined="$(join_space "${dispatched[@]:-}")"
capped_joined="$(join_space     "${capped[@]:-}")"
paused_joined="$(join_space     "${paused[@]:-}")"
count="${#dispatched[@]}"

emit_lines() {
  for n in "${dispatched[@]:-}"; do
    [[ -z "$n" ]] && continue
    printf 'candidate=%s decision=dispatched depth=%s\n' "$n" "$CHAIN_DEPTH"
  done
  for n in "${capped[@]:-}"; do
    [[ -z "$n" ]] && continue
    printf 'candidate=%s decision=capped depth=%s\n' "$n" "$CHAIN_DEPTH"
  done
  for n in "${paused[@]:-}"; do
    [[ -z "$n" ]] && continue
    printf 'candidate=%s decision=paused depth=%s\n' "$n" "$CHAIN_DEPTH"
  done
}

emit_lines

printf 'successor-count=%s\n' "$count"
printf 'successors=%s\n'      "$dispatched_joined"
printf 'capped=%s\n'          "$capped_joined"
printf 'paused=%s\n'          "$paused_joined"
printf 'decision-summary=dispatched=%s capped=%s paused=%s\n' \
  "${#dispatched[@]}" "${#capped[@]}" "${#paused[@]}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'successor-count=%s\n' "$count"
    printf 'successors=%s\n'      "$dispatched_joined"
    printf 'capped=%s\n'          "$capped_joined"
    printf 'paused=%s\n'          "$paused_joined"
    printf 'decision-summary=dispatched=%s capped=%s paused=%s\n' \
      "${#dispatched[@]}" "${#capped[@]}" "${#paused[@]}"
  } >> "$GITHUB_OUTPUT"
fi
