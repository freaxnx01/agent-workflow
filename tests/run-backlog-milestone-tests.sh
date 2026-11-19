#!/usr/bin/env bash
#
# run-backlog-milestone-tests.sh — Layer-1 tests for the `backlog` milestone
# rules in /parked, /roadmap and /milestone triage (#644, ai-instructions#61).
#
# These run the command text, not grep it: each test pulls the ```bash fences
# out of a command's section and executes them against fixture JSON, with `gh`
# and `tea` replaced by stubs that serve the fixtures through the real jq and
# log every call. The Azure DevOps sections run against the real
# scripts/lib/azdo.sh with tests/mocks/az behind it, so the WIQL is asserted as
# the server would receive it.
#
# Usage: tests/run-backlog-milestone-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMDS="$ROOT/commands"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"
LIB="$ROOT/scripts/lib/azdo.sh"

PASS=0
FAIL=0
FAIL_NAMES=()

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_DIM=''; C_OFF=''
fi

SECTION=''
section() { SECTION="$1"; printf '\n%s── %s ──%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
# ok <name> <detail> <command...> — pass when the command succeeds
ok() { local name="$1" detail="$2"; shift 2; if "$@"; then pass "$name"; else fail "$name" "$detail"; fi; }
# no <name> <detail> <command...> — pass when the command fails
no() { local name="$1" detail="$2"; shift 2; if "$@"; then fail "$name" "$detail"; else pass "$name"; fi; }
has() { [[ "$1" == *"$2"* ]]; }

# fail_closed — the mocks reject a call they do not recognise, but the extracted
# command text runs without errexit, so that rejection would otherwise leave RC
# at 0 and a mistyped forge call would still read as "runs cleanly". Every run
# goes through this, so an unrecognised call is a failure wherever it happens.
fail_closed() {
  case "$OUT" in
    *"unexpected gh call"*|*"unexpected tea call"*|*"az mock: no fixture for"*)
      fail "$SECTION — no unrecognised forge call" "$OUT" ;;
  esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# blocks <file> <h2 title> <h3 title> [index] — the ```bash fences under
# "## <h2>" > "### <h3>", concatenated; with an index, only that fence (1-based).
blocks() {
  awk -v h2="## $2" -v h3="### $3" -v want="${4:-0}" '
    $0 == h2 { in2 = 1; next }
    in2 && /^## / { in2 = 0 }
    in2 && $0 == h3 { in3 = 1; next }
    in3 && /^##+ / { in3 = 0 }
    in3 && /^```bash$/ { code = 1; n++; next }
    code && /^```$/ { code = 0; next }
    code && (want == 0 || n == want) { print }
  ' "$1"
}

# --- fixtures ---------------------------------------------------------------

cat > "$WORK/issues.json" <<'JSON'
[
  {"number": 1, "title": "plain, no milestone", "labels": [], "milestone": null, "createdAt": "2026-01-01T00:00:00Z"},
  {"number": 2, "title": "in backlog", "labels": [{"name": "bug"}], "milestone": {"title": "backlog"}, "createdAt": "2026-01-02T00:00:00Z"},
  {"number": 3, "title": "parked in backlog", "labels": [{"name": "parked"}], "milestone": {"title": "backlog"}, "createdAt": "2026-01-03T00:00:00Z"},
  {"number": 4, "title": "roadmap in backlog", "labels": [{"name": "roadmap"}], "milestone": {"title": "backlog"}, "createdAt": "2026-01-04T00:00:00Z"},
  {"number": 5, "title": "scheduled in v1.2", "labels": [], "milestone": {"title": "v1.2 · goal"}, "createdAt": "2026-01-05T00:00:00Z"},
  {"number": 6, "title": "legacy parked, no milestone", "labels": [{"name": "parked"}], "milestone": null, "createdAt": "2026-01-06T00:00:00Z"}
]
JSON
# A full page: 200 open issues, all but three already scheduled into v1.2, so
# the filter leaves three rows while the fetch itself hit the cap.
jq -n '[range(1; 201) | {number: ., title: "issue \(.)", labels: [],
  milestone: (if . <= 3 then null else {title: "v1.2 · goal"} end),
  createdAt: "2026-01-01T00:00:00Z"}]' > "$WORK/issues-full-page.json"
