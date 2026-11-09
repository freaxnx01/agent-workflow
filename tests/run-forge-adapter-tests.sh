#!/usr/bin/env bash
#
# run-forge-adapter-tests.sh — Layer-1 tests for scripts/lib/forge.sh.
# `gh` is mocked; no network, no live forge.
#
# Usage: tests/run-forge-adapter-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/forge.sh"
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
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name" "expected: $expected | actual: $actual"; fi
}

# make_repo <remote-url> — throwaway git repo with that origin, echoes its path.
# detect_forge reads the remote, so the forge under test is chosen by this URL.
make_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$1"
  echo "$dir"
}

# _forge_env <repo-dir> — runs forge_export_issue in a subshell and dumps the
# two variables it exports, NUL-free and one per record, for the callers below.
# Structured this way rather than eval'ing snippets so nothing has to be quoted
# past shellcheck.
# SC2030/SC2031: the exports are deliberately local to the subshell; that
# isolation is what keeps each case independent.
# shellcheck disable=SC2030,SC2031
_forge_env() {
  local dir="$1" map ghlog
  map="$(mktemp)"; ghlog="$(mktemp)"
  printf 'issue view\t%s/forge-issue-github.json\n' "$FIXTURES" > "$map"
  (
    cd "$dir"
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_LOG="$ghlog"
    export GH_MOCK_STDOUT_MAP="$map"
    export GH_MOCK_AUTH_HOSTS="github.com"
    export REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    rc=0
    forge_export_issue 42 >/dev/null 2>&1 || rc=$?
    printf 'RC=%s\n' "$rc"
    # `env` proves they are EXPORTED, not merely set: the classifiers are
    # separate processes and would never see a shell-local variable.
    env | grep -c '^ISSUE_LABELS=' | sed 's/^/EXPORTED_LABELS=/'
    env | grep -c '^ISSUE_BODY=' | sed 's/^/EXPORTED_BODY=/'
    printf 'LABELS<<\n%s\n>>\n' "${ISSUE_LABELS:-}"
    printf 'BODY<<\n%s\n>>\n' "${ISSUE_BODY:-}"
    printf 'JSON<<\n%s\n>>\n' "${ISSUE_JSON:-}"
    printf 'COMMENTS<<\n%s\n>>\n' "${ISSUE_COMMENTS_JSON:-}"
  )
  rm -f "$map" "$ghlog"
}

# forge_field <repo-dir> <RC|EXPORTED_LABELS|EXPORTED_BODY>
forge_field() { _forge_env "$1" | sed -n "s/^$2=//p"; }

# forge_block <repo-dir> <LABELS|BODY> — the value between the << >> markers.
forge_block() { _forge_env "$1" | sed -n "/^$2<</,/^>>$/p" | sed '1d;$d'; }

# --- cases -------------------------------------------------------------

section "forge_export_issue — fills what the classifiers already prefer"

REPO_GH="$(make_repo 'https://github.com/o/r.git')"

# classify-agent / classify-task / classify-turns read ISSUE_LABELS one name per
# line and call gh only when it is unset. Filling it is the whole adapter.
assert_eq "labels arrive one per line" "$(printf 'ai-implement\nturns:80')" \
  "$(forge_block "$REPO_GH" LABELS)"

# title + "\n" + body, matching what classify-turns.sh's own gh fallback builds.
# Body alone would make the injected path score differently from the fallback
# for any issue whose signal is in the title.
assert_eq "body is title + newline + body" "$(printf 'Do the thing\nImplement the thing.')" \
  "$(forge_block "$REPO_GH" BODY)"

assert_eq "ISSUE_LABELS is exported, not shell-local" "1" \
  "$(forge_field "$REPO_GH" EXPORTED_LABELS)"

assert_eq "ISSUE_BODY is exported, not shell-local" "1" \
  "$(forge_field "$REPO_GH" EXPORTED_BODY)"

assert_eq "github path succeeds" "0" "$(forge_field "$REPO_GH" RC)"

# build-agent-prompt and check-attempt-cap prefer their own payloads. Filling all
# four from ONE gh call replaces what were five separate reads across the job.
assert_eq "ISSUE_JSON carries title, body and comments" "Do the thing|Implement the thing.|1" \
  "$(forge_block "$REPO_GH" JSON | python3 -c 'import sys,json; d=json.load(sys.stdin); print("%s|%s|%d" % (d["title"], d["body"], len(d["comments"])))')"

