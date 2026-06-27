# PR-aware run status with recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the implement job from stamping `ai:done` when a successful-looking run opened no PR — verify a PR exists, recover by opening it from the workflow when the work is on a pushed branch, and mark `ai:failed` only when recovery is impossible.

**Architecture:** A new `scripts/verify-or-recover-pr.sh` runs after the agent step and before `post-run-report.sh`. It reuses `find-pipeline-pr.sh` to detect an existing PR; if none, it discovers the agent's branch from the job's live checkout and opens the draft PR via a retry/backoff helper (`scripts/lib/gh-retry.sh`). Its `pr-present` output feeds a new optional `PR_PRESENT` input on `post-run-report.sh`, which flips status to `ai:failed` when a non-error run produced no PR.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `gh` CLI, `jq`, GitHub Actions YAML. Layer-1 fixture tests in `tests/run-script-tests.sh` with the `gh` mock at `tests/mocks/gh`.

## Global Constraints

- Every script starts with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`.
- Quote every expansion; `[[ ]]` over `[ ]`; `$(...)` over backticks; no `eval`.
- Exit codes: `0` success, `2` usage/required-env missing.
- Env-driven (not flag-driven) for CI scripts; test seams via env vars (mirror `find-pipeline-pr.sh`'s `PIPELINE_PRS_JSON`).
- `set +x` around any token-bearing command; `printf` (not `echo`) for formatted output.
- Layer-1 tests: no network, no real `gh`, no real git remote; whole suite < 5s.
- Every new code branch covered by at least one fixture/case (repo convention).
- Lint clean: `just lint` (pre-commit → actionlint + shellcheck `-x`).
- Reuse the existing `ai:failed` label — no new label.
- Dual output pattern: print `key=value` to stdout AND append to `$GITHUB_OUTPUT` when set.

**Test command:** `bash tests/run-script-tests.sh` (or `just test`).
**Lint command:** `just lint`.

---

### Task 1: `scripts/lib/gh-retry.sh` — backoff helper

**Files:**
- Create: `scripts/lib/gh-retry.sh`
- Test: `tests/run-script-tests.sh` (new `gh-retry` section)

**Interfaces:**
- Produces: `with_backoff "$@"` — runs the command; returns `0` on success. On failure, retries only when the command's stderr matches a retryable signature, up to `GH_RETRY_MAX` attempts (default `3`); returns the command's last non-zero exit code otherwise. Honors seams: `GH_RETRY_MAX`, `GH_RETRY_BASE_SLEEP` (default `2`), `GH_RETRY_SLEEP_CMD` (default `sleep`), `GH_RETRY_NO_JITTER` (default unset → jitter on).
- Produces: `gh_retryable "<text>"` — exit `0` if the text matches a transient/secondary-rate-limit signature and does NOT match a non-retryable signature; else exit `1`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-script-tests.sh` (before the final summary block):