printf '%s\n' '[{"title": "v1.2 · goal", "due_on": null}, {"title": "backlog", "due_on": null}]' > "$WORK/ms-with-backlog.json"
printf '%s\n' '[{"title": "v1.2 · goal", "due_on": null}]' > "$WORK/ms-without-backlog.json"
printf '%s\n' '{"number": 42, "milestone": {"title": "v1.2 · goal"}}' > "$WORK/issue-in-v12.json"
printf '%s\n' '{"number": 42, "milestone": {"title": "backlog"}}' > "$WORK/issue-in-backlog.json"
printf '%s\n' '{"comments": [{"body": "parked: waiting on vendor"}, {"body": "roadmap: waiting on vendor"}]}' > "$WORK/comments.json"
# Forgejo returns the comments as a bare array, GitHub wraps them in the issue.
printf '%s\n' '[{"body": "parked: waiting on vendor"}, {"body": "roadmap: waiting on vendor"}]' > "$WORK/fj-comments.json"
# What `az ... --query 'fields."System.IterationPath"' --output tsv` prints back.
printf '%s\n' 'MyProject' > "$WORK/az-iteration-root.tsv"
# What the workitemsbatch call behind `azdo_fields` returns: one item scheduled
# into a sprint, one already at the project root (this forge's `backlog`).
printf '%s\n' '{"value": [{"id": 42, "fields": {"System.Id": 42, "System.Title": "t", "System.State": "To Do", "System.Tags": "parked", "System.IterationPath": "MyProject\\Sprint 3"}}]}' \
  > "$WORK/az-batch-in-sprint.json"
printf '%s\n' '{"value": [{"id": 42, "fields": {"System.Id": 42, "System.Title": "t", "System.State": "To Do", "System.Tags": "parked", "System.IterationPath": "MyProject"}}]}' \
  > "$WORK/az-batch-at-root.json"
# What the comments API returns — HTML-wrapped, which is why `azdo_comments`
# strips it and why the record has to be its own comment, not a second line.
printf '%s\n' '{"comments": [{"id": 11, "text": "<div>waiting on vendor</div>"}, {"id": 12, "text": "<div>iteration-was: MyProject\\Sprint 3</div>"}]}' \
  > "$WORK/az-comments-record.json"
printf '%s\n' '{"comments": [{"id": 11, "text": "<div>waiting on vendor</div>"}]}' \
  > "$WORK/az-comments-plain.json"

# The stubs. Every call is logged; reads are served from fixtures via the real
# jq, so the command's own --jq filter is what gets tested.
# shellcheck disable=SC2016  # STUBS is code for a child bash; it must not expand here
STUBS='
IFS=$'"'"' \t\n'"'"'
repo=owner/repo
gh() {
  printf "%s\n" "gh $*" >> "$LOG"
  local jqf="." i args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in --jq|-q) jqf="${args[i+1]}" ;; esac
  done
  case "$*" in
    "repo view"*) printf "owner/repo\n" ;;
    "api repos/owner/repo/milestones"*) jq -r "$jqf" "$FIX_MS" ;;
    "issue list"*) jq -r "$jqf" "$FIX_ISSUES" ;;
    "issue view 42 --json comments"*) jq -r "$jqf" "$FIX_COMMENTS" ;;
    "issue view 42 --json"*) jq -r "$jqf" "$FIX_ISSUE" ;;
    "issue comment"*|"issue edit"*) : ;;
    *) printf "unexpected gh call: %s\n" "$*" >&2; return 99 ;;
  esac
}
tea() {
  printf "%s\n" "tea $*" >> "$LOG"
  case "$*" in
    *"/milestones?"*) cat "$FIX_MS" ;;
    *"/issues?"*) cat "$FIX_ISSUES" ;;
    *"/comments"*) cat "$FIX_FJ_COMMENTS" ;;
    *"/issues/"*) cat "$FIX_ISSUE" ;;
    "comment "*|"milestones issues add"*) : ;;
    *) printf "unexpected tea call: %s\n" "$*" >&2; return 99 ;;
  esac
}
'

# run <code> <milestones fixture> <issue fixture> — runs code with the stubs;
# sets OUT, RC and LOG. $ISSUES, when set, replaces the `issue list` fixture.
run() {
  LOG="$WORK/log.$RANDOM"; : > "$LOG"
  RC=0
  OUT="$(LOG="$LOG" FIX_MS="$2" FIX_ISSUE="$3" FIX_ISSUES="${ISSUES:-$WORK/issues.json}" \
    FIX_COMMENTS="$WORK/comments.json" FIX_FJ_COMMENTS="$WORK/fj-comments.json" \
    bash -c "$STUBS$1" 2>&1)" || RC=$?
  fail_closed
}

