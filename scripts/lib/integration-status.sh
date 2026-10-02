#!/usr/bin/env bash
#
# integration-status.sh — How a repo is wired into agent-workflow and
# ai-instructions, and whether that wiring will actually work.
#
# Read-only. Fixing is somebody else's job: `onboard-consumer.sh` /
# `/agent-workflow-init` for the pipeline half, the `sync-ai-instructions`
# skill for the instructions half.
#
# Two halves, answered very differently:
#
#   agent-workflow    The consumer stub names its pinned ref, agent, model,
#                     flow and timeouts in plain sight, so the config half is
#                     one file read. What it does NOT show is the repo-side
#                     state a run depends on — secrets, labels, settings —
#                     and that is where runs die silently.
#
#   ai-instructions   Has no tags and no releases, and the sync skill prints
#                     the source SHA without writing it anywhere. A repo
#                     therefore carries no record of what it was synced from.
#                     So "up to date" is answered by comparing git blob SHAs
#                     against upstream `main`: the contents API returns a
#                     blob SHA per file, two files per repo, no downloads.
#
#                     That comparison is exact but it is not a clock. A
#                     mismatch means the bytes differ — an old sync and a
#                     deliberate local edit are indistinguishable. The report
#                     therefore says "drifted", never "N commits behind".
#
# The findings worth the API calls are the silent ones, each of which has cost
# a real run:
#
#   secret-not-forwarded   A secret is set on the repo but the stub's
#                          `secrets:` block never passes it through, so the
#                          App stays inert with no error anywhere
#                          (docs/PIPELINE-APP-SETUP.md step 7).
#   flow-label-missing     `gh issue edit --add-label` is atomic across its
#                          flags: one absent label and NEITHER lands, so the
#                          run never starts and the error names no label.
#   permissions-incomplete A reusable workflow cannot be granted more than its
#                          caller. Missing `actions: write` turns every
#                          retry into a hard failure (CONSUMER-SETUP.md #5).
#   opencode-without-key   classify-agent.sh's credential guard silently falls
#                          back to Claude, so `agent: opencode` looks honoured
#                          while the run is not.
#
# Usage:
#   integration-status.sh                     # the current repo
#   integration-status.sh --repo owner/name   # a named repo (repeatable)
#   integration-status.sh --all               # every non-archived repo under --owner
#   integration-status.sh --show-all          # list the not-integrated repos too
#   integration-status.sh --json              # graded records, no report
#   integration-status.sh --from records.json # grade/render a previous --json dump
#
# Options:
#   --repo <owner/name>  Repo to inspect. Repeatable. Default: the current clone.
#   --all                Every non-archived repo under --owner.
#   --owner <login>      Owner for --all. Default: the authenticated gh user.
#   --show-all           List repos with neither half wired, instead of counting them.
#   --json               Emit graded records as JSON and exit.
#   --from <file>        Skip collection; grade and render <file>.
#   --upstream <o/n>     ai-instructions source. Default: freaxnx01/ai-instructions.
#   --pipeline <o/n>     agent-workflow source. Default: freaxnx01/agent-workflow.
#
# Requires: gh (authenticated), jq.
#
# Exit codes:
#   0  success
#   2  usage error
#   3  missing dependency (gh or jq)
#   4  no matching repo
set -euo pipefail
IFS=$'\n\t'

OWNER=''
SCAN_ALL=0
SHOW_ALL=0
OUTPUT_JSON=0
FROM_FILE=''
UPSTREAM='freaxnx01/ai-instructions'
PIPELINE='freaxnx01/agent-workflow'
COLLECT_JOBS="${COLLECT_JOBS:-4}"
# `wait -n` needs bash 4.3. Probed once rather than per batch, and the absence
# is handled rather than swallowed by a `|| true`.
if (help wait 2>/dev/null | grep -q -- '-n'); then HAVE_WAIT_N=1; else HAVE_WAIT_N=0; fi
REPOS=()

# Secrets the pipeline reads. A secret set on the repo but missing from the
# stub's `secrets:` block is inert, which is the single most common silent
# misconfiguration — hence checking the pair rather than either alone.
#
# These three break the run or the App outright when they are not forwarded.
CRITICAL_SECRETS=(
  CLAUDE_CODE_OAUTH_TOKEN
  PIPELINE_APP_ID
  PIPELINE_APP_PRIVATE_KEY
)

# OPENROUTER_API_KEY is the one conditional case, and it dominates the fleet:
# on a `agent: claude` repo an unforwarded key costs nothing until somebody
# applies a per-issue `agent:opencode` label, at which point the run silently
# becomes a Claude run. Grading that the same as a missing auth token buried
# the repos that are genuinely broken, so it is graded by what it costs.

