# Blocked Agent-PR Checks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a pipeline PR whose required checks cannot run say so — loudly, on the issue — instead of looking identical to a finished run.

**Architecture:** Three diagnostic touchpoints, none of which can fail the job. A four-line preflight warns at job start when `PIPELINE_APP_ID` is unset; a new bounded-poll script determines after the PR opens whether its checks actually started; and the existing run-report comment grows a warning block plus an `ai:checks-blocked` label. The outcome label stays `ai:done` throughout — the agent did its job, the repo is misconfigured.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), GitHub Actions reusable workflow YAML, `gh` CLI + `jq`, fixture-driven Layer-1 bash tests against `tests/mocks/gh`, `actionlint` + `shellcheck -x`.

**Spec:** `docs/superpowers/specs/2026-09-22-agent-pr-checks-blocked-design.md`

## Global Constraints

- Every script starts with `#!/usr/bin/env bash`, then `set -euo pipefail`, then `IFS=$'\n\t'`.
- Quote every variable expansion. `[[ ... ]]` over `[ ... ]`. `$(...)` over backticks. No `eval`.
- `printf` over `echo` for anything formatted.
- Exit codes are documented in each script's header block.
- Env-driven, not flag-driven — these are CI scripts invoked from `env:` blocks.
- **No inline bash longer than 5 lines inside a YAML step.** The preflight warning is exactly four; anything longer goes in `scripts/`.
- **This change is diagnostic only.** Nothing added here may fail the implement job, and nothing may change `STATUS_LABEL` in `post-run-report.sh`. The calling step carries `continue-on-error: true`; the script's exit code only tells the report which branch to render.
- Layer-1 tests are hermetic: no network, no GitHub, no Docker; whole suite under 5 seconds. Tests set `POLL_INTERVAL=0` so no test ever sleeps.
- Test runners are auto-discovered by `tests/run-all.sh` via `find -maxdepth 1 -name 'run-*-tests.sh'` — a new runner needs **no** registration.
- Conventional Commits; scope `pipeline` for workflow/script work, `docs` for doc-only.

---

### Task 1: The checks-runnable probe

**Files:**
- Create: `scripts/check-pr-checks-runnable.sh`
- Create: `tests/run-check-pr-checks-runnable-tests.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/check-pr-checks-runnable.sh`. Required env `PR_NUMBER`. Optional `REPO` (default `$GITHUB_REPOSITORY`), `APP_TOKEN_CONFIGURED`, `POLL_INTERVAL` (default `10`), `POLL_TIMEOUT` (default `120`), `GITHUB_OUTPUT`. Writes `checks-runnable=true|false` and `checks-blocked-reason=<slug>` to stdout and, when set, to `$GITHUB_OUTPUT`. Reason slugs: `no-app-token`, `rollup-empty`, or empty when runnable. Exit `0` on a determination, `2` on missing required env. Task 2 consumes these as `CHECKS_RUNNABLE` / `CHECKS_BLOCKED_REASON`; Task 3 wires it.

- [ ] **Step 1: Write the failing test**

