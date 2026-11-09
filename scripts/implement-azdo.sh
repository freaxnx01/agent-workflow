#!/usr/bin/env bash
#
# implement-azdo.sh — run the implement sequence against an Azure DevOps work
# item, locally or as the driver step of an Azure Pipelines run. Step 4 of #253.
#
# The GitHub path is a workflow triggered by a label. Azure DevOps has no
# equivalent trigger in this design, so this is invoked explicitly. It composes
# the same pipeline scripts the GitHub job runs, through the forge adapter.
#
# RETRY. Retry happens in the job, not by re-dispatch: retry-dispatch.sh needs
# `gh workflow run`, which has no Azure DevOps equivalent. The decision table is
# lib/retry-policy.sh and the attempt cap comes from check-attempt-cap.sh.
# Escalate-on-retry is a no-op here: this path only ever runs Claude.
#
# WHAT THIS DOES NOT DO, and cannot:
#
#   * No AI review and no auto-merge. check-merge-envelope.sh is GitHub-specific
#     reasoning about required status checks and review decisions; Azure DevOps
#     expresses those as branch policies and reviewer votes, which is a different
#     model and its own design. The run opens a draft PR and stops.
#   * No label-and-walk-away. This is the cost the issue anticipated.
#
# So the shape is: invoke -> agent implements -> draft PR opens -> a human
# reviews and merges. That is less than the GitHub path and deliberately so;
# pretending otherwise would be the expensive mistake.
#
# Required environment:
#   ISSUE_NUMBER            the work item id
#   AZURE_DEVOPS_EXT_PAT    a PAT with work-item and code scopes. May be left
#                           unset on Azure Pipelines: SYSTEM_ACCESSTOKEN is used
#                           instead (lib/ci-host.sh, ci_host_export_azdo_pat).
#                           A PAT that is set always wins. On any other host it
#                           must be set explicitly.
#   ANTHROPIC_API_KEY       or CLAUDE_CODE_OAUTH_TOKEN, for the agent
#
# Optional:
#   IMPLEMENT_TIMEOUT_MIN  wall-clock limit per agent attempt, in minutes
#               (decimals allowed). Default 45. On expiry the agent is killed
#               (SIGKILL after a 30 s grace) and the attempt counts as transient.
#   MAX_ATTEMPTS  attempts allowed before the work item is parked. Default 2,
#               read by check-attempt-cap.sh.
#   DRY_RUN=1   resolve, classify and report what WOULD run; invoke no agent
#               and write nothing. Use this first on any new project.
#
# Pipeline-file guard:
#   Before pushing, the driver refuses (exit 1) if the agent's commits touch
#   pipeline definitions (azure-pipelines*.yml, .azure-pipelines/, .azuredevops/,
#   plus PIPELINE_FILE_GLOBS, comma-separated). A diff that cannot be computed
#   also refuses. See lib/pipeline-file-guard.sh.
#
# Exit codes: 0 completed; 1 error; 2 required env missing or not an ADO remote.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/detect-forge.sh
source "$HERE/lib/detect-forge.sh"
# shellcheck source=scripts/lib/forge.sh
source "$HERE/lib/forge.sh"
# shellcheck source=scripts/lib/azdo.sh
source "$HERE/lib/azdo.sh"
# shellcheck source=scripts/lib/ci-host.sh
source "$HERE/lib/ci-host.sh"
# shellcheck source=scripts/lib/pipeline-file-guard.sh
source "$HERE/lib/pipeline-file-guard.sh"
# shellcheck source=scripts/lib/retry-policy.sh
source "$HERE/lib/retry-policy.sh"