assert_eq "ISSUE_COMMENTS_JSON is the comments array" "1" \
  "$(forge_block "$REPO_GH" COMMENTS | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')"

section "an unsupported forge fails loudly, never silently empty"

# An empty ISSUE_LABELS is indistinguishable from "this issue has no labels",
# which every classifier would act on: no agent override, no model override,
# default turn budget. Exit 2 rather than leave that ambiguity.
#
# Forgejo is the unimplemented forge now -- azdo gained its adapter in #253
# step 3. This case is about the DEFAULT branch, not about any one forge, so it
# follows whichever is still unimplemented.
REPO_FJ="$(make_repo 'https://git.home.freaxnx01.ch/freax/hello.git')"
assert_eq "an unimplemented forge returns 2" "2" "$(forge_field "$REPO_FJ" RC)"

rm -rf "$REPO_GH" "$REPO_FJ"

section "export-issue-context.sh — GITHUB_ENV is injection-resistant"

# An issue body in a public repo is written by anyone. With a FIXED heredoc
# delimiter, a body containing that delimiter followed by KEY=value closes the
# heredoc early and sets arbitrary environment variables for every later step in
# the job. The delimiter is randomised per run precisely to stop that.
EXPORT="$ROOT/scripts/export-issue-context.sh"
inj_dir="$(mktemp -d)"
inj_map="$inj_dir/map"
cat > "$inj_dir/malicious.json" <<'JSON'
{
  "labels": [{ "name": "ai-implement" }],
  "title": "Looks ordinary",
  "body": "Normal text.\nPIPELINE_EOF\nINJECTED_VAR=pwned\nISSUE_BODY<<PIPELINE_EOF\nrest",
  "comments": []
}
JSON
printf 'issue view\t%s/malicious.json\n' "$inj_dir" > "$inj_map"

REPO_INJ="$(make_repo 'https://github.com/o/r.git')"
genv="$inj_dir/github_env"
: > "$genv"
# SC2030/SC2031: the exports are deliberately local to each subshell -- that
# isolation is what makes the three runs below independent.
# shellcheck disable=SC2030,SC2031
(
  cd "$REPO_INJ"
  export PATH="$MOCKS:$PATH"
  export GH_MOCK_LOG="$inj_dir/gh.log"
  export GH_MOCK_STDOUT_MAP="$inj_map"
  export GH_MOCK_AUTH_HOSTS="github.com"
  export REPO=o/r ISSUE_NUMBER=42 GITHUB_ENV="$genv"
  bash "$EXPORT"
) >/dev/null 2>&1

# Parse $GITHUB_ENV the way the runner does and assert the injected key is NOT
# among the variables it would set.
# Parse the way the RUNNER does: it honours both `KEY<<DELIM` heredocs and plain
# `KEY=value` lines. A parser that only understood heredocs would miss exactly
# the injected assignment this test exists to catch.
keys="$(python3 -c '
import re, sys
txt = open(sys.argv[1]).read()
out, i, lines = [], 0, txt.splitlines()
while i < len(lines):
    m = re.match(r"^(\w+)<<(\S+)$", lines[i])
    if m:
        name, delim = m.groups()
        out.append(name)
        i += 1
        while i < len(lines) and lines[i] != delim:
            i += 1
        i += 1
        continue
    m = re.match(r"^(\w+)=", lines[i])
    if m:
        out.append(m.group(1))
    i += 1
print(" ".join(out))' "$genv")"

assert_eq "only the four intended keys are set" \
  "ISSUE_LABELS ISSUE_BODY ISSUE_JSON ISSUE_COMMENTS_JSON" "$keys"

# $keys is a space-separated list of NAMES, so test membership rather than an
# anchored `NAME=` pattern -- which could never match and would pass vacuously.
if [[ " $keys " == *" INJECTED_VAR "* ]]; then
  fail "a crafted issue body cannot inject an env var" "INJECTED_VAR escaped the heredoc"
else
  pass "a crafted issue body cannot inject an env var"
fi