Create `tests/run-check-pr-checks-runnable-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-check-pr-checks-runnable-tests.sh — Layer-1 tests for
# scripts/check-pr-checks-runnable.sh.
#
# Drives the script against the shared `gh` mock (tests/mocks/gh), using its
# GH_MOCK_STDOUT_MAP seam to serve a canned `statusCheckRollup`. POLL_INTERVAL=0
# everywhere, so no test ever sleeps and the suite stays sub-second.
#
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-pr-checks-runnable.sh"
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
assert_equals() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected '$2' got '$1'"; fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A rollup with two checks, and an empty one. The script asks for
# `.statusCheckRollup | length`, so the mock serves whatever the --jq would
# have produced: the mock does not run jq itself.
printf '2\n' > "$tmp/rollup-two.txt"
printf '0\n' > "$tmp/rollup-empty.txt"

map_for() {
  # Build a GH_MOCK_STDOUT_MAP serving $1 for any `pr view` invocation.
  printf 'pr view\t%s\n' "$1" > "$tmp/map.tsv"
  printf '%s' "$tmp/map.tsv"
}

run_probe() {
  # Usage: run_probe [env assignments...]
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$tmp/gh.log" POLL_INTERVAL=0 \
    "$@" bash "$SCRIPT" 2>&1
}

section "required env"

ec=0
out="$(run_probe GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-two.txt")" || ec=$?)"
assert_equals "$ec" "2"                 "missing PR_NUMBER → exit 2"
assert_contains "$out" "PR_NUMBER"      "missing PR_NUMBER → names PR_NUMBER"

section "checks are running"

ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=1 \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-two.txt")" || ec=$?)"
assert_equals "$ec" "0"                             "non-empty rollup → exit 0"
assert_contains "$out" "checks-runnable=true"       "non-empty rollup → runnable=true"
assert_contains "$out" "checks-blocked-reason="     "non-empty rollup → reason key present"

section "checks are blocked — no app token"

ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=1 APP_TOKEN_CONFIGURED=false \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")" || ec=$?)"
assert_equals "$ec" "0"                                    "empty rollup → still exit 0"
assert_contains "$out" "checks-runnable=false"             "empty rollup → runnable=false"
assert_contains "$out" "checks-blocked-reason=no-app-token" "no app token → no-app-token reason"

section "checks are blocked — app token configured"

ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=1 APP_TOKEN_CONFIGURED=true \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")" || ec=$?)"
assert_contains "$out" "checks-runnable=false"              "app configured, empty → runnable=false"
assert_contains "$out" "checks-blocked-reason=rollup-empty" "app configured → rollup-empty reason"

section "GITHUB_OUTPUT"

gh_out="$tmp/gh_output"; : > "$gh_out"
run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=1 APP_TOKEN_CONFIGURED=false \
  GITHUB_OUTPUT="$gh_out" \
  GH_MOCK_STDOUT_MAP="$(map_for "$tmp/rollup-empty.txt")" >/dev/null
written="$(cat "$gh_out")"
assert_contains "$written" "checks-runnable=false"              "GITHUB_OUTPUT → runnable key"
assert_contains "$written" "checks-blocked-reason=no-app-token" "GITHUB_OUTPUT → reason key"

section "gh failure is not fatal"

printf 'pr view\n' > "$tmp/failmap.tsv"
ec=0
out="$(run_probe PR_NUMBER=7 REPO=o/r POLL_TIMEOUT=1 APP_TOKEN_CONFIGURED=false \
  GH_MOCK_FAIL_MAP="$tmp/failmap.tsv" || ec=$?)"
assert_equals "$ec" "0"                          "gh failing → still exit 0"
assert_contains "$out" "checks-runnable=false"   "gh failing → treated as not runnable"

# --- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'; printf '  - %s\n' "${FAIL_NAMES[@]}"
  exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-check-pr-checks-runnable-tests.sh`
Expected: FAIL — `scripts/check-pr-checks-runnable.sh` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/check-pr-checks-runnable.sh`:

```bash
#!/usr/bin/env bash
#
# check-pr-checks-runnable.sh — Determine whether a pipeline-opened PR's
# required status checks can actually run.
#
# A PR opened with the ambient GITHUB_TOKEN is authored by `github-actions`.
# Its `pull_request` workflow runs are created but stall at `action_required`
# awaiting manual approval, so `statusCheckRollup` stays empty and a repo with
# required checks leaves the PR permanently BLOCKED (#364, observed on #363).
# Nothing in the pipeline said so: a stalled PR looked exactly like a finished
# one. This probe is what makes the stall visible.
#
# DIAGNOSTIC ONLY. This script never fails the job — the calling step carries
# `continue-on-error: true`, and a blocked determination does not change the
# run's outcome label. The agent did its work; the repo is misconfigured.
#
# Polls for check PRESENCE, not completion. `gh pr checks --watch` is the wrong
# tool here: it waits for checks to finish, and the whole symptom is that none
# ever start.
#
# Required environment variables:
#   PR_NUMBER   The pull request to probe.
#
# Optional environment variables:
#   REPO                  owner/repo. Default: $GITHUB_REPOSITORY.
#   APP_TOKEN_CONFIGURED  "true" when a pipeline App token was minted. The
#                         workflow passes `${{ env.PIPELINE_APP_ID != '' }}`.
#                         Selects which blocked reason is reported.
#   POLL_INTERVAL         Seconds between polls. Default 10. Tests set 0.
#   POLL_TIMEOUT          Seconds to keep polling. Default 120.
#   GITHUB_OUTPUT         When set, both output keys are appended to it.
#
# Output (stdout, and $GITHUB_OUTPUT when set):
#   checks-runnable=true|false
#   checks-blocked-reason=|no-app-token|rollup-empty
#
# Exit codes:
#   0   determination made (runnable or not)
#   2   required env missing
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${PR_NUMBER:-}" ]]; then
  printf 'error: PR_NUMBER must be set\n' >&2
  exit 2