# run_azdo <az fixture> <code> — runs code with the real scripts/lib/azdo.sh
# sourced, `az` served by tests/mocks/az and the AZDO_* context pre-set; sets
# OUT, RC, AZ_LOG (argv per call) and AZ_STDIN (the WIQL request body).
#
# $AZ_MAP, when set, names a "<argv substring>\t<fixture>" file that picks the
# fixture per call — needed once a section makes several different az calls
# (read the iteration, comment, then move it), which one fixture cannot serve.
run_azdo() {
  AZ_LOG="$WORK/az.log.$RANDOM"; AZ_STDIN="$WORK/az.stdin.$RANDOM"
  : > "$AZ_LOG"; : > "$AZ_STDIN"
  RC=0
  OUT="$(
    export PATH="$MOCKS:$PATH" AZ_MOCK_FIXTURE="$1" AZ_MOCK_LOG="$AZ_LOG" \
      AZ_MOCK_STDIN_LOG="$AZ_STDIN" AZ_MOCK_MAP="${AZ_MAP:-}" AZDO_ORG=contoso \
      AZDO_PROJECT=MyProject AZDO_REPO=my-repo AZURE_DEVOPS_EXT_PAT=not-a-real-token
    bash -c "source '$LIB'
$2" 2>&1
  )" || RC=$?
  fail_closed
}

# az_line <pattern> — the 1-based position of the first az call matching
# <pattern>, or 0 when there is none. Lets a test assert call ORDER, which is
# the whole point of recording an iteration before overwriting it.
az_line() {
  local n
  n="$(grep -n -m1 -e "$1" "$AZ_LOG" | cut -d: -f1)"
  printf '%s\n' "${n:-0}"
}

# in_order <a> <b> <c> — true when all three az_line positions were found and
# the calls happened in that order.
in_order() { [[ "$1" -gt 0 ]] && [[ "$1" -lt "$2" ]] && [[ "$2" -lt "$3" ]]; }

# wiql — the query as the WIQL parser would receive it, decoded from the body
# azdo_wiql posted. PARSE-FAILED when the body is not the JSON it must be.
wiql() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["query"])' "$AZ_STDIN" \
    2>/dev/null || printf 'PARSE-FAILED\n'
}

numbers() { grep -oE '^[0-9]+' <<<"$1" | sort -n | paste -sd, -; }
subst() { sed -e 's/<n>/42/g' -e 's/<reason>/waiting on vendor/g'; }

# --- /milestone triage ------------------------------------------------------

section "/milestone triage — GitHub Phase 1"
code="$(blocks "$CMDS/milestone.md" GitHub triage 1)"
run "$code" "$WORK/ms-with-backlog.json" /dev/null
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "lists backlog (not parked/roadmap) + every no-milestone issue" "got: $(numbers "$OUT")" test "$(numbers "$OUT")" = "1,2,6"
no "no missing-backlog warning when it exists" "$OUT" has "$OUT" MISSING
ok "reports what was fetched, not what survived the filter" "$OUT" \
  has "$OUT" "fetched: 6 of at most 200"
ISSUES="$WORK/issues-full-page.json" run "$code" "$WORK/ms-with-backlog.json" /dev/null
ok "a full page of 200 reports the cap even when the filter leaves 3 rows" \
  "rows: $(numbers "$OUT"); $OUT" has "$OUT" "fetched: 200 of at most 200"
ok "the full page still lists only the 3 unscheduled issues" "got: $(numbers "$OUT")" \
  test "$(numbers "$OUT")" = "1,2,3"
run "$code" "$WORK/ms-without-backlog.json" /dev/null
ok "missing backlog is reported with the create pointer" "$OUT" has "$OUT" "/milestone new backlog"
ok "still lists the gap when backlog is missing" "got: $(numbers "$OUT")" test "$(numbers "$OUT")" = "1,2,6"

section "/milestone triage — Forgejo Phase 1"
code="$(blocks "$CMDS/milestone.md" Forgejo triage 1)"
run "$code" "$WORK/ms-with-backlog.json" /dev/null
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "lists backlog (not parked/roadmap) + every no-milestone issue" "got: $(numbers "$OUT")" test "$(numbers "$OUT")" = "1,2,6"
run "$code" "$WORK/ms-without-backlog.json" /dev/null
ok "missing backlog is reported with the create pointer" "$OUT" has "$OUT" "/milestone new backlog"

# --- /parked repark (GitHub) ------------------------------------------------