```bash
section "gh-retry — backoff classifies and retries transient failures"

GH_RETRY="$ROOT/scripts/lib/gh-retry.sh"

# Fake command: fails the first N invocations (tracked in a counter file),
# emitting a chosen stderr, then succeeds. Used to drive with_backoff.
make_flaky() {
  local script="$1" fail_times="$2" stderr_msg="$3"
  cat > "$script" <<EOF
#!/usr/bin/env bash
ctr="\${FLAKY_CTR:?}"
n=\$(cat "\$ctr" 2>/dev/null || printf 0)
n=\$((n + 1)); printf '%s' "\$n" > "\$ctr"
if (( n <= $fail_times )); then printf '%s\n' "$stderr_msg" >&2; exit 1; fi
printf 'ok\n'; exit 0
EOF
  chmod +x "$script"
}

# Retryable: secondary rate limit, succeeds on the 2nd attempt.
flaky="$(mktemp)"; ctr="$(mktemp)"; : > "$ctr"
make_flaky "$flaky" 1 "You have exceeded a secondary rate limit"
ec=0
( source "$GH_RETRY"
  FLAKY_CTR="$ctr" GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "0" "with_backoff retries secondary-rate-limit then succeeds"
assert_equals "$(cat "$ctr")" "2" "  → exactly 2 attempts (1 fail + 1 success)"

# Non-retryable: permission error fails fast on the first attempt.
flaky2="$(mktemp)"; ctr2="$(mktemp)"; : > "$ctr2"
make_flaky "$flaky2" 5 "GitHub Actions is not permitted to create or approve pull requests"
ec=0
( source "$GH_RETRY"
  FLAKY_CTR="$ctr2" GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky2" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "1" "with_backoff fails fast on non-retryable permission error"
assert_equals "$(cat "$ctr2")" "1" "  → exactly 1 attempt (no retry)"

# Exhausts retries on a persistently retryable failure.
flaky3="$(mktemp)"; ctr3="$(mktemp)"; : > "$ctr3"
make_flaky "$flaky3" 9 "503 Server Error"
ec=0
( source "$GH_RETRY"
  FLAKY_CTR="$ctr3" GH_RETRY_MAX=3 GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 with_backoff "$flaky3" ) >/dev/null 2>&1 || ec=$?
assert_equals "$ec" "1" "with_backoff gives up after GH_RETRY_MAX attempts"
assert_equals "$(cat "$ctr3")" "3" "  → exactly GH_RETRY_MAX (3) attempts"

# gh_retryable classification.
( source "$GH_RETRY"; gh_retryable "secondary rate limit" ) \
  && pass "gh_retryable: secondary rate limit → retryable" \
  || fail "gh_retryable: secondary rate limit → retryable"
( source "$GH_RETRY"; gh_retryable "not permitted to create or approve pull requests" ) \
  && fail "gh_retryable: permission error → must NOT be retryable" \
  || pass "gh_retryable: permission error → not retryable"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep gh-retry -A12`
Expected: FAIL — `scripts/lib/gh-retry.sh` does not exist (source errors / assertions fail).

- [ ] **Step 3: Implement `scripts/lib/gh-retry.sh`**

```bash
#!/usr/bin/env bash
#
# gh-retry.sh — backoff helper for flaky `gh` calls (e.g. `gh pr create`
# under secondary rate limits). Source it; do not execute.
#
#   with_backoff <cmd> [args...]   run cmd, retrying transient failures
#   gh_retryable "<stderr text>"   exit 0 if text is a transient signature
#
# Seams (env): GH_RETRY_MAX (3), GH_RETRY_BASE_SLEEP (2),
#              GH_RETRY_SLEEP_CMD (sleep), GH_RETRY_NO_JITTER (unset).
set -euo pipefail
IFS=$'\n\t'

# Transient signatures worth retrying.
_GH_RETRY_TRANSIENT='secondary rate limit|rate limit|was submitted too quickly|abuse detection|\b5[0-9][0-9]\b|server error|timed out|timeout|connection reset'
# Hard failures we must NOT retry (surface immediately).
_GH_RETRY_FATAL='not permitted to create or approve pull requests|must be a collaborator|authentication|bad credentials'

gh_retryable() {
  local text="$1"
  shopt -s nocasematch
  if [[ "$text" =~ $_GH_RETRY_FATAL ]]; then shopt -u nocasematch; return 1; fi
  if [[ "$text" =~ $_GH_RETRY_TRANSIENT ]]; then shopt -u nocasematch; return 0; fi
  shopt -u nocasematch
  return 1
}

with_backoff() {
  local max="${GH_RETRY_MAX:-3}"
  local base="${GH_RETRY_BASE_SLEEP:-2}"
  local sleep_cmd="${GH_RETRY_SLEEP_CMD:-sleep}"
  local attempt=1 ec errfile jitter
  errfile="$(mktemp)"
  # shellcheck disable=SC2064  # expand errfile now, on function return
  trap "rm -f '$errfile'" RETURN

  while :; do
    ec=0
    "$@" 2>"$errfile" || ec=$?
    cat "$errfile" >&2
    [[ "$ec" -eq 0 ]] && return 0
    if ! gh_retryable "$(cat "$errfile")"; then return "$ec"; fi
    if (( attempt >= max )); then return "$ec"; fi
    jitter=0
    [[ -z "${GH_RETRY_NO_JITTER:-}" ]] && jitter=$(( RANDOM % 2 ))
    "$sleep_cmd" "$(( base * attempt + jitter ))"
    attempt=$(( attempt + 1 ))
  done
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep gh-retry -A12`
Expected: PASS — all `gh-retry` assertions green.

