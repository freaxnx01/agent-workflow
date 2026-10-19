# Issue Intake Labels New Issues `needs-enrichment` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An issue opened by hand in a consumer repo gets `needs-enrichment` automatically, the way bridge/flowhub and `/new` issues already do, so the autopilot lane picks it up without anyone remembering the label.

**Architecture:** A query-then-write script `scripts/issue-intake.sh` with a pure decision function. A reusable workflow `.github/workflows/issue-intake.yml` runs it. `scripts/onboard-consumer.sh` generates a consumer stub `.github/workflows/issue-intake.yml` that triggers on `issues: [opened]`. Docs in `docs/CONSUMER-SETUP.md` and `docs/AUTOPILOT.md`.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `jq`, `gh` (mocked by `tests/mocks/gh`), GitHub Actions reusable workflows, Layer-1 tests (`tests/run-issue-intake-tests.sh`, `tests/run-onboard-stub-tests.sh`).

**Spec:** [`docs/superpowers/specs/2026-10-19-issue-intake-needs-enrichment-design.md`](../specs/2026-10-19-issue-intake-needs-enrichment-design.md)

## Global Constraints

- Label name `needs-enrichment`, colour `d4c5f9`, description `Needs a spec and plan before it can be implemented — /enrich or the autopilot lane`.
- Blocking labels, exactly: `ai-implement`, `enrichment-ongoing`, `needs-human`, `parked`, `🧊 parked`, `roadmap`, `pipeline-paused`, plus any label starting with `ai:`. No other label blocks intake.
- Decision order: bot author → already labelled → blocking label → `## Implementation Plan` heading line in the body → label.
- Skip reasons, verbatim: `opened by a bot`, `already labelled`, `pipeline label <name>`, `already has an implementation plan`.
- Output lines, verbatim: `intake: #<n> labelled needs-enrichment`, `intake: #<n> skipped (<reason>)`, `DRY_RUN: would label #<n> needs-enrichment`.
- Exit codes: `0` labelled or skipped; `1` issue unreadable or label write failed; `2` `REPO`/`ISSUE_NUMBER` missing or invalid.
- Reusable workflow: `permissions: contents: read` at workflow level, `issues: write` only on the job, every action pinned by full SHA (`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`, as in `pipeline-health.yml`), `timeout-minutes` set.
- Every script keeps `set -euo pipefail` + `IFS=$'\n\t'`; `shellcheck -x -e SC1091` and `actionlint` stay clean. No inline bash longer than 5 lines in YAML.

## Review Focus

