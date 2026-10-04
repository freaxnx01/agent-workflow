# Plan Coverage Grading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grade an `ai-implement` run against the issue's Implementation Plan, so a PR missing whole plan tasks is labelled `ai:partial` and never enters the AI-merge job.

**Architecture:** A query-only script (`check-plan-coverage.sh`) maps each `### Task N` to the files its **Files** block names and checks them against the PR's changed files. A thin workflow-glue script (`plan-coverage-step.sh`) fetches both inputs and turns any fetch failure into `unverifiable`. `post-run-report.sh` grades `partial` as `ai:partial` / `:warning:`, and the `ai_review_ai_merge` job requires `plan-coverage == 'complete'`.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), awk, `gh` (mocked by `tests/mocks/gh` via `GH_MOCK_LOG` / `GH_MOCK_STDOUT_MAP` / `GH_MOCK_FAIL_MAP`), GitHub Actions YAML, Layer-1 runners discovered by `tests/run-all.sh`.

**Spec:** `docs/superpowers/specs/2026-10-04-plan-coverage-grading-design.md`

## Global Constraints

- A task is **landed** when at least one of its listed files is in the PR's changed set. A task whose files are all shared with another landed task counts as landed (documented blind spot).
- `coverage=unverifiable` when: no `## Implementation Plan` heading (`reason=no-plan`), zero task headings (`no-tasks`), any task with no file entries (`task-without-files:<N>`, first such task), or any fetch failure (`fetch-failed`).
- Task heading pattern: `^#{2,3} Task [0-9]+` (h2 or h3), matching `scripts/classify-turns.sh:129`.
- File lines: `^- (Create|Modify|Test|Delete): `; every backticked token on the line, trailing `:<digit>…` stripped, empty results dropped.
- Grade precedence in the report: agent error → no PR → partial → salvaged → success.
- Exactly one of `ai:done` / `ai:failed` / `ai:partial` remains on the issue after a report.
- Unverifiable keeps today's grade and label; it only adds `**Plan coverage:** not checked — <reason>` and blocks AI-merge.
- Human-merge job is not gated by coverage.
- No inline bash longer than 5 lines in YAML; every `gh` call in tests goes through `tests/mocks/gh`.
- `shellcheck -x -e SC1091`, `actionlint`, `markdownlint-cli2` and `bash tests/run-all.sh` clean before the PR.

## Review Focus

1. **Headings inside fenced code blocks** — a plan that quotes the writing-plans template contains `### Task N:` inside a fence; it must not count as a task. Task 1's "format" fixture puts a fake `### Task 9:` inside a four-backtick fence that itself contains a three-backtick fence.
2. **Plan-level h2 headings before the tasks** (`## Global Constraints`, `## Review Focus`, inlined under `## Implementation Plan`) must not end the plan; an h2 after the tasks (`## Spec`) must. Covered by the same fixture.
3. **A PR with zero changed files** — every task is missing → `partial` with all task numbers, not `unverifiable`. Task 1 asserts it.
4. **A rename** — the plan names the old path, the PR renames it; `previous_filename` must count. Task 3's step test asserts the jq expression emits both names (the mock serves the post-jq output, so the test asserts the call shape).
5. **The act suite runs `dry-run: true` with stub verdicts** (`.github/workflows/agent-implement.test.yml:245`, `:264`), where the coverage step is skipped. The AI-merge condition must exempt `inputs.dry-run`, or those act tests stop reaching the AI-merge job. Task 3 adds that carve-out.

---

### Task 1: `check-plan-coverage.sh` — grade a plan against a changed-file list

**Files:**
- Create: `scripts/check-plan-coverage.sh`
- Test: `tests/run-plan-coverage-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/check-plan-coverage.sh` — env `ISSUE_BODY_FILE`, `CHANGED_FILES_FILE` (readable files). Stdout, always exactly three lines in this order: `coverage=<complete|partial|unverifiable>`, `missing-tasks=<comma-separated task numbers or empty>`, `reason=<no-plan|no-tasks|task-without-files:N|empty>`. Exit 0 on every grade; 2 on usage error.

- [ ] **Step 1: Write the failing test**

Create `tests/run-plan-coverage-tests.sh` (and `chmod +x` it):