- [ ] **Step 5: Lint**

Run: `just lint`
Expected: shellcheck + actionlint clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/gh-retry.sh tests/run-script-tests.sh
git commit -m "feat(gh-retry): backoff helper retrying transient gh failures (#100)"
```

---

### Task 2: `scripts/verify-or-recover-pr.sh` — verify a PR exists, recover if not

**Files:**
- Create: `scripts/verify-or-recover-pr.sh`
- Modify: `tests/mocks/gh` (teach it to simulate `gh pr create` failures)
- Test: `tests/run-script-tests.sh` (new `verify-or-recover-pr` section)

**Interfaces:**
- Consumes: `scripts/find-pipeline-pr.sh` (existing) via `PIPELINE_PRS_JSON`; `scripts/lib/gh-retry.sh` `with_backoff` (Task 1).
- Produces: stdout + `$GITHUB_OUTPUT` lines `found=<bool> pr-present=<bool> recovered=<bool>`.
- Inputs (env): `ISSUE_NUMBER` (required), `REPO` (default `$GITHUB_REPOSITORY`), `DEFAULT_BRANCH`, `IS_ERROR` (default `false`), `GH_TOKEN`/ambient. Seams: `PIPELINE_PRS_JSON` (existence check), `BRANCH` / `BRANCH_REMOTE_EXISTS` / `BRANCH_AHEAD` (override the git probes used for recovery eligibility).

- [ ] **Step 1: Teach the gh mock to simulate `gh pr create` failures**

The current `tests/mocks/gh` always exits 0. Recovery tests need it to fail a configurable number of `pr create` calls. Replace the mock body so it stays a pure logger by default but honors two new seams:

```bash
#!/usr/bin/env bash
#
# gh — minimal stand-in for the GitHub CLI used by Layer-1 fixture tests.
#
# Appends each invocation's argv as a single space-joined line to $GH_MOCK_LOG.
# Exits 0 by default. Optional seams let a test simulate a flaky `gh pr create`:
#   GH_MOCK_PR_CREATE_FAIL_TIMES  fail the first N `pr create` calls (exit 1)
#   GH_MOCK_PR_CREATE_STDERR      stderr emitted on those failures
#   GH_MOCK_PR_CREATE_CTR         counter file path (required if FAIL_TIMES set)
set -euo pipefail
IFS=$'\n\t'
: "${GH_MOCK_LOG:?GH_MOCK_LOG must be set when using the gh mock}"
( IFS=' '; printf '%s\n' "$*" >> "$GH_MOCK_LOG" )

if [[ "${1:-}" == "pr" && "${2:-}" == "create" && -n "${GH_MOCK_PR_CREATE_FAIL_TIMES:-}" ]]; then
  ctr="${GH_MOCK_PR_CREATE_CTR:?GH_MOCK_PR_CREATE_CTR must be set with FAIL_TIMES}"
  n=$(cat "$ctr" 2>/dev/null || printf 0); n=$((n + 1)); printf '%s' "$n" > "$ctr"
  if (( n <= GH_MOCK_PR_CREATE_FAIL_TIMES )); then
    printf '%s\n' "${GH_MOCK_PR_CREATE_STDERR:-secondary rate limit}" >&2
    exit 1
  fi
fi
exit 0
```

- [ ] **Step 2: Write the failing tests**

Append a new section to `tests/run-script-tests.sh`:

```bash
section "verify-or-recover-pr — make run status PR-aware"

VERIFY="$ROOT/scripts/verify-or-recover-pr.sh"