# And the delimiter must differ run to run, or it is guessable again.
: > "$genv"
# shellcheck disable=SC2030,SC2031
(
  cd "$REPO_INJ"
  export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$inj_dir/gh2.log" GH_MOCK_STDOUT_MAP="$inj_map"
  export GH_MOCK_AUTH_HOSTS="github.com" REPO=o/r ISSUE_NUMBER=42 GITHUB_ENV="$genv"
  bash "$EXPORT"
) >/dev/null 2>&1
d2="$(sed -n 's/^ISSUE_LABELS<<//p' "$genv" | head -1)"
: > "$genv"
# shellcheck disable=SC2030,SC2031
(
  cd "$REPO_INJ"
  export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$inj_dir/gh3.log" GH_MOCK_STDOUT_MAP="$inj_map"
  export GH_MOCK_AUTH_HOSTS="github.com" REPO=o/r ISSUE_NUMBER=42 GITHUB_ENV="$genv"
  bash "$EXPORT"
) >/dev/null 2>&1
d3="$(sed -n 's/^ISSUE_LABELS<<//p' "$genv" | head -1)"
if [[ -n "$d2" && "$d2" != "$d3" ]]; then
  pass "the delimiter differs between runs"
else
  fail "the delimiter differs between runs" "got '$d2' twice"
fi

rm -rf "$inj_dir" "$REPO_INJ"

section "write verbs — the call reaches the forge intact"

# A write verb's contract IS the call it makes, so assert on the argv the mock
# records rather than on a return value.
w_dir="$(mktemp -d)"
w_log="$w_dir/gh.log"
REPO_W="$(make_repo 'https://github.com/o/r.git')"

# shellcheck disable=SC2030,SC2031
run_write() {
  : > "$w_log"
  (
    cd "$REPO_W"
    export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$w_log" GH_MOCK_AUTH_HOSTS="github.com" REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    "$@"
  ) >/dev/null 2>&1
  # detect_forge probes with `gh auth token` and that lands in the same log, so
  # take the last line: the write itself, which is what the verb's contract is.
  tail -1 "$w_log"
}

printf 'hello\n' > "$w_dir/body.md"

# The comment verb takes a FILE, never a string: a run report is multi-line and
# long enough that passing it as an argument is a real risk.
assert_eq "comment passes a body file" \
  "issue comment 42 --repo o/r --body-file $w_dir/body.md" \
  "$(run_write forge_issue_comment 42 "$w_dir/body.md")"

assert_eq "label add" "issue edit 42 --repo o/r --add-label a,b" \
  "$(run_write forge_issue_label_add 42 'a,b')"

assert_eq "label remove" "issue edit 42 --repo o/r --remove-label a" \
  "$(run_write forge_issue_label_remove 42 'a')"

assert_eq "label ensure" "label create x --repo o/r --color FF0000 --description d" \
  "$(run_write forge_label_ensure x FF0000 d)"

section "write verbs refuse an unimplemented forge"

# Same rule as the read verb: a write that silently does nothing is worse than
# one that fails, because the caller reports success.
REPO_WA="$(make_repo 'https://git.home.freaxnx01.ch/freax/hello.git')"
# shellcheck disable=SC2030,SC2031
azdo_rc() {
  (
    cd "$REPO_WA"
    # GH_MOCK_AUTH_HOSTS must EXCLUDE this host. The gh mock exits 0 for any
    # host by default, so without it detect_forge's auth probe succeeds and an
    # unimplemented forge is detected as github -- and the verb passes for the
    # wrong reason.
    export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$w_dir/a.log" REPO=o/r
    export GH_MOCK_AUTH_HOSTS="github.com"
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    rc=0; "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
  )
}
assert_eq "comment on an unimplemented forge returns 2"      "2" "$(azdo_rc forge_issue_comment 42 "$w_dir/body.md")"
assert_eq "label add on an unimplemented forge returns 2"    "2" "$(azdo_rc forge_issue_label_add 42 'a')"
assert_eq "label ensure on an unimplemented forge returns 2" "2" "$(azdo_rc forge_label_ensure x FF0000 d)"

rm -rf "$w_dir" "$REPO_W" "$REPO_WA"

section "azdo read branch — normalised to gh's shape"

# The two calls return different documents, so the mock needs a per-call map.
az_dir="$(mktemp -d)"
az_map="$az_dir/map"
printf 'work-item show\t%s/forge-workitem-azdo.json\n' "$FIXTURES" > "$az_map"
printf 'resource comments\t%s/forge-comments-azdo.json\n' "$FIXTURES" >> "$az_map"
REPO_AZ="$(make_repo 'https://dev.azure.com/contoso/MyProject/_git/my-repo')"

