#!/usr/bin/env bash
#
# run-migrate-gh-issues-tests.sh — Layer-1 fixture tests for
# scripts/migrate-gh-issues-to-azdo.sh (#642).
#
# `gh`, `az` and `curl` are all mocked; no network, no GitHub, no live
# organization. The fixture repository has three open issues (1, 2, 3 — oldest
# first) and one pull request, which the same REST endpoint returns and the
# script must drop. Issue 2 is labelled `bug` and has three comments served over
# two pages. Both labelled issues carry pipeline state — an `agent:*` override
# and, on issue 2, the `ai-review-ai-merge` gate — which must not become tags.
#
# Usage: tests/run-migrate-gh-issues-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/migrate-gh-issues-to-azdo.sh"
MOCKS="$ROOT/tests/mocks"
FIXTURES="$ROOT/tests/fixtures"

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
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "expected: $expected | actual: $actual"
  fi
}
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "missing '$needle' in: $haystack"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GH_MAP="$WORK/gh-map.tsv"
AZ_MAP="$WORK/az-map.tsv"
CURL_MAP="$WORK/curl-map.tsv"
REPO='contoso/consumer-repo'
AREA='Contoso Project\consumer-repo'

# reset_case [issue-1-comments] [types-fixture] [areas-fixture] — fresh logs and
# mock routing tables, so no case can read the previous one's calls.
reset_case() {
  local comments1="${1:-gh-issue-comments-none.json}"
  local types="${2:-azdo-workitemtypes-agile.json}"
  local areas="${3:-azdo-areas-consumer-repo.json}"
  : > "$WORK/gh-argv.txt"; : > "$WORK/gh-body.txt"
  : > "$WORK/curl-argv.txt"; : > "$WORK/curl-body.txt"
  rm -f "$GH_MAP.seen"
  {
    printf 'issues/1/comments\t%s/%s\n' "$FIXTURES" "$comments1"
    # .txt, not .json: the fixture is TWO concatenated arrays — what `gh api
    # --paginate` actually emits for a multi-page array endpoint — which is not
    # one JSON document, so the check-json lint hook would reject the name.
    printf 'issues/2/comments\t%s/gh-issue-comments-paged.txt\n' "$FIXTURES"
    printf 'issues/3/comments\t%s/gh-issue-comments-none.json\n' "$FIXTURES"
    printf 'issues?state=open\t%s/gh-issues-open.json\n' "$FIXTURES"
  } > "$GH_MAP"
  {
    printf 'workitemtypes\t%s/%s\n' "$FIXTURES" "$types"
    printf 'boards area project list\t%s/%s\n' "$FIXTURES" "$areas"
  } > "$AZ_MAP"
  {
    printf 'comments?format=markdown\t%s/azdo-comment-created.json\n' "$FIXTURES"
    printf '_apis/wit/workitems/$\t%s/azdo-create-item.json\n' "$FIXTURES"
  } > "$CURL_MAP"
}

# run_migrate [args...] — the script under test, with every external CLI mocked.
# A case drives a failure by setting CURL_MOCK_FAIL_PATTERN or GH_MOCK_FAIL_MAP
# before the call; both are empty by default, which the mocks ignore.
# shellcheck disable=SC2030,SC2031
run_migrate() {
  (
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_LOG="$WORK/gh-argv.txt" GH_MOCK_BODY_LOG="$WORK/gh-body.txt"
    export GH_MOCK_STDOUT_MAP="$GH_MAP"
    export GH_MOCK_FAIL_MAP="${GH_MOCK_FAIL_MAP:-}"
    export CURL_MOCK_LOG="$WORK/curl-argv.txt" CURL_MOCK_BODY_LOG="$WORK/curl-body.txt"
    export CURL_MOCK_FIXTURE_MAP="$CURL_MAP"
    export CURL_MOCK_FAIL_PATTERN="${CURL_MOCK_FAIL_PATTERN:-}"
    export AZ_MOCK_MAP="$AZ_MAP"
    export AZDO_ORG=contoso AZDO_PROJECT='Contoso Project' AZDO_REPO=consumer-repo
    export AZURE_DEVOPS_EXT_PAT=s3cr3t
    "$SCRIPT" "$@"
  )
}

