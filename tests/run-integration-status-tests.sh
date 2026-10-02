#!/usr/bin/env bash
#
# run-integration-status-tests.sh — Layer-1 fixture tests for
# scripts/lib/integration-status.sh.
#
# Drives the grading and rendering halves through --from, so no network, no gh
# and no GitHub API are involved — the same seam run-ai-stats-tests.sh uses.
# The collection half (the gh calls that build a record) is Layer 3's job; what
# is worth testing here is the judgement: which findings a given repo state
# produces, and which verdict those findings add up to.
#
# Usage: tests/run-integration-status-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/lib/integration-status.sh"
FIXTURE="$ROOT/tests/fixtures/integration/records.json"

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

section() { printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '    %s%s%s\n' "$C_DIM" "$2" "$C_OFF"
  return 0
}

# Argument order matches run-ai-stats-tests.sh: got, want, name.
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name" "want [$want], got [$got]"; fi
}

assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name" "expected substring not found: $needle"; fi
}

assert_not_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" != *"$needle"* ]]; then pass "$name"
  else fail "$name" "unexpected substring present: $needle"; fi
}

graded="$("$SCRIPT" --from "$FIXTURE" --json)"

# shellcheck source=../scripts/lib/integration-status.sh
source "$SCRIPT"

verdict_of() { jq -r --arg r "$1" '.[] | select(.repo == $r) | .verdict' <<< "$graded"; }
findings_of() { jq -r --arg r "$1" '.[] | select(.repo == $r) | .findings[].code' <<< "$graded"; }
has_finding() {
  findings_of "$1" | grep -qx "$2"
}
assert_finding() {
  if has_finding "$1" "$2"; then pass "$3"
  else fail "$3" "findings were: $(findings_of "$1" | tr '\n' ' ')"; fi
}
assert_no_finding() {
  if has_finding "$1" "$2"; then fail "$3" "findings were: $(findings_of "$1" | tr '\n' ' ')"
  else pass "$3"; fi
}

# --- verdicts ---------------------------------------------------------------

section "verdict per repo"

assert_eq "$(verdict_of freaxnx01/agent-workflow)" "healthy" "a fully wired, in-sync repo is healthy"
assert_eq "$(verdict_of freaxnx01/bridge)" "broken" "an unforwarded secret plus a missing label is broken"
assert_eq "$(verdict_of freaxnx01/flowhub)" "broken" "opencode with no OpenRouter key is broken"
assert_eq "$(verdict_of freaxnx01/widget)" "broken" "ai-merge without auto-merge enabled is broken"
assert_eq "$(verdict_of freaxnx01/notes)" "not-integrated" "neither half present is not-integrated"
assert_eq "$(verdict_of freaxnx01/vault)" "partial" "instructions but no workflow is partial"

# --- the agent-workflow half ------------------------------------------------

section "agent-workflow findings"

# The silent one: a secret exists on the repo but the stub never forwards it,
# so the App stays inert with no error anywhere (PIPELINE-APP-SETUP.md step 7).
assert_finding freaxnx01/bridge secret-not-forwarded \
  "a secret set on the repo but absent from secrets: is reported"
assert_contains "$("$SCRIPT" --from "$FIXTURE" --repo freaxnx01/bridge)" "PIPELINE_APP_ID" \
  "the unforwarded secret is named"
assert_no_finding freaxnx01/agent-workflow secret-not-forwarded \
  "a stub that forwards everything set is clean"

# Applying a label the repo does not have fails the whole gh call atomically,
# so neither label lands and the run never starts.
assert_finding freaxnx01/bridge flow-label-missing \
  "a flow whose label does not exist in the repo is reported"
assert_no_finding freaxnx01/agent-workflow flow-label-missing \
  "a repo carrying its flow label is clean"

assert_finding freaxnx01/flowhub legacy-workflow-name \
  "a legacy claude.yml stub is reported"
assert_finding freaxnx01/flowhub deprecated-flow-spelling \
  "the deprecated pre-preview spelling is reported"
assert_finding freaxnx01/flowhub permissions-incomplete \
  "a permissions block missing actions: write is reported"