# Run state. Initialised here so the file can be sourced under `set -u`.
DRY_RUN="${DRY_RUN:-0}"
MODEL="${MODEL:-claude-sonnet-5}"
RUN_CONTEXT=''       # pipeline | local
DEFAULT_BRANCH=''
RUN_ATTEMPT=1        # 1-based attempt number within this run
CAP_ATTEMPT=''       # attempt number counted from the work item's reports
CAP_SCRIPT_ATTEMPT=''
CAP_SCRIPT_PROCEED=''
RETRY_DECISION=''    # retry | stop, from retry_policy
RETRY_DELAY=0
PR_ID=''             # empty until open_draft_pr succeeds
HEAD_BRANCH=''       # the branch the attempt ended on
AGENT_RC=''
ATTEMPT_CLASS=''
ATTEMPT_SECONDS=''
ATTEMPT_ERROR=''     # why a PR step failed, one line
AGENT_NAME=''
TURNS_BUDGET=''
WORK_DIR=''
PROMPT_FILE=''
RESULT_FILE=''

# --- phases ------------------------------------------------------------------

preflight() {
  : "${ISSUE_NUMBER:?ISSUE_NUMBER must be set (the work item id)}"

  local forge
  forge="$(detect_forge | awk '{print $1}')"
  if [[ "$forge" != "azdo" ]]; then
    printf 'error: this entry point is for Azure DevOps remotes; detected "%s".\n' "$forge" >&2
    printf '       On GitHub, label the issue ai-implement and let the pipeline run.\n' >&2
    exit 2
  fi

  if [[ ! "${IMPLEMENT_TIMEOUT_MIN:-45}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'error: IMPLEMENT_TIMEOUT_MIN must be a number of minutes\n' >&2
    exit 2
  fi

  ci_host_export_azdo_pat || exit 2
  if [[ -z "${AZURE_DEVOPS_EXT_PAT:-}" ]]; then
    printf 'error: AZURE_DEVOPS_EXT_PAT must be set — prefer an allowed .envrc reached with direnv exec\n' >&2
    exit 2
  fi
  resolve_azdo_context || { printf 'error: could not resolve the ADO context from origin\n' >&2; exit 2; }

  # Where this run happens, for the banner and the work-item report.
  RUN_CONTEXT=local
  [[ "$(ci_host)" == "pipelines" ]] && RUN_CONTEXT=pipeline
  return 0
}

print_banner() {
  printf '== implement (%s, Azure DevOps) ==\n' "$RUN_CONTEXT"
  printf '   org/project/repo : %s / %s / %s\n' "$AZDO_ORG" "$AZDO_PROJECT" "$AZDO_REPO"
  printf '   work item        : #%s\n' "$ISSUE_NUMBER"
  printf '   retry            : in-job, per lib/retry-policy.sh (cap MAX_ATTEMPTS=%s)\n' "${MAX_ATTEMPTS:-2}"
  printf '   review / merge   : human, after the draft PR opens\n\n'
}

# Fills ISSUE_LABELS / ISSUE_BODY / ISSUE_JSON / ISSUE_COMMENTS_JSON, which is
# what lets the unchanged classifiers run on this forge at all.
read_work_item() {
  REPO="${AZDO_PROJECT}/${AZDO_REPO}"   # the classifiers want it set; unused on ADO
  export REPO
  forge_export_issue "$ISSUE_NUMBER" || { printf 'error: could not read work item #%s\n' "$ISSUE_NUMBER" >&2; exit 1; }

  printf 'tags  : %s\n' "$(printf '%s' "$ISSUE_LABELS" | tr '\n' ' ')"
  printf 'title : %s\n' "$(printf '%s' "$ISSUE_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')"
}

# These scripts are untouched. They take their injected path because
# forge_export_issue filled the variables they already prefer.
classify_issue() {
  local out agent turns
  out="$WORK_DIR/classify.out"
  export ATTEMPT="$RUN_ATTEMPT"
  GITHUB_OUTPUT="$out" bash "$HERE/classify-agent.sh" >/dev/null 2>&1 || true
  GITHUB_OUTPUT="$out" bash "$HERE/classify-turns.sh" >/dev/null 2>&1 || true
  agent="$(sed -n 's/^agent=//p' "$out" | tail -1)"
  turns="$(sed -n 's/^turns=//p' "$out" | tail -1)"
  AGENT_NAME="${agent:-claude}"
  TURNS_BUDGET="${turns:-80}"
  printf 'agent : %s\nturns : %s\n\n' "$AGENT_NAME" "${turns:-?}"
}

# `|| true` is load-bearing. origin/HEAD is only set by `git clone`, not by
# `git remote add` -- so in a clone built by hand it is absent, symbolic-ref
# exits 1, and under `set -e` the assignment kills the script. With stderr sent
# to /dev/null that failure is completely silent: the run ends at exit 0 having
# implemented the change and opened nothing. Observed on the first real run.
resolve_default_branch() {
  local branch
  branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  printf '%s\n' "${branch:-main}"
}

# Same wrapper the GitHub job uses, same contract: AGENT_CMD <prompt> <result>.
# agent-cmd-claude.sh is review-pr.sh's wrapper: --print with no tool
# permissions. Pointed at an implement prompt it reads the task, cannot write a
# file, and exits 0 having done nothing -- observed on the first real run here.
run_attempt() {
  PROMPT_FILE="$WORK_DIR/prompt.md"
  RESULT_FILE="$WORK_DIR/result.json"
  : > "$RESULT_FILE"
  # build-agent-prompt takes its injected ISSUE_JSON path, so it reads the work
  # item's description and comments without ever calling gh.
  PROMPT_FILE="$PROMPT_FILE" PROMPT_FORGE=azdo bash "$HERE/build-agent-prompt.sh" >/dev/null

  printf 'running the agent (max %s turns)...\n\n' "$TURNS_BUDGET"
  AGENT_RC=0
  SECONDS=0
  MODEL="$MODEL" MAX_TURNS="$TURNS_BUDGET" \
    timeout --kill-after=30s "${IMPLEMENT_TIMEOUT_MIN:-45}m" \
    bash "$HERE/lib/agent-cmd-claude-implement.sh" "$PROMPT_FILE" "$RESULT_FILE" || AGENT_RC=$?
  ATTEMPT_SECONDS="$SECONDS"

  # Empty on a detached HEAD, which is how Azure Pipelines checks out: there is
  # no branch called HEAD to push, report or delete.
  HEAD_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
  ATTEMPT_CLASS="$(classify_attempt "$AGENT_RC" "$RESULT_FILE")"
  printf '\noutcome: %s (agent rc=%s)\n' "$ATTEMPT_CLASS" "$AGENT_RC"
}

# classify-failure.sh is the one pipeline script that was already forge-agnostic.
# No OPENROUTER_API_KEY on purpose: this path runs Claude, whose result carries
# no provider request host, so it can never be out_of_credits and the budget
# check would have nothing to confirm (#521, spec A9).
classify_attempt() {
  local agent_rc="$1" result_file="$2" class
  if [[ "$agent_rc" == 124 || "$agent_rc" == 137 ]]; then
    printf 'transient\n'
    return 0
  fi
  class="$(RESULT_FILE="$result_file" IS_ERROR=false bash "$HERE/classify-failure.sh" 2>/dev/null \
           | sed -n 's/^class=//p' | tail -1)" || class=''
  if [[ -z "$class" || ( "$class" == success && "$agent_rc" != 0 ) ]]; then
    class=bug
  fi
  printf '%s\n' "$class"
}

# `ls-remote` against an https origin needs the same Basic auth as the push, or
# it fails on the server and the "branch left on the server" line never appears.
_azdo_auth_header() {
  printf 'Authorization: Basic %s' "$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 -w0)"
}

remote_branch_exists() {
  git -c http.extraheader="$(_azdo_auth_header)" \
    ls-remote --exit-code --heads origin "refs/heads/$1" >/dev/null 2>&1
}

# Prints the branch's SHA on the server, or nothing when it is absent.
remote_branch_sha() {
  git -c http.extraheader="$(_azdo_auth_header)" \
    ls-remote --heads origin "refs/heads/$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

# push_branch <branch> [<expected-remote-sha>]: with a SHA, overwrite only that
# exact remote state (a stale branch an earlier attempt left behind).
push_branch() {
  local lease=()
  [[ -z "${2:-}" ]] || lease=("--force-with-lease=refs/heads/$1:$2")
  git -c http.extraheader="$(_azdo_auth_header)" push -q -u "${lease[@]}" origin "$1"
}

# Through the adapter, so the work item and the PR are linked -- Azure DevOps
# has no "Closes #N" convention, the --work-items association IS the link.
# Sets PR_ID and returns 0; on failure sets ATTEMPT_ERROR and returns 1.
open_draft_pr() {
  ATTEMPT_ERROR=''
  if [[ -z "$HEAD_BRANCH" || "$HEAD_BRANCH" == "$DEFAULT_BRANCH" ]]; then
    ATTEMPT_ERROR="still on ${HEAD_BRANCH:-a detached HEAD}; the agent did not branch, so there is nothing to PR"
    printf 'error: still on %s — the agent did not branch, so there is nothing to PR.\n' "${HEAD_BRANCH:-a detached HEAD}" >&2
    return 1
  fi

  # The agent must not alter the pipeline definitions that validate its own PR.
  # Any non-zero is fatal: 1 = a pipeline file changed (the guard lists them on
  # stderr), 2 = the diff could not be computed, which fails closed.
  local guard_rc=0 guard_err guard_text
  guard_err="$(mktemp -p "$WORK_DIR")"
  pipeline_file_guard "origin/$DEFAULT_BRANCH" 2>"$guard_err" || guard_rc=$?
  if [[ "$guard_rc" -ne 0 ]]; then
    guard_text="$(tr '\n' ' ' < "$guard_err" | sed 's/  */ /g; s/^ //; s/ $//')"
    if [[ "$guard_rc" -eq 1 ]]; then
      ATTEMPT_ERROR="the agent changed pipeline files: $guard_text"
      printf 'error: the agent changed pipeline files; refusing to push or open a PR:\n' >&2
    else
      ATTEMPT_ERROR="could not verify the agent left pipeline files alone: $guard_text"
      printf 'error: could not verify the agent left pipeline files alone; refusing to push or open a PR.\n' >&2
    fi
    cat "$guard_err" >&2
    return 1
  fi

  # Push unless the server already has exactly our HEAD. A PR cannot be opened
  # against a ref the server has never seen, and "commit but never push" is the
  # single largest measured failure mode in this pipeline. A different remote tip
  # is an earlier attempt's leftover under the same name: replace it, but only
  # that exact state.
  local remote_sha
  remote_sha="$(remote_branch_sha "$HEAD_BRANCH")"
  if [[ "$remote_sha" != "$(git rev-parse HEAD)" ]]; then
    printf 'pushing  : %s (the server does not have this commit)\n' "$HEAD_BRANCH"
    if ! push_branch "$HEAD_BRANCH" "$remote_sha"; then
      ATTEMPT_ERROR="could not push $HEAD_BRANCH"
      printf 'error: could not push %s\n' "$HEAD_BRANCH" >&2
      return 1
    fi
  fi

  if ! PR_ID="$(forge_pr_create_draft "$HEAD_BRANCH" "$DEFAULT_BRANCH" \
        "Implement #${ISSUE_NUMBER}" "Implements work item #${ISSUE_NUMBER}." \
        "$ISSUE_NUMBER")"; then
    PR_ID=''
    ATTEMPT_ERROR='could not open the draft PR'
    printf 'error: could not open the draft PR\n' >&2
    return 1
  fi
  printf 'draft PR  : #%s (work item #%s linked)\n' "$PR_ID" "$ISSUE_NUMBER"
  return 0
}

# --- the per-attempt work-item report ----------------------------------------

report_metrics_line() {
  local result_file="$1" turns cost
  turns="$(jq -r 'if (.num_turns | type) == "number" then .num_turns else empty end' "$result_file" 2>/dev/null)" || turns=''
  cost="$(jq -r 'if (.total_cost_usd | type) == "number" then .total_cost_usd else empty end' "$result_file" 2>/dev/null)" || cost=''
  [[ -n "$turns" ]] || turns=unknown
  if [[ -n "$cost" ]]; then
    cost="$(awk -v v="$cost" 'BEGIN {
      if (v + 0 == 0)        printf "$0.00";
      else if (v + 0 < 0.01) printf "$%.4g", v;
      else                   printf "$%.2f", v;
    }')"
  else
    cost=unknown
  fi
  printf '**Duration:** %ss · **Turns:** %s / cap %s · **Cost:** %s\n' \
    "$ATTEMPT_SECONDS" "$turns" "$TURNS_BUDGET" "$cost"
}

render_report() {
  local outcome="$1" next_line="$2"
  printf '## ai-implement run (%s, Azure DevOps) — attempt %s\n\n' "$RUN_CONTEXT" "$RUN_ATTEMPT"
  printf '**Outcome:** %s\n' "$outcome"
  report_metrics_line "$RESULT_FILE"
  printf -- '- agent: %s, model: %s\n' "$AGENT_NAME" "$MODEL"
  printf -- '- cap: attempt %s of %s\n' "${CAP_ATTEMPT:-?}" "${MAX_ATTEMPTS:-2}"
  [[ -z "$PR_ID" ]] || printf -- '- draft PR: !%s\n' "$PR_ID"
  if [[ "$outcome" == failed* && -n "$HEAD_BRANCH" && "$HEAD_BRANCH" != "$DEFAULT_BRANCH" ]] \
     && remote_branch_exists "$HEAD_BRANCH"; then
    printf -- '- branch left on the server: %s\n' "$HEAD_BRANCH"
  fi
  printf -- '- %s\n' "$next_line"
}

# Appends the report to ISSUE_COMMENTS_JSON even when the post fails (fail
# closed): the attempt cap must count a report the forge never stored.
post_report() {
  local outcome="$1" next_line="$2" report_file body updated
  report_file="$(mktemp -p "$WORK_DIR")"
  render_report "$outcome" "$next_line" > "$report_file"
  if forge_issue_comment "$ISSUE_NUMBER" "$report_file" >/dev/null; then
    printf 'reported  : comment posted on #%s\n' "$ISSUE_NUMBER"
  else
    printf 'warning: could not post the report on #%s\n' "$ISSUE_NUMBER" >&2
  fi
  body="$(cat "$report_file")"
  if updated="$(jq -c --arg b "$body" '. + [{body: $b}]' <<<"${ISSUE_COMMENTS_JSON:-[]}")"; then
    ISSUE_COMMENTS_JSON="$updated"
  fi
  return 0
}

# --- the attempt loop --------------------------------------------------------

# Runs check-attempt-cap.sh against the reports counted so far (post_report
# keeps ISSUE_COMMENTS_JSON current). Returns 0 to proceed, 1 when it parked the
# item; a failure of the script itself stops the run.
check_cap() {
  run_cap_script "$ISSUE_COMMENTS_JSON" 0 || exit 1
  CAP_ATTEMPT="$CAP_SCRIPT_ATTEMPT"
  [[ "$CAP_SCRIPT_PROCEED" == true ]]
}

# Sets CAP_SCRIPT_ATTEMPT / CAP_SCRIPT_PROCEED for the given comments. With
# DRY_RUN=1 the script decides but parks nothing; its chatter is dropped then.
run_cap_script() {
  local comments="$1" dry="$2" out="$WORK_DIR/cap.out" rc=0
  : > "$out"
  if [[ "$dry" == 1 ]]; then
    GITHUB_OUTPUT="$out" REPO="$REPO" ISSUE_COMMENTS_JSON="$comments" DRY_RUN=1 \
      MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}" bash "$HERE/check-attempt-cap.sh" >/dev/null || rc=$?
  else
    GITHUB_OUTPUT="$out" REPO="$REPO" ISSUE_COMMENTS_JSON="$comments" DRY_RUN=0 \
      MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}" bash "$HERE/check-attempt-cap.sh" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf 'error: the attempt cap check failed\n' >&2
    return 1
  fi
  CAP_SCRIPT_ATTEMPT="$(sed -n 's/^attempt=//p' "$out" | tail -1)"
  CAP_SCRIPT_PROCEED="$(sed -n 's/^proceed=//p' "$out" | tail -1)"
}

