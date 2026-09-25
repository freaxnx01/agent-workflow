#!/usr/bin/env bash
#
# run-build-agent-prompt-tests.sh — Layer-1 tests for scripts/build-agent-prompt.sh.
#
# The prompt used to be built inline from `gh issue view --json title,body`, so
# issue COMMENTS never reached the agent — and the implementation contract is
# posted as a comment. Every dispatch ran without it (#393). These tests pin the
# fix: the contract reaches the prompt, and pipeline-generated chatter does not.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/build-agent-prompt.sh"
MOCKS="$HERE/mocks"

PASS=0; FAIL=0; FAIL_NAMES=()

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
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The four comment shapes that actually occur on a dispatched issue (observed
# on #302): a human correction, the enrichment lock, the contract, a run report.
cat > "$tmp/issue.json" <<'JSON'
{
  "title": "fix(runners): something broke",
  "body": "## What\n\nThe thing is broken.\n\n## Implementation Plan\n\n### Task 1: fix it\n",
  "comments": [
    {"body": "## Correction — my root-cause analysis above was wrong\n\nIt is actually the other thing."},
    {"body": "🔒 Enrichment lock acquired at 2026-09-22T16:41:10Z"},
    {"body": "## TDD Required — Non-Negotiable\n\nCommit and push after every task.\nOpen the draft PR after the first task passes."},
    {"body": "## ai-implement run\n\n**Outcome:** :x: failed: error_during_execution\n**Cost:** $7.28"},
    {"body": "🔓 Enrichment lock released at 2026-09-22T17:00:00Z"},
    {"body": "Review held: the review job could not find a pipeline-opened draft PR."}
  ]
}
JSON
printf 'issue view\t%s\n' "$tmp/issue.json" > "$tmp/map.tsv"

build() {
  local out="$tmp/prompt.md"; : > "$out"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$tmp/gh.log" GH_MOCK_STDOUT_MAP="$tmp/map.tsv" \
    ISSUE_NUMBER=42 REPO=o/r PROMPT_FILE="$out" bash "$SCRIPT" >/dev/null 2>&1
  cat "$out"
}

section "required env"

ec=0
out="$(env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$tmp/gh.log" REPO=o/r bash "$SCRIPT" 2>&1)" || ec=$?
assert_equals "$ec" "2"                "missing ISSUE_NUMBER → exit 2"
assert_contains "$out" "ISSUE_NUMBER"  "missing ISSUE_NUMBER → names it"

section "issue body still reaches the agent"

p="$(build)"
assert_contains "$p" "fix(runners): something broke" "prompt carries the title"
assert_contains "$p" "The thing is broken"           "prompt carries the body"
assert_contains "$p" "## Implementation Plan"        "prompt carries the inlined plan"
assert_contains "$p" "Closes #42"                    "prompt still demands the closing reference"

section "the contract now reaches the agent (#393)"

assert_contains "$p" "TDD Required"                         "contract comment is included"
assert_contains "$p" "Commit and push after every task"     "contract's push rule reaches the agent"
assert_contains "$p" "Open the draft PR after the first"    "contract's draft-PR rule reaches the agent"

section "genuine human context is kept"

assert_contains "$p" "Correction — my root-cause analysis"  "human correction is included"
assert_contains "$p" "It is actually the other thing"       "correction body is included"

section "pipeline chatter is dropped"

assert_not_contains "$p" "Enrichment lock acquired"   "enrichment lock is dropped"
assert_not_contains "$p" "Enrichment lock released"   "lock release is dropped"
assert_not_contains "$p" "ai-implement run"           "run report is dropped"
assert_not_contains "$p" "7.28"                       "run report metrics are dropped"
assert_not_contains "$p" "Review held"                "review-held notice is dropped"

section "comments are labelled as instructions, not thread noise"

assert_contains "$p" "Issue comments" "comments arrive under a heading that frames them"

section "an issue with no comments still builds"

cat > "$tmp/bare.json" <<'JSON'
{"title": "bare issue", "body": "nothing else", "comments": []}
JSON
printf 'issue view\t%s\n' "$tmp/bare.json" > "$tmp/map.tsv"
p="$(build)"
assert_contains "$p" "bare issue"         "no comments → title still present"
assert_contains "$p" "Closes #42"         "no comments → instructions still present"
assert_not_contains "$p" "Issue comments" "no comments → no empty comments heading"

section "has-plan output (/ai-stats depends on it)"