assert_finding freaxnx01/flowhub opencode-without-key \
  "agent: opencode with no OPENROUTER_API_KEY is reported"
assert_finding freaxnx01/flowhub pinned-exact-version \
  "an exact-version pin (no moving tag) is reported"

assert_finding freaxnx01/bridge major-drift \
  "a pin left behind by a new major line is reported"
assert_no_finding freaxnx01/widget major-drift \
  "a pin on the current major line is clean"

assert_finding freaxnx01/widget ai-merge-without-auto-merge \
  "an ai-merge repo without allow-auto-merge is reported"
assert_no_finding freaxnx01/bridge ai-merge-without-auto-merge \
  "a human-merge repo does not need auto-merge"

# --- the ai-instructions half -----------------------------------------------

section "ai-instructions findings"

assert_finding freaxnx01/bridge instructions-drifted \
  "a base-instructions blob that differs from upstream is reported"
assert_no_finding freaxnx01/agent-workflow instructions-drifted \
  "matching blobs are not reported as drifted"

assert_finding freaxnx01/flowhub instructions-files-missing \
  "missing copilot-instructions.md / SKILL.md is reported"
assert_no_finding freaxnx01/agent-workflow instructions-files-missing \
  "a complete file set is clean"

# A mismatch cannot distinguish an old sync from a deliberate local edit,
# because nothing records the synced SHA. The wording must not claim it can.
out_bridge="$("$SCRIPT" --from "$FIXTURE" --repo freaxnx01/bridge)"
assert_contains "$out_bridge" "drifted" "a blob mismatch is worded as drifted"
assert_not_contains "$out_bridge" "commits behind" \
  "a blob mismatch does not claim a commit distance it cannot know"

# --- rendering --------------------------------------------------------------

section "report rendering"

all_out="$("$SCRIPT" --from "$FIXTURE")"

assert_contains "$all_out" "freaxnx01/bridge" "an integrated repo gets a row"
assert_contains "$all_out" "claude-sonnet-5" "the model is shown"
assert_contains "$all_out" "ci" "the stack is shown"

# Two-phase grouping: repos with neither half collapse to a count, so a sweep
# over 82 repos is not 69 rows of nothing.
assert_not_contains "$all_out" "freaxnx01/notes" \
  "a not-integrated repo is collapsed out of the default report"
assert_contains "$all_out" "not integrated" "the collapsed group is still counted"
assert_contains "$("$SCRIPT" --from "$FIXTURE" --show-all)" "freaxnx01/notes" \
  "--show-all lists the collapsed repos"

# Broken first: the report is read top-down and the actionable rows are the
# broken ones.
first_repo="$(printf '%s\n' "$all_out" | grep -oE 'freaxnx01/[a-z-]+' | head -1)"
assert_eq "$(verdict_of "$first_repo")" "broken" "the first repo listed is a broken one"

section "limits the report must state about itself"

# A secret can be read as present but never as valid; saying otherwise would
# make an expired token look healthy.
assert_contains "$all_out" "set, not validated" \
  "the report says a present secret was not validated"

section "single-repo and usage"

one_out="$("$SCRIPT" --from "$FIXTURE" --repo freaxnx01/widget)"
assert_contains "$one_out" "freaxnx01/widget" "--repo renders the named repo"
assert_not_contains "$one_out" "freaxnx01/bridge" "--repo renders only the named repo"

rc=0; "$SCRIPT" --nonsense >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "an unknown flag is a usage error"

rc=0; "$SCRIPT" --from "$ROOT/tests/fixtures/integration/nope.json" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a missing --from file is a usage error"

rc=0; "$SCRIPT" --from "$FIXTURE" --repo freaxnx01/absent >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "a --repo absent from the records is its own exit code"

section "stub parsing"

# runner-labels is a quoted JSON array, so a scalar reader that stops at the
# first quote returns "[" and the report shows a bare bracket.
stub_yaml="$(cat <<'YAML'
    with:
      runner-labels: '["self-hosted", "homelab"]'
      agent: claude
      default-model: claude-sonnet-5
      timeout-minutes: 60
