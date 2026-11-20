#!/usr/bin/env bash
#
# run-migrate-guard-tests.sh — Layer-1 tests for the backlog guard rollout
# (#653): scripts/lib/milestone-stub.sh, the milestone queries in
# scripts/lib/backlog-milestone.sh and
# `scripts/migrate-consumers.sh --add-milestone-guard`. gh is mocked; no
# network.
#
# Usage: tests/run-migrate-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/migrate-guard"
MOCKS="$ROOT/tests/mocks"
MIGRATE="$ROOT/scripts/migrate-consumers.sh"

unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY REPO

PASS=0
FAIL=0
FAIL_NAMES=()

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}
section() { printf '\n── %s ──\n' "$1"; }
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "missing: $3 | in: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "unexpected: $3 | in: $2"; fi
}

section "milestone stub — one source for onboarding and the rollout"

# shellcheck disable=SC1091
stub="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml freaxnx01/agent-workflow v2)"

assert_contains "calls the reusable workflow at the given ref" "$stub" \
  'uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2'
assert_contains "checks out the scripts at the same ref" "$stub" '      pipeline-ref: v2'
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains "passes only the issue number, unexpanded" "$stub" \
  'issue-number: ${{ github.event.issue.number }}'
assert_contains "runs on opened and reopened" "$stub" 'types: [opened, reopened]'
assert_contains "the calling job may set the milestone" "$stub" '      issues: write'
assert_not_contains "never writes code" "$stub" 'contents: write'

# The ref is a parameter, not the sourcing script's environment: the rollout
# writes the stub at whatever ref the consumer already pins.
# shellcheck disable=SC1091
other="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml o/p v2.4.1)"
assert_contains "the pipeline repo is a parameter" "$other" 'uses: o/p/.github/workflows/backlog-milestone.yml@v2.4.1'
assert_contains "the ref is a parameter" "$other" '      pipeline-ref: v2.4.1'

if command -v actionlint >/dev/null 2>&1; then
  d="$(mktemp -d)"
  printf '%s\n' "$stub" > "$d/issue-milestone.yml"
  if actionlint "$d/issue-milestone.yml" >/dev/null 2>&1; then
    pass "actionlint accepts the generated stub"
  else
    fail "actionlint accepts the generated stub" "$(actionlint "$d/issue-milestone.yml" 2>&1 | head -5)"
  fi
  rm -rf "$d"
else
  printf '  - skipped actionlint (not installed)\n'
fi

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$stub" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "the generated stub is valid YAML"
  else
    fail "the generated stub is valid YAML" "yamllint rejected it"
  fi
fi

section "milestone queries — state, creation, un-milestoned issues"

# in_lib <map-line...> — runs the lib call in $LIB_CALL with gh mocked. Each
# map line is "<argv substring>\t<fixture>"; $LIB_FAIL, when set, is the mock's
# fail map. The gh argv log is left in $LIB_DIR/gh for the caller to read — the
# calls a query makes are part of what is asserted.
#
# SC2030/SC2031: the exports are deliberately confined to the subshell — that
# isolation is the point, so every case starts from the same environment.
# shellcheck disable=SC2030,SC2031
in_lib() {
  : > "$LIB_DIR/gh"
  printf '%b' "$@" > "$LIB_DIR/map"
  # shellcheck disable=SC1091
  (export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LIB_DIR/gh" GH_MOCK_STDOUT_MAP="$LIB_DIR/map" \
          ${LIB_FAIL:+GH_MOCK_FAIL_MAP="$LIB_FAIL"}
   source "$ROOT/scripts/lib/backlog-milestone.sh"; "${LIB_CALL[@]}")
}

LIB_DIR="$(mktemp -d)"
LIB_FAIL=''
MILESTONES='milestones?state=all\t'

LIB_CALL=(list_unmilestoned_issues o/r)
assert_eq "un-milestoned issues span every page, pull requests dropped" \
  "$(printf '1\n2\n4')" "$(in_lib 'milestone=none\t'"$FIX/unmilestoned-two-pages.json"'\n')"
assert_contains "un-milestoned issues are read page by page" "$(cat "$LIB_DIR/gh")" '--paginate'