fi

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
APP_TOKEN_CONFIGURED="${APP_TOKEN_CONFIGURED:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
POLL_TIMEOUT="${POLL_TIMEOUT:-120}"

emit() {
  local runnable="$1" reason="$2"
  printf 'checks-runnable=%s\n' "$runnable"
  printf 'checks-blocked-reason=%s\n' "$reason"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'checks-runnable=%s\n' "$runnable" >> "$GITHUB_OUTPUT"
    printf 'checks-blocked-reason=%s\n' "$reason" >> "$GITHUB_OUTPUT"
  fi
}

# Count the checks attached to the PR. A `gh` failure is deliberately NOT
# fatal: an outage must not fail a diagnostic step, so it counts as zero and
# the poll simply carries on until the window closes.
rollup_count() {
  local args=(pr view "$PR_NUMBER" --json statusCheckRollup
              --jq '.statusCheckRollup | length')
  [[ -n "$REPO" ]] && args+=(--repo "$REPO")
  gh "${args[@]}" 2>/dev/null || printf '0'
}

deadline=$(( $(date +%s) + POLL_TIMEOUT ))
runnable=false

while :; do
  count="$(rollup_count | tr -d '[:space:]')"
  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    runnable=true
    break
  fi
  (( $(date +%s) >= deadline )) && break
  sleep "$POLL_INTERVAL"
done

if [[ "$runnable" == "true" ]]; then
  printf 'checks are running on PR #%s\n' "$PR_NUMBER" >&2
  emit true ''
  exit 0
fi

# Two reasons, because they call for different operator actions.
if [[ "$APP_TOKEN_CONFIGURED" == "true" ]]; then
  reason='rollup-empty'
  printf 'PR #%s has no checks after %ss, and a pipeline App token WAS minted.\n' \
    "$PR_NUMBER" "$POLL_TIMEOUT" >&2
else
  reason='no-app-token'
  printf 'PR #%s has no checks after %ss; no pipeline App token was configured,\n' \
    "$PR_NUMBER" "$POLL_TIMEOUT" >&2
  printf 'so the PR is authored by github-actions and its checks need approval.\n' >&2
  printf 'See docs/PIPELINE-APP-SETUP.md\n' >&2
fi

emit false "$reason"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-check-pr-checks-runnable-tests.sh`
Expected: PASS — all cases green, sub-second (no test sleeps, because `POLL_INTERVAL=0`).

- [ ] **Step 5: Lint**

Run: `shellcheck -x scripts/check-pr-checks-runnable.sh tests/run-check-pr-checks-runnable-tests.sh`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-pr-checks-runnable.sh tests/run-check-pr-checks-runnable-tests.sh
git commit -m "feat(pipeline): probe whether an agent PR's checks can run

Adds check-pr-checks-runnable.sh: polls statusCheckRollup for check
PRESENCE over a bounded window and reports one of two blocked reasons,
distinguishing 'no App token was configured' from 'the App was configured
and checks still did not start'.

Diagnostic only — never fails the job, and a gh outage counts as zero
rather than erroring.

Refs #364"
```

---

### Task 2: Report it on the issue

**Files:**
- Modify: `scripts/post-run-report.sh` (env block ~`:16-35`, `render_comment` `:269-288`, `labels_csv` `:290-296`)
- Modify: `scripts/ensure-issue-labels.sh` (add `ai:checks-blocked` beside the other blocked labels, ~line 85)
- Modify: `tests/run-script-tests.sh` (add assertions for the new block)

**Interfaces:**
- Consumes: Task 1's `checks-runnable` / `checks-blocked-reason`, passed in as `CHECKS_RUNNABLE` and `CHECKS_BLOCKED_REASON`.
- Produces: a run-report comment that carries a warning block when checks are blocked, and `labels_csv()` returning a third label `ai:checks-blocked`. Task 3 wires the env through.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-script-tests.sh`, immediately before its final summary block:

```bash
section "checks-blocked warning (#364)"

