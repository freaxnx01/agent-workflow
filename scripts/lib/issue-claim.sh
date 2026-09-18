#!/usr/bin/env bash
#
# issue-claim.sh — read an implement claim off an issue and decide whether the
# run it names is still working. Source it; do not execute.
#
# The claim (ADR-015, #366) is a label plus a comment:
#
#   label:   ai-implementing
#   comment: 🔒 Implement claim by run <run-id>
#            <run-url>
#            claimed <ISO-8601 UTC>
#
# The label is the greppable boolean; the comment carries the **run
# reference**, which is what staleness is judged from. Both live on the issue,
# so a local session with no GitHub Actions access reaches the same verdict
# from the same data as the pipeline does.
#
#   parse_claims <comments>        every claim, oldest first, as
#                                  `run_id<TAB>run_url<TAB>claimed_at`
#   parse_latest_claim <comments>  the newest claim only, same shape
#   claim_state <run-id>           `live` | `stale`
#
# Staleness is never decided by elapsed time. An implement run is ~10–15
# minutes, so any time rule would be either uselessly long or prone to false
# takeovers; the run's own state is the only signal. `queued` and `in_progress`
# are live, and everything else — **including a run that cannot be resolved at
# all** — is stale. That last mapping is deliberate: an unresolvable run (run
# deleted, logs expired, API erroring) cannot be in progress, and failing open
# is what keeps a crashed run from wedging the issue forever without falling
# back on a timestamp. The cost is a possible false takeover during a GitHub
# API outage, which is strictly better than a permanently blocked issue.
#
# A label with no parseable claim comment is therefore stale too: there is no
# run reference to judge, so there is nothing holding the issue.
#
# Seams (env):
#   RUN_STATE  If set (even to the empty string), used instead of calling
#              `gh run view`. Empty means "unresolvable" → stale. Used by tests
#              to stay hermetic.
#   REPO       owner/repo passed to `gh run view` when set.
set -euo pipefail
IFS=$'\n\t'

# The marker is matched as a prefix of the line, so the release note
# ("🔓 Implement claim released by run N") cannot be read as a claim.
CLAIM_MARKER='🔒 Implement claim by run '
CLAIM_LABEL="${CLAIM_LABEL:-ai-implementing}"

# parse_claims <comments> — print every claim found in the blob, oldest first,
# one per line as `run_id<TAB>run_url<TAB>claimed_at`. Prints nothing when the
# blob holds no claim.
parse_claims() {
  local comments="${1:-}"
  [[ -n "$comments" ]] || return 0

  local -a lines=()
  mapfile -t lines <<< "$comments"

  local i run_id run_url claimed_at
  for (( i = 0; i < ${#lines[@]}; i++ )); do
    [[ "${lines[i]}" == "$CLAIM_MARKER"* ]] || continue

    run_id="${lines[i]#"$CLAIM_MARKER"}"
    run_id="${run_id%%[^0-9]*}"
    [[ -n "$run_id" ]] || continue

    run_url=''
    claimed_at=''
    if (( i + 1 < ${#lines[@]} )) && [[ "${lines[i + 1]}" == http* ]]; then
      run_url="${lines[i + 1]}"
    fi
    if (( i + 2 < ${#lines[@]} )) && [[ "${lines[i + 2]}" == 'claimed '* ]]; then
      claimed_at="${lines[i + 2]#claimed }"
    fi

    printf '%s\t%s\t%s\n' "$run_id" "$run_url" "$claimed_at"
  done
}

# parse_latest_claim <comments> — the newest claim only. A redispatched issue
# accumulates claim comments and the oldest one is never the answer.
parse_latest_claim() {
  parse_claims "${1:-}" | tail -n 1
}

# claim_state <run-id> — `live` if GitHub says the run is still going, `stale`
# otherwise. See the header for why unresolvable maps to stale.
claim_state() {
  local run_id="${1:-}"
  local state=''

  if [[ -n "${RUN_STATE+x}" ]]; then
    state="$RUN_STATE"
  elif [[ -n "$run_id" ]]; then
    local -a args=(run view "$run_id" --json status --jq '.status')
    [[ -n "${REPO:-}" ]] && args+=(--repo "$REPO")
    # Guarded: any non-zero exit (unknown run, no permission, API down) must
    # yield stale rather than killing the caller under `set -e`.
    state="$(gh "${args[@]}" 2>/dev/null || true)"
  fi

  case "$state" in
    queued | in_progress | requested | waiting | pending) printf 'live\n' ;;
    *) printf 'stale\n' ;;
  esac
}