# A reusable workflow cannot be granted more than its caller grants it.
REQUIRED_PERMISSIONS=(contents pull-requests issues actions)

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-2}"; }

to_json_array() { printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'; }

# --- argument parsing -------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)     [[ -n "${2:-}" ]] || die "--repo needs owner/name"; REPOS+=("$2"); shift 2 ;;
      --all)      SCAN_ALL=1; shift ;;
      --owner)    [[ -n "${2:-}" ]] || die "--owner needs a login"; OWNER="$2"; shift 2 ;;
      --show-all) SHOW_ALL=1; shift ;;
      --json)     OUTPUT_JSON=1; shift ;;
      --from)     [[ -n "${2:-}" ]] || die "--from needs a file"; FROM_FILE="$2"; shift 2 ;;
      --upstream) [[ -n "${2:-}" ]] || die "--upstream needs owner/name"; UPSTREAM="$2"; shift 2 ;;
      --pipeline) [[ -n "${2:-}" ]] || die "--pipeline needs owner/name"; PIPELINE="$2"; shift 2 ;;
      -h|--help)  sed -n '2,76p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *)          die "unknown option: $1" ;;
    esac
  done
}

validate_args() {
  if [[ -n "$OWNER" ]] && (( ! SCAN_ALL )); then
    die "--owner only applies with --all"
  fi
  if [[ -n "$FROM_FILE" ]] && (( SCAN_ALL )); then
    die "--all and --from are mutually exclusive (--from renders an existing dump)"
  fi
}

require_deps() {
  command -v jq >/dev/null 2>&1 || die "jq is required" 3
  [[ -n "$FROM_FILE" ]] && return 0
  command -v gh >/dev/null 2>&1 || die "gh is required" 3
}

# --- collection -------------------------------------------------------------
#
# Every gh call here is read-only and tolerant: a repo the token cannot see is
# reported as unreadable rather than silently graded on missing data.

drop_api_error() {
  local body; body="$(cat)"
  # A GitHub error object carries .message and .status and never a payload we
  # asked for. Non-JSON (a --jq scalar) passes through untouched.
  if jq -e 'type == "object" and has("message") and has("status")' >/dev/null 2>&1 <<< "$body"; then
    return 0
  fi
  printf '%s' "$body"
}

# One definition of "transient" in this repo: gh-retry.sh already encodes the
# secondary-rate-limit and 5xx signatures, so this sources it rather than
# growing a second list that drifts.
# shellcheck source=gh-retry.sh
source "$(dirname "${BASH_SOURCE[0]}")/gh-retry.sh"

api_failure_kind() {
  local text="$1"
  if grep -qiE 'HTTP 404|Not Found' <<< "$text"; then printf 'absent\n'; return 0; fi
  if gh_retryable "$text"; then printf 'transient\n'; return 0; fi
  printf 'fatal\n'
}

# Echoes the payload. Return: 0 found, 1 genuinely absent, 2 unreadable.
#
# Reading a failure as absence is the bug this guards against: at 8-way
# concurrency GitHub's secondary rate limit turned 18 wired repos into
# "not integrated" with no error anywhere.
gh_json() {
  local attempt=1 max="${GH_RETRY_MAX:-3}" body err ec kind
  err="$(mktemp)"
  # shellcheck disable=SC2064  # expand err now, on function return
  trap "rm -f '$err'" RETURN
  while :; do
    ec=0
    body="$(gh api "$@" 2>"$err")" || ec=$?
    if (( ec == 0 )); then
      printf '%s' "$(drop_api_error <<< "$body")"
      return 0
    fi
    kind="$(api_failure_kind "$(cat "$err")")"
    case "$kind" in
      absent) return 1 ;;
      fatal)  return 2 ;;
      transient)
        if (( attempt >= max )); then return 2; fi
        "${GH_RETRY_SLEEP_CMD:-sleep}" "$(( ${GH_RETRY_BASE_SLEEP:-2} * attempt ))"
        attempt=$((attempt + 1))
        ;;
    esac
  done
}

# Echoes the blob SHA. Return mirrors gh_json: 0 found, 1 absent, 2 unreadable.
blob_sha() {
  local repo="$1" path="$2" out ec=0
  out="$(gh_json "repos/$repo/contents/$path" --jq '.sha // empty')" || ec=$?
  printf '%s' "$out"
  return "$ec"
}