# Reuses the existing success fixture: a blocked run is still a SUCCESSFUL run,
# so the outcome must not change. That is the regression this guards.
out="$(CHECKS_RUNNABLE=false CHECKS_BLOCKED_REASON=no-app-token \
  render_only result-success-cheap.json)"
assert_contains "$out" 'Required checks could not run'  "blocked → warning block rendered"
assert_contains "$out" 'PIPELINE_APP_ID'                "blocked → names the unset secret"
assert_contains "$out" 'docs/PIPELINE-APP-SETUP.md'     "blocked → points at the runbook"
assert_contains "$out" 'ai:checks-blocked'              "blocked → label in LABELS line"
assert_contains "$out" 'LABELS: ai:done'                "blocked → outcome STILL ai:done"

out="$(CHECKS_RUNNABLE=false CHECKS_BLOCKED_REASON=rollup-empty \
  render_only result-success-cheap.json)"
assert_contains "$out" 'a pipeline App token was minted' "rollup-empty → different wording"
assert_contains "$out" 'ai:checks-blocked'               "rollup-empty → label present"

out="$(CHECKS_RUNNABLE=true render_only result-success-cheap.json)"
assert_not_contains "$out" 'Required checks could not run' "runnable → no warning block"
assert_not_contains "$out" 'ai:checks-blocked'             "runnable → no label"

out="$(render_only result-success-cheap.json)"
assert_not_contains "$out" 'Required checks could not run' "unset → no warning block"
assert_not_contains "$out" 'ai:checks-blocked'             "unset → no label"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — the new assertions fail; `post-run-report.sh` ignores both env vars.

- [ ] **Step 3: Write minimal implementation**

Three edits to `scripts/post-run-report.sh`.

**3a.** Add to the "Optional environment variables" header block, after the `RENDER_ONLY` entry:

```bash
#   CHECKS_RUNNABLE     "false" when check-pr-checks-runnable.sh determined the
#                       PR's required checks cannot run. Adds a warning block to
#                       the comment and the ai:checks-blocked label. Never
#                       changes the outcome — a blocked run is still a
#                       successful run (#364).
#   CHECKS_BLOCKED_REASON
#                       "no-app-token" | "rollup-empty". Selects the remedy
#                       wording. Only read when CHECKS_RUNNABLE is "false".
```

**3b.** Add near the other env defaults, beside the existing `SALVAGED` line at `:59`:

```bash
CHECKS_RUNNABLE="${CHECKS_RUNNABLE:-}"              # "false" → checks cannot run (#364)
CHECKS_BLOCKED_REASON="${CHECKS_BLOCKED_REASON:-}"  # no-app-token | rollup-empty

# Rendered into the comment, and gates the ai:checks-blocked label. Built here
# rather than inside render_comment so labels_csv can test one variable.
CHECKS_BLOCKED_BLOCK=''
if [[ "$CHECKS_RUNNABLE" == "false" ]]; then
  if [[ "$CHECKS_BLOCKED_REASON" == "rollup-empty" ]]; then
    CHECKS_BLOCKED_BLOCK="$(printf '\n> [!WARNING]\n> **Required checks could not run on this PR.**\n> A pipeline App token was minted, yet no checks appeared. This is not the\n> usual cause — inspect the PR directly. See `docs/PIPELINE-APP-SETUP.md`.\n')"
  else
    CHECKS_BLOCKED_BLOCK="$(printf '\n> [!WARNING]\n> **Required checks could not run on this PR.**\n> No `PIPELINE_APP_ID` is configured, so the PR is authored by\n> `github-actions` and its checks stall awaiting manual approval — the PR\n> stays BLOCKED until someone approves them or pushes to the branch.\n> The implementation itself is unaffected. Fix: `docs/PIPELINE-APP-SETUP.md`.\n')"
  fi
fi
```

**3c.** Render it and label it. In `render_comment` (`:269`), insert `${CHECKS_BLOCKED_BLOCK}` between the metrics table and the run link:

```bash
| Max context per turn | ${CONTEXT_ROW} |
${CHECKS_BLOCKED_BLOCK}

[View workflow run](${WORKFLOW_RUN_URL})
EOF
```

And replace `labels_csv` (`:290-296`) — note it must stay a pure query, and
`STATUS_LABEL` is deliberately untouched:

```bash
labels_csv() {
  local out="$STATUS_LABEL"
  [[ -n "$CTX_LABEL" ]] && out="${out},${CTX_LABEL}"
  # Additive only. A blocked run is still ai:done — the agent did its job and
  # the PR is reviewable; it is the repo that is misconfigured (#364).
  [[ -n "$CHECKS_BLOCKED_BLOCK" ]] && out="${out},ai:checks-blocked"
  printf '%s' "$out"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-script-tests.sh`
Expected: PASS — the new assertions green **and** every pre-existing assertion still green. The pre-existing `LABELS: ai:done` and `ctx:high` cases are the guard that `labels_csv`'s rewrite did not change old behaviour.

- [ ] **Step 5: Register the label**

In `scripts/ensure-issue-labels.sh`, below the `ai:review-blocked` line (~line 85):

```bash
# Three blocked states, deliberately distinct:
#   ai:review-blocked  — the reviewer RAN and refused to promote the PR
#   ai:runner-blocked  — the reviewer NEVER STARTED; runner toolchain unmet
#   ai:checks-blocked  — the PR is fine; its required checks cannot run (#364)
create ai:checks-blocked D73A4A 'Required checks cannot run on the pipeline PR'
```

- [ ] **Step 6: Run the full Layer-1 suite**

Run: `bash tests/run-all.sh`
Expected: every runner green, including Task 1's new one. Under 5 seconds.

- [ ] **Step 7: Lint**

Run: `shellcheck -x scripts/post-run-report.sh scripts/ensure-issue-labels.sh tests/run-script-tests.sh`
Expected: no findings.

- [ ] **Step 8: Commit**

```bash
git add scripts/post-run-report.sh scripts/ensure-issue-labels.sh tests/run-script-tests.sh
git commit -m "feat(pipeline): report blocked PR checks on the issue

The run report gains a warning block and the ai:checks-blocked label when
the PR's required checks cannot run, naming which of the two reasons
applies and the remedy.

Additive only: the outcome stays ai:done, guarded by a test asserting
exactly that. A blocked run is a successful run against a misconfigured
repo.

Refs #364"
```

---

### Task 3: Expose the PR number from verify-or-recover-pr.sh

**Files:**
- Modify: `scripts/verify-or-recover-pr.sh` (header `:29`, `emit()` `:45-56`, `open_draft_pr()` `:59-74`, the found path `:86-88`)
- Modify: `tests/run-script-tests.sh` (assertions for the new output)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `verify-or-recover-pr.sh` additionally writes `pr-number=<n>` (empty when no PR) to stdout and `$GITHUB_OUTPUT`. Task 4's probe step reads it as `steps.verify_pr.outputs.pr-number`.

**Why this is its own task.** The probe from Task 1 needs a PR number, and
`verify-or-recover-pr.sh` does not currently emit one — its documented outputs
are `found`, `pr-present`, `recovered`, `salvaged`. Without this the probe step
receives an empty `PR_NUMBER`, exits 2, and — because it carries
`continue-on-error` — fails **silently**. That is precisely the class of bug
#364 is about, so it gets its own test cycle rather than being an afterthought.

`emit()` is positional with nine call sites. Adding a fifth parameter would mean
editing all nine, so this uses a global the function reads instead — a smaller,
lower-risk change.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-script-tests.sh`, in the section covering
`verify-or-recover-pr.sh` (search for `verify-or-recover` to find it; if no such
section exists, add it before the final summary block):

```bash
section "verify-or-recover-pr — pr-number output (#364)"

vor_tmp="$(mktemp -d)"
vor_script="$HERE/../scripts/verify-or-recover-pr.sh"

# An existing pipeline PR is found: its number must be reported.
printf '[{"number":123,"isDraft":true,"headRefName":"fix/1-x","author":{"login":"app/github-actions"},"headRefOid":"abc123"}]\n' \
  > "$vor_tmp/prs.json"
gh_out="$vor_tmp/out"; : > "$gh_out"
out="$(env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$vor_tmp/gh.log" \
  ISSUE_NUMBER=1 REPO=o/r SALVAGE_APPLY=0 \
  PIPELINE_PRS_JSON="$(cat "$vor_tmp/prs.json")" \
  GITHUB_OUTPUT="$gh_out" bash "$vor_script" 2>&1 || true)"
assert_contains "$out" 'pr-present=true'   "found PR → pr-present=true"
assert_contains "$out" 'pr-number=123'     "found PR → pr-number on stdout"
assert_contains "$(cat "$gh_out")" 'pr-number=123' "found PR → pr-number in GITHUB_OUTPUT"