section "/parked repark — GitHub"
code="$(blocks "$CMDS/parked.md" GitHub repark | subst)"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-v12.json"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the issue to backlog" "$(cat "$LOG")" grep -qx 'gh issue edit 42 --milestone backlog' "$LOG"
no "never strips the milestone" "$(cat "$LOG")" grep -q -- '--remove-milestone' "$LOG"
ok "records the milestone it moved away from" "$(cat "$LOG")" grep -qx 'milestone-was: v1.2 · goal' "$LOG"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-backlog.json"
no "records nothing when it was already in backlog" "$(cat "$LOG")" grep -q 'milestone-was:' "$LOG"
run "$code" "$WORK/ms-without-backlog.json" "$WORK/issue-in-v12.json"
ok "stops when backlog is missing" "$OUT" test "$RC" -ne 0
no "writes nothing when backlog is missing" "$(cat "$LOG")" grep -qE '^gh issue (comment|edit)' "$LOG"
ok "points at /milestone new backlog" "$OUT" has "$OUT" "/milestone new backlog"

# --- /roadmap defer (GitHub) ------------------------------------------------

section "/roadmap defer — GitHub"
code="$(blocks "$CMDS/roadmap.md" GitHub defer | subst)"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-v12.json"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the issue to backlog" "$(cat "$LOG")" grep -qx 'gh issue edit 42 --milestone backlog' "$LOG"
no "never strips the milestone" "$(cat "$LOG")" grep -q -- '--remove-milestone' "$LOG"
run "$code" "$WORK/ms-without-backlog.json" "$WORK/issue-in-v12.json"
ok "stops when backlog is missing" "$OUT" test "$RC" -ne 0
no "writes nothing when backlog is missing" "$(cat "$LOG")" grep -qE '^gh issue (comment|edit)' "$LOG"
ok "points at /milestone new backlog" "$OUT" has "$OUT" "/milestone new backlog"

# --- /parked repark (Forgejo) -----------------------------------------------

section "/parked repark — Forgejo"
code="$(blocks "$CMDS/parked.md" Forgejo repark | subst)"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-v12.json"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the issue to backlog" "$(cat "$LOG")" \
  grep -qx 'tea milestones issues add --login git-home backlog 42' "$LOG"
no "never removes the milestone" "$(cat "$LOG")" grep -q 'milestones issues remove' "$LOG"
ok "records the milestone it moved away from" "$(cat "$LOG")" grep -qx 'milestone-was: v1.2 · goal' "$LOG"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-backlog.json"
no "records nothing when it was already in backlog" "$(cat "$LOG")" grep -q 'milestone-was:' "$LOG"
run "$code" "$WORK/ms-without-backlog.json" "$WORK/issue-in-v12.json"
ok "stops when backlog is missing" "$OUT" test "$RC" -ne 0
no "writes nothing when backlog is missing" "$(cat "$LOG")" \
  grep -qE '^tea (comment|milestones issues add)' "$LOG"
ok "points at /milestone new backlog" "$OUT" has "$OUT" "/milestone new backlog"

# --- /roadmap defer (Forgejo) -----------------------------------------------

section "/roadmap defer — Forgejo"
code="$(blocks "$CMDS/roadmap.md" Forgejo defer | subst)"
run "$code" "$WORK/ms-with-backlog.json" "$WORK/issue-in-v12.json"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the issue to backlog" "$(cat "$LOG")" \
  grep -qx 'tea milestones issues add --login git-home backlog 42' "$LOG"
no "never removes the milestone" "$(cat "$LOG")" grep -q 'milestones issues remove' "$LOG"
run "$code" "$WORK/ms-without-backlog.json" "$WORK/issue-in-v12.json"
ok "stops when backlog is missing" "$OUT" test "$RC" -ne 0
no "writes nothing when backlog is missing" "$(cat "$LOG")" \
  grep -qE '^tea (comment|milestones issues add)' "$LOG"
ok "points at /milestone new backlog" "$OUT" has "$OUT" "/milestone new backlog"

# --- Azure DevOps -----------------------------------------------------------
#
# The WIQL here is never parsed by anything local, so the query is asserted as
# the parser would receive it: decoded out of the body azdo_wiql posts. The
# `NOT CONTAINS` spelling is the whole point — WIQL has no prefix `NOT` on a
# clause (commands/issues.md), and `NOT [System.Tags] CONTAINS` fails to parse.

section "/milestone triage — Azure DevOps"
code="$(blocks "$CMDS/milestone.md" "Azure DevOps" triage 1)"
run_azdo "$FIXTURES/azdo-wiql-rows.json" "$code
printf 'rc=%s ids=%s\n' \"\$rc\" \"\$(printf '%s' \"\$ids\" | tr '\n' ',')\""
ok "the query runs and returns ids" "$OUT" has "$OUT" "rc=0 ids=1,2,4"
q="$(wiql)"
ok "asks for the project root iteration" "$q" has "$q" "[System.IterationPath] = 'MyProject'"
ok "filters parked with a single NOT CONTAINS operator" "$q" has "$q" "[System.Tags] NOT CONTAINS 'parked'"
ok "filters roadmap with a single NOT CONTAINS operator" "$q" has "$q" "[System.Tags] NOT CONTAINS 'roadmap'"
no "never prefixes a clause with NOT" "$q" has "$q" "NOT [System."
no "no command spells it NOT ... CONTAINS" "a prefix NOT is in one of the three commands" \
  grep -qn 'NOT \[System\.' "$CMDS/milestone.md" "$CMDS/parked.md" "$CMDS/roadmap.md"