verify_run() {
  local go log; go="$(mktemp)"; log="$(mktemp)"
  GITHUB_OUTPUT="$go" GH_MOCK_LOG="$log" PATH="$MOCKS:$PATH" "$@" bash "$VERIFY" >/dev/null 2>&1 || true
  printf 'LOG<<%s>>\n' "$(tr '\n' ';' < "$log")"
  cat "$go"; rm -f "$go" "$log"
}

# Genuine agent error → no-op, pr-present=false, no gh pr create.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=true)"
assert_contains "$out" 'pr-present=false'  "IS_ERROR=true → pr-present=false"
assert_contains "$out" 'recovered=false'   "IS_ERROR=true → recovered=false"
assert_not_contains "$out" 'pr create'     "IS_ERROR=true → never calls gh pr create"

# PR already exists → pr-present=true, no recovery.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false \
        PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"x","author":{"login":"github-actions[bot]"}}]')"
assert_contains "$out" 'pr-present=true'    "existing PR → pr-present=true"
assert_contains "$out" 'recovered=false'    "existing PR → no recovery"
assert_not_contains "$out" 'pr create'      "existing PR → never calls gh pr create"

# No PR + recoverable branch → recovery opens the PR.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true)"
assert_contains "$out" 'recovered=true'     "no PR + branch → recovery runs"
assert_contains "$out" 'pr-present=true'    "no PR + branch → pr-present after recovery"
assert_contains "$out" 'pr create'          "recovery calls gh pr create"
assert_contains "$out" 'Closes #42'         "recovery PR body closes the issue"

# No PR + no usable branch → pr-present=false, no recovery attempt.
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=main BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true)"
assert_contains "$out" 'pr-present=false'   "branch == default → not recoverable"
assert_not_contains "$out" 'pr create'      "default branch → never calls gh pr create"

out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=false BRANCH_AHEAD=true)"
assert_contains "$out" 'pr-present=false'   "branch not pushed → pr-present=false"

# No PR + branch, but gh pr create fails transiently then succeeds → recovered.
ctr="$(mktemp)"; : > "$ctr"
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true \
        GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 \
        GH_MOCK_PR_CREATE_FAIL_TIMES=1 GH_MOCK_PR_CREATE_CTR="$ctr" \
        GH_MOCK_PR_CREATE_STDERR='secondary rate limit')"
assert_contains "$out" 'recovered=true'     "transient pr-create failure → retried → recovered"

# No PR + branch, but gh pr create fails permanently (permission) → not recovered.
ctr2="$(mktemp)"; : > "$ctr2"
out="$(verify_run env ISSUE_NUMBER=42 REPO=o/r IS_ERROR=false DEFAULT_BRANCH=main \
        PIPELINE_PRS_JSON='[]' BRANCH=ai/issue-42 BRANCH_REMOTE_EXISTS=true BRANCH_AHEAD=true \
        GH_RETRY_SLEEP_CMD=: GH_RETRY_NO_JITTER=1 \
        GH_MOCK_PR_CREATE_FAIL_TIMES=9 GH_MOCK_PR_CREATE_CTR="$ctr2" \
        GH_MOCK_PR_CREATE_STDERR='not permitted to create or approve pull requests')"
assert_contains "$out" 'pr-present=false'   "permanent pr-create failure → pr-present=false"
assert_contains "$out" 'recovered=false'    "permanent pr-create failure → recovered=false"

# Missing required env → exit 2.
ec="$(run_capture_ec env REPO=o/r IS_ERROR=false bash "$VERIFY")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep verify-or-recover -A30`
Expected: FAIL — `scripts/verify-or-recover-pr.sh` does not exist.

- [ ] **Step 4: Implement `scripts/verify-or-recover-pr.sh`**