# shellcheck disable=SC2030,SC2031
az_read() {
  (
    cd "$REPO_AZ"
    export PATH="$MOCKS:$PATH"
    export AZ_MOCK_FIXTURE="$FIXTURES/forge-workitem-azdo.json"
    export AZ_MOCK_MAP="$az_map"
    export REPO=ignored-on-azdo
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    forge_export_issue 42 >/dev/null 2>&1 || true
    printf 'L<<\n%s\n>>\n' "${ISSUE_LABELS:-}"
    printf 'B<<\n%s\n>>\n' "${ISSUE_BODY:-}"
    printf 'J<<\n%s\n>>\n' "${ISSUE_JSON:-}"
    printf 'C<<\n%s\n>>\n' "${ISSUE_COMMENTS_JSON:-}"
  )
}
az_block() { az_read | sed -n "/^$1<</,/^>>$/p" | sed '1d;$d'; }

# Tags are `; `-separated -- semicolon AND space. Splitting on the bare
# character leaves leading whitespace on every tag after the first.
assert_eq "tags become labels, one per line, stripped" "$(printf 'ai-implement\nturns:80')" \
  "$(az_block L)"

# Same shape as the GitHub branch. Including the title also stops this being
# EMPTY for a work item with no description -- which the classifiers' guards
# would read as "not injected" and fall back to gh for.
assert_eq "body is title + newline + description" "$(printf 'Do the thing\nImplement the thing.')" \
  "$(az_block B)"

# An ADO comment's text is `.text`; build-agent-prompt reads `.body`. Without the
# mapping every comment renders EMPTY -- and silently, which is the whole risk.
assert_eq "comments are normalised from .text to .body" "A discussion comment." \
  "$(az_block J | python3 -c 'import sys,json; print(json.load(sys.stdin)["comments"][0]["body"])')"

rm -rf "$az_dir" "$REPO_AZ"

section "azdo comments become plain text"

# The comments API returns HTML; check-attempt-cap matches on a leading
# "## ai-implement run", so a <div> wrapper hides every report from the cap.
az_dir="$(mktemp -d)"
az_map="$az_dir/map"
printf 'work-item show\t%s/forge-workitem-azdo.json\n' "$FIXTURES" > "$az_map"
printf 'resource comments\t%s/azdo-comments-report-html.json\n' "$FIXTURES" >> "$az_map"
REPO_AZ="$(make_repo 'https://dev.azure.com/contoso/MyProject/_git/my-repo')"

cbody() { az_block C | python3 -c 'import sys,json; print(json.load(sys.stdin)[int(sys.argv[1])]["body"], end="")' "$1"; }
REPORT_HEAD='## ai-implement run (pipeline, Azure DevOps) — attempt 1'

assert_eq "web-UI report body starts with the report heading" "$REPORT_HEAD" \
  "$(cbody 0 | head -n1)"
case "$(cbody 0)" in
  *$'\n**Outcome:** failed: transient'*) pass "report body keeps its outcome line on its own line" ;;
  *) fail "report body keeps its outcome line on its own line" ;;
esac
assert_eq "entities are unescaped after tags are stripped" "a <b> tag & text" "$(cbody 2)"
assert_eq "ISSUE_JSON comments match ISSUE_COMMENTS_JSON" "$(cbody 0)" \
  "$(az_block J | python3 -c 'import sys,json; print(json.load(sys.stdin)["comments"][0]["body"], end="")')"
assert_eq "pipeline-posted body keeps its newlines and heading" "$REPORT_HEAD" \
  "$(cbody 3 | head -n1)"
assert_eq "pipeline-posted body ends with the unescaped note" "- note: a < b && c > d" \
  "$(cbody 3 | tail -n1)"

cap_out="$(ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 ISSUE_COMMENTS_JSON="$(az_block C)" \
  bash "$ROOT/scripts/check-attempt-cap.sh" 2>/dev/null)"
assert_eq "attempt cap counts the real attempt" "attempt=2" "$(grep '^attempt=' <<<"$cap_out")"
assert_eq "attempt cap counts both non-starts" "non-starts=2" "$(grep '^non-starts=' <<<"$cap_out")"

rm -rf "$az_dir" "$REPO_AZ"