# A genuine agent failure reports no PR, so the number must be empty, not stale.
gh_out2="$vor_tmp/out2"; : > "$gh_out2"
out="$(env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$vor_tmp/gh.log" \
  ISSUE_NUMBER=1 REPO=o/r SALVAGE_APPLY=0 IS_ERROR=true \
  GITHUB_OUTPUT="$gh_out2" bash "$vor_script" 2>&1 || true)"
assert_contains "$out" 'pr-number='        "agent failure → pr-number key still emitted"
assert_not_contains "$out" 'pr-number=123' "agent failure → no stale number"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — `pr-number` appears nowhere in the script's output.

- [ ] **Step 3: Write minimal implementation**

Three edits to `scripts/verify-or-recover-pr.sh`.

**3a.** Update the documented output line at `:29`:

```bash
# Output: found=<bool> pr-present=<bool> recovered=<bool> salvaged=<bool>
#         pr-number=<n|empty>
```

**3b.** Add the global and emit it. Replace `emit()` (`:45-56`):

```bash
# The PR number, once known. A global rather than a fifth positional parameter:
# emit() has nine call sites and widening its signature would mean editing all
# of them. Empty whenever there is no PR — never stale (#364).
PR_NUMBER_OUT=''

emit() {
  local salvaged="${4:-false}"
  printf 'found=%s pr-present=%s recovered=%s salvaged=%s pr-number=%s\n' \
    "$1" "$2" "$3" "$salvaged" "$PR_NUMBER_OUT"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'found=%s\n' "$1"
      printf 'pr-present=%s\n' "$2"
      printf 'recovered=%s\n' "$3"
      printf 'salvaged=%s\n' "$salvaged"
      printf 'pr-number=%s\n' "$PR_NUMBER_OUT"
    } >> "$GITHUB_OUTPUT"
  fi
}
```

**3c.** Set it on both paths that end with a PR.

On the found path, `find-pipeline-pr.sh` already reports `pr-number` (its header
documents it at `:32`), so parse it out of `pr_out`. Replace the found branch
(`:86-89`):

```bash
if [[ "$pr_out" == *"found=true"* ]]; then
  PR_NUMBER_OUT="$(printf '%s\n' "$pr_out" | sed -n 's/^pr-number=//p' | head -1)"
  emit true true false
  exit 0
fi
```

On the recovery paths, `gh pr create` prints the new PR's URL, which
`open_draft_pr` already captures in `out`. Set the global from it — add these
two lines inside `open_draft_pr`, in the `ec -eq 0` branch:

```bash
  if [[ "$ec" -eq 0 ]]; then
    PR_CREATE_RESULT=created
    # `gh pr create` prints the PR URL; the last path segment is the number.
    PR_NUMBER_OUT="$(printf '%s' "$out" | tr -d '[:space:]')"
    PR_NUMBER_OUT="${PR_NUMBER_OUT##*/}"
    [[ "$PR_NUMBER_OUT" =~ ^[0-9]+$ ]] || PR_NUMBER_OUT=''
  elif printf '%s' "$out" | grep -qi 'already exists'; then
```

The regex guard matters: on the `exists` and `failed` paths `out` is an error
message, not a URL, so without it the global would carry a fragment of prose
into `$GITHUB_OUTPUT`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-script-tests.sh`
Expected: PASS — the new assertions green, and every pre-existing
`verify-or-recover-pr` assertion still green (the stdout line gained a field;
any test asserting on the whole line verbatim must be updated, not the script).

- [ ] **Step 5: Lint**

Run: `shellcheck -x scripts/verify-or-recover-pr.sh tests/run-script-tests.sh`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-or-recover-pr.sh tests/run-script-tests.sh
git commit -m "feat(pipeline): report the PR number from verify-or-recover-pr

The checks probe needs a PR number and this script never emitted one.
Adds pr-number to stdout and GITHUB_OUTPUT via a global rather than a
fifth positional emit() parameter, which would have touched nine call
sites.

Refs #364"
```

---

### Task 4: Wire it up and document the operator half