```bash
#!/usr/bin/env bash
#
# verify-or-recover-pr.sh — after an implement run, ensure a draft PR exists
# for the issue. If the run looked successful but no PR was opened (e.g. a
# `gh pr create` secondary-rate-limit race, issue #100), recover by opening
# the PR for the agent's pushed branch. Reports whether a PR is now present
# so post-run-report.sh can pick ai:done vs ai:failed accurately.
#
# Required env: ISSUE_NUMBER. Optional: REPO (default $GITHUB_REPOSITORY),
# DEFAULT_BRANCH, IS_ERROR (default false), GH_TOKEN/ambient.
# Seams (tests): PIPELINE_PRS_JSON, BRANCH, BRANCH_REMOTE_EXISTS, BRANCH_AHEAD.
#
# Output: found=<bool> pr-present=<bool> recovered=<bool>
# Exit: 0 success; 2 required env missing.
set -euo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/gh-retry.sh
source "$HERE/lib/gh-retry.sh"

if [[ -z "${ISSUE_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER must be set\n' >&2
  exit 2
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
IS_ERROR="${IS_ERROR:-false}"

emit() {
  printf 'found=%s pr-present=%s recovered=%s\n' "$1" "$2" "$3"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'found=%s\n' "$1"
      printf 'pr-present=%s\n' "$2"
      printf 'recovered=%s\n' "$3"
    } >> "$GITHUB_OUTPUT"
  fi
}

# 1. Genuine agent failure — existing handling owns it.
if [[ "$IS_ERROR" == "true" ]]; then
  emit false false false
  exit 0
fi

# 2. Does a pipeline PR already exist?
pr_out="$(ISSUE_NUMBER="$ISSUE_NUMBER" REPO="$REPO" \
  PIPELINE_PRS_JSON="${PIPELINE_PRS_JSON:-}" bash "$HERE/find-pipeline-pr.sh" 2>/dev/null || printf 'found=false')"
if [[ "$pr_out" == *"found=true"* ]]; then
  emit true true false
  exit 0
fi

# 3. Recovery eligibility — discover the agent's branch from the live checkout
#    (the workflow leaves HEAD on the branch the agent created and pushed).
branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')}"
default_branch="${DEFAULT_BRANCH:-}"

remote_exists() {
  [[ -n "${BRANCH_REMOTE_EXISTS:-}" ]] && { [[ "$BRANCH_REMOTE_EXISTS" == "true" ]]; return; }
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}
branch_ahead() {
  [[ -n "${BRANCH_AHEAD:-}" ]] && { [[ "$BRANCH_AHEAD" == "true" ]]; return; }
  [[ -n "$default_branch" ]] || return 1
  local n; n="$(git rev-list --count "origin/${default_branch}..${branch}" 2>/dev/null || printf 0)"
  (( n > 0 ))
}

if [[ -z "$branch" || "$branch" == "HEAD" || "$branch" == "$default_branch" ]] \
   || ! remote_exists || ! branch_ahead; then
  emit false false false
  exit 0
fi

# 4. Recover — open the draft PR with retry/backoff.
set +x
recover_ec=0
GH_TOKEN="${GH_TOKEN:-}" with_backoff \
  gh pr create --repo "$REPO" --draft \
    --base "$default_branch" --head "$branch" \
    --title "Implement #${ISSUE_NUMBER}" \
    --body "Recovered by pipeline. Closes #${ISSUE_NUMBER}." \
  || recover_ec=$?

if [[ "$recover_ec" -eq 0 ]]; then
  emit false true true
else
  emit false false false
fi
exit 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep verify-or-recover -A30`
Expected: PASS — all `verify-or-recover-pr` assertions green.

- [ ] **Step 6: Run the FULL suite (regression guard)**

Run: `bash tests/run-script-tests.sh`
Expected: all sections pass, including the existing `find-pipeline-pr` and `post-run-report` sections (gh-mock change must not break them).

- [ ] **Step 7: Lint**