count_matches() { # <file> <literal>
  local n; n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# created_titles — System.Title of every create POST, in the order they were sent.
created_titles() {
  python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        ops = json.loads(line)
    except ValueError:
        continue
    if not isinstance(ops, list):
        continue
    for op in ops:
        if op.get("path") == "/fields/System.Title":
            print(op["value"])' "$WORK/curl-body.txt"
}

# create_field <index> <json-patch path> — one field of the Nth create POST.
create_field() {
  python3 -c '
import json, sys
wanted, path = int(sys.argv[2]), sys.argv[3]
creates = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        ops = json.loads(line)
    except ValueError:
        continue
    if isinstance(ops, list):
        creates.append(ops)
for op in creates[wanted]:
    if op.get("path") == path:
        # bytes, not text: one case asserts a non-ASCII body is byte-identical,
        # which an encoding chosen by the locale would decide instead of us.
        sys.stdout.buffer.write(op["value"].encode("utf-8"))
        break
else:
    sys.stdout.write("MISSING")' "$WORK/curl-body.txt" "$1" "$2"
}

# digest — reads stdin and echoes "<n> bytes sha256=<hex>", so a case can assert
# that two very large strings are identical without printing either of them.
digest() {
  python3 -c '
import hashlib, sys
raw = sys.stdin.buffer.read()
print("%d bytes sha256=%s" % (len(raw), hashlib.sha256(raw).hexdigest()))'
}

# comment_texts — the text of every comment POST, newlines shown as \n so one
# comment stays one line.
comment_texts() {
  python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if isinstance(d, dict) and "text" in d:
        print(d["text"].replace("\n", "\\n"))' "$WORK/curl-body.txt"
}

# --- validation ---------------------------------------------------------

section "validation happens before anything is read or written"

reset_case
rc=0; err="$(run_migrate --repo "$REPO" 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UsageWithoutArea: exit 2" "2" "$rc"
assert_contains "migrate_UsageWithoutArea: says so" "$err" "--area"
assert_eq "migrate_UsageWithoutArea: calls nothing" "0 0" \
  "$(wc -c < "$WORK/gh-argv.txt" | tr -d ' ') $(wc -c < "$WORK/curl-argv.txt" | tr -d ' ')"

reset_case
rc=0; err="$(run_migrate --area "$AREA" 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UsageWithoutRepo: exit 2" "2" "$rc"
assert_contains "migrate_UsageWithoutRepo: says so" "$err" "--repo"

reset_case
rc=0; err="$(run_migrate --repo "$REPO" --area "$AREA" --limit x 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UsageNonNumericLimit: exit 2" "2" "$rc"
assert_contains "migrate_UsageNonNumericLimit: says so" "$err" "--limit"

# A Basic process has Issue, not User Story. Discovering that after 20 creates
# have failed is no use, so the types are checked up front and the message says
# which flag changes them.
reset_case gh-issue-comments-none.json azdo-workitemtypes-basic.json
rc=0; err="$(run_migrate --repo "$REPO" --area "$AREA" 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UnknownType: exit 2" "2" "$rc"
assert_contains "migrate_UnknownType: names the type" "$err" "User Story"
assert_contains "migrate_UnknownType: names the flag" "$err" "--story-type"
assert_eq "migrate_UnknownType: writes nothing" "0" \
  "$(count_matches "$WORK/curl-argv.txt" '-X POST')"

# --type replaces both defaults, so it is the only name checked — and the one
# named back. An Agile project has no `Impediment`.
reset_case
rc=0; err="$(run_migrate --repo "$REPO" --area "$AREA" --type Impediment 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UnknownTypeOverride: exit 2" "2" "$rc"
assert_contains "migrate_UnknownTypeOverride: names the type" "$err" "'Impediment' does not exist"
assert_contains "migrate_UnknownTypeOverride: names the flag" "$err" "--type"
assert_eq "migrate_UnknownTypeOverride: the defaults are not checked too" "1" \
  "$(printf '%s\n' "$err" | grep -c 'does not exist' || true)"
assert_eq "migrate_UnknownTypeOverride: writes nothing" "0" \
  "$(count_matches "$WORK/curl-argv.txt" '-X POST')"

reset_case
rc=0; err="$(run_migrate --repo "$REPO" --area "$AREA" --limit 0 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UsageZeroLimit: exit 2" "2" "$rc"
assert_contains "migrate_UsageZeroLimit: says so" "$err" "--limit must be greater than 0"
assert_eq "migrate_UsageZeroLimit: migrates nothing" "0 0" \
  "$(wc -c < "$WORK/gh-argv.txt" | tr -d ' ') $(wc -c < "$WORK/curl-argv.txt" | tr -d ' ')"

# --help is output, not an error: it goes to stdout, and it carries the whole
# header comment including the exit codes.
reset_case
rc=0; help_out="$(run_migrate --help 2>/dev/null)" || rc=$?
assert_eq "migrate_HelpOnStdout: exit 0" "0" "$rc"
assert_contains "migrate_HelpOnStdout: the usage line" "$help_out" "Usage:"
assert_contains "migrate_HelpOnStdout: through to the exit codes" "$help_out" "Exit codes:"

reset_case gh-issue-comments-none.json azdo-workitemtypes-agile.json azdo-areas-nested.json
rc=0; err="$(run_migrate --repo "$REPO" --area "$AREA" 2>&1 >/dev/null)" || rc=$?
assert_eq "migrate_UnknownArea: exit 2" "2" "$rc"
assert_contains "migrate_UnknownArea: names the area" "$err" "consumer-repo"

# --- the migration run --------------------------------------------------

section "one Markdown work item per open issue, in order"

reset_case
rc=0; out="$(run_migrate --repo "$REPO" --area "$AREA")" || rc=$?
assert_eq "migrate_CreatesOnePerOpenIssue: exit 0" "0" "$rc"
assert_eq "migrate_CreatesOnePerOpenIssue: three creates in issue order" \
  "A plain issue,A broken thing,A labelless issue" "$(created_titles | paste -sd, -)"
assert_eq "migrate_CreatesOnePerOpenIssue: the pull request is ignored" "0" \
  "$(count_matches "$WORK/curl-body.txt" 'A pull request')"
assert_contains "migrate_CreatesOnePerOpenIssue: reports each item" "$out" \
  "#1 -> work item 42"

# shellcheck disable=SC2016
assert_eq "migrate_BugType: the bug label picks the type" "1" \
  "$(count_matches "$WORK/curl-argv.txt" '/workitems/$Bug?api-version=7.1')"
# shellcheck disable=SC2016
assert_eq "migrate_BugType: the others are stories" "2" \
  "$(count_matches "$WORK/curl-argv.txt" '/workitems/$User%20Story?api-version=7.1')"

assert_eq "migrate_AreaOnEveryItem" "$AREA" "$(create_field 2 /fields/System.AreaPath)"

assert_eq "migrate_TagsDropPipelineState" "enhancement; needs-enrichment" \
  "$(create_field 0 /fields/System.Tags)"
assert_eq "migrate_NoLabelsNoTagsOp" "MISSING" "$(create_field 2 /fields/System.Tags)"

assert_eq "migrate_MarkdownFormat" "Markdown" \
  "$(create_field 0 /multilineFieldsFormat/System.Description)"

# The body travels verbatim — quotes, backslashes, a fenced block and a task
# list — with only the migrated-from line appended.
expected_desc="$(python3 -c '
import json, sys
issues = json.load(open(sys.argv[1], encoding="utf-8"))
issue = next(i for i in issues if i["number"] == 1)
sys.stdout.write((issue["body"] or "").rstrip("\r\n")
                 + "\n\n_Migrated from %s._" % issue["html_url"])' "$FIXTURES/gh-issues-open.json")"
assert_eq "migrate_DescriptionHasMigratedLine" "$expected_desc" \
  "$(create_field 0 /fields/System.Description)"

# An issue with no body at all still gets the migrated-from line.
assert_contains "migrate_EmptyBodyStillLinksBack" "$(create_field 2 /fields/System.Description)" \
  "_Migrated from https://github.com/contoso/consumer-repo/issues/3._"

section "comments are copied in order, with an author/date header"

assert_eq "migrate_CommentsInOrderWithHeader: three posts" "3" \
  "$(count_matches "$WORK/curl-argv.txt" '/workItems/42/comments?format=markdown')"
assert_eq "migrate_CommentsInOrderWithHeader: headers in createdAt order" \
  "**octocat** on GitHub, 2026-02-01:|**ghost** on GitHub, 2026-02-02:|**hubot** on GitHub, 2026-02-03:" \
  "$(comment_texts | sed 's/\\n.*//' | paste -sd'|' -)"
# shellcheck disable=SC2016
assert_contains "migrate_CommentsInOrderWithHeader: body follows a blank line" \
  "$(comment_texts | head -1)" '2026-02-01:\n\nFirst, with a `fence`'

section "the GitHub write-back, and --close"

assert_contains "migrate_WriteBackWithMarker: links the work item" "$(cat "$WORK/gh-body.txt")" \
  'Migrated to Azure DevOps work item [#42](https://dev.azure.com/contoso/Contoso%20Project/_workitems/edit/42).'
assert_contains "migrate_WriteBackWithMarker: carries the marker" "$(cat "$WORK/gh-body.txt")" \
  '<!-- awf-migrated-to: https://dev.azure.com/contoso/Contoso%20Project#42 -->'
assert_eq "migrate_WriteBackWithMarker: one comment per issue" "3" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue comment')"
assert_eq "migrate_CloseFlag: closes nothing by default" "0" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue close')"

reset_case
run_migrate --repo "$REPO" --area "$AREA" --close >/dev/null
assert_eq "migrate_CloseFlag: closes every migrated issue" "3" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue close')"

section "idempotency — a marker for THIS project, and only this one"

reset_case gh-issue-comments-migrated.json
rc=0; out="$(run_migrate --repo "$REPO" --area "$AREA")" || rc=$?
assert_eq "migrate_SkipsMigrated: exit 0" "0" "$rc"
assert_contains "migrate_SkipsMigrated: reports the skip" "$out" "skip #1 (already work item 42)"
assert_eq "migrate_SkipsMigrated: the other two are created" \
  "A broken thing,A labelless issue" "$(created_titles | paste -sd, -)"
assert_eq "migrate_SkipsMigrated: no write-back for the skipped issue" "2" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue comment')"

# Work item ids are per ORGANIZATION, so a marker naming another project says
# nothing about this backlog — the issue must still be migrated.
reset_case gh-issue-comments-other-project.json
run_migrate --repo "$REPO" --area "$AREA" >/dev/null
assert_eq "migrate_OtherProjectMarkerNotSkipped" \
  "A plain issue,A broken thing,A labelless issue" "$(created_titles | paste -sd, -)"

section "--dry-run and --limit"

reset_case
rc=0; out="$(run_migrate --repo "$REPO" --area "$AREA" --dry-run)" || rc=$?
assert_eq "migrate_DryRunWritesNothing: exit 0" "0" "$rc"
assert_eq "migrate_DryRunWritesNothing: no POST or PATCH" "0 0" \
  "$(count_matches "$WORK/curl-argv.txt" '-X POST') $(count_matches "$WORK/curl-argv.txt" '-X PATCH')"
assert_eq "migrate_DryRunWritesNothing: no GitHub write" "0 0" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue comment') $(count_matches "$WORK/gh-argv.txt" 'issue close')"
assert_eq "migrate_DryRunWritesNothing: one report line per issue" "3" \
  "$(printf '%s\n' "$out" | grep -c '^would create' || true)"
assert_contains "migrate_DryRunWritesNothing: the report names type, tags and sizes" "$out" \
  'would create Bug "A broken thing" tags=[bug] comments=3 body='

reset_case
run_migrate --repo "$REPO" --area "$AREA" --limit 1 >/dev/null
assert_eq "migrate_Limit: exactly one create" "A plain issue" "$(created_titles | paste -sd, -)"

section "a large non-ASCII body survives byte for byte"

# The first consumer's largest issue body is 37 KB (#642), and `json.dumps`
# escapes every non-ASCII character to a six-byte \uXXXX — so the serialised
# patch is a multiple of the body. This one is deliberately past the 128 KiB
# Linux allows in ONE argv entry, which is what handing the patch to curl as a
# file rather than as `-d <string>` buys: as a string the create would die with
# "Argument list too long" before curl ran.
reset_case
big_issues="$WORK/gh-issues-big.json"
python3 - "$big_issues" <<'PY'
import json, sys

line = "見出し — a 日本語 line with an emoji 🎉 and a `fence`\n"
body = "```bash\nprintf '%s\\n' \"$x\"\n```\n\n" + line * 2000
json.dump([{
    "number": 9,
    "title": "A huge issue",
    "body": body,
    "state": "open",
    "html_url": "https://github.com/contoso/consumer-repo/issues/9",
    "labels": [],
    "user": {"login": "octocat"},
    "created_at": "2026-01-05T10:00:00Z",
}], open(sys.argv[1], "w", encoding="utf-8"))
PY
{
  printf 'issues/9/comments\t%s/gh-issue-comments-none.json\n' "$FIXTURES"
  printf 'issues?state=open\t%s\n' "$big_issues"
} > "$GH_MAP"

rc=0; out="$(run_migrate --repo "$REPO" --area "$AREA")" || rc=$?
assert_eq "migrate_LargeNonAsciiBody: exit 0" "0" "$rc"
assert_contains "migrate_LargeNonAsciiBody: the item is created" "$out" "#9 -> work item 42"

# Asserted as a length plus a digest: both sides are hundreds of kilobytes, and
# a failure message carrying them whole would be unreadable.
expected_big="$(python3 -c '
import json, sys
issue = json.load(open(sys.argv[1], encoding="utf-8"))[0]
sys.stdout.buffer.write((issue["body"].rstrip("\r\n")
                         + "\n\n_Migrated from %s._" % issue["html_url"]).encode("utf-8"))' \
  "$big_issues" | digest)"
assert_eq "migrate_LargeNonAsciiBody: byte-identical description" \
  "$expected_big" "$(create_field 0 /fields/System.Description | digest)"

section "a failed write stops the run and names the orphan"

# Issue 1 has no comments, so it completes. Issue 2's first comment POST fails
# AFTER its work item exists: that item carries no marker on GitHub, so a
# re-run would create a second one. The run stops and hands the id to the
# operator rather than guessing.
reset_case
rc=0
out="$(CURL_MOCK_FAIL_PATTERN='comments?format=markdown' \
       run_migrate --repo "$REPO" --area "$AREA" 2>&1)" || rc=$?
assert_eq "migrate_OrphanOnCommentFailure: exit 1" "1" "$rc"
assert_contains "migrate_OrphanOnCommentFailure: the exact message" "$out" \
  "orphan work item 42 for #2: delete it, or add the marker to the issue by hand"
assert_eq "migrate_OrphanOnCommentFailure: no write-back for that issue" "1" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue comment')"
assert_eq "migrate_OrphanOnCommentFailure: no later issue touched" "2" \
  "$(created_titles | wc -l | tr -d ' ')"

reset_case
printf 'issue comment\n' > "$WORK/gh-fail.tsv"
rc=0
out="$(GH_MOCK_FAIL_MAP="$WORK/gh-fail.tsv" \
       run_migrate --repo "$REPO" --area "$AREA" 2>&1)" || rc=$?
assert_eq "migrate_OrphanOnWriteBackFailure: exit 1" "1" "$rc"
assert_contains "migrate_OrphanOnWriteBackFailure: the exact message" "$out" \
  "orphan work item 42 for #1: delete it, or add the marker to the issue by hand"
assert_eq "migrate_OrphanOnWriteBackFailure: stops at the first issue" "1" \
  "$(created_titles | wc -l | tr -d ' ')"

# A create that fails leaves nothing behind, so it is an error without an orphan.
reset_case
rc=0
out="$(CURL_MOCK_FAIL_PATTERN='_apis/wit/workitems/$' \
       run_migrate --repo "$REPO" --area "$AREA" 2>&1)" || rc=$?
assert_eq "migrate_CreateFailureIsNotAnOrphan: exit 1" "1" "$rc"
assert_contains "migrate_CreateFailureIsNotAnOrphan: names the issue" "$out" "#1"
case "$out" in
  *orphan*) fail "migrate_CreateFailureIsNotAnOrphan: no orphan reported" "$out" ;;
  *) pass "migrate_CreateFailureIsNotAnOrphan: no orphan reported" ;;
