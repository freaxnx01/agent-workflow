# Backlog Milestone Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An issue opened or reopened without a milestone gets the standing
`backlog` milestone (#646). The change ships three things:

- a dry-run-first backfill script for existing issues;
- a consumer stub written by onboarding;
- this repo's own dogfood caller.

**Architecture:** It mirrors the issue-intake guard (#549):

- one shared lib (`scripts/lib/backlog-milestone.sh`);
- an env-driven guard script, plus a flag-driven backfill script;
- a reusable workflow with `local-scripts` / `stub-mode` inputs;
- a Layer-2 `*.test.yml`;
- a dogfood caller;
- a stub generator in `scripts/onboard-consumer.sh`.

**Tech Stack:** Bash 5, jq, gh (mocked by `tests/mocks/gh`), GitHub Actions
YAML, python3 + PyYAML in the tests, actionlint, shellcheck.

**Spec:** `docs/superpowers/specs/2026-11-19-backlog-milestone-guard-design.md`

## Global Constraints

- **Never create the `backlog` milestone.** If it is missing, the guard
  prints `::warning::` and exits 0, and the backfill exits 64. No code path
  POSTs to `/milestones`.
- **Only an open milestone titled exactly `backlog` counts.**
- **The write is `gh api -X PATCH "repos/$REPO/issues/$N" -F "milestone=$NUM"`.**
  It carries only the milestone field, and the argument order is exactly
  this, because the tests grep the mock log for it.
- **Paginated reads are `--paginate` piped into `jq -s`.** Never use
  `gh --jq`, which runs once per page and which the mock ignores.
- **SECURITY: this is a public repo, so anyone can open an issue.** No
  workflow may reference `github.event.issue.title`, `.body`, `.user` or any
  `github.event.comment` field. Only `github.event.issue.number` goes in,
  through `with:`, and the script gets `REPO`, `ISSUE_NUMBER` and `GH_TOKEN`
  via `env:`.
- **Workflows:**
  - Pin every action by full SHA. Checkout is
    `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`.
  - Top-level `permissions:` is `contents: read`. `issues: write` goes on
    jobs only.
  - Every job that runs steps has `timeout-minutes:`.
  - No inline `run:` block is longer than 5 lines.
- **Every script starts with the stack prelude:** `set -euo pipefail` and
  `IFS=$'\n\t'`.
- **The implementing agent must NOT run the backfill against a real repo and
  must NOT open a test issue.** Those are post-merge manual steps (spec A2).
- **Do not edit `commands/*.md` or `docs/COMMAND-CHEATSHEET.md`**, because
  #644 and #645 own them. Do not edit `docs/DECISIONS.md` or reword
  ADR-017; #616 owns that. Do not touch `scripts/pipeline-pause.sh` (spec
  A11).
- **Commit messages reference `(#646)` and never contain `Closes`.**
- **Lint a new file only after `git add`:** pre-commit `--all-files` skips
  untracked files.
- **The runner is `tests/run-backlog-milestone-guard-tests.sh`, not
  `run-backlog-milestone-tests.sh`.** #644's plan creates
  `tests/run-backlog-milestone-tests.sh` for the command-side filters. If
  that file already exists when this runs, leave it alone.

## File Structure

| File | Change |
|---|---|
| `scripts/lib/backlog-milestone.sh` | new: `BACKLOG_MILESTONE`, `backlog_milestone_number`, `assign_milestone` |
| `scripts/assign-backlog-milestone.sh` | new: per-issue guard (env-driven) |
| `scripts/backfill-backlog-milestone.sh` | new: one-off backfill (`-R`, `--apply`) |
| `tests/fixtures/backlog-milestone/*.json` | new: fixtures |
| `tests/run-backlog-milestone-guard-tests.sh` | new: Layer-1 runner (picked up by `tests/run-all.sh`) |
| `.github/workflows/backlog-milestone.yml` | new: reusable workflow |
| `.github/workflows/backlog-milestone.test.yml` | new: Layer-2 test |
| `.github/workflows/issue-milestone.yml` | new: dogfood caller for this repo |
| `justfile` | add a `test-act` line |
| `scripts/onboard-consumer.sh` | `build_milestone_yml` + both write paths + header |
| `tests/run-onboard-stub-tests.sh` | stub assertions |
| `docs/CONSUMER-SETUP.md` | new §3d |
| `CHANGELOG.md` | `[Unreleased]` → `### Added` entry (shared with #644/#645) |

---

## Task 1: Fixtures, shared lib and the per-issue guard

**Files:**

- Create:
  - `tests/fixtures/backlog-milestone/` (fixtures below)
  - `tests/run-backlog-milestone-guard-tests.sh`
  - `scripts/lib/backlog-milestone.sh`
  - `scripts/assign-backlog-milestone.sh`

- [ ] **Step 1: Write the fixtures**

  The two-page files hold two concatenated JSON arrays, which is exactly what
  `gh api --paginate` prints. `check-json` excludes `tests/fixtures/`, so this
  is allowed.

`tests/fixtures/backlog-milestone/issue-open.json`:

```json
{"number": 42, "state": "open", "milestone": null, "labels": [], "title": "x", "body": "x"}
```

`tests/fixtures/backlog-milestone/issue-has-milestone.json`:

```json
{"number": 42, "state": "open", "milestone": {"number": 9, "title": "v2.3 · intake"}, "labels": [], "title": "x", "body": "x"}
```

`tests/fixtures/backlog-milestone/issue-closed.json`:

```json
{"number": 42, "state": "closed", "milestone": null, "labels": [], "title": "x", "body": "x"}
```

`tests/fixtures/backlog-milestone/issue-pull-request.json`:

```json
{"number": 42, "state": "open", "milestone": null, "pull_request": {"url": "x"}, "labels": [], "title": "x", "body": "x"}
```

`tests/fixtures/backlog-milestone/milestones-with-backlog.json`:

```json
[{"number": 9, "title": "v2.3 · intake", "state": "open"}, {"number": 7, "title": "backlog", "state": "open"}]
```

`tests/fixtures/backlog-milestone/milestones-without-backlog.json`:

```json
[{"number": 9, "title": "v2.3 · intake", "state": "open"}, {"number": 5, "title": "backlog-old", "state": "open"}]
```

`tests/fixtures/backlog-milestone/milestones-two-pages.json`:

```json
[{"number": 9, "title": "v2.3 · intake", "state": "open"}]
[{"number": 7, "title": "backlog", "state": "open"}]
```

`tests/fixtures/backlog-milestone/unmilestoned-two-pages.json`:

```json
[{"number": 11, "state": "open", "milestone": null}, {"number": 12, "state": "open", "milestone": null}, {"number": 13, "state": "open", "milestone": null, "pull_request": {"url": "x"}}]
[{"number": 14, "state": "open", "milestone": null}]
```

`tests/fixtures/backlog-milestone/unmilestoned-empty.json`:

```json
[]
```

- [ ] **Step 2: Write the failing test runner (guard sections)**

  Create `tests/run-backlog-milestone-guard-tests.sh` with the content below. Task 2
  and Task 3 append sections **above the summary block**.

```bash
#!/usr/bin/env bash
#
# run-backlog-milestone-guard-tests.sh — Layer-1 tests for the backlog milestone
# guard (#646): scripts/assign-backlog-milestone.sh,
# scripts/backfill-backlog-milestone.sh and their workflows. gh is mocked; no
# network.
#
# Usage: tests/run-backlog-milestone-guard-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/backlog-milestone"
MOCKS="$ROOT/tests/mocks"
GUARD="$ROOT/scripts/assign-backlog-milestone.sh"
BACKFILL="$ROOT/scripts/backfill-backlog-milestone.sh"

unset GITHUB_REPOSITORY GITHUB_OUTPUT GITHUB_STEP_SUMMARY REPO ISSUE_NUMBER DRY_RUN

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

decide() {
  # shellcheck disable=SC1090
  (source "$GUARD"; milestone_decision < "$FIX/$1")
}

section "milestone_decision — which issues the guard touches"

assert_eq "an open issue with no milestone is assigned" "assign" "$(decide issue-open.json)"
assert_eq "an issue with a milestone is left alone" "skip has milestone v2.3 · intake" "$(decide issue-has-milestone.json)"
assert_eq "a closed issue is left alone" "skip issue is closed" "$(decide issue-closed.json)"
assert_eq "a pull request is left alone" "skip is a pull request" "$(decide issue-pull-request.json)"

section "backlog_milestone_number — exact title, every page"

# lookup <milestones-fixture> — the lib's lookup with gh mocked.
lookup() {
  local d; d="$(mktemp -d)"
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$1" > "$d/map"
  # shellcheck disable=SC1090
  (export PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" GH_MOCK_STDOUT_MAP="$d/map"
   source "$ROOT/scripts/lib/backlog-milestone.sh"; backlog_milestone_number freaxnx01/sample)
  rm -rf "$d"
}
assert_eq "finds backlog among other milestones" "7" "$(lookup milestones-with-backlog.json)"
assert_eq "a near-miss title does not count" "" "$(lookup milestones-without-backlog.json)"
assert_eq "finds backlog on the second page" "7" "$(lookup milestones-two-pages.json)"

# run_guard <dir> <issue-fixture> <milestones-fixture> [extra env...]
run_guard() {
  local dir="$1" issue="$2" milestones="$3"; shift 3
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$milestones" 'api repos/' "$FIX/$issue" > "$dir/map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/map" \
    REPO=freaxnx01/sample ISSUE_NUMBER=42 "$@" bash "$GUARD" 2>&1
}

section "the guard — write path"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "assigned -> exit 0" "0" "$rc"
assert_contains "assigned -> says so" "$out" 'milestone: #42 assigned backlog'
assert_contains "assigned -> PATCHes only the milestone, by number" "$(cat "$d/gh")" \
  'api -X PATCH repos/freaxnx01/sample/issues/42 -F milestone=7'
assert_contains "the issue is re-read over REST" "$(cat "$d/gh")" 'api repos/freaxnx01/sample/issues/42'
assert_contains "GITHUB_OUTPUT gets decision=assigned" "$(cat "$d/out")" 'decision=assigned'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-has-milestone.json milestones-with-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "has a milestone -> exit 0" "0" "$rc"
assert_contains "has a milestone -> says why" "$out" 'milestone: #42 skipped (has milestone v2.3 · intake)'
assert_not_contains "has a milestone -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "has a milestone -> no milestone lookup" "$(cat "$d/gh")" 'milestones?'
assert_contains "GITHUB_OUTPUT names the reason" "$(cat "$d/out")" 'reason=has milestone v2.3 · intake'
rm -rf "$d"

section "the guard — no backlog milestone warns, never creates"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-without-backlog.json GITHUB_OUTPUT="$d/out")" || rc=$?
assert_eq "missing backlog -> exit 0" "0" "$rc"
assert_contains "missing backlog -> a warning annotation" "$out" '::warning::'
assert_contains "missing backlog -> skipped with reason" "$out" 'milestone: #42 skipped (no backlog milestone)'
assert_not_contains "missing backlog -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "missing backlog -> no milestone is created" "$(cat "$d/gh")" 'POST'
assert_contains "GITHUB_OUTPUT says skipped" "$(cat "$d/out")" 'decision=skipped'
rm -rf "$d"

section "the guard — dry run, failures, usage"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json DRY_RUN=1)" || rc=$?
assert_eq "dry run -> exit 0" "0" "$rc"
assert_contains "dry run -> says what it would do" "$out" 'DRY_RUN: would assign #42 to backlog (#7)'
assert_not_contains "dry run -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'api repos/freaxnx01/sample/issues/42' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "unreadable issue -> exit 1" "1" "$rc"
assert_not_contains "unreadable issue -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'milestones?state=open' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "unreadable milestone list -> exit 1" "1" "$rc"
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'PATCH' > "$d/fail"
rc=0; out="$(run_guard "$d" issue-open.json milestones-with-backlog.json GH_MOCK_FAIL_MAP="$d/fail")" || rc=$?
assert_eq "failed write -> exit 1" "1" "$rc"
rm -rf "$d"

rc=0; env -u REPO ISSUE_NUMBER=42 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "missing REPO -> exit 2" "2" "$rc"
rc=0; env REPO='a/b/../c' ISSUE_NUMBER=42 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "malformed REPO -> exit 2" "2" "$rc"
rc=0; env REPO=a/b ISSUE_NUMBER=0 bash "$GUARD" >/dev/null 2>&1 || rc=$?
assert_eq "non-positive ISSUE_NUMBER -> exit 2" "2" "$rc"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
```

- [ ] **Step 3: Run it and watch it fail**

Run: `chmod +x tests/run-backlog-milestone-guard-tests.sh && bash tests/run-backlog-milestone-guard-tests.sh`
Expected: FAIL, because the scripts do not exist yet. The decision and lookup
assertions fail first.

- [ ] **Step 4: Write `scripts/lib/backlog-milestone.sh`**

```bash
#!/usr/bin/env bash
#
# backlog-milestone.sh — the standing `backlog` milestone, looked up and
# assigned in one place (#646, freaxnx01/ai-instructions#61).
#
# Sourced by assign-backlog-milestone.sh (per issue, from a workflow) and
# backfill-backlog-milestone.sh (one-off, by an operator), so the two cannot
# disagree about which milestone counts or how it is written.
#
# Sourced, not executed. Exposes:
#   BACKLOG_MILESTONE          the milestone title
#   backlog_milestone_number   query — prints the number, or nothing
#   assign_milestone           command — writes the milestone field only
set -euo pipefail
IFS=$'\n\t'

BACKLOG_MILESTONE='backlog'

# backlog_milestone_number <repo> — the number of the OPEN milestone titled
# exactly $BACKLOG_MILESTONE, or nothing when there is none. A closed one does
# not count: the convention says it is never closed, so one that is should
# surface as "missing" rather than collect issues out of sight. Every page is
# slurped (`jq -s`); `gh --jq` would run once per page. Returns 1 when the list
# cannot be read. Query.
backlog_milestone_number() {
  local repo="$1" pages
  pages="$(gh api "repos/$repo/milestones?state=open&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs --arg t "$BACKLOG_MILESTONE" \
    '[.[][] | select(.title == $t) | .number] | first // empty'
}

# assign_milestone <repo> <issue> <milestone-number> — sets the milestone and
# nothing else. A PATCH carrying only `milestone` cannot clobber a label that
# issue-intake writes on the same `opened` event. Command.
assign_milestone() {
  local repo="$1" issue="$2" number="$3"
  gh api -X PATCH "repos/$repo/issues/$issue" -F "milestone=$number" >/dev/null
}
```

- [ ] **Step 5: Write `scripts/assign-backlog-milestone.sh`**

```bash
#!/usr/bin/env bash
#
# assign-backlog-milestone.sh — give an issue opened (or reopened) without a
# milestone the standing `backlog` milestone (#646).
#
# Every open issue carries a milestone (freaxnx01/ai-instructions#61). Several
# paths file issues without one — agent-filed follow-ups, scripts — so one
# event-driven guard catches them instead of patching each creator. Issues
# created with a workflow's GITHUB_TOKEN start no workflow and are never seen
# here; the backfill script catches those.
#
# Skipped: a closed issue, a pull request, an issue that already has any
# milestone. A repo with no open `backlog` milestone gets a ::warning:: and
# exit 0 — this script never creates the milestone.
#
# Required env: REPO (owner/name), ISSUE_NUMBER, GH_TOKEN (or ambient gh auth).
# Optional: DRY_RUN=1 decides and prints, writes nothing.
#
# Output: `milestone: #<n> assigned backlog` or `milestone: #<n> skipped
# (<reason>)`; `decision=` and `reason=` appended to $GITHUB_OUTPUT when set.
#
# Exit codes:
#   0  assigned, or skipped by rule (a missing backlog milestone is a skip)
#   1  the issue or the milestone list could not be read, or the write failed
#   2  REPO or ISSUE_NUMBER missing or invalid
set -euo pipefail
IFS=$'\n\t'

_ABM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/backlog-milestone.sh
source "$_ABM_HERE/lib/backlog-milestone.sh"

# milestone_decision — a REST issue object on stdin. Prints `assign` or
# `skip <reason>`. Query.
milestone_decision() {
  jq -r '
    if (.state // "") != "open" then "skip issue is closed"
    elif .pull_request != null then "skip is a pull request"
    elif .milestone != null then "skip has milestone " + (.milestone.title // "?")
    else "assign" end'
}

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }
fatal() { printf 'error: %s\n' "$1" >&2; exit 1; }

# report <decision> <reason> — the stdout line plus $GITHUB_OUTPUT. Command.
report() {
  local decision="$1" reason="$2"
  if [[ "$decision" == assigned ]]; then
    printf 'milestone: #%s assigned %s\n' "$ISSUE_NUMBER" "$BACKLOG_MILESTONE"
  else
    printf 'milestone: #%s skipped (%s)\n' "$ISSUE_NUMBER" "$reason"
  fi
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf 'decision=%s\nreason=%s\n' "$decision" "$reason" >> "$GITHUB_OUTPUT"
}

validate_env() {
  [[ "${REPO:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || usage_error "REPO must be owner/name (got: ${REPO:-})"
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || usage_error "ISSUE_NUMBER must be a positive integer (got: ${ISSUE_NUMBER:-})"
}

main() {
  validate_env
  local json decision number
  # Re-read, not the event payload: a milestone set between the event and this
  # run must win.
  json="$(gh api "repos/$REPO/issues/$ISSUE_NUMBER")" \
    || fatal "could not read issue #$ISSUE_NUMBER in $REPO — no milestone assigned"
  decision="$(printf '%s' "$json" | milestone_decision)" \
    || fatal "could not decide on issue #$ISSUE_NUMBER in $REPO"
  if [[ "$decision" != assign ]]; then
    report skipped "${decision#skip }"
    return 0
  fi

  number="$(backlog_milestone_number "$REPO")" \
    || fatal "could not read the milestones of $REPO — no milestone assigned"
  if [[ -z "$number" ]]; then
    printf '::warning::%s has no open "%s" milestone; #%s stays without one. Create it with /milestone new %s.\n' \
      "$REPO" "$BACKLOG_MILESTONE" "$ISSUE_NUMBER" "$BACKLOG_MILESTONE"
    report skipped "no $BACKLOG_MILESTONE milestone"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY_RUN: would assign #%s to %s (#%s)\n' "$ISSUE_NUMBER" "$BACKLOG_MILESTONE" "$number"
    return 0
  fi
  assign_milestone "$REPO" "$ISSUE_NUMBER" "$number" \
    || fatal "could not assign $BACKLOG_MILESTONE to #$ISSUE_NUMBER in $REPO"
  report assigned ''
}

# Sourced by tests/run-backlog-milestone-guard-tests.sh to call milestone_decision.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `chmod +x scripts/assign-backlog-milestone.sh && bash tests/run-backlog-milestone-guard-tests.sh`
Expected: `failed: 0`, exit 0.

- [ ] **Step 7: Lint**

Run: `git add scripts/lib/backlog-milestone.sh scripts/assign-backlog-milestone.sh tests/run-backlog-milestone-guard-tests.sh tests/fixtures/backlog-milestone && shellcheck -x -e SC1091 scripts/lib/backlog-milestone.sh scripts/assign-backlog-milestone.sh tests/run-backlog-milestone-guard-tests.sh`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(milestone): assign backlog to issues opened without a milestone (#646)"
```

---

## Task 2: Backfill script

**Files:**

- Create: `scripts/backfill-backlog-milestone.sh`
- Modify: `tests/run-backlog-milestone-guard-tests.sh` (append above the summary block)

- [ ] **Step 1: Append the failing backfill tests**

```bash
# run_backfill <dir> <unmilestoned-fixture> <milestones-fixture> [args...]
run_backfill() {
  local dir="$1" issues="$2" milestones="$3"; shift 3
  printf '%s\t%s\n' 'milestones?state=open' "$FIX/$milestones" 'milestone=none' "$FIX/$issues" > "$dir/map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/map" \
    ${GH_MOCK_FAIL_MAP:+GH_MOCK_FAIL_MAP="$GH_MOCK_FAIL_MAP"} \
    bash "$BACKFILL" -R freaxnx01/sample "$@" 2>&1
}

section "backfill — dry run counts every page, writes nothing"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json)" || rc=$?
assert_eq "dry run -> exit 0" "0" "$rc"
# 11, 12 on page one, 14 on page two; 13 is a pull request.
assert_contains "dry run -> counts across pages, PRs excluded" "$out" \
  'backfill: 3 open issues without a milestone in freaxnx01/sample'
assert_contains "dry run -> lists a page-two issue" "$out" '#14'
assert_not_contains "dry run -> does not list the pull request" "$out" '#13'
assert_contains "dry run -> says how to apply" "$out" 'DRY_RUN: would assign backlog (#7) to 3 issues'
assert_not_contains "dry run -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_contains "dry run -> reads every page" "$(cat "$d/gh")" '--paginate'
rm -rf "$d"

section "backfill — --apply assigns each issue"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "apply -> exit 0" "0" "$rc"
for n in 11 12 14; do
  assert_contains "apply -> #$n assigned" "$(cat "$d/gh")" "api -X PATCH repos/freaxnx01/sample/issues/$n -F milestone=7"
done
assert_not_contains "apply -> the pull request is not touched" "$(cat "$d/gh")" 'issues/13 '
assert_contains "apply -> reports the tally" "$out" 'backfill: assigned 3 of 3'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf '%s\n' 'issues/12 -F' > "$d/fail"
rc=0; out="$(GH_MOCK_FAIL_MAP="$d/fail" run_backfill "$d" unmilestoned-two-pages.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "one failed write -> exit 1" "1" "$rc"
assert_contains "one failed write -> keeps going" "$(cat "$d/gh")" 'issues/14 -F milestone=7'
assert_contains "one failed write -> the tally shows it" "$out" 'backfill: assigned 2 of 3'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-empty.json milestones-with-backlog.json --apply)" || rc=$?
assert_eq "nothing to do -> exit 0" "0" "$rc"
assert_contains "nothing to do -> reports zero" "$out" 'backfill: 0 open issues without a milestone'
assert_not_contains "nothing to do -> no PATCH" "$(cat "$d/gh")" 'PATCH'
rm -rf "$d"

section "backfill — never creates backlog"

d="$(mktemp -d)"; : > "$d/gh"
rc=0; out="$(run_backfill "$d" unmilestoned-two-pages.json milestones-without-backlog.json --apply)" || rc=$?
assert_eq "missing backlog -> exit 64" "64" "$rc"
assert_contains "missing backlog -> says so" "$out" 'has no open "backlog" milestone'
assert_not_contains "missing backlog -> no PATCH" "$(cat "$d/gh")" 'PATCH'
assert_not_contains "missing backlog -> no POST" "$(cat "$d/gh")" 'POST'
rm -rf "$d"

section "backfill — usage"

rc=0; bash "$BACKFILL" >/dev/null 2>&1 || rc=$?
assert_eq "no -R -> exit 2" "2" "$rc"
rc=0; bash "$BACKFILL" -R freaxnx01/sample --bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown flag -> exit 2" "2" "$rc"
rc=0; bash "$BACKFILL" -R 'not a repo' >/dev/null 2>&1 || rc=$?
assert_eq "malformed repo -> exit 2" "2" "$rc"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-backlog-milestone-guard-tests.sh`
Expected: the backfill sections FAIL, because the script is missing. The
Task 1 sections still pass.

- [ ] **Step 3: Write `scripts/backfill-backlog-milestone.sh`**

```bash
#!/usr/bin/env bash
#
# backfill-backlog-milestone.sh — one-off: give every open issue without a
# milestone the standing `backlog` milestone (#646).
#
# The guard (assign-backlog-milestone.sh) only sees issues opened after it is
# wired, and never sees one created with a workflow's GITHUB_TOKEN. This sweeps
# the rest. Operator-invoked, so flag-driven; a dry run unless --apply, like
# migrate-consumers.sh. Pull requests are excluded.
#
# Usage: backfill-backlog-milestone.sh -R <owner/repo> [--apply]
#
# Exit codes:
#   0   dry run done, or every listed issue assigned
#   1   a read failed, or at least one assignment failed
#   2   usage error
#   64  the repo has no open `backlog` milestone — never created here
set -euo pipefail
IFS=$'\n\t'

_BBM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/backlog-milestone.sh
source "$_BBM_HERE/lib/backlog-milestone.sh"

REPO=''
APPLY=false

usage_error() { printf 'error: %s\nusage: %s -R <owner/repo> [--apply]\n' "$1" "${0##*/}" >&2; exit 2; }
fatal() { printf 'error: %s\n' "$1" >&2; exit 1; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -R|--repo) [[ $# -ge 2 ]] || usage_error "$1 needs a value"; REPO="$2"; shift 2 ;;
      --apply)   APPLY=true; shift ;;
      -h|--help) printf 'usage: %s -R <owner/repo> [--apply]\n' "${0##*/}"; exit 0 ;;
      *)         usage_error "unknown argument: $1" ;;
    esac
  done
  [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
    || usage_error "-R owner/name is required (got: ${REPO:-})"
}

# list_unmilestoned — open issue numbers with no milestone, every page,
# pull requests dropped. One number per line. Query.
list_unmilestoned() {
  local pages
  pages="$(gh api "repos/$REPO/issues?state=open&milestone=none&per_page=100" --paginate)" || return 1
  printf '%s\n' "$pages" | jq -rs '.[][] | select(.pull_request == null) | .number'
}

# assign_all <milestone-number> <issues> <total> — assigns each, keeps going past a
# failure, prints the tally. Returns 1 if any write failed. Command.
assign_all() {
  local number="$1" issues="$2" total="$3" n assigned=0 failed=0
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if assign_milestone "$REPO" "$n" "$number"; then
      assigned=$((assigned + 1))
    else
      failed=$((failed + 1))
      printf 'error: could not assign %s to #%s\n' "$BACKLOG_MILESTONE" "$n" >&2
    fi
  done <<< "$issues"
  printf 'backfill: assigned %s of %s\n' "$assigned" "$total"
  (( failed == 0 ))
}

main() {
  parse_args "$@"
  local number issues count=0
  number="$(backlog_milestone_number "$REPO")" || fatal "could not read the milestones of $REPO"
  if [[ -z "$number" ]]; then
    printf 'error: %s has no open "%s" milestone — create it first (/milestone new %s); nothing assigned\n' \
      "$REPO" "$BACKLOG_MILESTONE" "$BACKLOG_MILESTONE" >&2
    exit 64
  fi
  issues="$(list_unmilestoned)" || fatal "could not list the open issues of $REPO"
  [[ -z "$issues" ]] || count="$(printf '%s\n' "$issues" | wc -l | tr -d ' ')"
  printf 'backfill: %s open issues without a milestone in %s\n' "$count" "$REPO"
  [[ -z "$issues" ]] || printf '%s\n' "$issues" | sed 's/^/  #/'

  if [[ "$APPLY" != true ]]; then
    printf 'DRY_RUN: would assign %s (#%s) to %s issues — re-run with --apply\n' \
      "$BACKLOG_MILESTONE" "$number" "$count"
    return 0
  fi
  assign_all "$number" "$issues" "$count" || exit 1
}

main "$@"
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `chmod +x scripts/backfill-backlog-milestone.sh && bash tests/run-backlog-milestone-guard-tests.sh`
Expected: `failed: 0`, exit 0.

- [ ] **Step 5: Lint and commit**

Run: `git add scripts/backfill-backlog-milestone.sh tests/run-backlog-milestone-guard-tests.sh && shellcheck -x -e SC1091 scripts/backfill-backlog-milestone.sh tests/run-backlog-milestone-guard-tests.sh`
Expected: clean.

```bash
git commit -m "feat(milestone): add a dry-run-first backlog backfill script (#646)"
```

---

## Task 3: Reusable workflow, Layer-2 test, dogfood caller

**Files:**

- Create:
  - `.github/workflows/backlog-milestone.yml`
  - `.github/workflows/backlog-milestone.test.yml`
  - `.github/workflows/issue-milestone.yml`
- Modify:
  - `tests/run-backlog-milestone-guard-tests.sh` (append above the summary)
  - `justfile`

- [ ] **Step 1: Append the failing workflow assertions**

```bash
section "the workflows"

WF="$ROOT/.github/workflows/backlog-milestone.yml"
TEST_WF="$ROOT/.github/workflows/backlog-milestone.test.yml"
CALLER="$ROOT/.github/workflows/issue-milestone.yml"
wf="$(cat "$WF" 2>/dev/null || true)"
test_wf="$(cat "$TEST_WF" 2>/dev/null || true)"
caller="$(cat "$CALLER" 2>/dev/null || true)"

assert_contains "reusable: callable" "$wf" 'workflow_call:'
assert_contains "reusable: runs the guard script" "$wf" 'scripts/assign-backlog-milestone.sh'
assert_contains "reusable: has a job timeout" "$wf" 'timeout-minutes:'
assert_contains "reusable: has per-issue concurrency" "$wf" 'concurrency:'
assert_not_contains "reusable: never writes code" "$wf" 'contents: write'
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
for needle in 'id: assign' \
              'decision: ${{ steps.assign.outputs.decision }}' \
              'value: ${{ jobs.milestone.outputs.decision }}' \
              'value: ${{ jobs.milestone.outputs.reason }}'; do
  assert_contains "reusable: the caller can read the decision — $needle" "$wf" "$needle"
done

assert_contains "caller: on opened and reopened" "$caller" 'types: [opened, reopened]'
assert_contains "caller: calls the local reusable workflow" "$caller" 'uses: ./.github/workflows/backlog-milestone.yml'
assert_contains "caller: uses this repo's scripts" "$caller" 'local-scripts: true'
# shellcheck disable=SC2016
assert_contains "caller: passes only the issue number" "$caller" 'issue-number: ${{ github.event.issue.number }}'

assert_contains "test: calls the reusable workflow" "$test_wf" 'uses: ./.github/workflows/backlog-milestone.yml'
assert_contains "test: drives the real script through the gh mock" "$test_wf" 'stub-mode: true'
for fixture in milestones-with-backlog.json milestones-without-backlog.json issue-has-milestone.json; do
  assert_contains "test: covers $fixture" "$test_wf" "tests/fixtures/backlog-milestone/$fixture"
done

# SECURITY: public repo, anyone can open an issue. No user-controlled field may
# reach a workflow at all — only the number goes in.
leaks="$(grep -nE 'github\.event\.(issue\.(title|body|user)|comment)' "$WF" "$TEST_WF" "$CALLER" 2>/dev/null || true)"
assert_eq "no workflow reads a user-controlled event field" "" "$leaks"

for f in "$WF" "$TEST_WF" "$CALLER"; do
  unpinned="$(grep -E '^\s*-?\s*uses: [^.]' "$f" 2>/dev/null | grep -vE '@[0-9a-f]{40}' || true)"
  assert_eq "${f##*/}: every external action is pinned by full SHA" "" "$unpinned"
  top="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(d.get("permissions"))' "$f" 2>/dev/null || true)"
  assert_eq "${f##*/}: top-level permissions are contents: read only" "{'contents': 'read'}" "$top"
done

# A calling job granting less than the callee's jobs declare is rejected at
# load (startup_failure, #34 / #435). Assert every calling job grants the union.
perm_check() {
  python3 - "$WF" "$1" <<'PY'
import sys, yaml
callee = yaml.safe_load(open(sys.argv[1]))
need = {}
for job in callee["jobs"].values():
    need.update(job.get("permissions") or {})
caller = yaml.safe_load(open(sys.argv[2]))
bad = [n for n, j in caller["jobs"].items()
       if "uses" in j and (j.get("permissions") or {}) != need]
print(" ".join(bad))
PY
}
assert_eq "caller: every calling job grants the callee's permissions" "" "$(perm_check "$CALLER" 2>&1 || true)"
assert_eq "test: every calling job grants the callee's permissions" "" "$(perm_check "$TEST_WF" 2>&1 || true)"

if command -v actionlint >/dev/null 2>&1; then
  for f in "$WF" "$TEST_WF" "$CALLER"; do
    if actionlint "$f" >/dev/null 2>&1; then pass "actionlint is clean (${f##*/})"
    else fail "actionlint is clean (${f##*/})" "$(actionlint "$f" 2>&1 | head -5)"; fi
  done
fi
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-backlog-milestone-guard-tests.sh`
Expected: the "the workflows" section FAILS, because the files are missing.

- [ ] **Step 3: Write `.github/workflows/backlog-milestone.yml`**

```yaml
# Backlog milestone (reusable) — assign `backlog` to an issue opened or
# reopened without a milestone (#646, freaxnx01/ai-instructions#61).
#
# Consumers call this from their own `issues: [opened, reopened]` stub
# (scripts/onboard-consumer.sh generates it). The rules live in
# scripts/assign-backlog-milestone.sh. A missing `backlog` milestone is a
# warning, never a creation.
#
# SECURITY: only the issue number comes in. Nothing user-controlled (title,
# body, author) is ever interpolated into a step — the script re-reads the
# issue over REST itself.
#
# GitHub-only: there is no Forgejo Actions tier yet (ADR-005,
# docs/FACTORY-MAP.md). Issues created with a workflow's GITHUB_TOKEN start no
# workflow, so this never sees them; scripts/backfill-backlog-milestone.sh does.
name: Backlog milestone (reusable)

on:
  workflow_call:
    inputs:
      issue-number:
        description: The issue that was just opened or reopened.
        type: number
        required: true
      pipeline-repo:
        description: Repo holding the shared scripts.
        type: string
        default: freaxnx01/agent-workflow
      pipeline-ref:
        description: Ref of `pipeline-repo` to check out. Pin the caller's moving major tag.
        type: string
        default: main
      local-scripts:
        description: Use the caller repo's own scripts/ (agent-workflow dogfooding).
        type: boolean
        default: false
      stub-mode:
        description: Test-only, with `local-scripts`. Routes every `gh` call through tests/mocks/gh.
        type: boolean
        default: false
      stub-issue-fixture:
        description: Test-only. REST issue object the mocked `gh api` returns.
        type: string
        default: tests/fixtures/backlog-milestone/issue-open.json
      stub-milestones-fixture:
        description: Test-only. Milestone list the mocked `gh api` returns.
        type: string
        default: tests/fixtures/backlog-milestone/milestones-with-backlog.json
      timeout-minutes:
        type: number
        default: 5
    outputs:
      decision:
        description: '`assigned` or `skipped`.'
        value: ${{ jobs.milestone.outputs.decision }}
      reason:
        description: Why it was skipped; empty when assigned.
        value: ${{ jobs.milestone.outputs.reason }}

permissions:
  contents: read

jobs:
  milestone:
    name: Assign backlog milestone
    runs-on: ubuntu-latest
    timeout-minutes: ${{ inputs.timeout-minutes }}
    permissions:
      contents: read
      issues: write
    concurrency:
      group: backlog-milestone-${{ github.repository }}-${{ inputs.issue-number }}
      cancel-in-progress: false
    outputs:
      decision: ${{ steps.assign.outputs.decision }}
      reason: ${{ steps.assign.outputs.reason }}
    steps:
      - name: Checkout caller repo (local-scripts mode)
        if: ${{ inputs.local-scripts }}
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

      - name: Checkout agent-workflow scripts
        if: ${{ !inputs.local-scripts }}
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          repository: ${{ inputs.pipeline-repo }}
          ref: ${{ inputs.pipeline-ref }}
          path: .claude-pipeline
          sparse-checkout: scripts

      - name: Mirror local scripts to .claude-pipeline (self-test mode)
        if: ${{ inputs.local-scripts }}
        run: mkdir -p .claude-pipeline/scripts && cp -r scripts/. .claude-pipeline/scripts/

      - name: Wire the gh mock (stub-mode)
        # Refuses rather than letting real `gh` calls through without the mock.
        if: ${{ inputs.stub-mode }}
        env:
          WORKSPACE: ${{ github.workspace }}
          RUNNER_TEMP_DIR: ${{ runner.temp }}
          ISSUE_FIXTURE: ${{ inputs.stub-issue-fixture }}
          MILESTONES_FIXTURE: ${{ inputs.stub-milestones-fixture }}
        run: |
          [[ -x tests/mocks/gh && -r "$ISSUE_FIXTURE" && -r "$MILESTONES_FIXTURE" ]] || { echo "::error::stub-mode needs local-scripts, tests/mocks/gh and both fixtures"; exit 1; }
          map="$RUNNER_TEMP_DIR/gh-stdout-map"
          printf '%s\t%s/%s\n' 'milestones?state=open' "$WORKSPACE" "$MILESTONES_FIXTURE" 'api repos/' "$WORKSPACE" "$ISSUE_FIXTURE" > "$map"
          printf 'PATH=%s/tests/mocks:%s\nGH_MOCK_LOG=%s\nGH_MOCK_STDOUT_MAP=%s\n' "$WORKSPACE" "$PATH" "$RUNNER_TEMP_DIR/gh-mock.log" "$map" >> "$GITHUB_ENV"

      - name: Assign the backlog milestone
        id: assign
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
        run: bash .claude-pipeline/scripts/assign-backlog-milestone.sh
```

- [ ] **Step 4: Write `.github/workflows/backlog-milestone.test.yml`**

```yaml
name: backlog-milestone-test

# Layer-2 test for backlog-milestone.yml (#646). Calls the reusable workflow
# with `local-scripts` + `stub-mode`, so the real
# scripts/assign-backlog-milestone.sh runs against fixtures through the gh
# mock: no issue is read, nothing is written, no token is needed. Catches the
# wiring Layer 1 cannot — inputs reaching the script's env, and
# `decision`/`reason` travelling out to a caller.

on:
  workflow_dispatch:
  pull_request:
    paths:
      - .github/workflows/backlog-milestone.yml
      - .github/workflows/backlog-milestone.test.yml
      - scripts/assign-backlog-milestone.sh
      - scripts/lib/backlog-milestone.sh
      - tests/fixtures/backlog-milestone/**
      - tests/mocks/gh

permissions:
  contents: read

concurrency:
  group: backlog-milestone-test-${{ github.ref }}
  cancel-in-progress: true

jobs:
  call-assigned:
    name: an issue without a milestone (assigned)
    permissions:
      contents: read
      issues: write
    uses: ./.github/workflows/backlog-milestone.yml
    with:
      issue-number: 9001
      local-scripts: true
      stub-mode: true
      stub-issue-fixture: tests/fixtures/backlog-milestone/issue-open.json
      stub-milestones-fixture: tests/fixtures/backlog-milestone/milestones-with-backlog.json

  call-has-milestone:
    name: an issue with a milestone (skipped)
    permissions:
      contents: read
      issues: write
    uses: ./.github/workflows/backlog-milestone.yml
    with:
      issue-number: 9002
      local-scripts: true
      stub-mode: true
      stub-issue-fixture: tests/fixtures/backlog-milestone/issue-has-milestone.json
      stub-milestones-fixture: tests/fixtures/backlog-milestone/milestones-with-backlog.json

  call-no-backlog:
    name: a repo without backlog (warned, skipped)
    permissions:
      contents: read
      issues: write
    uses: ./.github/workflows/backlog-milestone.yml
    with:
      issue-number: 9003
      local-scripts: true
      stub-mode: true
      stub-issue-fixture: tests/fixtures/backlog-milestone/issue-open.json
      stub-milestones-fixture: tests/fixtures/backlog-milestone/milestones-without-backlog.json

  verify:
    name: Assert the three decisions
    needs: [call-assigned, call-has-milestone, call-no-backlog]
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      A_DEC: ${{ needs.call-assigned.outputs.decision }}
      A_REASON: ${{ needs.call-assigned.outputs.reason }}
      H_DEC: ${{ needs.call-has-milestone.outputs.decision }}
      H_REASON: ${{ needs.call-has-milestone.outputs.reason }}
      N_DEC: ${{ needs.call-no-backlog.outputs.decision }}
      N_REASON: ${{ needs.call-no-backlog.outputs.reason }}
    steps:
      - name: Assert decision and reason per case
        run: |
          [[ "$A_DEC" == assigned && -z "$A_REASON" ]] || { echo "::error::assigned case: $A_DEC / $A_REASON"; exit 1; }
          [[ "$H_DEC" == skipped && "$H_REASON" == "has milestone v2.3 · intake" ]] || { echo "::error::has-milestone case: $H_DEC / $H_REASON"; exit 1; }
          [[ "$N_DEC" == skipped && "$N_REASON" == "no backlog milestone" ]] || { echo "::error::no-backlog case: $N_DEC / $N_REASON"; exit 1; }
          echo "backlog-milestone wiring OK"
```

- [ ] **Step 5: Write `.github/workflows/issue-milestone.yml` (dogfood caller)**

```yaml
# Dogfood caller — runs the backlog milestone guard (#646) on this repo's own
# issues. `uses: ./…` + `local-scripts: true` exercise current main, like
# agent.yml. Consumers get the same stub from scripts/onboard-consumer.sh,
# pointing at the published workflow instead.
#
# SECURITY: public repo — only the issue number is passed on.
name: Issue milestone

on:
  issues:
    types: [opened, reopened]

permissions:
  contents: read

jobs:
  milestone:
    permissions:
      contents: read
      issues: write   # assigns the backlog milestone
    uses: ./.github/workflows/backlog-milestone.yml
    with:
      issue-number: ${{ github.event.issue.number }}
      local-scripts: true
```

- [ ] **Step 6: Add the Layer-2 run to `justfile`**

Under `test-act:`, after the `issue-intake.test.yml` line, add:

```text
    act -W .github/workflows/backlog-milestone.test.yml workflow_dispatch
```

- [ ] **Step 7: Run the tests and watch them pass**

Run: `bash tests/run-backlog-milestone-guard-tests.sh`
Expected: `failed: 0`. If actionlint is installed, its three assertions pass
too.

- [ ] **Step 8: Lint and commit**

Run: `git add .github/workflows/backlog-milestone.yml .github/workflows/backlog-milestone.test.yml .github/workflows/issue-milestone.yml justfile tests/run-backlog-milestone-guard-tests.sh && actionlint .github/workflows/backlog-milestone.yml .github/workflows/backlog-milestone.test.yml .github/workflows/issue-milestone.yml`
Expected: clean.

```bash
git commit -m "ci(milestone): reusable backlog milestone workflow, Layer-2 test and dogfood caller (#646)"
```

---

## Task 4: Onboarding writes the consumer stub

**Files:**

- Modify:
  - `scripts/onboard-consumer.sh` (header lines 14-16, new `build_milestone_yml`
    after `build_intake_yml`, both write paths)
  - `tests/run-onboard-stub-tests.sh`

- [ ] **Step 1: Write the failing stub tests**

  In `tests/run-onboard-stub-tests.sh`:

  - Add the extractor below after `intake_stub()`.
  - Add the new section just before
    `section "consumer stub — still well-formed"`.

```bash
# milestone_stub — echoes the generated issue-milestone.yml (#646). Same
# extraction trick as stub().
milestone_stub() {
  # shellcheck disable=SC2034
  (
    REF='v2'
    PIPELINE_REPO='freaxnx01/agent-workflow'
    # shellcheck disable=SC1090
    source <(sed -n '/^build_milestone_yml()/,/^}/p' "$SRC")
    build_milestone_yml
  )
}
```

```bash
section "milestone stub — issues without a milestone land in backlog (#646)"

milestone="$(milestone_stub)"
assert_contains 'uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2' \
  "$milestone" "calls the backlog milestone workflow at the pinned ref"
assert_contains 'types: [opened, reopened]' "$milestone" "runs when an issue is opened or reopened"
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains 'issue-number: ${{ github.event.issue.number }}' "$milestone" "passes only the issue number"
assert_contains 'pipeline-ref: v2' "$milestone" "checks out scripts at the same ref"
assert_contains 'issues: write' "$milestone" "may set the milestone"
assert_not_contains 'contents: write' "$milestone" "never writes code"
assert_not_contains 'github.event.issue.title' "$milestone" "never reads the title"
assert_not_contains 'github.event.issue.body' "$milestone" "never reads the body"
# shellcheck disable=SC2016  # `\$NO_STUB` is a sed pattern, not a shell expansion
writes="$(sed -n '/^if \[\[ "\$NO_STUB"/,/^fi/p' "$SRC" | grep -c 'put_file ".github/workflows/issue-milestone.yml"' || true)"
if [[ "$writes" == 2 ]]; then
  pass "both onboarding paths write the milestone stub"
else
  fail "both onboarding paths write the milestone stub" "found $writes put_file calls, expected 2"
fi
if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$milestone" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "generated milestone stub is valid YAML"
  else
    fail "generated milestone stub is valid YAML" "yamllint rejected it"
  fi
fi
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/run-onboard-stub-tests.sh`
Expected: the milestone section FAILS (`build_milestone_yml` does not exist,
0 put_file calls).

- [ ] **Step 3: Implement in `scripts/onboard-consumer.sh`**

  Add the function after `build_intake_yml`:

```bash
# The backlog milestone guard (#646). Unconditional, like the intake stub:
# every open issue carries a milestone (freaxnx01/ai-instructions#61). It
# never creates `backlog` — onboarding does not either; a repo without one
# gets a warning per issue until `/milestone new backlog` is run.
build_milestone_yml() {
  cat <<YAML
name: Issue milestone
on:
  issues:
    types: [opened, reopened]

permissions:
  contents: read

jobs:
  milestone:
    permissions:
      contents: read
      issues: write   # assigns the backlog milestone
    uses: $PIPELINE_REPO/.github/workflows/backlog-milestone.yml@$REF
    with:
      issue-number: \${{ github.event.issue.number }}
      pipeline-ref: $REF
YAML
}
```

  In **both** branches of the `if [[ "$NO_STUB" == true ]]` block, add the
  following right after the `issue-intake.yml` `put_file` pair:

```bash
  build_milestone_yml | put_file ".github/workflows/issue-milestone.yml" \
    "ci(agent-workflow): add backlog milestone stub"
```

  Update the header bullet (lines 14-16) so it lists the stub:
  `.github/workflows/agent.yml, pipeline-health.yml, issue-intake.yml and
  issue-milestone.yml (and chain-dispatch.yml with --chain)`.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `bash tests/run-onboard-stub-tests.sh`
Expected: 0 failed.

- [ ] **Step 5: Lint and commit**

Run: `shellcheck -x -e SC1091 scripts/onboard-consumer.sh tests/run-onboard-stub-tests.sh`
Expected: clean.

```bash
git add scripts/onboard-consumer.sh tests/run-onboard-stub-tests.sh
git commit -m "feat(onboard): write the backlog milestone stub for consumers (#646)"
```

---

## Task 5: Docs and CHANGELOG

**Files:**

- Modify: `docs/CONSUMER-SETUP.md` (new §3d before `## 4. Issue chaining`), `CHANGELOG.md`

- [ ] **Step 1: Add §3d to `docs/CONSUMER-SETUP.md`**

  Insert it directly before `## 4. Issue chaining (optional, requires
  ai-review-ai-merge)`:

````markdown
## 3d. Backlog milestone guard (recommended)

Every open issue carries a milestone (freaxnx01/ai-instructions#61); the
standing `backlog` milestone holds whatever is not scheduled. Issues filed by
agents and scripts often arrive without one. This stub assigns `backlog` to an
issue opened or reopened without a milestone (#646).
`scripts/onboard-consumer.sh` writes it on every onboarding.

```yaml
# .github/workflows/issue-milestone.yml
name: Issue milestone
on:
  issues:
    types: [opened, reopened]

permissions:
  contents: read

jobs:
  milestone:
    permissions:
      contents: read
      issues: write
    uses: freaxnx01/agent-workflow/.github/workflows/backlog-milestone.yml@v2
    with:
      issue-number: ${{ github.event.issue.number }}
      pipeline-ref: v2
```

Rules (`scripts/assign-backlog-milestone.sh`):

- An issue that already has **any** milestone is left alone.
- Closed issues and pull requests are left alone.
- Only an **open** milestone titled exactly `backlog` counts. If there is
  none, the run logs a `::warning::` and exits green — it **never creates**
  the milestone. Create it with `/milestone new backlog`.
- Only the issue number is passed in; the script re-reads the issue itself.
  No title, body or author ever reaches a step, so the stub is safe in a
  public repo where anyone can open an issue.

Not covered:

- **Issues created with a workflow's `GITHUB_TOKEN`** start no workflow, so
  the guard never sees them — for example the pipeline alarm that
  `pipeline-health.yml` raises. Sweep those, and every issue opened before the
  stub was merged, with the backfill:

  ```bash
  scripts/backfill-backlog-milestone.sh -R <owner/repo>          # dry run: prints the count
  scripts/backfill-backlog-milestone.sh -R <owner/repo> --apply  # assigns
  ```

- **Forgejo.** GitHub-only for now: there is no Forgejo Actions tier yet
  (ADR-005, `docs/DESIGN.md`), and most Forgejo repos have no runner
  (`docs/FACTORY-MAP.md`).
- **Azure DevOps** needs nothing: every work item has at least the root
  iteration.
````

- [ ] **Step 2: Add the CHANGELOG entry**

  In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, add this as the
  first bullet. #644 and #645 add to the same section; on a conflict, keep
  every bullet.

```markdown
- *(milestone)* Issues opened or reopened without a milestone get the standing `backlog` milestone (#646, freaxnx01/ai-instructions#61). New reusable workflow `backlog-milestone.yml`; `scripts/onboard-consumer.sh` writes the `issue-milestone.yml` stub. A repo without an open `backlog` milestone gets a warning — it is never created. `scripts/backfill-backlog-milestone.sh -R <owner/repo> [--apply]` sweeps existing issues (dry run by default). GitHub-only.
```

- [ ] **Step 3: Verify the docs carry the decisions**

Run: `grep -c 'backlog-milestone.yml@v2\|never creates\|GITHUB_TOKEN\|ADR-005\|FACTORY-MAP' docs/CONSUMER-SETUP.md && ! grep -n 'ADR-017' <(sed -n '/^## 3d\./,/^## 4\./p' docs/CONSUMER-SETUP.md)`
Expected: a count ≥ 5, and no ADR-017 inside §3d. The test runners in
Task 6 are the executable check. This step only guards the wording.

- [ ] **Step 4: Commit**

```bash
git add docs/CONSUMER-SETUP.md CHANGELOG.md
git commit -m "docs(milestone): document the backlog milestone guard and backfill (#646)"
```

---

## Task 6: Full verification

- [ ] **Step 1: Layer-1 suite**

Run: `bash tests/run-all.sh`
Expected: exit 0. Both `run-backlog-milestone-guard-tests.sh` and
`run-onboard-stub-tests.sh` are discovered and pass.

- [ ] **Step 2: Lint gate**

Run: `pre-commit run --all-files`. If pre-commit is unavailable, run
`actionlint` on all three workflows and
`shellcheck -x -e SC1091 scripts/assign-backlog-milestone.sh scripts/backfill-backlog-milestone.sh scripts/lib/backlog-milestone.sh scripts/onboard-consumer.sh tests/run-backlog-milestone-guard-tests.sh tests/run-onboard-stub-tests.sh`.
Expected: clean.

- [ ] **Step 3: Exercise the backfill's dry run end to end against the mock**

Run:
```bash
d="$(mktemp -d)"; : > "$d/gh"
printf '%s\t%s\n' 'milestones?state=open' "$PWD/tests/fixtures/backlog-milestone/milestones-two-pages.json" 'milestone=none' "$PWD/tests/fixtures/backlog-milestone/unmilestoned-two-pages.json" > "$d/map"
PATH="$PWD/tests/mocks:$PATH" GH_MOCK_LOG="$d/gh" GH_MOCK_STDOUT_MAP="$d/map" bash scripts/backfill-backlog-milestone.sh -R freaxnx01/sample
grep -c PATCH "$d/gh" || true; rm -rf "$d"
```
Expected output contains `backfill: 3 open issues without a milestone` and
`DRY_RUN: would assign backlog (#7) to 3 issues`. The PATCH count is `0`.

- [ ] **Step 4: Do NOT run the backfill against GitHub and do NOT open a test
  issue.** Those are post-merge manual steps (spec, *Post-merge steps*).