build_out() {
  local out="$tmp/prompt.md" gho="$tmp/ghout"; : > "$out"; : > "$gho"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$tmp/gh.log" GH_MOCK_STDOUT_MAP="$tmp/map.tsv" \
    ISSUE_NUMBER=42 REPO=o/r PROMPT_FILE="$out" GITHUB_OUTPUT="$gho" \
    bash "$SCRIPT" >/dev/null 2>&1
  cat "$gho"
}

# The bare fixture (still selected above) has no plan heading.
assert_contains "$(build_out)" "has-plan=false"  "body without a plan → has-plan=false"
assert_contains "$(build_out)" "prompt-file="    "prompt-file output still emitted"

# An enriched body carries the heading.
cat > "$tmp/planned.json" <<'JSON'
{"title": "planned", "body": "intro\n\n## Implementation Plan\n\n### Task 1: go", "comments": []}
JSON
printf 'issue view\t%s\n' "$tmp/planned.json" > "$tmp/map.tsv"
assert_contains "$(build_out)" "has-plan=true"   "body with a plan → has-plan=true"

# A plan heading quoted in a COMMENT must not count as enrichment.
cat > "$tmp/quoted.json" <<'JSON'
{"title": "quoted", "body": "no plan here", "comments": [{"body": "## Implementation Plan\n\n### Task 1: nope"}]}
JSON
printf 'issue view\t%s\n' "$tmp/quoted.json" > "$tmp/map.tsv"
assert_contains "$(build_out)" "has-plan=false"  "plan heading only in a comment → still false"

section "ISSUE_JSON seam — an injected payload skips the gh call (#253)"

# The same seam classify-agent, classify-turns and check-attempt-cap already
# carry. It lets a caller that has already read the issue -- or read it from a
# forge gh does not speak -- hand the result straight in.
seam_dir="$(mktemp -d)"
seam_out="$seam_dir/prompt.md"
seam_log="$seam_dir/gh.log"
: > "$seam_log"

env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$seam_log" \
  ISSUE_JSON='{"title":"Injected title","body":"Injected body.","comments":[]}' \
  ISSUE_NUMBER=42 REPO=o/r PROMPT_FILE="$seam_out" \
  bash "$SCRIPT" >/dev/null 2>&1 || true

assert_contains "$(cat "$seam_out" 2>/dev/null || true)" 'Injected body.' \
  "the injected payload is used"

# The point of the seam is that gh is never reached. A non-empty log means the
# fallback ran anyway, which would defeat the whole purpose on another forge.
if [[ -s "$seam_log" ]]; then
  fail "gh is not called when ISSUE_JSON is set" "gh.log: $(head -1 "$seam_log")"
else
  pass "gh is not called when ISSUE_JSON is set"
fi
rm -rf "$seam_dir"


section "PROMPT_FORGE=azdo — the closing instructions are forge-specific"

# On GitHub the agent opens its own PR and "Closes #N" is what
# find-pipeline-pr.sh keys on. On Azure DevOps neither applies: gh cannot reach
# that forge, there is no Closes-# convention, and implement-azdo.sh opens the PR
# itself -- so telling the agent to open one would either fail or leave a second,
# unlinked PR behind.
fs_dir="$(mktemp -d)"
fs_json='{"title":"T","body":"B","comments":[]}'

env ISSUE_JSON="$fs_json" ISSUE_NUMBER=7 REPO=o/r PROMPT_FILE="$fs_dir/gh.md" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
env ISSUE_JSON="$fs_json" ISSUE_NUMBER=7 REPO=o/r PROMPT_FILE="$fs_dir/az.md" \
  PROMPT_FORGE=azdo bash "$SCRIPT" >/dev/null 2>&1 || true

gh_tail="$(cat "$fs_dir/gh.md" 2>/dev/null || true)"
az_tail="$(cat "$fs_dir/az.md" 2>/dev/null || true)"

assert_contains "$gh_tail" 'Closes #7'          "github keeps the Closes-# phrase"
assert_contains "$gh_tail" 'open a DRAFT pull'  "github asks the agent to open the PR"
assert_not_contains "$az_tail" 'Closes #7'      "azdo drops the Closes-# phrase"
assert_not_contains "$az_tail" 'open a DRAFT pull' "azdo does not ask the agent to open a PR"
assert_contains "$az_tail" 'Do NOT open a pull request yourself' "azdo says who opens it"
assert_contains "$az_tail" 'push the'            "azdo still requires a branch and push"
rm -rf "$fs_dir"


printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