YAML
)"
assert_eq "$(yaml_scalar "$stub_yaml" 'runner-labels')" '["self-hosted", "homelab"]' \
  "a quoted JSON array survives scalar extraction"
assert_eq "$(yaml_scalar "$stub_yaml" 'agent')" "claude" "a bare scalar is read"
assert_eq "$(yaml_scalar "$stub_yaml" 'timeout-minutes')" "60" "a numeric scalar is read"

# A trailing comment is not part of the value.
commented="$(printf '      default-model: claude-sonnet-5  # the fleet default\n')"
assert_eq "$(yaml_scalar "$commented" 'default-model')" "claude-sonnet-5" \
  "a trailing comment is stripped"

section "upstream path absent is not drift (#381 discipline)"

# If a file does not exist upstream, its blob SHA comes back empty. Comparing
# that to a real local SHA would report "drifted", which sends the operator to
# re-sync against a file that is not there. Absent and different are not the
# same answer.
absent_up='[{"repo":"o/r","workflow":null,"latest_release":"v3.0.0","secrets_set":[],"labels":[],
  "settings":{"actions_can_create_prs":false,"allow_auto_merge":false,"allow_squash_merge":true},
  "instructions":{"stack":"exotic","files":{"CLAUDE.md":true,".ai/base-instructions.md":true},
  "blobs":{".ai/stacks/exotic.md":{"local":"abc1234","upstream":""}}}}]'
printf '%s' "$absent_up" > "$ROOT/tests/fixtures/integration/upstream-absent.json"
up_json="$("$SCRIPT" --from "$ROOT/tests/fixtures/integration/upstream-absent.json" --json)"
up_codes="$(jq -r '.[0].findings[].code' <<< "$up_json")"
if grep -qx 'instructions-upstream-absent' <<< "$up_codes"; then
  pass "a path missing upstream gets its own finding"
else
  fail "a path missing upstream gets its own finding" "findings were: $(tr '\n' ' ' <<< "$up_codes")"
fi
if grep -qx 'instructions-drifted' <<< "$up_codes"; then
  fail "a path missing upstream is not reported as drifted" "findings were: $(tr '\n' ' ' <<< "$up_codes")"
else
  pass "a path missing upstream is not reported as drifted"
fi

section "permissions parsing tolerates the documented stub"

# Every permission line in the real consumer stub carries a trailing comment
# explaining why it is needed. An anchor that demands end-of-line after
# "write" reports a fully-correct repo as broken — a false positive, which is
# the one failure mode that makes an audit tool worth less than nothing.
commented_perms="$(cat <<'YAML'
permissions:
  contents: write       # caller; the repo's default GITHUB_TOKEN is read-only,
  pull-requests: write  # so omitting this fails the run at startup_failure.
  issues: write
  actions: write        # retry-dispatch.sh re-dispatches THIS workflow
YAML
)"
assert_eq "$(detect_permissions "$commented_perms" | jq -r 'sort | join(",")')" \
  "actions,contents,issues,pull-requests" \
  "permission lines with trailing comments all count"

read_perms="$(printf 'permissions:\n  contents: read\n')"
assert_eq "$(detect_permissions "$read_perms" | jq -r 'length')" "0" \
  "contents: read is not contents: write"

section "a GitHub error body is not data"

# `gh api` prints a 404 body to STDOUT. Passed through, it became the stack
# name in the report: 'stack {"message":"Not Found",...}'.
err_body='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
assert_eq "$(printf '%s' "$err_body" | drop_api_error)" "" \
  "a 404 error object is dropped"
assert_eq "$(printf '%s' '{"sha":"abc123"}' | drop_api_error)" '{"sha":"abc123"}' \
  "a real payload passes through"
assert_eq "$(printf '%s' 'ci' | drop_api_error)" "ci" \
  "a plain non-JSON value passes through"

section "progress never pollutes the data stream"

# --json is a pipe into jq; a progress line on stdout would break it.
assert_eq "$("$SCRIPT" --from "$FIXTURE" --json 2>/dev/null | jq -r 'length')" "6" \
  "--json emits parseable JSON and nothing else"

printf '\n%s──────────%s\n' "$C_DIM" "$C_OFF"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