LIB_CALL=(backlog_milestone_state o/r)
assert_eq "an open backlog is found among other milestones" "open 7" \
  "$(in_lib "$MILESTONES$FIX/milestones-open.json"'\n')"
assert_eq "a closed backlog is reported as closed, never as missing" "closed 5" \
  "$(in_lib "$MILESTONES$FIX/milestones-closed.json"'\n')"
assert_eq "no backlog at all is missing" "missing" \
  "$(in_lib "$MILESTONES$FIX/milestones-missing.json"'\n')"
assert_eq "an open backlog wins over a closed namesake" "open 7" \
  "$(in_lib "$MILESTONES$FIX/milestones-open-and-closed.json"'\n')"

printf '%s\n' 'milestones?state=all' > "$LIB_DIR/fail"
LIB_FAIL="$LIB_DIR/fail"
rc=0; in_lib "$MILESTONES$FIX/milestones-open.json"'\n' >/dev/null || rc=$?
assert_eq "an unreadable milestone list fails, never reads as missing" "1" "$rc"
LIB_FAIL=''

LIB_CALL=(create_backlog_milestone o/r)
assert_eq "creating backlog prints the new number" "9" \
  "$(in_lib '-X POST repos/o/r/milestones\t'"$FIX/milestone-created.json"'\n')"
assert_contains "creating backlog POSTs the title exactly" "$(cat "$LIB_DIR/gh")" \
  'api -X POST repos/o/r/milestones -f title=backlog'
assert_contains "creating backlog says where the convention comes from" "$(cat "$LIB_DIR/gh")" \
  'freaxnx01/ai-instructions#61'

LIB_CALL=(create_backlog_milestone o/r)
printf '%s\n' '-X POST' > "$LIB_DIR/fail"
LIB_FAIL="$LIB_DIR/fail"
rc=0; in_lib '-X POST repos/o/r/milestones\t'"$FIX/milestone-created.json"'\n' >/dev/null || rc=$?
assert_eq "a failed creation returns 1, never a number" "1" "$rc"
LIB_FAIL=''
rm -rf "$LIB_DIR"

section "guard_ref_ok — only a ref that has the workflow gets a stub"

# Extracted from the shipped script, which runs the rollout at top level and so
# cannot be sourced whole. The predicate has no dependencies, so the extract is
# the real thing — not a copy that could drift.
# shellcheck disable=SC1090
source <(sed -n '/^guard_ref_ok()/,/^}/p' "$MIGRATE")

for ref in v2 v3 v10 v2.3.0 v2.10.0 v3.0.0 v11.0.0; do
  if guard_ref_ok "$ref"; then pass "$ref qualifies"; else fail "$ref qualifies"; fi
done
# v1 never had the workflow, v2.2.1 predates it, and a stub pinned at a ref
# without backlog-milestone.yml fails on every issue event.
for ref in v1 v1.13.0 v2.2.1 v2.0.0 main master '' v2.3 2.3.0 \
           0123456789abcdef0123456789abcdef01234567; do
  if guard_ref_ok "$ref"; then fail "${ref:-(empty)} does not qualify"; else pass "${ref:-(empty)} does not qualify"; fi
done

section "add-milestone-guard — dry run"

MG="$(mktemp -d)"
printf 'deadbeef\n' > "$MG/sha"
printf 'main\n' > "$MG/default-branch"
printf 'cafe1234\n' > "$MG/base-sha"
printf 'https://github.com/o/a/pull/12\n' > "$MG/pr-url"
printf 'https://github.com/o/a/pull/7\n' > "$MG/open-pr"