resolve_repos() {
  if (( SCAN_ALL )); then
    [[ -n "$OWNER" ]] || OWNER="$(gh api user --jq .login)"
    gh repo list "$OWNER" --limit 500 --no-archived --json nameWithOwner \
      --jq '.[].nameWithOwner'
    return 0
  fi
  if (( ${#REPOS[@]} )); then
    printf '%s\n' "${REPOS[@]}"
    return 0
  fi
  gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null \
    || die "no repo given and the current directory is not a GitHub clone" 4
}

# Phase 1. One cheap probe per repo, so a sweep over an owner's whole account
# does not pay for deep checks on repos that were never wired up.
probe_repo() {
  local repo="$1" agent_yml claude_yml='' base_sha ec unreadable=false
  agent_yml="$(blob_sha "$repo" '.github/workflows/agent.yml')" && ec=0 || ec=$?
  (( ec == 2 )) && unreadable=true
  if [[ -z "$agent_yml" ]]; then
    claude_yml="$(blob_sha "$repo" '.github/workflows/claude.yml')" && ec=0 || ec=$?
    (( ec == 2 )) && unreadable=true
  fi
  base_sha="$(blob_sha "$repo" '.ai/base-instructions.md')" && ec=0 || ec=$?
  (( ec == 2 )) && unreadable=true
  jq -nc --arg repo "$repo" --arg a "$agent_yml" --arg c "$claude_yml" --arg b "$base_sha" \
    --argjson unreadable "$unreadable" \
    '{repo: $repo, unreadable: $unreadable,
      workflow_file: (if $a != "" then "agent.yml" elif $c != "" then "claude.yml" else null end),
      base_sha: $b}'
}

workflow_text() {
  local repo="$1" file="$2" b64 ec=0
  b64="$(gh_json "repos/$repo/contents/.github/workflows/$file" --jq '.content // empty')" || ec=$?
  printf '%s' "$b64" | tr -d '\n' | base64 -d 2>/dev/null || true
  return "$ec"
}

# The stub's values are plain scalars, so grep reads them without a YAML
# parser. Anything it cannot find comes back empty and is rendered as "?"
# rather than guessed at.
yaml_scalar() {
  local text="$1" key="$2" line value
  line="$(printf '%s\n' "$text" | grep -m1 -E "^[[:space:]]*${key}:" || true)"
  [[ -n "$line" ]] || return 0
  value="${line#*:}"
  value="${value#"${value%%[![:space:]]*}"}"
  case "$value" in
    # A quoted value keeps everything up to its closing quote, so a JSON array
    # like '["self-hosted", "homelab"]' survives intact.
    \'*) value="${value#\'}"; value="${value%%\'*}" ;;
    \"*) value="${value#\"}"; value="${value%%\"*}" ;;
    *)  value="${value%%#*}"; value="${value%"${value##*[![:space:]]}"}" ;;
  esac
  printf '%s\n' "$value"
}

yaml_flag_true() {
  local text="$1" key="$2"
  printf '%s\n' "$text" | grep -qE "^[[:space:]]*${key}:[[:space:]]*['\"]?true['\"]?([[:space:]]|#|$)"
}

detect_flow() {
  local text="$1"
  yaml_flag_true "$text" 'ai-review-ai-merge'   && { printf 'ai-review-ai-merge\n'; return; }
  yaml_flag_true "$text" 'ai-review-human-merge' && { printf 'ai-review-human-merge\n'; return; }
  yaml_flag_true "$text" 'pre-preview'           && { printf 'pre-preview\n'; return; }
  printf 'draft-only\n'
}

detect_ref() {
  local text="$1" uses
  uses="$(printf '%s\n' "$text" | grep -oE 'uses:[[:space:]]*\./[^[:space:]]*' | head -1)"
  [[ -n "$uses" ]] && { printf 'local\n'; return; }
  printf '%s\n' "$text" \
    | grep -oE 'uses:[[:space:]]*[^[:space:]]+/\.github/workflows/agent-implement\.yml@[^[:space:]]+' \
    | head -1 | sed -e 's/.*@//' -e 's/["'"'"']*$//'
}

detect_permissions() {
  local text="$1" p out=()
  for p in "${REQUIRED_PERMISSIONS[@]}"; do
    if printf '%s\n' "$text" | grep -qE "^[[:space:]]*${p}:[[:space:]]*write([[:space:]]|#|$)"; then
      out+=("$p")
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))'
}

detect_forwarded_secrets() {
  # `secrets: inherit` passes everything through without naming anything, so
  # it matches no ${{ secrets.X }} and used to read as "forwards nothing" —
  # three false broken findings on every repo using the documented pattern.
  if printf '%s\n' "$1" | grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*(#|$)'; then
    printf '["*"]'
    return 0
  fi
  printf '%s\n' "$1" | grep -oE '\$\{\{[[:space:]]*secrets\.[A-Z_]+' \
    | sed 's/.*secrets\.//' | sort -u | jq -R . | jq -sc 'map(select(. != ""))'
}

# Each reader echoes a usable value AND returns gh_json's status, so the
# caller can tell "this repo has no secrets" from "I could not read them".
# Folding rc=2 into an empty default is what made a 403 render as four
# fabricated findings and a `broken` verdict.
repo_secrets() {
  local out ec=0
  out="$(gh_json "repos/$1/actions/secrets" --jq '[.secrets[].name]')" || ec=$?
  printf '%s' "${out:-[]}"
  return "$ec"
}

repo_labels() {
  local out ec=0
  out="$(gh_json "repos/$1/labels?per_page=100" --jq '[.[].name]')" || ec=$?
  printf '%s' "${out:-[]}"
  return "$ec"
}

repo_settings() {
  local repo="$1" meta perms ec=0 e=0
  meta="$(gh_json "repos/$repo" --jq '{allow_auto_merge, allow_squash_merge}')" || e=$?
  (( e > ec )) && ec=$e
  e=0
  perms="$(gh_json "repos/$repo/actions/permissions/workflow" \
    --jq '.can_approve_pull_request_reviews // false')" || e=$?
  (( e > ec )) && ec=$e
  jq -nc --argjson m "${meta:-{\}}" --argjson p "${perms:-false}" \
    '{allow_auto_merge: ($m.allow_auto_merge // false),
      allow_squash_merge: ($m.allow_squash_merge // false),
      actions_can_create_prs: $p}'
  return "$ec"
}

instructions_of() {
  local repo="$1" stack base_local base_up stack_path='' stack_local='' stack_up=''
  local ec=0 e=0
  # Not a pipeline: a pipeline's exit status is sed's, so gh_json's would be
  # silently discarded.
  e=0; stack="$(gh_json "repos/$repo/contents/.ai/stacks" --jq '[.[].name][0] // empty')" || e=$?
  (( e == 2 )) && ec=2
  stack="${stack%.md}"
  e=0; base_local="$(blob_sha "$repo" '.ai/base-instructions.md')" || e=$?
  (( e == 2 )) && ec=2
  e=0; base_up="$(blob_sha "$UPSTREAM" '.ai/base-instructions.md')" || e=$?
  (( e == 2 )) && ec=2
  if [[ -n "$stack" ]]; then
    stack_path=".ai/stacks/$stack.md"
    e=0; stack_local="$(blob_sha "$repo" "$stack_path")" || e=$?
    (( e == 2 )) && ec=2
    e=0; stack_up="$(blob_sha "$UPSTREAM" "$stack_path")" || e=$?
    (( e == 2 )) && ec=2
  fi
  # Every one of these is guarded. blob_sha returns 1 for a file that is
  # simply absent — which most repos are, for SKILL.md and
  # copilot-instructions.md — and an unguarded assignment under `set -e`
  # kills the whole collection job for that repo. That produced an empty
  # shard, and 30 of 82 repos came back "unreadable" on the first fleet run
  # after the status contract was introduced.
  local claude copilot skill
  e=0; claude="$(blob_sha "$repo" 'CLAUDE.md')" || e=$?
  (( e == 2 )) && ec=2
  e=0; copilot="$(blob_sha "$repo" '.github/copilot-instructions.md')" || e=$?
  (( e == 2 )) && ec=2
  e=0; skill="$(blob_sha "$repo" 'SKILL.md')" || e=$?
  (( e == 2 )) && ec=2
  jq -nc \
    --arg stack "$stack" --arg sp "$stack_path" \
    --arg bl "$base_local" --arg bu "$base_up" \
    --arg sl "$stack_local" --arg su "$stack_up" \
    --arg c "$claude" --arg co "$copilot" --arg sk "$skill" '
    {
      stack: (if $stack == "" then null else $stack end),
      files: ({
        "CLAUDE.md": ($c != ""),
        ".ai/base-instructions.md": ($bl != ""),
        ".github/copilot-instructions.md": ($co != ""),
        "SKILL.md": ($sk != "")
      } + (if $sp == "" then {} else {($sp): ($sl != "")} end)),
      blobs: ((if $bl == "" then {} else {".ai/base-instructions.md": {local: $bl, upstream: $bu}} end)
            + (if $sp == "" or $sl == "" then {} else {($sp): {local: $sl, upstream: $su}} end))
    }'
  return "$ec"
}

latest_release() {
  gh_json "repos/$PIPELINE/releases/latest" --jq '.tag_name // empty'
}

collect_repo() {
  local repo="$1" probe="$2" release="$3" wf_file text wf_ec=0
  wf_file="$(jq -r '.workflow_file // empty' <<< "$probe")"
  local workflow='null'
  if [[ -n "$wf_file" ]]; then
    text="$(workflow_text "$repo" "$wf_file")" || wf_ec=$?
    workflow="$(jq -nc \
      --arg file "$wf_file" \
      --arg ref "$(detect_ref "$text")" \
      --arg agent "$(yaml_scalar "$text" 'agent')" \
      --arg model "$(yaml_scalar "$text" 'default-model')" \
      --arg flow "$(detect_flow "$text")" \
      --arg sfmi "$(yaml_scalar "$text" 'self-fix-max-iterations')" \
      --arg tm "$(yaml_scalar "$text" 'timeout-minutes')" \
      --arg ctm "$(yaml_scalar "$text" 'claude-timeout-minutes')" \
      --arg rl "$(yaml_scalar "$text" 'runner-labels')" \
      --argjson selffix "$(yaml_flag_true "$text" 'self-fix' && printf true || printf false)" \
      --argjson perms "$(detect_permissions "$text")" \
      --argjson fwd "$(detect_forwarded_secrets "$text")" '
      {file: $file, ref: $ref, agent: $agent, model: $model, flow: $flow,
       self_fix: $selffix,
       self_fix_max_iterations: (if $sfmi == "" then null else ($sfmi | tonumber?) end),
       timeout_minutes: (if $tm == "" then null else ($tm | tonumber?) end),
       claude_timeout_minutes: (if $ctm == "" then null else ($ctm | tonumber?) end),
       runner_labels: $rl, permissions: $perms, secrets_forwarded: $fwd}')"
  fi
  # Each read reports separately whether it succeeded; one unreadable read
  # makes the whole record unreadable, because a verdict computed from data
  # that was never read is worse than no verdict.
  local unreadable e=0 secrets labels settings instructions
  unreadable="$(jq -r '.unreadable // false' <<< "$probe")"
  (( wf_ec == 2 )) && unreadable=true
  e=0; secrets="$(repo_secrets "$repo")" || e=$?;         (( e == 2 )) && unreadable=true
  e=0; labels="$(repo_labels "$repo")" || e=$?;           (( e == 2 )) && unreadable=true
  e=0; settings="$(repo_settings "$repo")" || e=$?;       (( e == 2 )) && unreadable=true
  e=0; instructions="$(instructions_of "$repo")" || e=$?; (( e == 2 )) && unreadable=true

  jq -nc \
    --arg repo "$repo" \
    --arg release "$release" \
    --argjson unreadable "$unreadable" \
    --argjson workflow "$workflow" \
    --argjson secrets "${secrets:-[]}" \
    --argjson labels "${labels:-[]}" \
    --argjson settings "${settings:-{\}}" \
    --argjson instructions "${instructions:-{\}}" '
    {repo: $repo, unreadable: $unreadable, workflow: $workflow, latest_release: $release,
     secrets_set: $secrets, labels: $labels, settings: $settings,
     instructions: $instructions}'
}

# Collection renders nothing until it finishes, and a sweep over an owner's
# whole account takes minutes. Progress goes to stderr so --json stays a clean
# pipe and the operator still sees the thing is alive.
progress() { printf '%s\n' "$*" >&2; }

collect_one() {
  local repo="$1" release="$2" probe
  probe="$(probe_repo "$repo")"
  # Phase 1 shortcut: neither half wired, so skip the ~8 deep calls.
  if [[ "$(jq -r '.workflow_file // ""' <<< "$probe")" == "" \
     && "$(jq -r '.base_sha // ""' <<< "$probe")" == "" ]]; then
    jq -nc --arg repo "$repo" --arg release "$release" \
      --argjson unreadable "$(jq -r '.unreadable // false' <<< "$probe")" '
      {repo: $repo, unreadable: $unreadable, workflow: null, latest_release: $release,
       secrets_set: [], labels: [],
       settings: {actions_can_create_prs: false, allow_auto_merge: false, allow_squash_merge: false},
       instructions: {stack: null, files: {}, blobs: {}}}'
    return 0
  fi
  collect_repo "$repo" "$probe" "$release"
}

# Shards are named by input position, so the merge is deterministic however
# the jobs finish. An empty shard (a repo whose collection produced nothing)
# is skipped rather than becoming a null record.
merge_records() {
  # jq -s already yields [] for empty input; the `|| true` is only so a
  # no-match glob does not trip pipefail.
  { cat "$1"/*.json 2>/dev/null || true; } | jq -sc '.'
}

# Every requested repo must appear exactly once. A shard that is empty or not
# valid JSON means its job died; that repo becomes an unreadable record rather
# than silently disappearing from the report.
reconcile_shards() {
  local dir="$1"; shift
  local repos=("$@") i=0 repo shard out=()
  for repo in "${repos[@]}"; do
    i=$((i + 1))
    shard="$dir/$(printf '%05d' "$i").json"
    if [[ -s "$shard" ]] && jq -e . "$shard" >/dev/null 2>&1; then
      out+=("$(cat "$shard")")
    else
      out+=("$(jq -nc --arg repo "$repo" '
        {repo: $repo, unreadable: true, workflow: null, latest_release: "",
         secrets_set: [], labels: [],
         settings: {actions_can_create_prs: false, allow_auto_merge: false, allow_squash_merge: false},
         instructions: {stack: null, files: {}, blobs: {}}}')")
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}" | jq -sc .
}

collect() {
  local release repos=() repo total i=0 running=0 dir
  release="$(latest_release)"
  mapfile -t repos < <(resolve_repos)
  total="${#repos[@]}"
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand dir now, on function return
  trap "rm -rf '$dir'" RETURN

  # Serially this was ~10 gh calls per repo and 9 minutes over 82 repos, with
  # nothing rendered until the end. The calls are independent and read-only,
  # so they fan out; COLLECT_JOBS caps the fan-out well under the API's
  # concurrency tolerance.
  if (( total > 1 )); then
    progress "scanning $total repos, $COLLECT_JOBS at a time…"
  fi

  for repo in "${repos[@]}"; do
    i=$((i + 1))
    {
      collect_one "$repo" "$release" > "$dir/$(printf '%05d' "$i").json"
      if (( total > 1 )); then progress "  ✓ $repo"; fi
    } &
    running=$((running + 1))
    if (( running >= COLLECT_JOBS )); then
      if (( HAVE_WAIT_N )); then
        wait -n 2>/dev/null || true
        running=$((running - 1))
      else
        # Without `wait -n` the only way to bound the fan-out is to drain the
        # whole batch. Slower, but silently degrading to no throttling at all
        # over ~80 repos is what trips the secondary rate limit.
        wait
        running=0
      fi
    fi
  done
  wait

  reconcile_shards "$dir" "${repos[@]}"
}

# --- grading ----------------------------------------------------------------
#
# Pure: records in, findings and a verdict out. Everything the tests exercise
# lives here, which is why collection stays as thin as it does.

# shellcheck disable=SC2016  # $foo inside are jq variables, not shell expansions
GRADE_JQ='
def major(ref): (ref | capture("^v(?<n>[0-9]+)") | .n // empty);

def finding(code; sev; text): {code: code, severity: sev, text: text};

def grade_workflow(r):
  (r.workflow) as $w
  | if $w == null then []
    else
      [
        # --- broken: the run will not start, or will not do what it says ---
        ( (if (($w.secrets_forwarded // []) | index("*")) then []
           else (r.secrets_set // []) - ($w.secrets_forwarded // []) end)
          | map(select(. as $s | $critical_secrets | index($s)))
          | if length > 0
            then finding("secret-not-forwarded"; "broken";
                 "set on the repo but not forwarded in secrets:: " + join(", "))
            else empty end ),

        ( if ((($w.secrets_forwarded // []) | index("*")) | not)
             and (((r.secrets_set // []) - ($w.secrets_forwarded // [])) | index("OPENROUTER_API_KEY"))
          then finding("openrouter-not-forwarded";
               (if $w.agent == "opencode" then "broken" else "degraded" end);
               (if $w.agent == "opencode"
                then "agent: opencode, but OPENROUTER_API_KEY is set on the repo and not forwarded — the run falls back to Claude silently"
                else "OPENROUTER_API_KEY is set on the repo but not forwarded; a per-issue agent:opencode label would silently run Claude" end))
          else empty end ),

        ( if (r.secrets_set // []) | index("CLAUDE_CODE_OAUTH_TOKEN") then empty
          else finding("auth-secret-missing"; "broken";
               "CLAUDE_CODE_OAUTH_TOKEN is not set on the repo") end ),

        ( if ($w.agent == "opencode") and (((r.secrets_set // []) | index("OPENROUTER_API_KEY")) == null)
          then finding("opencode-without-key"; "broken";
               "agent: opencode with no OPENROUTER_API_KEY — classify-agent.sh falls back to Claude silently")
          else empty end ),

        ( if ((r.labels // []) | index("ai-implement")) == null
          then finding("implement-label-missing"; "broken";
               "the ai-implement label does not exist in this repo")
          else empty end ),

        ( if ($w.flow | test("^ai-review-")) and (((r.labels // []) | index($w.flow)) == null)
          then finding("flow-label-missing"; "broken";
               "flow is " + $w.flow + " but that label does not exist — gh issue edit is atomic, so neither label lands")
          else empty end ),

        ( $required_permissions - ($w.permissions // [])
          | if length > 0
            then finding("permissions-incomplete"; "broken";
                 "permissions: missing " + join(", "))
            else empty end ),

        ( if (r.settings.actions_can_create_prs // false) then empty
          else finding("actions-cannot-create-prs"; "broken";
               "\"Allow GitHub Actions to create and approve pull requests\" is off") end ),

        ( if ($w.flow == "ai-review-ai-merge") and ((r.settings.allow_auto_merge // false) | not)
          then finding("ai-merge-without-auto-merge"; "broken";
               "flow is ai-review-ai-merge but allow-auto-merge is off")
          else empty end ),

        ( if ($w.flow == "ai-review-ai-merge") and ((r.settings.allow_squash_merge // false) | not)
          then finding("ai-merge-without-squash"; "broken";
               "flow is ai-review-ai-merge but allow-squash-merge is off — the pipeline squash-merges")
          else empty end ),

        # --- degraded: it runs, but not as intended ---
        ( if $w.file == "claude.yml"
          then finding("legacy-workflow-name"; "degraded";
               "stub is still named claude.yml — retry and chain dispatch target agent.yml, so retries 404")
          else empty end ),

        ( if $w.flow == "pre-preview"
          then finding("deprecated-flow-spelling"; "degraded";
               "pre-preview is the deprecated spelling of ai-review-human-merge")
          else empty end ),

        ( if ($w.ref | test("^v[0-9]+$")) and (r.latest_release != null) and (r.latest_release != "")
             and (major($w.ref) != major(r.latest_release))
          then finding("major-drift"; "degraded";
               "pinned " + $w.ref + " but the current line is " + r.latest_release + " — the moving tag never crosses majors")
          else empty end ),

        ( if ($w.ref | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
          then finding("pinned-exact-version"; "degraded";
               "pinned to the exact version " + $w.ref + ", so it receives no patches")
          else empty end )
      ]
    end;

def grade_instructions(r):
  (r.instructions) as $i
  | ( [ $i.blobs // {} | to_entries[] | select(.value.upstream != "" and .value.local != .value.upstream) | .key ] ) as $drifted
  | ( [ $i.blobs // {} | to_entries[] | select(.value.upstream == "") | .key ] ) as $upstream_absent
  | ( [ $i.files // {} | to_entries[] | select(.value == false) | .key ] ) as $missing
  | ( if ($i.files // {} | length) == 0 or (($i.files // {}) | to_entries | map(.value) | any) == false
      then [ finding("instructions-absent"; "degraded"; "no ai-instructions files in this repo") ]
      else
        [ ( if ($drifted | length) > 0
            then finding("instructions-drifted"; "degraded";
                 "drifted from upstream: " + ($drifted | join(", ")))
            else empty end ),
          ( if ($missing | length) > 0
            then finding("instructions-files-missing"; "degraded";
                 "not synced: " + ($missing | join(", ")))
            else empty end ),
          ( if ($upstream_absent | length) > 0
            then finding("instructions-upstream-absent"; "degraded";
                 "present here but not upstream, so there is nothing to compare against: "
                 + ($upstream_absent | join(", ")))
            else empty end ) ]
      end );

map(
  . as $r
  # An unreadable repo gets exactly one finding. Grading the rest would mean
  # reporting conclusions drawn from data that was never read — which is how a
  # 403 on actions/secrets produced four confident, fabricated findings.
  | (if ($r.unreadable // false)
     then [ finding("probe-unreadable"; "broken";
            "one or more API reads failed after retries — this repo was not graded, it was not read") ]
     else grade_workflow($r)
          + (if $r.workflow == null and (($r.instructions.files // {} | to_entries | map(.value) | any) == false)
             then [] else grade_instructions($r) end)
     end) as $findings
  | $r + {
      findings: $findings,
      verdict: (
        if ($r.unreadable // false) then "unreadable"
        elif $r.workflow == null then
          (if ($r.instructions.files // {} | to_entries | map(.value) | any) then "partial" else "not-integrated" end)
        elif ($findings | map(select(.severity == "broken")) | length) > 0 then "broken"
        elif ($findings | length) > 0 then "degraded"
        else "healthy" end)
    }
)
'

# The two lists the grader judges against are the shell arrays above, passed in
# rather than restated in jq — one definition, so adding a secret to the
# pipeline cannot leave the audit silently checking the old set.
grade() {
  jq \
    --argjson critical_secrets "$(to_json_array "${CRITICAL_SECRETS[@]}")" \
    --argjson required_permissions "$(to_json_array "${REQUIRED_PERMISSIONS[@]}")" \
    "$GRADE_JQ"
}

# --- rendering --------------------------------------------------------------

VERDICT_ORDER='{"unreadable":0,"broken":1,"degraded":2,"partial":3,"healthy":4,"not-integrated":5}'

render() {
  local graded="$1"
  local shown
  shown="$(jq -c --argjson order "$VERDICT_ORDER" \
    'map(select(.verdict != "not-integrated")) | sort_by($order[.verdict])' <<< "$graded")"

  printf '# agent-workflow + ai-instructions integration\n\n'

  local i count
  count="$(jq 'length' <<< "$shown")"
  if (( count == 0 )); then
    printf 'No repo has either half wired up.\n\n'
  fi
  for (( i = 0; i < count; i++ )); do
    render_repo "$(jq -c ".[$i]" <<< "$shown")"
  done

  render_not_integrated "$graded"
  render_caveats
}

render_repo() {
  local rec="$1"
  jq -r '
    def dash(v): if v == null or v == "" then "—" else (v | tostring) end;
    "## " + .repo + "  ·  " + (.verdict | ascii_upcase) + "\n" +
    (if .workflow == null then "- pipeline: not wired\n"
     else
       "- pipeline: " + .workflow.file + " @ " + dash(.workflow.ref) +
         (if (.latest_release // "") != "" then "  (latest " + .latest_release + ")" else "" end) + "\n" +
       "- agent: " + dash(.workflow.agent) + " / " + dash(.workflow.model) +
         "  ·  flow: " + dash(.workflow.flow) + "\n" +
       "- self-fix: " + (if .workflow.self_fix then "on ×" + dash(.workflow.self_fix_max_iterations) else "off" end) +
         "  ·  timeout: " + (if .workflow.timeout_minutes == null then "—" else (.workflow.timeout_minutes | tostring) + "m" end) +
         (if .workflow.claude_timeout_minutes != null then " (agent " + dash(.workflow.claude_timeout_minutes) + "m)" else "" end) +
         "  ·  runners: " + dash(.workflow.runner_labels) + "\n"
     end) +
    "- instructions: stack " + dash(.instructions.stack) +
      "  ·  " + ((.instructions.blobs // {}) | to_entries
                 | map(.key + " " + (if .value.local == .value.upstream then "in sync" else "drifted" end))
                 | if length == 0 then "none" else join("  ·  ") end) + "\n" +
    (if (.findings | length) == 0 then "- findings: none\n"
     else (.findings | map("- " + (if .severity == "broken" then "✗" else "!" end) + " " + .code + ": " + .text) | join("\n")) + "\n"
     end)
  ' <<< "$rec"
  printf '\n'
}

render_not_integrated() {
  local graded="$1" names count
  names="$(jq -r 'map(select(.verdict == "not-integrated") | .repo) | .[]' <<< "$graded")"
  count="$(jq '[.[] | select(.verdict == "not-integrated")] | length' <<< "$graded")"
  (( count == 0 )) && return 0
  if (( SHOW_ALL )); then
    printf '## not integrated (%d)\n\n' "$count"
    printf '%s\n' "$names" | sed 's/^/- /'
  else
    printf '## not integrated (%d)\n\n' "$count"
    printf 'Neither half wired. Pass --show-all to list them.\n'
  fi
  printf '\n'
}

render_caveats() {
  cat <<'EOF'
## What this report cannot tell you

- A secret is read as **set, not validated** — an expired CLAUDE_CODE_OAUTH_TOKEN
  reads exactly like a working one.
- An instructions mismatch is **drifted**, not stale. Nothing records the SHA a
  repo was synced from, so an old sync and a deliberate local edit are
  indistinguishable by content alone.
EOF
}

# --- main -------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args
  require_deps

  local records graded
  if [[ -n "$FROM_FILE" ]]; then
    [[ -f "$FROM_FILE" ]] || die "no such file: $FROM_FILE"
    records="$(cat "$FROM_FILE")"
    # --repo filters a dump as well as a live scan, so one collection can be
    # re-read per repo without paying for it again.
    if (( ${#REPOS[@]} )); then
      records="$(jq -c --argjson want "$(printf '%s\n' "${REPOS[@]}" | jq -R . | jq -sc .)" \
        'map(select(.repo as $r | $want | index($r)))' <<< "$records")"
      [[ "$(jq 'length' <<< "$records")" -gt 0 ]] || die "no matching repo in $FROM_FILE" 4
    fi
  else
    records="$(collect)"
  fi

  graded="$(grade <<< "$records")"

  if (( OUTPUT_JSON )); then
    jq . <<< "$graded"
    return 0
  fi
  render "$graded"
}

# Sourced by tests/run-integration-status-tests.sh to exercise the parsers
# directly; only a direct invocation collects anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