`````bash
#!/usr/bin/env bash
#
# run-plan-coverage-tests.sh — Layer-1 tests for scripts/check-plan-coverage.sh
# and scripts/plan-coverage-step.sh (#457). No network; gh is mocked.
#
# Usage: tests/run-plan-coverage-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-plan-coverage.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
FAIL_NAMES=()

section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1")
  printf '  ✗ %s\n' "$1"
  [[ $# -gt 1 ]] && printf '      %s\n' "$2"
  return 0
}
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

# grade <body-file> <changed-file> → the script's three output lines
grade() { ISSUE_BODY_FILE="$1" CHANGED_FILES_FILE="$2" bash "$CHECK"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

section "the #430 shape: 3 tasks planned, 1 landed"

cat > "$T/body-430.md" <<'EOF'
Some description.

## Implementation Plan

### Task 1: Parser

**Files:**
- Create: `scripts/parse.sh`
- Test: `tests/run-parse-tests.sh`

### Task 2: Workflow

**Files:**
- Modify: `.github/workflows/agent-implement.yml:120-140`

### Task 3: Docs

**Files:**
- Modify: `docs/DESIGN.md`

## Spec

[spec](docs/spec.md)
EOF
printf 'scripts/parse.sh\ntests/run-parse-tests.sh\n' > "$T/changed-430.txt"
out="$(grade "$T/body-430.md" "$T/changed-430.txt")"
assert_eq "#430 shape is partial" "partial" "$(field "$out" coverage)"
assert_eq "#430 shape names tasks 2 and 3" "2,3" "$(field "$out" missing-tasks)"
assert_eq "partial has no reason" "" "$(field "$out" reason)"
assert_eq "output is exactly three lines" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

section "every task landed"

printf 'scripts/parse.sh\n.github/workflows/agent-implement.yml\ndocs/DESIGN.md\n' > "$T/changed-all.txt"
out="$(grade "$T/body-430.md" "$T/changed-all.txt")"
assert_eq "all tasks landed is complete" "complete" "$(field "$out" coverage)"
assert_eq "complete has no missing tasks" "" "$(field "$out" missing-tasks)"

section "a PR with no changed files"

: > "$T/changed-none.txt"
out="$(grade "$T/body-430.md" "$T/changed-none.txt")"
assert_eq "no changed files is partial, not unverifiable" "partial" "$(field "$out" coverage)"
assert_eq "no changed files names every task" "1,2,3" "$(field "$out" missing-tasks)"

section "a task whose only file is shared with a landed task"

cat > "$T/body-shared.md" <<'EOF'
## Implementation Plan

### Task 1: Code

**Files:**
- Modify: `scripts/a.sh`
- Test: `tests/run-a-tests.sh`

### Task 2: More tests

**Files:**
- Test: `tests/run-a-tests.sh`
EOF
printf 'scripts/a.sh\ntests/run-a-tests.sh\n' > "$T/changed-shared.txt"
out="$(grade "$T/body-shared.md" "$T/changed-shared.txt")"
assert_eq "a shared-file task counts as landed" "complete" "$(field "$out" coverage)"

section "unverifiable plans"

printf 'Just a description, no plan.\n\n## Acceptance Criteria\n\n- [ ] works\n' > "$T/body-no-plan.md"
out="$(grade "$T/body-no-plan.md" "$T/changed-all.txt")"
assert_eq "no plan is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "no plan reason" "no-plan" "$(field "$out" reason)"

printf '## Implementation Plan\n\nDo the thing in scripts/a.sh.\n' > "$T/body-no-tasks.md"
out="$(grade "$T/body-no-tasks.md" "$T/changed-all.txt")"
assert_eq "no task headings is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "no task headings reason" "no-tasks" "$(field "$out" reason)"

cat > "$T/body-task-without-files.md" <<'EOF'
## Implementation Plan

### Task 1: Code

**Files:**
- Modify: `scripts/a.sh`

### Task 2: Think about it

Consider the options.
EOF
out="$(grade "$T/body-task-without-files.md" "$T/changed-shared.txt")"
assert_eq "a task with no files is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "it names the task" "task-without-files:2" "$(field "$out" reason)"

section "format: h2 tasks, line ranges, fences, plan-level h2 headings"

cat > "$T/body-format.md" <<'EOF'
## Implementation Plan

# Some Feature Implementation Plan

## Global Constraints

- none

## Review Focus

1. fences

---

## Task 1: Edit b

**Files:**
- Modify: `scripts/b.sh:10-20` and `:30`

````markdown
```bash
echo inner fence
```
### Task 9: inside a fence, not a task
- Create: `scripts/ghost.sh`
````

```
[ full listing in the committed plan file — see the note at the top ]
```

### Task 2: Edit c

**Files:**
- Test: `tests/run-c-tests.sh:5`

## Spec

- Create: `docs/not-a-task-file.md`
EOF
printf 'scripts/b.sh\ntests/run-c-tests.sh\n' > "$T/changed-format.txt"
out="$(grade "$T/body-format.md" "$T/changed-format.txt")"
assert_eq "h2 tasks, line ranges and fences parse" "complete" "$(field "$out" coverage)"
printf 'scripts/b.sh\n' > "$T/changed-format-partial.txt"
out="$(grade "$T/body-format.md" "$T/changed-format-partial.txt")"
assert_eq "the fenced Task 9 is not counted" "2" "$(field "$out" missing-tasks)"

section "usage"

rc=0; ISSUE_BODY_FILE='' CHANGED_FILES_FILE="$T/changed-all.txt" bash "$CHECK" >/dev/null 2>&1 || rc=$?
assert_eq "unset ISSUE_BODY_FILE exits 2" "2" "$rc"
rc=0; ISSUE_BODY_FILE="$T/body-430.md" CHANGED_FILES_FILE="$T/nope.txt" bash "$CHECK" >/dev/null 2>&1 || rc=$?
assert_eq "unreadable CHANGED_FILES_FILE exits 2" "2" "$rc"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
`````

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-plan-coverage-tests.sh`
Expected: FAIL on every grading assertion (`bash: …/scripts/check-plan-coverage.sh: No such file or directory`); the two usage assertions may pass by accident (exit 127 ≠ 2 — they fail too).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/check-plan-coverage.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
#
# check-plan-coverage.sh — grade a PR's changed files against the issue's
# Implementation Plan (#457). Query only: no network, no writes.
#
# A run can end cleanly while whole plan tasks never reached the branch (#430:
# two of three tasks left as a patch in the PR body, graded ai:done). This maps
# each `### Task N` (or `## Task N`) heading to the paths its **Files** block
# names and checks them against the changed set.
#
# A task is LANDED when at least one of its files is in the changed set. Known
# blind spot, by design: a task whose files all belong to another landed task
# is indistinguishable from it and counts as landed. Flagging those would make
# `partial` fire on clean runs, because plans routinely share a test file.
#
# Parsing rules:
#   - only from the `## Implementation Plan` heading onward; once a task has
#     been seen, the next non-task h2 (e.g. `## Spec`) ends the plan. h2s before
#     the first task (`## Global Constraints`) do not;
#   - lines inside fenced code blocks are ignored (a fence closes on a line of
#     at least as many backticks as opened it, so ```` can wrap ```);
#   - file lines are `- Create|Modify|Test|Delete: ...`; every backticked token
#     on the line counts, with a trailing `:<digit>...` line range stripped.
#
# Env (required):
#   ISSUE_BODY_FILE     the issue body
#   CHANGED_FILES_FILE  the PR's changed paths, one per line
#
# Stdout, always these three lines:
#   coverage=complete|partial|unverifiable
#   missing-tasks=<comma-separated task numbers>   (partial only)
#   reason=no-plan|no-tasks|task-without-files:<N> (unverifiable only)
#
# Exit codes:
#   0  graded (any grade)
#   2  usage error: an input unset or unreadable
set -euo pipefail
IFS=$'\n\t'

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