Run: `just lint`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add scripts/verify-or-recover-pr.sh tests/mocks/gh tests/run-script-tests.sh
git commit -m "feat(verify-or-recover-pr): verify a PR exists, recover orphan branch (#100)"
```

---

### Task 3: `post-run-report.sh` — PR-aware status

**Files:**
- Modify: `scripts/post-run-report.sh` (the `IS_ERROR` status block, ~L203-217)
- Test: `tests/run-script-tests.sh` (extend the `render_only` section)

**Interfaces:**
- Consumes: new optional env `PR_PRESENT` (`true|false`; unset = legacy behaviour).
- Produces: when `IS_ERROR=false` AND `PR_PRESENT=false` → `STATUS_LABEL='ai:failed'`, `STATUS_TEXT='run completed but no PR was opened'`.

- [ ] **Step 1: Write the failing tests**

Add to the `render_only` section of `tests/run-script-tests.sh` (near the other `LABELS:` assertions):

```bash
# #100: a successful run that opened no PR must NOT be ai:done.
out="$(PR_PRESENT=false render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:failed'   "success but PR_PRESENT=false → ai:failed"
assert_contains "$out" 'no PR was opened'     "  → status text names the missing-PR cause"

# Regression: PR_PRESENT=true (or unset) preserves ai:done.
out="$(PR_PRESENT=true render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:done'      "success + PR_PRESENT=true → ai:done"
out="$(render_only result-success-cheap.json)"
assert_contains "$out" 'LABELS: ai:done'      "success + PR_PRESENT unset → ai:done (legacy)"

# A genuine agent error stays ai:failed regardless of PR_PRESENT.
out="$(PR_PRESENT=true render_only result-rate-limit.json)"
assert_contains "$out" 'LABELS: ai:failed'    "agent error + PR_PRESENT=true → still ai:failed"
```

> Note: if `render_only` does not already forward arbitrary env, no change is needed — the `PR_PRESENT=... render_only ...` prefix exports it into the `bash "$SCRIPT"` child. Confirm by running the tests.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep 'no PR was opened\|PR_PRESENT' -A1`
Expected: FAIL — `PR_PRESENT=false` still renders `ai:done`.

- [ ] **Step 3: Implement the status change**

In `scripts/post-run-report.sh`, replace the success branch of the status block:

```bash
if [[ "$IS_ERROR" == "true" ]]; then
  STATUS_EMOJI=':x:'
  STATUS_TEXT="failed: ${SUBTYPE}"
  STATUS_LABEL='ai:failed'
  STATUS_LABEL_OPPOSITE='ai:done'
elif [[ "${PR_PRESENT:-}" == "false" ]]; then
  # #100: run finished without error but no PR exists (and recovery, if any,
  # failed). Do not report success — the work is not reviewable.
  STATUS_EMOJI=':x:'
  STATUS_TEXT='failed: run completed but no PR was opened'
  STATUS_LABEL='ai:failed'
  STATUS_LABEL_OPPOSITE='ai:done'
else
  STATUS_EMOJI=':white_check_mark:'
  STATUS_TEXT='success'
  STATUS_LABEL='ai:done'
  STATUS_LABEL_OPPOSITE='ai:failed'
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | grep 'no PR was opened\|PR_PRESENT\|ai:done\|ai:failed' -A0`
Expected: PASS — new `#100` assertions green, all existing `ai:done`/`ai:failed` assertions still green.

- [ ] **Step 5: Lint**

Run: `just lint`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/post-run-report.sh tests/run-script-tests.sh
git commit -m "feat(post-run-report): mark ai:failed when a run opens no PR (#100)"
```

---

### Task 4: Wire the step into `claude-implement.yml`

**Files:**
- Modify: `.github/workflows/claude-implement.yml` (add a step after `Extract job outputs from result.json` / id `outputs` ~L610-620, before `Post run report` ~L640; add `PR_PRESENT` to the report step's env)

**Interfaces:**
- Consumes: `steps.outputs.outputs.outcome` (`success|failed`), `scripts/verify-or-recover-pr.sh` outputs.
- Produces: `steps.verify_pr.outputs.pr-present` consumed by the report step.

- [ ] **Step 1: Add the verify-or-recover step**

Insert immediately before the `- name: Post run report` step:

```yaml
      - name: Verify or recover PR
        id: verify_pr
        if: always() && !inputs.dry-run && (steps.claude.outputs.result-file != '' || steps.opencode_adapt.outputs.result-file != '' || steps.stub_run.outputs.result-file != '')
        env:
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          REPO: ${{ github.repository }}
          DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
          IS_ERROR: ${{ steps.outputs.outputs.outcome == 'failed' }}
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
        run: bash .claude-pipeline/scripts/verify-or-recover-pr.sh