# A null or empty text, or a null comments list, must degrade to empty -- the
# conversion may not crash the export (the old mapping passed null through).
text_of() {
  # shellcheck disable=SC1090
  ( source "$LIB"; printf '%s' "$1" | _forge_azdo_comments_text )
}
assert_eq "null comment text yields an empty body" '[{"body": ""}]' \
  "$(text_of '{"comments":[{"text":null}]}')"
assert_eq "empty comment text yields an empty body" '[{"body": ""}]' \
  "$(text_of '{"comments":[{"text":""}]}')"
assert_eq "null comments list yields an empty array" '[]' \
  "$(text_of '{"comments":null}')"

# A real report, read back from the comments API after the in-job retry proof
# (2026-11-09): markdown with no wrapper tags, format "html".
live_comments="$(text_of "$(cat "$FIXTURES/azdo-comments-report-live.json")")"
assert_eq "live report body starts with the report heading" "$REPORT_HEAD" \
  "$(python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["body"].splitlines()[0])' <<<"$live_comments")"
live_cap="$(ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 ISSUE_COMMENTS_JSON="$live_comments" \
  bash "$ROOT/scripts/check-attempt-cap.sh" 2>/dev/null)"
assert_eq "live report counts as one real attempt" "attempt=2" "$(grep '^attempt=' <<<"$live_cap")"
assert_eq "live report is not a non-start" "non-starts=0" "$(grep '^non-starts=' <<<"$live_cap")"

section "azdo tag arithmetic — read-modify-write, since set_tags REPLACES"

# The label verbs are read-modify-write on this forge: azdo_set_tags replaces the
# whole field, because the --fields form appends and cannot clear. This is the
# arithmetic that decides what gets written.
retag() {
  printf '%s' "$1" | python3 -c '
import sys
cur = [t.strip() for t in sys.stdin.read().splitlines() if t.strip()]
add = [t.strip() for t in sys.argv[1].split(",") if t.strip()]
rm  = {t.strip() for t in sys.argv[2].split(",") if t.strip()}
out = [t for t in cur if t not in rm]
for t in add:
    if t not in out:
        out.append(t)
print(";".join(out))' "$2" "$3"
}

assert_eq "add appends"            "a;b;c"  "$(retag "$(printf 'a\nb')" 'c' '')"
assert_eq "add is idempotent"      "a;b"    "$(retag "$(printf 'a\nb')" 'b' '')"
assert_eq "remove drops one"       "b"      "$(retag "$(printf 'a\nb')" '' 'a')"
assert_eq "add and remove together" "b;c"   "$(retag "$(printf 'a\nb')" 'c' 'a')"
assert_eq "removing everything clears" ""   "$(retag "$(printf 'a\nb')" '' 'a,b')"

section "PR verbs"

# pr_run <repo-dir> <forge> <fn> [args...] — runs one PR verb in a subshell with
# both mocks on PATH and the logs in $PR_LOG_DIR. Echoes stdout; stderr goes to
# $PR_LOG_DIR/err; the verb's status is written to $PR_LOG_DIR/rc.
# shellcheck disable=SC2030,SC2031
pr_run() {
  local dir="$1" forge="$2"; shift 2
  (
    cd "$dir"
    export PATH="$MOCKS:$PATH"
    export GH_MOCK_LOG="$PR_LOG_DIR/gh.log" AZ_MOCK_LOG="$PR_LOG_DIR/az.log"
    export AZ_MOCK_STDIN_LOG="$PR_LOG_DIR/az.stdin"
    export FORGE="$forge" REPO=o/r
    # shellcheck disable=SC1090
    source "$ROOT/scripts/lib/detect-forge.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    rc=0
    "$@" 2>"$PR_LOG_DIR/err" || rc=$?
    printf '%s' "$rc" > "$PR_LOG_DIR/rc"
  )
}
pr_reset() { rm -f "$PR_LOG_DIR"/{gh.log,az.log,az.stdin,err,rc}; : > "$PR_LOG_DIR/gh.log"; : > "$PR_LOG_DIR/az.log"; : > "$PR_LOG_DIR/az.stdin"; }
pr_rc() { cat "$PR_LOG_DIR/rc"; }