[[ -n "${ISSUE_BODY_FILE:-}" && -r "${ISSUE_BODY_FILE:-}" ]] \
  || usage_error "ISSUE_BODY_FILE must name a readable file"
[[ -n "${CHANGED_FILES_FILE:-}" && -r "${CHANGED_FILES_FILE:-}" ]] \
  || usage_error "CHANGED_FILES_FILE must name a readable file"

emit() { printf 'coverage=%s\nmissing-tasks=%s\nreason=%s\n' "$1" "$2" "$3"; }

# One "T<TAB>n" line per task heading and one "F<TAB>n<TAB>path" per planned file.
parse_plan() {
  awk '
    function ticks(s,   n) { n = 0; while (substr(s, n + 1, 1) == "`") n++; return n }
    {
      t = ticks($0)
      if (infence) { if (t >= flen && $0 ~ /^`+[[:space:]]*$/) infence = 0; next }
      if (t >= 3) { infence = 1; flen = t; next }
    }
    tolower($0) ~ /^## implementation plan[[:space:]]*$/ { inplan = 1; next }
    !inplan { next }
    /^###? Task [0-9]+/ {
      match($0, /Task [0-9]+/)
      task = substr($0, RSTART + 5, RLENGTH - 5)
      print "T\t" task
      next
    }
    /^## / && task != "" { exit }
    task != "" && /^- (Create|Modify|Test|Delete): / {
      line = $0
      while (match(line, /`[^`]+`/)) {
        path = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        sub(/:[0-9].*$/, "", path)
        if (path != "") print "F\t" task "\t" path
      }
    }
  ' "$ISSUE_BODY_FILE"
}

files_of_task() { awk -F'\t' -v t="$2" '$1 == "F" && $2 == t { print $3 }' <<< "$1"; }

task_landed() {
  local plan="$1" task="$2" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -qxF -- "$path" "$CHANGED_FILES_FILE" && return 0
  done <<< "$(files_of_task "$plan" "$task")"
  return 1
}

main() {
  if ! grep -qi '^## Implementation Plan' "$ISSUE_BODY_FILE"; then
    emit unverifiable '' no-plan; return 0
  fi

  local plan tasks=() task missing=()
  plan="$(parse_plan)"
  mapfile -t tasks < <(awk -F'\t' '$1 == "T" { print $2 }' <<< "$plan")
  if (( ${#tasks[@]} == 0 )); then
    emit unverifiable '' no-tasks; return 0
  fi

  for task in "${tasks[@]}"; do
    if [[ -z "$(files_of_task "$plan" "$task")" ]]; then
      emit unverifiable '' "task-without-files:$task"; return 0
    fi
  done

  for task in "${tasks[@]}"; do
    task_landed "$plan" "$task" || missing+=("$task")
  done

  if (( ${#missing[@]} > 0 )); then
    emit partial "$(IFS=,; printf '%s' "${missing[*]}")" ''
  else
    emit complete '' ''
  fi
}

main
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-plan-coverage-tests.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Lint and commit**

Run: `shellcheck -x -e SC1091 scripts/check-plan-coverage.sh tests/run-plan-coverage-tests.sh`
Expected: no output.

```bash
git add scripts/check-plan-coverage.sh tests/run-plan-coverage-tests.sh
git commit -m "feat(pipeline): grade a PR's changed files against the plan's tasks

Refs #457"
git push
```

---

### Task 2: Report grades `partial` as `ai:partial`; one status label at a time

**Files:**
- Modify: `scripts/post-run-report.sh:63-80` (env), `:255-300` (grade), `:315-335` (render), `:363-370` (label cleanup)
- Modify: `scripts/ensure-issue-labels.sh:11` (header comment) and `:83-84` (registry)
- Modify: `docs/DESIGN.md:180`
- Test: `tests/run-script-tests.sh` (new section after the salvaged-PR assertions near `:3460`; one assertion added near `:3187`; one block added after `:3282`)

**Interfaces:**
- Consumes: Task 1's output vocabulary (`complete|partial|unverifiable`, comma-separated `missing-tasks`, `reason`), passed in as env by Task 3.
- Produces: `post-run-report.sh` reads optional env `PLAN_COVERAGE`, `MISSING_TASKS`, `PLAN_COVERAGE_REASON`; status label is one of `ai:done|ai:failed|ai:partial`; the other two are removed.

- [ ] **Step 1: Write the failing test**

In `tests/run-script-tests.sh`, directly after the line
`assert_not_contains "$out" 'salvaged'      "an ordinary success is not flagged as salvaged"`, add:

```bash
section "plan coverage grading (#457)"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PLAN_COVERAGE=partial MISSING_TASKS=2,3 \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" ':warning: partial: plan task(s) 2, 3 have no file in the PR' \
  "partial coverage renders a warning naming the missing tasks"
assert_contains "$out" 'LABELS: ai:partial' "partial coverage labels ai:partial"
assert_not_contains "$out" ':white_check_mark:' "partial coverage is not reported as success"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PLAN_COVERAGE=partial MISSING_TASKS=2 SALVAGED=true \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" 'LABELS: ai:partial' "partial wins over salvaged"

out="$(RESULT_FILE="$FIXTURES/result-rate-limit.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PLAN_COVERAGE=partial MISSING_TASKS=2 \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" 'LABELS: ai:failed' "an agent error wins over partial"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PR_PRESENT=false PLAN_COVERAGE=partial MISSING_TASKS=2 \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" 'no PR was opened' "no PR wins over partial"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PLAN_COVERAGE=unverifiable PLAN_COVERAGE_REASON=no-plan \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" ':white_check_mark: success' "unverifiable keeps the success grade"
assert_contains "$out" 'LABELS: ai:done' "unverifiable keeps ai:done"
assert_contains "$out" '**Plan coverage:** not checked — no-plan' "unverifiable says coverage was not checked"

out="$(RESULT_FILE="$FIXTURES/result-success-cheap.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PLAN_COVERAGE=complete \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_not_contains "$out" 'Plan coverage' "complete coverage adds nothing to the report"
```

Near `:3187`, after `assert_contains "$log" 'label create ai:failed --repo owner/repo'  "creates ai:failed"`, add:

```bash
assert_contains "$log" 'label create ai:partial --repo owner/repo' "creates ai:partial (#457)"
```

After the line `assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:failed'    "removes opposite label (ai:failed) on success"`, add:

```bash
assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:partial'   "removes ai:partial on success (#457)"

: > "$MOCK_LOG"
PATH="$MOCKS:$PATH" \
GH_MOCK_LOG="$MOCK_LOG" \
RESULT_FILE="$FIXTURES/result-success-cheap.json" \
ISSUE_NUMBER=42 \
REPO=owner/repo \
WORKFLOW_RUN_URL=https://example/run/778 \
PLAN_COVERAGE=partial MISSING_TASKS=2 \
  bash "$SCRIPT" >/dev/null
log="$(cat "$MOCK_LOG")"
assert_contains "$log" 'issue edit 42 --repo owner/repo --add-label ai:partial'      "applies ai:partial (#457)"
assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:done'      "partial removes ai:done (#457)"
assert_contains "$log" 'issue edit 42 --repo owner/repo --remove-label ai:failed'    "partial removes ai:failed (#457)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL on every new `#457` assertion (partial still renders `:white_check_mark: success` / `ai:done`; no `Plan coverage` line; no `ai:partial` label create or remove).

- [ ] **Step 3: Write minimal implementation**

`scripts/post-run-report.sh`:

1. After the `HAS_PLAN=` env line, add:

```bash
PLAN_COVERAGE="${PLAN_COVERAGE:-}"                # complete | partial | unverifiable (#457)
MISSING_TASKS="${MISSING_TASKS:-}"                # comma-separated plan task numbers (partial)
PLAN_COVERAGE_REASON="${PLAN_COVERAGE_REASON:-}"  # why coverage was unverifiable
```

2. Extend the header's "Optional environment variables" block with:

```bash
#   PLAN_COVERAGE       "complete" | "partial" | "unverifiable", from
#                       check-plan-coverage.sh (#457). "partial" grades the run
#                       ai:partial with :warning: — below an agent error and a
#                       missing PR, above salvaged. "unverifiable" keeps the
#                       grade and adds a "Plan coverage: not checked" line.
#   MISSING_TASKS       Comma-separated plan task numbers; read when partial.
#   PLAN_COVERAGE_REASON
#                       Why coverage could not be checked; read when unverifiable.
```

3. In the grade chain, delete every `STATUS_LABEL_OPPOSITE=…` line (four of them), and insert this arm between the `PR_PRESENT == false` arm and the `SALVAGED == true` arm:

```bash
elif [[ "$PLAN_COVERAGE" == "partial" ]]; then
  # #457: the session ended cleanly but whole plan tasks have no file in the
  # PR (#430). Not a success — ai-stats counts only :white_check_mark: — and
  # the AI-merge job refuses it on plan-coverage != complete.
  STATUS_EMOJI=':warning:'
  STATUS_TEXT="partial: plan task(s) ${MISSING_TASKS//,/, } have no file in the PR"
  STATUS_LABEL='ai:partial'
```

4. Directly after the `MODEL_AGENT_LINE` block (before `CACHE_HIT_PCT=`), add:

```bash
# Header lines under the Outcome: the model/agent line, then — only when the
# plan could not be checked — a coverage note (#457). Built here so an empty
# coverage note adds no blank line to the comment.
META_LINES="$MODEL_AGENT_LINE"
if [[ "$PLAN_COVERAGE" == "unverifiable" ]]; then
  META_LINES+=$'\n'"**Plan coverage:** not checked — ${PLAN_COVERAGE_REASON:-unknown}"
fi
```

and in `render_comment`'s heredoc replace the line `${MODEL_AGENT_LINE}` with `${META_LINES}`.

5. Replace the line
`forge_issue_label_remove "$ISSUE_NUMBER" "$STATUS_LABEL_OPPOSITE" 2>/dev/null || true`
with:

```bash
# Exactly one status label survives: a re-run that changes the grade must not
# leave two grades on the issue (#457 added a third).
for stale_label in ai:done ai:failed ai:partial; do
  [[ "$stale_label" == "$STATUS_LABEL" ]] && continue
  forge_issue_label_remove "$ISSUE_NUMBER" "$stale_label" 2>/dev/null || true
done
```

Update the script header's line `# observability labels: ai:done | ai:failed, plus …` to `# observability labels: ai:done | ai:failed | ai:partial, plus …`.

`scripts/ensure-issue-labels.sh`: change the header line
`#   lifecycle  ai:running, ai:done, ai:failed, ctx:medium, ctx:high` to
`#   lifecycle  ai:running, ai:done, ai:failed, ai:partial, ctx:medium, ctx:high`,
and after `create ai:failed  D73A4A 'Pipeline run failed'` add:

```bash
create ai:partial FBCA04 'Pipeline run ended cleanly but plan tasks are missing from the PR'
```

`docs/DESIGN.md:180`: change to
`Plus stamps labels: \`ai:running\`, \`ai:done\`, \`ai:failed\`, \`ai:partial\` (plan tasks missing from the PR, #457), \`ctx:high\` / \`ctx:medium\`.`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-script-tests.sh`
Expected: PASS, `failed: 0` — including the pre-existing success / salvaged / no-PR / rate-limit assertions.

- [ ] **Step 5: Lint and commit**

Run: `shellcheck -x -e SC1091 scripts/post-run-report.sh scripts/ensure-issue-labels.sh tests/run-script-tests.sh && npx --no-install markdownlint-cli2 docs/DESIGN.md`
Expected: no shellcheck output, `0 issues`.

```bash
git add scripts/post-run-report.sh scripts/ensure-issue-labels.sh docs/DESIGN.md tests/run-script-tests.sh
git commit -m "feat(pipeline): report a run missing plan tasks as ai:partial

Refs #457"
git push
```

---

### Task 3: Wire coverage into the implement job and gate AI-merge on it

**Files:**
- Create: `scripts/plan-coverage-step.sh`
- Modify: `.github/workflows/agent-implement.yml:396-404` (implement job outputs), after `:964` (new step after `Verify or recover PR`), `:982-998` (`Post run report` env), `:1026-1031` (`ai_review_ai_merge` `if:`)
- Test: `tests/run-plan-coverage-tests.sh` (new section before the summary block)

**Interfaces:**
- Consumes: `scripts/check-plan-coverage.sh` (Task 1) — env `ISSUE_BODY_FILE`, `CHANGED_FILES_FILE`, three-line stdout. `post-run-report.sh` env `PLAN_COVERAGE`, `MISSING_TASKS`, `PLAN_COVERAGE_REASON` (Task 2).
- Produces: `scripts/plan-coverage-step.sh` — env `REPO`, `ISSUE_NUMBER`, `PR_NUMBER` (required), `GITHUB_OUTPUT` (optional, default stdout). Appends `coverage=`, `missing-tasks=`, `reason=` to `$GITHUB_OUTPUT`. Exit 0 on any grade including a failed fetch; 2 on usage error. Workflow: implement-job output `plan-coverage`.

- [ ] **Step 1: Write the failing test**

In `tests/run-plan-coverage-tests.sh`, insert before the final `printf '\npassed: …` summary:

```bash
section "plan-coverage-step.sh (gh mocked)"

STEP="$ROOT/scripts/plan-coverage-step.sh"
export PATH="$ROOT/tests/mocks:$PATH"
export GH_MOCK_LOG="$T/gh.log"

# The mock ignores --jq and serves the fixture verbatim, so the files fixture is
# the post-jq shape: one path per line.
printf 'issue view\t%s\n' "$T/body-430.md" > "$T/step.map"
printf 'pulls/7/files\t%s\n' "$T/changed-430.txt" >> "$T/step.map"

: > "$GH_MOCK_LOG"
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GITHUB_OUTPUT="$T/out1" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP"; cat "$T/out1")"
assert_eq "the step writes the grade" "partial" "$(field "$out" coverage)"
assert_eq "the step writes the missing tasks" "2,3" "$(field "$out" missing-tasks)"
case "$(cat "$GH_MOCK_LOG")" in
  *"api --paginate repos/o/r/pulls/7/files"*"previous_filename"*)
    pass "changed files are paginated and include rename sources" ;;
  *) fail "changed files are paginated and include rename sources" "$(cat "$GH_MOCK_LOG")" ;;
esac

printf 'pulls/7/files\n' > "$T/step-fail.map"
rc=0
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GH_MOCK_FAIL_MAP="$T/step-fail.map" GITHUB_OUTPUT="$T/out2" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP")" || rc=$?
assert_eq "a failed fetch still exits 0" "0" "$rc"
out="$(cat "$T/out2")"
assert_eq "a failed fetch is unverifiable" "unverifiable" "$(field "$out" coverage)"
assert_eq "a failed fetch says why" "fetch-failed" "$(field "$out" reason)"

printf 'issue view\n' > "$T/step-fail-body.map"
out="$(GH_MOCK_STDOUT_MAP="$T/step.map" GH_MOCK_FAIL_MAP="$T/step-fail-body.map" GITHUB_OUTPUT="$T/out3" \
  REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=7 bash "$STEP"; cat "$T/out3")"
assert_eq "a failed body fetch is unverifiable, never complete" "unverifiable" "$(field "$out" coverage)"

rc=0; REPO=o/r ISSUE_NUMBER=42 PR_NUMBER='' bash "$STEP" >/dev/null 2>&1 || rc=$?
assert_eq "missing PR_NUMBER exits 2" "2" "$rc"

section "workflow wiring"

WF="$ROOT/.github/workflows/agent-implement.yml"
if grep -q 'run: bash .claude-pipeline/scripts/plan-coverage-step.sh' "$WF"; then
  pass "the implement job runs the coverage step"
else
  fail "the implement job runs the coverage step"
fi
if grep -qE '^ +plan-coverage: +\$\{\{ steps\.plan_coverage\.outputs\.coverage \}\}' "$WF"; then
  pass "the implement job exports plan-coverage"
else
  fail "the implement job exports plan-coverage"
fi
if grep -qF "&& (inputs.dry-run || needs.implement.outputs.plan-coverage == 'complete')" "$WF"; then
  pass "AI-merge requires complete coverage outside dry-run"
else
  fail "AI-merge requires complete coverage outside dry-run"
fi
if grep -qF 'PLAN_COVERAGE: ${{ steps.plan_coverage.outputs.coverage }}' "$WF"; then
  pass "the run report receives the coverage grade"
else
  fail "the run report receives the coverage grade"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-plan-coverage-tests.sh`
Expected: Task 1's sections still pass; every assertion in the two new sections fails (`plan-coverage-step.sh` does not exist; the workflow has none of the four lines).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/plan-coverage-step.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
#
# plan-coverage-step.sh — the implement job's "Check plan coverage" step (#457).
#
# Fetches the issue body and the PR's changed files, grades them with
# check-plan-coverage.sh, and appends the grade to $GITHUB_OUTPUT. Any fetch
# failure is graded `unverifiable` / `fetch-failed` — never `complete`, so a
# GitHub blip cannot wave a PR into the AI-merge job, and never `partial`, so it
# cannot fail a good run either. This step must never fail the job.
#
# Required env: REPO, ISSUE_NUMBER, PR_NUMBER. Optional: GITHUB_OUTPUT (default
# stdout), GH_TOKEN / ambient gh auth.
#
# Exit codes:
#   0  graded (any grade, including fetch-failed)
#   2  usage error: a required variable unset
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for var in REPO ISSUE_NUMBER PR_NUMBER; do
  [[ -n "${!var:-}" ]] || { printf 'error: %s must be set\n' "$var" >&2; exit 2; }
done

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

emit_fetch_failed() {
  printf 'coverage=unverifiable\nmissing-tasks=\nreason=fetch-failed\n' >> "$OUT"
  exit 0
}

gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body --jq .body \
  > "$work/body.md" 2>/dev/null || emit_fetch_failed
[[ -s "$work/body.md" ]] || emit_fetch_failed

gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files" \
  --jq '.[] | .filename, (.previous_filename // empty)' \
  > "$work/changed.txt" 2>/dev/null || emit_fetch_failed

ISSUE_BODY_FILE="$work/body.md" CHANGED_FILES_FILE="$work/changed.txt" \
  bash "$HERE/check-plan-coverage.sh" > "$work/grade.txt" || emit_fetch_failed
cat "$work/grade.txt" >> "$OUT"
```

`.github/workflows/agent-implement.yml`:

1. In the implement job's `outputs:` block, after the `model:` line, add:

```yaml
      plan-coverage:       ${{ steps.plan_coverage.outputs.coverage }}
```

2. Directly after the `Verify or recover PR` step (the one ending `run: bash .claude-pipeline/scripts/verify-or-recover-pr.sh`), add:

```yaml
      - name: Check plan coverage
        # #457: grades the PR against the issue's Implementation Plan. A run
        # can end cleanly with whole plan tasks missing (#430); `partial` is
        # reported as ai:partial and, like `unverifiable`, keeps the PR out of
        # the AI-merge job. The script exits 0 on every grade, a failed fetch
        # included, so this step never fails the job.
        id: plan_coverage
        if: always() && !inputs.dry-run && steps.verify_pr.outputs.pr-present == 'true'
        env:
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.verify_pr.outputs.pr-number }}
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
        run: bash .claude-pipeline/scripts/plan-coverage-step.sh
```

3. In the `Post run report` step's `env:`, after `HAS_PLAN: …`, add:

```yaml
          PLAN_COVERAGE: ${{ steps.plan_coverage.outputs.coverage }}
          MISSING_TASKS: ${{ steps.plan_coverage.outputs.missing-tasks }}
          PLAN_COVERAGE_REASON: ${{ steps.plan_coverage.outputs.reason }}
```

4. In `ai_review_ai_merge`'s `if:`, after the line
`&& needs.implement.outputs.ai-review-human-merge-enabled != 'true'`, add:

```yaml
      && (inputs.dry-run || needs.implement.outputs.plan-coverage == 'complete')
```

and add to the job's leading comment block:

```yaml
    # #457: only a run whose PR covers every plan task reaches this job. The
    # coverage step is skipped under dry-run, where the act suite drives this
    # job with stub verdicts (agent-implement.test.yml), hence the exemption.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-plan-coverage-tests.sh && bash tests/run-all.sh`
Expected: `failed: 0` in the coverage runner; every runner in the full suite passes.

- [ ] **Step 5: Lint and commit**

Run: `actionlint .github/workflows/agent-implement.yml && shellcheck -x -e SC1091 scripts/plan-coverage-step.sh tests/run-plan-coverage-tests.sh`
Expected: no output from either.

```bash
git add scripts/plan-coverage-step.sh .github/workflows/agent-implement.yml tests/run-plan-coverage-tests.sh
git commit -m "feat(pipeline): gate AI-merge on complete plan coverage

Closes #457"
git push
```

The PR body quotes the RED and GREEN runs of each task.