```

- [ ] **Step 2: Pass `PR_PRESENT` into the report step**

Add to the `env:` of the `- name: Post run report` step:

```yaml
          PR_PRESENT: ${{ steps.verify_pr.outputs.pr-present }}
```

- [ ] **Step 3: Lint the workflow**

Run: `just lint`
Expected: actionlint clean (valid `if:`, env, step references).

- [ ] **Step 4: (Optional, recommended) Layer-2 act smoke**

Run: `just test-act`
Expected: the `claude-implement.test.yml` run still completes; the new step is a no-op on the stub path (`stub_run` + `dry-run` excluded by the `if:`). If `act` is unavailable locally, note it and rely on CI's act-run job. Document any blocker here.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/claude-implement.yml
git commit -m "ci(implement): verify/recover PR before stamping run status (#100)"
```

---

### Task 5: Documentation — gotcha #6 + CHANGELOG

**Files:**
- Modify: `docs/CONSUMER-SETUP.md` (gotcha #6 row, ~L154)
- Modify: `CHANGELOG.md` (`[Unreleased]` → Fixed)

- [ ] **Step 1: Update gotcha #6**

Append to the gotcha #6 cell a sentence noting the pipeline now self-heals:

```markdown
As of #100 the implement job verifies a PR exists after the run and, when the work is on a pushed branch, recovers by opening the PR itself (with retry/backoff); if no PR can be opened the run is marked **`ai:failed`** instead of silently reporting success.
```

- [ ] **Step 2: Add CHANGELOG entry**

Under `## [Unreleased]` add a `### Fixed` entry (create the section if absent):

```markdown
### Fixed

- **pipeline:** Runs that complete without opening a PR are no longer reported as `ai:done` — the implement job verifies the PR exists, recovers the orphan branch when possible, and marks `ai:failed` otherwise (#100)
```

- [ ] **Step 3: Lint**

Run: `just lint`
Expected: clean (markdown/yaml hooks pass).

- [ ] **Step 4: Commit**

```bash
git add docs/CONSUMER-SETUP.md CHANGELOG.md
git commit -m "docs: note PR verify/recover self-heal in gotcha #6 + CHANGELOG (#100)"
```

---

## Self-Review

**Spec coverage:**
- Verify PR exists before `ai:done` → Tasks 2 + 3. ✓
- Recover via `gh pr create` + retry/backoff → Tasks 1 + 2. ✓
- Branch discovered from post-agent local git state → Task 2 Step 4 (`git rev-parse --abbrev-ref HEAD`, seamed). ✓
- `ai:failed` when recovery impossible → Task 3. ✓
- `PR_PRESENT` single integration point → Tasks 3 + 4. ✓
- No batch jitter (non-goal) → not present. ✓
- Fail-fast on permission error (gotcha #6) → Task 1 `_GH_RETRY_FATAL` + tests. ✓
- Tests for every branch, Layer-1, < 5s → Tasks 1–3. ✓
- Docs (gotcha #6 + CHANGELOG) → Task 5. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type/name consistency:** `with_backoff` / `gh_retryable` used identically in Tasks 1–2. `PR_PRESENT`, `pr-present`, `recovered`, `found` consistent across Tasks 2–4. `verify_pr` step id referenced by the report step. ✓

**Refinement vs spec:** The spec said "re-run find-pipeline-pr.sh to confirm" after recovery; the plan instead trusts the `gh pr create` exit status (via `with_backoff`) as the recovered signal — simpler, fully testable, equally correct (a zero exit means the PR was created). Noted here intentionally.