- An `area:*` / `bug` / `enhancement` label must **not** block intake. Pinned in Task 1 ("a category label does not block intake").
- The `## Implementation Plan` match must be a heading line, not a substring of prose. Pinned in Task 1 ("a prose mention of the plan heading does not count").
- A bot-opened issue (Renovate's dependency dashboard, an App-filed issue) is never labelled. Pinned in Task 1.

## Files overlapping other plans in this batch

- `docs/AUTOPILOT.md`: also changed by **#509** (Setup, exit codes, wedged section) and **#550** (config / policy section). This plan touches only the "And per issue" paragraph (~lines 71-72). Expect at most a trivial rebase. It can be dispatched in parallel with #509.
- No other file is shared with #536, #509 or #550.

---

### Task 1: `scripts/issue-intake.sh` — decide and label

**Files:**
- Create: `scripts/issue-intake.sh`
- Create: `tests/run-issue-intake-tests.sh`
- Create: `tests/fixtures/intake/issue-plain.json`, `issue-labelled.json`, `issue-category.json`, `issue-ai-implement.json`, `issue-ai-prefixed.json`, `issue-parked-emoji.json`, `issue-planned.json`, `issue-plan-in-prose.json`, `issue-bot.json`

**Interfaces:**
- Produces: `intake_decision` (function; issue JSON on stdin; prints `label` or `skip <reason>`). The script runs `main` only when executed, not when sourced, so tests can call `intake_decision` directly.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/intake/issue-plain.json`:

```json
{"number":357,"labels":[],"body":"Show the current location in a debug overlay.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-labelled.json`:

```json
{"number":358,"labels":[{"name":"needs-enrichment"}],"body":"Filed by bridge.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-category.json`:

```json
{"number":359,"labels":[{"name":"area:ui"},{"name":"bug"}],"body":"HUD overlaps the minimap.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-ai-implement.json`:

```json
{"number":360,"labels":[{"name":"ai-implement"}],"body":"Already dispatched.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-ai-prefixed.json`:

```json
{"number":361,"labels":[{"name":"area:world"},{"name":"ai:paused"}],"body":"Stopped by a pause.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-parked-emoji.json`:

```json
{"number":362,"labels":[{"name":"🧊 parked"}],"body":"Parked on purpose.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-planned.json`:

```json
{"number":363,"labels":[],"body":"Deliver pizzas.\n\n## Acceptance Criteria\n\n- [ ] x\n\n## Implementation Plan\n\n### Task 1\n","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-plan-in-prose.json`:

```json
{"number":364,"labels":[],"body":"Once enriched this will get a ## Implementation Plan section.","author":{"login":"freaxnx01","is_bot":false}}
```

`tests/fixtures/intake/issue-bot.json`:

```json
{"number":365,"labels":[],"body":"Dependency Dashboard","author":{"login":"renovate[bot]","is_bot":true}}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/run-issue-intake-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-issue-intake-tests.sh — Layer-1 tests for scripts/issue-intake.sh and the
# issue-intake reusable workflow (#549). gh is mocked; no network.
#
# Usage: tests/run-issue-intake-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures/intake"
MOCKS="$ROOT/tests/mocks"
SCRIPT="$ROOT/scripts/issue-intake.sh"

# Hermetic: a runner always sets these, and the script falls back to none of them.
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
  (source "$SCRIPT"; intake_decision < "$FIX/$1")
}

section "intake_decision — who gets the label"

assert_eq "an unlabelled hand-filed issue is labelled" "label" "$(decide issue-plain.json)"
assert_eq "an issue that already has it is skipped" "skip already labelled" "$(decide issue-labelled.json)"
assert_eq "a category label does not block intake" "label" "$(decide issue-category.json)"
assert_eq "ai-implement blocks intake" "skip pipeline label ai-implement" "$(decide issue-ai-implement.json)"
assert_eq "an ai:-prefixed label blocks intake" "skip pipeline label ai:paused" "$(decide issue-ai-prefixed.json)"
assert_eq "the emoji parked label blocks intake" "skip pipeline label 🧊 parked" "$(decide issue-parked-emoji.json)"
assert_eq "a body with a plan heading is skipped" "skip already has an implementation plan" "$(decide issue-planned.json)"
assert_eq "a prose mention of the plan heading does not count" "label" "$(decide issue-plan-in-prose.json)"
assert_eq "a bot-opened issue is skipped" "skip opened by a bot" "$(decide issue-bot.json)"

for l in enrichment-ongoing needs-human parked roadmap pipeline-paused; do
  got="$(jq -n --arg l "$l" '{number:1,labels:[{name:$l}],body:"x",author:{login:"u",is_bot:false}}' \
    | (source "$SCRIPT"; intake_decision))"
  assert_eq "$l blocks intake" "skip pipeline label $l" "$got"
done

# run_intake <dir> <fixture> [extra env...] — runs the script with gh mocked.
run_intake() {
  local dir="$1" fixture="$2"; shift 2
  printf '%s\t%s\n' 'issue view' "$FIX/$fixture" > "$dir/stdout-map"
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" GH_MOCK_STDOUT_MAP="$dir/stdout-map" \
    REPO=freaxnx01/game-rhyflitzer ISSUE_NUMBER=357 "$@" bash "$SCRIPT" 2>&1
}

section "the write path"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-plain.json GITHUB_OUTPUT="$d/out")"
assert_contains "labelled -> says so" "$out" 'intake: #357 labelled needs-enrichment'
assert_contains "labelled -> the issue is edited" "$(cat "$d/gh")" \
  'issue edit 357 --repo freaxnx01/game-rhyflitzer --add-label needs-enrichment'
create_line="$(grep -n 'label create needs-enrichment' "$d/gh" | head -1 | cut -d: -f1)"
edit_line="$(grep -n -- '--add-label needs-enrichment' "$d/gh" | head -1 | cut -d: -f1)"
if [[ -n "$create_line" && -n "$edit_line" ]] && (( create_line < edit_line )); then
  pass "the label is created before it is applied"
else
  fail "the label is created before it is applied" "create ${create_line:-none}, edit ${edit_line:-none}"
fi
assert_contains "the create carries the colour" "$(grep 'label create' "$d/gh")" 'd4c5f9'
assert_contains "GITHUB_OUTPUT gets the decision" "$(cat "$d/out")" 'decision=labelled'
assert_contains "the issue is re-read, not taken from the payload" "$(cat "$d/gh")" \
  'issue view 357 --repo freaxnx01/game-rhyflitzer --json number,labels,body,author'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-ai-implement.json GITHUB_OUTPUT="$d/out")"
assert_contains "skipped -> says why" "$out" 'intake: #357 skipped (pipeline label ai-implement)'
assert_not_contains "skipped -> no edit" "$(cat "$d/gh")" 'issue edit'
assert_not_contains "skipped -> no label create" "$(cat "$d/gh")" 'label create'
assert_contains "skipped -> GITHUB_OUTPUT says skipped" "$(cat "$d/out")" 'decision=skipped'
assert_contains "skipped -> GITHUB_OUTPUT names the reason" "$(cat "$d/out")" 'reason=pipeline label ai-implement'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
out="$(run_intake "$d" issue-plain.json DRY_RUN=1)"
assert_contains "dry run -> says what it would do" "$out" 'DRY_RUN: would label #357 needs-enrichment'
assert_not_contains "dry run -> no edit" "$(cat "$d/gh")" 'issue edit'
assert_not_contains "dry run -> no label create" "$(cat "$d/gh")" 'label create'
rm -rf "$d"

section "failures are loud"

d="$(mktemp -d)"; : > "$d/gh"
printf 'issue view\n' > "$d/fail"
ec=0; out="$(run_intake "$d" issue-plain.json GH_MOCK_FAIL_MAP="$d/fail")" || ec=$?
assert_eq "unreadable issue -> exit 1" "1" "$ec"
assert_contains "unreadable issue -> says so" "$out" 'could not read issue #357'
assert_not_contains "unreadable issue -> no edit" "$(cat "$d/gh")" 'issue edit'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
printf -- '--add-label needs-enrichment\n' > "$d/fail"
ec=0; out="$(run_intake "$d" issue-plain.json GH_MOCK_FAIL_MAP="$d/fail")" || ec=$?
assert_eq "failed label write -> exit 1" "1" "$ec"
assert_contains "failed label write -> says so" "$out" 'could not label issue #357'
rm -rf "$d"

d="$(mktemp -d)"; : > "$d/gh"
ec=0; env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" ISSUE_NUMBER=357 bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
assert_eq "missing REPO -> exit 2" "2" "$ec"
ec=0; env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$d/gh" REPO=o/r ISSUE_NUMBER='12;x' bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
assert_eq "non-numeric ISSUE_NUMBER -> exit 2" "2" "$ec"
assert_eq "invalid env -> no gh call" "" "$(cat "$d/gh")"
rm -rf "$d"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
```

`chmod +x tests/run-issue-intake-tests.sh`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/run-issue-intake-tests.sh 2>&1 | tail -5`
Expected: FAIL. `scripts/issue-intake.sh` does not exist, so every `decide` and `run_intake` assertion fails.

- [ ] **Step 4: Implement**

Create `scripts/issue-intake.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
#
# issue-intake.sh — label a newly opened issue needs-enrichment (#549).
#
# The autopilot lane only enriches issues carrying needs-enrichment. Issues
# filed through bridge (flowhub's path) or /new are born with it; one opened in
# the GitHub UI is not, and would be ignored without a trace. This applies the
# same intake stamp to that path. Removing the label stays a deliberate act.
#
# Skipped (never labelled): issues opened by a bot, issues that already carry
# it, issues carrying a pipeline label (see BLOCKING below, plus any ai:*), and
# issues whose body already has a `## Implementation Plan` heading. Category
# labels (bug, area:*, …) do not block it.
#
# Required env: REPO (owner/name), ISSUE_NUMBER, GH_TOKEN (or ambient gh auth
# on a runner). Optional: DRY_RUN=1 decides and prints, writes nothing.
#
# Output: one stdout line, `intake: #<n> labelled needs-enrichment` or
# `intake: #<n> skipped (<reason>)`; `decision=` and `reason=` appended to
# $GITHUB_OUTPUT when set.
#
# Exit codes:
#   0  labelled, or skipped by rule
#   1  the issue could not be read, or the label could not be applied
#   2  REPO or ISSUE_NUMBER missing or invalid
set -euo pipefail
IFS=$'\n\t'

INTAKE_LABEL='needs-enrichment'
INTAKE_LABEL_COLOR='d4c5f9'
INTAKE_LABEL_DESC='Needs a spec and plan before it can be implemented — /enrich or the autopilot lane'

# intake_decision — issue JSON ({labels, body, author}) on stdin. Prints
# `label`, or `skip <reason>`. Query only.
intake_decision() {
  jq -r '
    def blocking: ["ai-implement", "enrichment-ongoing", "needs-human",
                   "parked", "🧊 parked", "roadmap", "pipeline-paused"];
    def names: [.labels[]?.name];
    def blockers: [names[] | select(. as $n | (blocking | index($n)) != null
                                     or startswith("ai:"))];
    if (.author.is_bot // false) then "skip opened by a bot"
    elif (names | index("needs-enrichment")) != null then "skip already labelled"
    elif (blockers | length) > 0 then "skip pipeline label " + blockers[0]
    elif ((.body // "") | test("(^|\n)## Implementation Plan[ \t]*\r?(\n|$)"))
      then "skip already has an implementation plan"
    else "label" end'
}

usage_error() { printf 'error: %s\n' "$1" >&2; exit 2; }

# report <decision> <reason> — the stdout line plus $GITHUB_OUTPUT.
report() {
  local decision="$1" reason="$2"
  if [[ "$decision" == labelled ]]; then
    printf 'intake: #%s labelled %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL"
  else
    printf 'intake: #%s skipped (%s)\n' "$ISSUE_NUMBER" "$reason"
  fi
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf 'decision=%s\nreason=%s\n' "$decision" "$reason" >> "$GITHUB_OUTPUT"
}

apply_label() {
  # Errors when the label exists — the expected, tolerated path.
  gh label create "$INTAKE_LABEL" --repo "$REPO" --color "$INTAKE_LABEL_COLOR" \
    --description "$INTAKE_LABEL_DESC" >/dev/null 2>&1 || true
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "$INTAKE_LABEL" >/dev/null 2>&1
}

main() {
  [[ -n "${REPO:-}" ]] || usage_error 'REPO must be set'
  [[ "${ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
    || usage_error "ISSUE_NUMBER must be a positive integer (got: ${ISSUE_NUMBER:-})"

  local json decision
  if ! json="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json number,labels,body,author 2>/dev/null)" \
     || ! decision="$(printf '%s' "$json" | intake_decision 2>/dev/null)"; then
    printf 'error: could not read issue #%s in %s — not labelled\n' "$ISSUE_NUMBER" "$REPO" >&2
    exit 1
  fi

  if [[ "$decision" != label ]]; then
    report skipped "${decision#skip }"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY_RUN: would label #%s %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL"
    return 0
  fi
  if ! apply_label; then
    printf 'error: could not label issue #%s %s in %s\n' "$ISSUE_NUMBER" "$INTAKE_LABEL" "$REPO" >&2
    exit 1
  fi
  report labelled ''
}

# Sourced by tests/run-issue-intake-tests.sh to call intake_decision directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run-issue-intake-tests.sh 2>&1 | tail -4`
Expected: `failed: 0`.

- [ ] **Step 6: Lint**

Run: `shellcheck -x -e SC1091 scripts/issue-intake.sh tests/run-issue-intake-tests.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add scripts/issue-intake.sh tests/run-issue-intake-tests.sh tests/fixtures/intake/
git commit -m "feat(intake): label new issues needs-enrichment unless already planned or in the pipeline (#549)"
```

---

### Task 2: Reusable workflow `issue-intake.yml`

**Files:**
- Create: `.github/workflows/issue-intake.yml`
- Test: `tests/run-issue-intake-tests.sh` (new section before the summary)

- [ ] **Step 1: Write the failing tests**

In `tests/run-issue-intake-tests.sh`, directly before the final `printf '\npassed: …'` line, add:

```bash
section "the reusable workflow"

WF="$ROOT/.github/workflows/issue-intake.yml"
wf="$(cat "$WF" 2>/dev/null || true)"
assert_contains "callable by a consumer stub" "$wf" 'workflow_call:'
assert_contains "takes the issue number" "$wf" 'issue-number:'
assert_contains "runs the intake script" "$wf" 'scripts/issue-intake.sh'
assert_contains "issues: write on the job" "$wf" 'issues: write'
assert_not_contains "never writes code" "$wf" 'contents: write'
assert_contains "has a job timeout" "$wf" 'timeout-minutes:'
unpinned="$(grep -E '^\s*-?\s*uses: ' "$WF" 2>/dev/null | grep -vE '@[0-9a-f]{40}' || true)"
assert_eq "every action is pinned by full SHA" "" "$unpinned"
if [[ -n "$wf" ]] && command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WF" >/dev/null 2>&1; then pass "actionlint is clean"; else fail "actionlint is clean" "$(actionlint "$WF" 2>&1 | head -5)"; fi
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-issue-intake-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: FAIL on `callable by a consumer stub`, `takes the issue number`, `runs the intake script`, `issues: write on the job`, `has a job timeout`.

- [ ] **Step 3: Implement**

Create `.github/workflows/issue-intake.yml`:

```yaml
# Issue intake (reusable) — label a newly opened issue needs-enrichment (#549).
#
# Issues filed through bridge (flowhub's path) or /new are born carrying
# needs-enrichment; one opened in the GitHub UI is not, and the autopilot lane
# ignores it. Consumers call this from their own `issues: [opened]` stub
# (scripts/onboard-consumer.sh generates it): a reusable workflow cannot add a
# trigger to a consumer. The rules are in scripts/issue-intake.sh.
#
# The label is applied with the caller's GITHUB_TOKEN, and events caused by
# that token start no other workflow — so it cannot fire agent.yml.
name: Issue intake (reusable)

on:
  workflow_call:
    inputs:
      issue-number:
        description: The issue that was just opened.
        type: number
        required: true
      pipeline-repo:
        description: Repo holding the shared scripts.
        type: string
        default: freaxnx01/agent-workflow
      pipeline-ref:
        description: |
          Ref of `pipeline-repo` to check out. Pin the same moving major tag
          the caller pinned in `uses:` — see docs/CONSUMER-SETUP.md.
        type: string
        default: main
      local-scripts:
        description: Use the caller repo's own scripts/ (agent-workflow dogfooding).
        type: boolean
        default: false
      timeout-minutes:
        type: number
        default: 5

permissions:
  contents: read

jobs:
  intake:
    name: Label needs-enrichment
    runs-on: ubuntu-latest
    timeout-minutes: ${{ inputs.timeout-minutes }}
    permissions:
      contents: read
      issues: write
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
        run: |
          mkdir -p .claude-pipeline/scripts
          cp -r scripts/. .claude-pipeline/scripts/

      - name: Label the issue
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
        run: bash .claude-pipeline/scripts/issue-intake.sh
```

- [ ] **Step 4: Run the tests and actionlint**

Run: `bash tests/run-issue-intake-tests.sh 2>&1 | tail -4 && actionlint .github/workflows/issue-intake.yml`
Expected: `failed: 0`; actionlint prints nothing.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/issue-intake.yml tests/run-issue-intake-tests.sh
git commit -m "feat(intake): add the issue-intake reusable workflow (#549)"
```

---

### Task 3: Onboarding generates the consumer stub

**Files:**
- Modify: `scripts/onboard-consumer.sh` (new `build_intake_yml` after `build_health_yml`, ~line 400; both stub-writing branches, ~lines 476-494; header step 5 comment, line 14)
- Test: `tests/run-onboard-stub-tests.sh` (new `intake_stub` helper after `health_stub`, ~line 76; new section after the health-stub section, ~line 136)

**Interfaces:**
- Consumes: `.github/workflows/issue-intake.yml` inputs `issue-number`, `pipeline-ref` (Task 2).

- [ ] **Step 1: Write the failing tests**

In `tests/run-onboard-stub-tests.sh`, after the `health_stub()` function, add:

```bash
# intake_stub — echoes the generated issue-intake.yml (#549). Same extraction
# trick as stub().
intake_stub() {
  # shellcheck disable=SC2034
  (
    REF='v2'
    PIPELINE_REPO='freaxnx01/agent-workflow'
    # shellcheck disable=SC1090
    source <(sed -n '/^build_intake_yml()/,/^}/p' "$SRC")
    build_intake_yml
  )
}
```

After the health-stub section (after its yamllint block), add:

```bash
section "intake stub — new issues enter the lane (#549)"

intake="$(intake_stub)"
assert_contains 'uses: freaxnx01/agent-workflow/.github/workflows/issue-intake.yml@v2' \
  "$intake" "calls the intake workflow at the pinned ref"
assert_contains 'types: [opened]' "$intake" "runs when an issue is opened"
# shellcheck disable=SC2016  # `${{ }}` is Actions expression syntax, not shell
assert_contains 'issue-number: ${{ github.event.issue.number }}' "$intake" "passes the new issue's number"
assert_contains 'pipeline-ref: v2' "$intake" "checks out scripts at the same ref"
assert_contains 'issues: write' "$intake" "may label the issue"
assert_not_contains 'contents: write' "$intake" "never writes code"
writes="$(sed -n '/^if \[\[ "\$NO_STUB"/,/^fi/p' "$SRC" | grep -c 'put_file ".github/workflows/issue-intake.yml"' || true)"
if [[ "$writes" == 2 ]]; then
  pass "both onboarding paths write the intake stub"
else
  fail "both onboarding paths write the intake stub" "found $writes put_file calls, expected 2"
fi

if command -v yamllint >/dev/null 2>&1; then
  if printf '%s\n' "$intake" | yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' - >/dev/null 2>&1; then
    pass "generated intake stub is valid YAML"
  else
    fail "generated intake stub is valid YAML" "yamllint rejected it"
  fi
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-onboard-stub-tests.sh 2>&1 | tail -12`
Expected: FAIL on every assertion in the new section (`build_intake_yml` does not exist yet).

- [ ] **Step 3: Implement**

In `scripts/onboard-consumer.sh`, after `build_health_yml`'s closing `}`, add:

```bash
# The intake stamp (#549). A consumer gets it unconditionally, like the health
# stub: /new and bridge already label every issue they file needs-enrichment,
# and this gives an issue opened in the GitHub UI the same start.
build_intake_yml() {
  cat <<YAML
name: Issue intake
on:
  issues:
    types: [opened]

permissions:
  contents: read
  issues: write   # applies needs-enrichment to the new issue

jobs:
  intake:
    uses: $PIPELINE_REPO/.github/workflows/issue-intake.yml@$REF
    with:
      issue-number: \${{ github.event.issue.number }}
      pipeline-ref: $REF
YAML
}
```

In **both** stub-writing branches (the `DIRECT_TO_MAIN` one and the PR one), directly after the `build_health_yml | put_file …` call, add:

```bash
  build_intake_yml | put_file ".github/workflows/issue-intake.yml" \
    "ci(agent-workflow): add issue intake stub"
```

In the header comment's step 5 (line 14), append `issue-intake.yml` to the list of committed stubs.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-onboard-stub-tests.sh 2>&1 | tail -4`
Expected: `0 failed` (no `failed` line).

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/onboard-consumer.sh tests/run-onboard-stub-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/onboard-consumer.sh tests/run-onboard-stub-tests.sh
git commit -m "feat(onboard): generate the issue intake stub (#549)"
```

---

### Task 4: Docs

**Files:**
- Modify: `docs/CONSUMER-SETUP.md` (new section `## 3c. Issue intake (recommended)` after section 3b, before `## 4. Issue chaining`, ~line 503)
- Modify: `docs/AUTOPILOT.md` (the "And per issue" paragraph, lines 71-72)

- [ ] **Step 1: Write `docs/CONSUMER-SETUP.md` section 3c**

````markdown
## 3c. Issue intake (recommended)

An issue filed through bridge (flowhub's path) or `/new` is born carrying
`needs-enrichment`. One opened in the GitHub UI is not, so the autopilot lane
(`docs/AUTOPILOT.md`) never sees it. The intake stub gives it the same start
(#549). `scripts/onboard-consumer.sh` writes it on every onboarding.

```yaml
# .github/workflows/issue-intake.yml
name: Issue intake
on:
  issues:
    types: [opened]

permissions:
  contents: read
  issues: write

jobs:
  intake:
    uses: freaxnx01/agent-workflow/.github/workflows/issue-intake.yml@v2
    with:
      issue-number: ${{ github.event.issue.number }}
      pipeline-ref: v2
```

It labels the new issue `needs-enrichment` **unless** the issue was opened by
a bot, already carries the label, carries a pipeline label (`ai-implement`,
`enrichment-ongoing`, `needs-human`, `parked`, `🧊 parked`, `roadmap`,
`pipeline-paused`, or any `ai:*`), or its body already has a
`## Implementation Plan` heading. Category labels (`bug`, `area:*`, …) do not
stop it. To keep an issue out of the lane, remove the label or park it.

Existing issues are not touched; the stub only sees issues opened after it is
merged.
````

- [ ] **Step 2: Update `docs/AUTOPILOT.md`**

Replace

```markdown
And per issue: open, `needs-enrichment`, a non-empty body, and none of
`parked`, `enrichment-ongoing`, `needs-human`, `ai-implement`.
```

with

```markdown
And per issue: open, `needs-enrichment`, a non-empty body, and none of
`parked`, `enrichment-ongoing`, `needs-human`, `ai-implement`.

Issues filed through bridge (flowhub) or `/new` are born with
`needs-enrichment`. One opened by hand gets it from the consumer's intake stub
(`.github/workflows/issue-intake.yml`, generated by `onboard-consumer.sh`;
see `docs/CONSUMER-SETUP.md` §3c), so it enters the lane without anyone
remembering the label (#549). A repo onboarded before the stub existed needs
`onboard-consumer.sh` re-run (or the stub copied in) to get it.
```

- [ ] **Step 3: Run the whole suite**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: all runners pass, `run-issue-intake-tests.sh` among them.

- [ ] **Step 4: Commit**

```bash
git add docs/CONSUMER-SETUP.md docs/AUTOPILOT.md
git commit -m "docs(intake): document the issue intake stub (#549)"
```