# mg_map <agent-fixture> <milestones-fixture> [extra "<pattern>\t<file>" lines]
# ORDER MATTERS: the mock answers with the first pattern found in argv, and
# only the sha call carries `--jq .sha`.
mg_map() {
  local agent="$1" milestones="$2"; shift 2
  base64 -w0 < "$FIX/$agent" > "$MG/agent.b64"
  { printf -- '--jq .default_branch\t%s\n' "$MG/default-branch"
    printf 'git/ref/heads/\t%s\n' "$MG/base-sha"
    printf '.sha\t%s\n' "$MG/sha"
    printf 'contents/.github/workflows/agent.yml\t%s\n' "$MG/agent.b64"
    printf 'milestones?state=all\t%s\n' "$FIX/$milestones"
    printf 'milestone=none\t%s\n' "$FIX/unmilestoned-two-pages.json"
    printf -- '-X POST repos/o/a/milestones\t%s\n' "$FIX/milestone-created.json"
    printf 'pr create\t%s\n' "$MG/pr-url"
    if (( $# > 0 )); then printf '%b\n' "$@"; fi
  } > "$MG/map"
}

GUARD_PATH='.github/workflows/issue-milestone.yml'
# The stub's *lookup*, and nothing else: an argv pattern of just the path would
# also match the PUT that writes it.
GUARD_GET="api repos/o/a/contents/$GUARD_PATH"

# mg_absent — the normal state of a repo that has not been rolled out yet: the
# stub lookup 404s, exactly as `gh api` reports a missing file.
mg_absent() {
  printf '%s\t%s\n' "$GUARD_GET" 'gh: Not Found (HTTP 404)' > "$MG/fail"
  MG_FAIL="$MG/fail"
}

# mg_run [args...] — the mode over CONSUMERS='o/a'; sets OUT, RC, and leaves
# the gh argv log in $MG/log.
# shellcheck disable=SC2031  # PATH is rebuilt per call from the pristine $MOCKS
mg_run() {
  : > "$MG/log"
  RC=0
  OUT="$(env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$MG/log" GH_MOCK_STDOUT_MAP="$MG/map" \
           ${MG_FAIL:+GH_MOCK_FAIL_MAP="$MG_FAIL"} GH_RETRY_SLEEP_CMD=true \
           CONSUMERS='o/a' bash "$MIGRATE" --add-milestone-guard "$@" 2>&1)" || RC=$?
}
MG_FAIL=''

mg_map agent-v2.yml milestones-open.json; mg_absent
mg_run
assert_contains "a pinned, guard-less consumer is reported with its counts" "$OUT" \
  'o/a  v2  would add guard  backlog:present  unmilestoned:3'
assert_contains "  → and tallied as a change" "$OUT" '1 changed, 0 skipped, 0 failed'
assert_eq "  → dry run exits 0" "0" "$RC"
assert_not_contains "  → nothing is created" "$(cat "$MG/log")" '-X POST repos/o/a/milestones'
assert_not_contains "  → and nothing is written" "$(cat "$MG/log")" '-X PUT'

mg_map agent-v2.yml milestones-missing.json; mg_absent
mg_run
assert_contains "a missing backlog is announced, not created" "$OUT" \
  'o/a  v2  would add guard  backlog:would create  unmilestoned:3'
assert_not_contains "  → no milestone POST" "$(cat "$MG/log")" '-X POST repos/o/a/milestones'

# No 404 seam: the lookup succeeds, so the stub is already there.
mg_map agent-v2.yml milestones-open.json; MG_FAIL=''
mg_run
assert_contains "a consumer that already has the guard is skipped" "$OUT" 'o/a  v2  guard present'
assert_contains "  → and tallied as skipped" "$OUT" '0 changed, 1 skipped, 0 failed'
assert_eq "  → exit 0" "0" "$RC"
assert_not_contains "  → its milestones are not even read" "$(cat "$MG/log")" 'milestones?state=all'

mg_map agent-v2.2.1.yml milestones-open.json; mg_absent
mg_run
assert_contains "an exact pin older than the guard is skipped, never given a 404 stub" "$OUT" \
  'o/a  v2.2.1  skipped (pins v2.2.1; guard needs v2.3.0+)'
assert_eq "  → exit 0" "0" "$RC"
mg_run --force
assert_contains "  → and --force does not override it" "$OUT" \
  'o/a  v2.2.1  skipped (pins v2.2.1; guard needs v2.3.0+)'

mg_map agent-v2.3.0.yml milestones-open.json; mg_absent
mg_run
assert_contains "the first release with the guard qualifies" "$OUT" 'o/a  v2.3.0  would add guard'

for fixture in agent-v1.yml agent-main.yml; do
  mg_map "$fixture" milestones-open.json; mg_absent
  mg_run
  assert_contains "$fixture is skipped with the reason" "$OUT" 'guard needs v2.3.0+'
done

# An outage must not read as "the file is not there" — that would hand the repo
# a second stub, or a PR nobody expected.
mg_map agent-v2.yml milestones-open.json
printf '%s\t%s\n' "$GUARD_GET" 'gh: HTTP 500: Internal Server Error' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run
assert_contains "a guard lookup that is not a 404 fails the repo" "$OUT" 'o/a  v2  CHECK FAILED'
assert_contains "  → and is tallied as failed" "$OUT" '0 changed, 0 skipped, 1 failed'
assert_eq "  → the run exits 1" "1" "$RC"
assert_not_contains "  → nothing is written" "$(cat "$MG/log")" '-X PUT'

mg_map agent-v2.yml milestones-closed.json; mg_absent
mg_run
assert_contains "a closed backlog fails the repo instead of being reopened" "$OUT" \
  'o/a  v2  backlog:CLOSED  not edited'
assert_eq "  → the run exits 1" "1" "$RC"
assert_not_contains "  → no milestone is created" "$(cat "$MG/log")" '-X POST repos/o/a/milestones'
assert_not_contains "  → and no PR is opened" "$(cat "$MG/log")" 'pr create'

mg_map agent-v2.yml milestones-open.json 'pr list --repo o/a\t'"$MG/open-pr"
mg_absent
mg_run
assert_contains "a rollout PR already open is not duplicated" "$OUT" \
  'o/a  v2  PR already open https://github.com/o/a/pull/7'
assert_eq "  → exit 0" "0" "$RC"

mg_map agent-v2.yml milestones-open.json
printf '%s\t%s\n%s\t%s\n' \
  "$GUARD_GET" 'gh: Not Found (HTTP 404)' \
  'milestones?state=all' 'gh: HTTP 502: Bad Gateway' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run
assert_contains "an unreadable milestone list fails the repo" "$OUT" 'o/a  v2  CHECK FAILED'
assert_eq "  → the run exits 1" "1" "$RC"

mg_map agent-v2.yml milestones-open.json
printf '%s\t%s\n%s\t%s\n' \
  "$GUARD_GET" 'gh: Not Found (HTTP 404)' \
  'milestone=none' 'gh: HTTP 502: Bad Gateway' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run
assert_contains "an unreadable issue list fails the repo" "$OUT" 'o/a  v2  CHECK FAILED'
assert_eq "  → the run exits 1" "1" "$RC"
MG_FAIL=''

section "add-milestone-guard — apply"

# log_line <pattern> — the gh log's first line number matching <pattern>, so
# the order of the writes can be asserted, not just their presence.
log_line() { local n; n="$(grep -nF -m1 -- "$1" "$MG/log" | cut -d: -f1)"; printf '%s' "${n:-0}"; }

mg_map agent-v2.yml milestones-missing.json; mg_absent
mg_run --apply
assert_contains "apply -> says what it did, with the milestone it created" "$OUT" \
  'added guard → PR https://github.com/o/a/pull/12  backlog:created  unmilestoned:3'
assert_eq "  → exit 0" "0" "$RC"
log="$(cat "$MG/log")"
assert_contains "  → the milestone is created" "$log" '-X POST repos/o/a/milestones -f title=backlog'
assert_contains "  → the stub is written on the rollout branch" "$log" \
  '-X PUT repos/o/a/contents/.github/workflows/issue-milestone.yml'
assert_contains "  → never on the default branch" "$log" 'branch=ci/backlog-milestone-guard'
assert_contains "  → and one PR is opened for it" "$log" \
  'pr create --repo o/a --head ci/backlog-milestone-guard'
# The milestone has to exist before the stub lands: the guard would otherwise
# warn on every issue until an operator noticed.
if (( $(log_line '-X POST repos/o/a/milestones') < $(log_line '-X PUT repos/o/a/contents/.github/workflows/issue-milestone.yml') )); then
  pass "  → the milestone is created before the stub is written"
else
  fail "  → the milestone is created before the stub is written" "$log"
fi
if (( $(log_line '-X PUT repos/o/a/contents/.github/workflows/issue-milestone.yml') < $(log_line 'pr create') )); then
  pass "  → and the stub is written before the PR is opened"
else
  fail "  → and the stub is written before the PR is opened" "$log"
fi
assert_contains "  → the branch is cut from the default branch's head" "$log" \
  '-X POST repos/o/a/git/refs -f ref=refs/heads/ci/backlog-milestone-guard -f sha=cafe1234'
assert_not_contains "  → and the new file is created without a sha" "$log" \
  'issue-milestone.yml -f message'$'\n''-f sha'

# The bytes a consumer gets are the bytes onboarding writes.
# shellcheck disable=SC1091
expected="$(source "$ROOT/scripts/lib/milestone-stub.sh"; build_milestone_yml freaxnx01/agent-workflow v2)"
written="$(grep -o 'content=[A-Za-z0-9+/=]*' "$MG/log" | head -1 | sed 's/^content=//' | base64 -d)"
assert_eq "apply -> the written stub is the shared stub at the consumer's own ref" \
  "$expected" "$written"

mg_map agent-v2.yml milestones-open.json; mg_absent
mg_run --apply
assert_contains "an existing backlog is used as it is" "$OUT" 'added guard → PR'
assert_contains "  → and reported as present" "$OUT" 'backlog:present'
assert_not_contains "  → no second milestone is created" "$(cat "$MG/log")" '-X POST repos/o/a/milestones'

mg_map agent-v2.yml milestones-missing.json
printf '%s\t%s\n%s\n' \
  "$GUARD_GET" 'gh: Not Found (HTTP 404)' \
  '-X POST repos/o/a/milestones' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run --apply
assert_contains "a failed milestone creation stops the repo there" "$OUT" 'o/a  v2  MILESTONE CREATE FAILED'
assert_eq "  → the run exits 1" "1" "$RC"
assert_not_contains "  → nothing is written" "$(cat "$MG/log")" '-X PUT'
assert_not_contains "  → and no PR is opened" "$(cat "$MG/log")" 'pr create'

mg_map agent-v2.yml milestones-missing.json
printf '%s\t%s\n%s\n' \
  "$GUARD_GET" 'gh: Not Found (HTTP 404)' \
  '-X PUT' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run --apply
# The created milestone is named so a re-run does not look surprising.
assert_contains "a failed write says the milestone was already created" "$OUT" \
  'o/a  v2  WRITE FAILED  backlog:created'
assert_eq "  → the run exits 1" "1" "$RC"
assert_not_contains "  → and no PR is opened" "$(cat "$MG/log")" 'pr create'

mg_map agent-v2.yml milestones-open.json
printf '%s\t%s\n%s\n' \
  "$GUARD_GET" 'gh: Not Found (HTTP 404)' \
  'pr create' > "$MG/fail"
MG_FAIL="$MG/fail"
mg_run --apply
assert_contains "a failed pr create names the branch that was written" "$OUT" \
  'o/a  v2  PR FAILED (branch ci/backlog-milestone-guard written)  backlog:present'
assert_eq "  → the run exits 1" "1" "$RC"

# --apply must not turn a skipped verdict into a write.
for case in 'agent-v2.2.1.yml:milestones-open.json:404' \
            'agent-v2.yml:milestones-closed.json:404' \
            'agent-v2.yml:milestones-open.json:present'; do
  IFS=':' read -r agent milestones guard <<< "$case"
  mg_map "$agent" "$milestones"
  MG_FAIL=''
  if [[ "$guard" == 404 ]]; then mg_absent; fi
  mg_run --apply
  assert_not_contains "$agent + $milestones (guard $guard) -> no milestone created" \
    "$(cat "$MG/log")" '-X POST repos/o/a/milestones'
  assert_not_contains "  → and nothing written" "$(cat "$MG/log")" '-X PUT'
done
MG_FAIL=''
rm -rf "$MG"

section "add-milestone-guard — argument handling"

for other in '--to:v2' '--fix-perms:' '--rename-flow:'; do
  flag="${other%%:*}"; value="${other#*:}"
  rc=0
  # shellcheck disable=SC2086  # $value is one optional argument, by design
  bash "$MIGRATE" --repo o/a --add-milestone-guard "$flag" $value >/dev/null 2>&1 || rc=$?
  assert_eq "--add-milestone-guard with $flag is a usage error" "2" "$rc"
done

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