# Would one more attempt be allowed once the report for the failed one is posted?
# Asks the cap script itself (dry), so the counting rules live in one place.
next_attempt_allowed() {
  local comments
  comments="$(jq -c --arg b "$(render_report "failed: $ATTEMPT_CLASS" 'next: retrying')" \
    '. + [{body: $b}]' <<<"$ISSUE_COMMENTS_JSON")" || return 1
  run_cap_script "$comments" 1 || return 1
  [[ "$CAP_SCRIPT_PROCEED" == true ]]
}

# One retry_policy call, so an unknown class warns once.
decide_retry() {
  local policy
  policy="$(retry_policy "$1" "$2")" || policy=''
  RETRY_DECISION="$(sed -n 's/^decision=//p' <<<"$policy" | tail -1)"
  RETRY_DELAY="$(sed -n 's/^delay=//p' <<<"$policy" | tail -1)"
  [[ "$RETRY_DECISION" == retry ]] || RETRY_DECISION=stop
  [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]] || RETRY_DELAY=0
}

# Back to a clean default branch so the next attempt starts from scratch. A local
# run keeps ignored files (.envrc); a pipeline checkout is disposable.
reset_workspace() {
  local clean_flags=-ffd
  [[ "$(ci_host)" != "pipelines" ]] || clean_flags=-ffdx
  git checkout --force "$DEFAULT_BRANCH" || return 1
  git reset --hard "origin/$DEFAULT_BRANCH" || return 1
  git clean "$clean_flags" || return 1
  if [[ -n "$HEAD_BRANCH" && "$HEAD_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    git branch -D "$HEAD_BRANCH" || return 1
  fi
  return 0
}

finish_success() {
  if ! open_draft_pr; then
    post_report "failed: $ATTEMPT_ERROR" "next: stopping"
    exit 1
  fi
  post_report success "next: review and merge !$PR_ID"
  printf '\nDone. Review and merge !%s when ready.\n' "$PR_ID"
  exit 0
}

exit_parked() {
  printf 'parked: cap reached (attempt %s of %s)\n' "$CAP_ATTEMPT" "${MAX_ATTEMPTS:-2}"
  exit 0
}

# Posts the report for a failed attempt. Returns 0 when another attempt follows,
# 1 when the cap forbids it (the caller parks); exits 1 when the class is final.
report_failed_attempt() {
  decide_retry "$ATTEMPT_CLASS" "$RUN_ATTEMPT"
  if [[ "$RETRY_DECISION" != retry ]]; then
    post_report "failed: $ATTEMPT_CLASS" "next: stopping"
    printf 'Stopping: %s does not retry (or the retry budget is spent).\n' "$ATTEMPT_CLASS" >&2
    exit 1
  fi
  if ! next_attempt_allowed; then
    post_report "failed: $ATTEMPT_CLASS" "next: stopping (attempt cap reached)"
    return 1
  fi
  post_report "failed: $ATTEMPT_CLASS" "next: retrying in ${RETRY_DELAY}s"
}

attempt_loop() {
  RUN_ATTEMPT=1
  while true; do
    check_cap || exit_parked
    printf 'cap   : attempt %s of %s\n' "$CAP_ATTEMPT" "${MAX_ATTEMPTS:-2}"
    classify_issue
    run_attempt
    [[ "$ATTEMPT_CLASS" != success ]] || finish_success
    if ! report_failed_attempt; then
      check_cap && { printf 'error: cap preview and cap check disagree\n' >&2; exit 1; }
      exit_parked
    fi
    sleep "$RETRY_DELAY"
    reset_workspace || { printf 'error: could not reset the workspace; not retrying\n' >&2; exit 1; }
    RUN_ATTEMPT=$((RUN_ATTEMPT + 1))
  done
}

main() {
  preflight
  print_banner
  read_work_item
  WORK_DIR="$(mktemp -d)"
  trap '[[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"' EXIT
  RUN_ATTEMPT=1
  classify_issue

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN=1 — stopping before the agent runs. Nothing was written.\n'
    exit 0
  fi

  DEFAULT_BRANCH="$(resolve_default_branch)"
  attempt_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
