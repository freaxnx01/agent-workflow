#!/usr/bin/env bash
#
# run-backlog-milestone-tests.sh — Layer-1 tests for the `backlog` milestone
# rules in /parked, /roadmap and /milestone triage (#644, ai-instructions#61).
#
# These run the command text, not grep it: each test pulls the ```bash fences
# out of a command's section and executes them against fixture JSON, with `gh`
# and `tea` replaced by stubs that serve the fixtures through the real jq and
# log every call.
#
# Usage: tests/run-backlog-milestone-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMDS="$ROOT/commands"

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
# ok <name> <detail> <command...> — pass when the command succeeds
ok() { local name="$1" detail="$2"; shift 2; if "$@"; then pass "$name"; else fail "$name" "$detail"; fi; }
# no <name> <detail> <command...> — pass when the command fails
no() { local name="$1" detail="$2"; shift 2; if "$@"; then fail "$name" "$detail"; else pass "$name"; fi; }
has() { [[ "$1" == *"$2"* ]]; }

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
printf '%s\n' '[{"title": "v1.2 · goal", "due_on": null}, {"title": "backlog", "due_on": null}]' > "$WORK/ms-with-backlog.json"
printf '%s\n' '[{"title": "v1.2 · goal", "due_on": null}]' > "$WORK/ms-without-backlog.json"
printf '%s\n' '{"number": 42, "milestone": {"title": "v1.2 · goal"}}' > "$WORK/issue-in-v12.json"
printf '%s\n' '{"number": 42, "milestone": {"title": "backlog"}}' > "$WORK/issue-in-backlog.json"
printf '%s\n' '{"comments": [{"body": "parked: waiting on vendor"}, {"body": "roadmap: waiting on vendor"}]}' > "$WORK/comments.json"

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
    *"/milestones"*) cat "$FIX_MS" ;;
    *"/issues?"*) cat "$FIX_ISSUES" ;;
    *) printf "unexpected tea call: %s\n" "$*" >&2; return 99 ;;
  esac
}
'

# run <code> <milestones fixture> <issue fixture> — runs code with the stubs;
# sets OUT, RC and LOG.
run() {
  LOG="$WORK/log.$RANDOM"; : > "$LOG"
  RC=0
  OUT="$(LOG="$LOG" FIX_MS="$2" FIX_ISSUE="$3" FIX_ISSUES="$WORK/issues.json" \
    FIX_COMMENTS="$WORK/comments.json" bash -c "$STUBS$1" 2>&1)" || RC=$?
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