section "/parked repark — Azure DevOps"
# The section makes three different az calls, so the fixture is chosen per call.
# `--discussion` writes nothing back, so /dev/null is the honest fixture for it.
printf 'workitemsbatch\t%s\n--discussion\t/dev/null\nSystem.IterationPath=\t%s\n' \
  "$WORK/az-batch-in-sprint.json" "$WORK/az-iteration-root.tsv" > "$WORK/az-map-sprint"
printf 'workitemsbatch\t%s\n--discussion\t/dev/null\nSystem.IterationPath=\t%s\n' \
  "$WORK/az-batch-at-root.json" "$WORK/az-iteration-root.tsv" > "$WORK/az-map-root"
# shellcheck disable=SC2016  # the heading itself contains backticks; it is a literal
code="$(blocks "$CMDS/parked.md" "Azure DevOps" 'repark `<n>` "<reason>"' | subst)"
AZ_MAP="$WORK/az-map-sprint" run_azdo "$WORK/az-iteration-root.tsv" "$code"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the item to the project root iteration" "$(cat "$AZ_LOG")" \
  grep -qE -- '--fields System\.IterationPath=MyProject( |$)' "$AZ_LOG"
ok "reads the iteration back" "$(cat "$AZ_LOG")" \
  grep -q -- '--query fields."System.IterationPath"' "$AZ_LOG"
ok "records the sprint it is taking the item out of" "$(cat "$AZ_LOG")" \
  grep -qF -- '--discussion iteration-was: MyProject\Sprint 3' "$AZ_LOG"
ok "records it before the move overwrites it" \
  "read=$(az_line workitemsbatch) record=$(az_line 'iteration-was:') move=$(az_line '--fields System\.IterationPath=')" \
  in_order "$(az_line workitemsbatch)" "$(az_line 'iteration-was:')" \
           "$(az_line '--fields System\.IterationPath=')"
AZ_MAP="$WORK/az-map-root" run_azdo "$WORK/az-iteration-root.tsv" "$code"
ok "runs cleanly when the item is already at the root" "$OUT" test "$RC" -eq 0
no "records nothing when the item is already at the root" "$(cat "$AZ_LOG")" \
  grep -q 'iteration-was:' "$AZ_LOG"

section "/parked unpark — Azure DevOps"
# Fence 2 of the section: the read that offers the recorded iteration back. The
# restore itself sits inside a bullet (indented fence), so `blocks` skips it —
# it only runs on an explicit yes, which a fixture test cannot give.
# shellcheck disable=SC2016  # the heading itself contains backticks; it is a literal
code="$(blocks "$CMDS/parked.md" "Azure DevOps" 'unpark `<n>`' 2 | subst)"
run_azdo "$WORK/az-comments-record.json" "$code
printf 'was=[%s]\n' \"\$was\""
ok "offers back the sprint repark recorded" "$OUT" has "$OUT" 'was=[MyProject\Sprint 3]'
run_azdo "$WORK/az-comments-plain.json" "$code
printf 'was=[%s]\n' \"\$was\""
ok "offers nothing when repark recorded nothing" "$OUT" has "$OUT" 'was=[]'

section "/roadmap defer — Azure DevOps"
# shellcheck disable=SC2016  # the heading itself contains backticks; it is a literal
code="$(blocks "$CMDS/roadmap.md" "Azure DevOps" 'defer `<n>` "<reason>"' | subst)"
run_azdo "$WORK/az-iteration-root.tsv" "$code"
ok "runs cleanly" "$OUT" test "$RC" -eq 0
ok "moves the item to the project root iteration" "$(cat "$AZ_LOG")" \
  grep -qE -- '--fields System\.IterationPath=MyProject( |$)' "$AZ_LOG"
ok "reads the iteration back" "$(cat "$AZ_LOG")" \
  grep -q -- '--query fields."System.IterationPath"' "$AZ_LOG"

# --- summary ----------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$C_RED" "$FAIL" "$C_OFF"
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\n  failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '    - %s\n' "$n"; done
  exit 1
fi