PR_LOG_DIR="$(mktemp -d)"
PR_NOGIT="$(mktemp -d)"   # not a git repo: proves github never calls detect_forge
PR_BODY="$PR_LOG_DIR/body.md"
# shellcheck disable=SC2016  # literal backtick and $ are the point
printf 'First line with `backtick` and $HOME\nsecond line\n' > "$PR_BODY"

pr_reset; pr_run "$PR_NOGIT" github forge_pr_diff 42 >/dev/null
assert_eq "github pr diff argv" "pr diff 42 --repo o/r" "$(cat "$PR_LOG_DIR/gh.log")"
pr_reset; pr_run "$PR_NOGIT" github forge_pr_head_sha 42 >/dev/null
assert_eq "github pr head sha argv" "pr view 42 --repo o/r --json headRefOid --jq .headRefOid" "$(cat "$PR_LOG_DIR/gh.log")"
pr_reset; pr_run "$PR_NOGIT" github forge_pr_comment 42 "$PR_BODY" >/dev/null
assert_eq "github pr comment argv" "pr comment 42 --repo o/r --body-file $PR_BODY" "$(cat "$PR_LOG_DIR/gh.log")"
pr_reset; pr_run "$PR_NOGIT" github forge_pr_comments_json 42 >/dev/null
assert_eq "github pr comments argv" "pr view 42 --repo o/r --json comments --jq .comments[].body" "$(cat "$PR_LOG_DIR/gh.log")"
assert_eq "github PR verbs never ask for an auth token" "0" "$(grep -c 'auth token' "$PR_LOG_DIR/gh.log" || true)"

REPO_PR="$(make_repo 'https://dev.azure.com/contoso/MyProject/_git/my-repo')"

pr_reset; AZ_MOCK_FIXTURE="$FIXTURES/azdo-pr-thread-created.json" pr_run "$REPO_PR" azdo forge_pr_comment 42 "$PR_BODY" >/dev/null
assert_eq "pr_comment_posts_one_active_thread: one az call" "1" "$(wc -l < "$PR_LOG_DIR/az.log" | tr -d ' ')"
for needle in '--area git --resource pullRequestThreads' 'pullRequestId=42' 'repositoryId=my-repo' '--http-method POST'; do
  case "$(cat "$PR_LOG_DIR/az.log")" in
    *"$needle"*) pass "pr_comment argv has $needle" ;;
    *) fail "pr_comment argv has $needle" "$(cat "$PR_LOG_DIR/az.log")" ;;
  esac
done
assert_eq "pr_comment thread is active" "active" "$(jq -r '.status' "$PR_LOG_DIR/az.stdin")"
jq -j '.comments[0].content' "$PR_LOG_DIR/az.stdin" > "$PR_LOG_DIR/posted.md"
if cmp -s "$PR_LOG_DIR/posted.md" "$PR_BODY"; then pass "pr_comment body arrives byte for byte"; else fail "pr_comment body arrives byte for byte"; fi

# Round trip: what was POSTed, served back by the GET, must still carry the
# marker line the review script greps for.
jq -s '{value: ., count: length}' "$PR_LOG_DIR/az.stdin" > "$PR_LOG_DIR/round-trip.json"
pr_reset; out="$(AZ_MOCK_FIXTURE="$PR_LOG_DIR/round-trip.json" pr_run "$REPO_PR" azdo forge_pr_comments_json 42)"
# shellcheck disable=SC2016
case "$out" in *'First line with `backtick` and $HOME'*) pass "pr_comments_json_round_trip" ;; *) fail "pr_comments_json_round_trip" "$out" ;; esac

pr_reset; out="$(AZ_MOCK_FIXTURE="$FIXTURES/azdo-pr-threads-marker.json" pr_run "$REPO_PR" azdo forge_pr_comments_json 42)"
case "$out" in *'<!-- review-pr:abc123 -->'*) pass "pr_comments_json_skips_contentless: marker present" ;; *) fail "pr_comments_json_skips_contentless: marker present" "$out" ;; esac
case "$out" in *None*|*null*) fail "pr_comments_json_skips_contentless: no None/null" "$out" ;; *) pass "pr_comments_json_skips_contentless: no None/null" ;; esac