**Files:**
- Modify: `.github/workflows/agent-implement.yml` — new preflight step after "Mint pipeline App token" (`:419-423`); new probe step after "Verify or recover PR" (`:919-927`); new env on "Post run report" (`:929-946`)
- Create: `docs/PIPELINE-APP-SETUP.md`
- Modify: `docs/CONSUMER-SETUP.md` (link the runbook)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:**
- Consumes: `scripts/check-pr-checks-runnable.sh` (Task 1), the `CHECKS_RUNNABLE` / `CHECKS_BLOCKED_REASON` contract (Task 2), and `steps.verify_pr.outputs.pr-number` (Task 3).
- Produces: no new interface; this is the wiring plus the operator runbook.

- [ ] **Step 1: Add the preflight warning**

In `.github/workflows/agent-implement.yml`, immediately after the
`Mint pipeline App token (optional)` step (it ends at the `private-key:` line):

```yaml
      - name: Warn when no pipeline App token is configured
        # Knowable at second zero, so say it before any agent cost is incurred:
        # without an App token the PR is authored by github-actions and its
        # pull_request runs stall at action_required (#364). Warning only —
        # the run proceeds and the PR is still opened and reviewable.
        if: ${{ env.PIPELINE_APP_ID == '' }}
        run: |
          printf '::warning title=No pipeline App token::PR will be authored by github-actions; its required checks will need manual approval. See docs/PIPELINE-APP-SETUP.md\n'
          printf '> [!WARNING]\n> No `PIPELINE_APP_ID` configured — this run'"'"'s PR will need its checks approved by hand. See `docs/PIPELINE-APP-SETUP.md`.\n' >> "$GITHUB_STEP_SUMMARY"
```

Two lines of bash — within the five-line ceiling.

- [ ] **Step 2: Add the probe step**

Immediately after the `Verify or recover PR` step:

```yaml
      - name: Check the PR's required checks can run
        id: pr_checks
        # Diagnostic only (#364). continue-on-error is what guarantees this can
        # never fail the implement job — the script's own exit 2 on missing env
        # would otherwise do exactly that.
        continue-on-error: true
        if: always() && !inputs.dry-run && steps.verify_pr.outputs.pr-present == 'true'
        env:
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.verify_pr.outputs.pr-number }}
          APP_TOKEN_CONFIGURED: ${{ env.PIPELINE_APP_ID != '' }}
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
        run: bash .claude-pipeline/scripts/check-pr-checks-runnable.sh
```

- [ ] **Step 3: Pass the results to the run report**

In the `Post run report` step's `env:` block, after the `SALVAGED:` line:

```yaml
          CHECKS_RUNNABLE: ${{ steps.pr_checks.outputs.checks-runnable }}
          CHECKS_BLOCKED_REASON: ${{ steps.pr_checks.outputs.checks-blocked-reason }}
```

- [ ] **Step 4: Lint the workflow**

Run: `actionlint .github/workflows/agent-implement.yml`
Expected: no findings.

- [ ] **Step 5: Write the operator runbook**

Create `docs/PIPELINE-APP-SETUP.md`:

```markdown
# Pipeline GitHub App setup

Without this, the pipeline still works — it implements issues and opens draft
PRs. What it cannot do is get those PRs' **required status checks to run**.

## Why it is needed

A PR opened with the ambient `GITHUB_TOKEN` is authored by `github-actions`.
Its `pull_request` workflow runs are created but stall at `action_required`,
awaiting manual approval. In a repo with required status checks the PR then
reports an empty `statusCheckRollup`, satisfies nothing, and sits `BLOCKED`
until a human approves the runs or pushes to the branch.

Observed on #363: three runs created at `07:27:15` stalled and resolved to
`failure`; a human push at `07:42` ran all of them green with no approval.

An App-authored PR does not have this problem. `agent-implement.yml` already
mints and uses an App token when one is configured (`:418-422`); the code path
is inert only because the secrets are unset.

## Setup

1. **Create the App.** GitHub → Settings → Developer settings → GitHub Apps →
   New GitHub App. Name it something like `<org>-pipeline`. Homepage URL can be
   the repo. Uncheck **Webhook → Active**.

2. **Repository permissions** — the minimum the pipeline uses:

   | Permission | Level | Used for |
   |---|---|---|
   | Contents | Read and write | Push the agent's branch |
   | Pull requests | Read and write | `gh pr create`, promote from draft |
   | Issues | Read and write | Run report comments, labels |

3. **Install it** on the repo (or the org, scoped to selected repositories).

4. **Generate a private key** — on the App's page, Generate a private key. A
   `.pem` downloads. Treat it as a credential: it is not recoverable, and
   anyone holding it can act as the App.

5. **Add two repository secrets:**

   ```bash
   gh secret set PIPELINE_APP_ID --body '<the numeric App ID>'
   gh secret set PIPELINE_APP_PRIVATE_KEY < path/to/private-key.pem
   ```

   `PIPELINE_APP_ID` is the numeric ID on the App's settings page, not its name.

6. **Delete the local `.pem`** once the secret is set.

## Verify it worked

Dispatch any issue, then on the PR the pipeline opens:

```bash
gh pr view <n> --json author,statusCheckRollup \
  --jq '{author: .author.login, checks: (.statusCheckRollup | length)}'