esac

# A failed --close is the one write failure that leaves no orphan: the marker is
# already on the issue, so a re-run skips it and only the closing is left undone.
reset_case
printf 'issue close\n' > "$WORK/gh-fail.tsv"
rc=0
out="$(GH_MOCK_FAIL_MAP="$WORK/gh-fail.tsv" \
       run_migrate --repo "$REPO" --area "$AREA" --close 2>&1)" || rc=$?
assert_eq "migrate_CloseFailureIsNotAnOrphan: exit 1" "1" "$rc"
assert_contains "migrate_CloseFailureIsNotAnOrphan: the exact message" "$out" \
  "#1: work item 42 is created and linked, but closing the issue failed"
assert_eq "migrate_CloseFailureIsNotAnOrphan: the link comment was posted" "1" \
  "$(count_matches "$WORK/gh-argv.txt" 'issue comment')"
assert_eq "migrate_CloseFailureIsNotAnOrphan: stops at the first issue" "1" \
  "$(created_titles | wc -l | tr -d ' ')"
case "$out" in
  *orphan*) fail "migrate_CloseFailureIsNotAnOrphan: no orphan reported" "$out" ;;
  *) pass "migrate_CloseFailureIsNotAnOrphan: no orphan reported" ;;
esac

# A READ that fails stops the run just as a write does: without an issue's
# comments the marker check cannot say whether it was migrated already, and
# guessing would risk a second work item.
reset_case
printf 'issues/1/comments\n' > "$WORK/gh-fail.tsv"
rc=0
out="$(GH_MOCK_FAIL_MAP="$WORK/gh-fail.tsv" \
       run_migrate --repo "$REPO" --area "$AREA" 2>&1)" || rc=$?
assert_eq "migrate_CommentReadFailure: exit 1" "1" "$rc"
assert_contains "migrate_CommentReadFailure: the exact message" "$out" \
  "#1: could not read the comments"
assert_eq "migrate_CommentReadFailure: writes nothing" "0" \
  "$(count_matches "$WORK/curl-argv.txt" '-X POST')"

section "the PAT never reaches an argv"

reset_case
run_migrate --repo "$REPO" --area "$AREA" --close >/dev/null
if grep -q 's3cr3t' "$WORK/curl-argv.txt" "$WORK/gh-argv.txt"; then
  fail "migrate_PatNotInArgv" "found the PAT in a recorded command line"
else
  pass "migrate_PatNotInArgv"
fi

# --- summary -------------------------------------------------------------

printf '\n%s─────%s\n' "$C_DIM" "$C_OFF"
printf '  %s%d passed%s' "$C_GREEN" "$PASS" "$C_OFF"
if [ "$FAIL" -gt 0 ]; then
  printf ', %s%d failed%s\n' "$C_RED" "$FAIL" "$C_OFF"
  printf '\nFailed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
printf '\n'
exit 0