# Real threads read back after the live self-fix proof (2026-11-09): a review,
# a system "reference updated" thread, and the re-review on the fix commit.
pr_reset; out="$(AZ_MOCK_FIXTURE="$FIXTURES/azdo-pr-threads-live.json" pr_run "$REPO_PR" azdo forge_pr_comments_json 42)"
case "$out" in *'<!-- review-pr:51e1e76148e5541bc5d7fdb4f5d97603efa7623e -->'*) pass "pr_comments_json_live: first marker" ;; *) fail "pr_comments_json_live: first marker" "$out" ;; esac
case "$out" in *'<!-- review-pr:e4c16fb19e8d754265ecebe9d3daa380e1d7e73f -->'*) pass "pr_comments_json_live: re-review marker" ;; *) fail "pr_comments_json_live: re-review marker" "$out" ;; esac

# A repo with origin/main and an agent branch that adds src/a.txt.
REPO_DIFF="$(make_repo 'https://dev.azure.com/contoso/MyProject/_git/my-repo')"
(
  cd "$REPO_DIFF"
  git config user.email t@example.invalid; git config user.name t
  git checkout -q -b main
  printf 'base\n' > base.txt; git add base.txt; git commit -q -m base
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b agent/x
  mkdir src; printf 'new\n' > src/a.txt; git add src/a.txt; git commit -q -m feature
  git config diff.noprefix true
)
pr_reset; out="$(DEFAULT_BRANCH=main pr_run "$REPO_DIFF" azdo forge_pr_diff 42)"
case "$out" in *'diff --git a/src/a.txt b/src/a.txt'*) pass "pr_diff_azdo_three_dot (diff.noprefix ignored)" ;; *) fail "pr_diff_azdo_three_dot (diff.noprefix ignored)" "$out" ;; esac

pr_reset; pr_run "$REPO_DIFF" azdo forge_pr_diff 42 >/dev/null
assert_eq "pr_diff_azdo_requires_default_branch: rc 1" "1" "$(pr_rc)"
case "$(cat "$PR_LOG_DIR/err")" in *'DEFAULT_BRANCH must be set'*) pass "pr_diff_azdo_requires_default_branch: message" ;; *) fail "pr_diff_azdo_requires_default_branch: message" "$(cat "$PR_LOG_DIR/err")" ;; esac

pr_reset; out="$(pr_run "$REPO_DIFF" azdo forge_pr_head_sha 42)"
assert_eq "pr_head_sha_azdo equals git rev-parse HEAD" "$(git -C "$REPO_DIFF" rev-parse HEAD)" "$out"
assert_eq "pr_head_sha_azdo makes no az call" "0" "$(wc -c < "$PR_LOG_DIR/az.log" | tr -d ' ')"

# IFS is newline/tab here, so the verb and its arguments go in as separate words.
for verb in forge_pr_diff forge_pr_head_sha forge_pr_comment forge_pr_comments_json; do
  pr_reset
  DEFAULT_BRANCH=main pr_run "$REPO_PR" forgejo "$verb" 42 "$PR_BODY" >/dev/null
  assert_eq "pr_verbs_refuse_unknown_forge: $verb" "2" "$(pr_rc)"
done

# `:?` exits the shell it runs in, so the verb runs in a nested subshell.
# shellcheck disable=SC2317  # called through pr_run
without_repo() { ( unset REPO; "$@" ); }
for verb in forge_pr_diff forge_pr_head_sha forge_pr_comment forge_pr_comments_json; do
  pr_reset
  pr_run "$PR_NOGIT" github without_repo "$verb" 42 "$PR_BODY" >/dev/null
  if [[ "$(pr_rc)" -ne 0 ]]; then pass "pr_verbs_github_need_repo: $verb"; else fail "pr_verbs_github_need_repo: $verb" "rc 0"; fi
done

printf '{"value":[{"id":1,"status":"active"}],"count":1}' > "$PR_LOG_DIR/no-comments-key.json"
pr_reset; out="$(AZ_MOCK_FIXTURE="$PR_LOG_DIR/no-comments-key.json" pr_run "$REPO_PR" azdo forge_pr_comments_json 42)"
assert_eq "pr_comments_json_thread_without_comments: no output" "" "$out"
assert_eq "pr_comments_json_thread_without_comments: rc 0" "0" "$(pr_rc)"
assert_eq "pr_comments_json_thread_without_comments: no error" "" "$(cat "$PR_LOG_DIR/err")"

rm -rf "$PR_LOG_DIR" "$PR_NOGIT" "$REPO_PR" "$REPO_DIFF"

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