```

- `author` should be `app/<your-app-name>`, not `github-actions`.
- `checks` should be non-zero within a couple of minutes.

If it is still `github-actions`, the secret is not visible to the run — check
it is a **repository** secret on the repo the workflow runs in, and that the
App is installed on that repo.

## If you skip this

The pipeline stays usable: PRs are opened as drafts and are perfectly
reviewable. Each run whose checks cannot start says so — the issue gets an
`ai:checks-blocked` label and the run report carries a warning block naming
this document. Approve the runs by hand from the PR's Checks tab, or push any
commit to the branch, and they run normally.
```

- [ ] **Step 6: Link it from consumer setup**

In `docs/CONSUMER-SETUP.md`, add to the section covering secrets (search for
`CLAUDE_CODE_OAUTH_TOKEN` to find it):

```markdown
**Optional but recommended:** `PIPELINE_APP_ID` + `PIPELINE_APP_PRIVATE_KEY`.
Without them the pipeline's PRs are authored by `github-actions` and their
required checks stall awaiting manual approval — see
[`PIPELINE-APP-SETUP.md`](PIPELINE-APP-SETUP.md).
```

- [ ] **Step 7: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
### Added

- **pipeline:** a run whose PR cannot get its required checks to run now says
  so — a warning at job start when `PIPELINE_APP_ID` is unset, a bounded probe
  of the PR's `statusCheckRollup` after it opens, an `ai:checks-blocked` label,
  and a warning block in the run report naming the remedy. Previously a stalled
  PR was indistinguishable from a finished one (#364).
- **docs:** `docs/PIPELINE-APP-SETUP.md` — operator runbook for configuring the
  pipeline GitHub App, which is what actually lets those checks run.
```

- [ ] **Step 8: Run the full quality gate**

```bash
just lint
just test
```

Expected: `actionlint` and `shellcheck` clean; every Layer-1 runner green.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/agent-implement.yml docs/PIPELINE-APP-SETUP.md \
        docs/CONSUMER-SETUP.md CHANGELOG.md scripts/verify-or-recover-pr.sh
git commit -m "feat(pipeline): surface PRs whose required checks cannot run

Wires the preflight warning and the checks probe into agent-implement.yml
and passes the result to the run report. Adds the operator runbook for
configuring the pipeline App, which is the part no agent can do.

A stalled PR previously looked identical to a finished one.

Closes #364"
```

---

## Verification

Confirm each acceptance criterion with a command, not an impression:

```bash
# Preflight fires only when the secret is absent
grep -n 'Warn when no pipeline App token' -A 6 .github/workflows/agent-implement.yml

# The probe can never fail the job
grep -n "id: pr_checks" -A 4 .github/workflows/agent-implement.yml | grep continue-on-error

# The probe actually receives a PR number (empty, never stale, when absent)
bash tests/run-script-tests.sh 2>&1 | grep -E 'pr-number (on stdout|in GITHUB_OUTPUT)'
bash tests/run-script-tests.sh 2>&1 | grep 'no stale number'

# A blocked run is still ai:done — the regression that matters
bash tests/run-script-tests.sh 2>&1 | grep 'outcome STILL ai:done'

# All three blocked labels exist and are distinct
grep -n 'ai:review-blocked\|ai:runner-blocked\|ai:checks-blocked' scripts/ensure-issue-labels.sh

# The runbook exists and is linked
test -f docs/PIPELINE-APP-SETUP.md && grep -rn 'PIPELINE-APP-SETUP.md' docs/ scripts/ | grep -v '^docs/PIPELINE-APP-SETUP.md'

# Quality gate
just lint
just test
```
