# Pre-Agent Failures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retry transient apt failures in `ensure-toolchain.sh`, and post one run report (with `ai-run` marker, `ai:failed`, no attempt consumed) on the issue whenever the `implement` job fails before the agent starts.

**Architecture:** `ensure-toolchain.sh` gets a bounded retry loop around apt. `post-run-report.sh` learns an optional `PRE_AGENT_STEP`. A new job `implement_prefail` in `agent-implement.yml`, whose `if:` is the complement of `implement_gate`'s, finds the failed step through the Actions API and calls `post-run-report.sh` with a synthetic zero-turn result.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, `gh`, GitHub Actions YAML, Layer-1 tests in `tests/run-script-tests.sh` and `tests/run-run-report-golden-tests.sh`, `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-11-12-pre-agent-failures-design.md`

## Global Constraints

- Existing tests pass **unmodified**, in particular `tests/run-run-report-golden-tests.sh` (visible report byte-identical when `PRE_AGENT_STEP` is unset) and the #594 apt-fallback tests in `tests/run-script-tests.sh`.
- Order in `ensure-toolchain.sh`: skip when present, then apt with retry, then the release-binary fallback, then exit 1. The "present" skip and fallback are not changed.
- `implement_gate` and its `if:` are **not** changed. `implement_prefail.if` is its complement, and fires only when `needs.implement.result == 'failure'`.
- The step name appears only in the visible comment, sanitized; never in the marker (ADR-021 item 4).
- No new label, no new consumer permission (`actions: read` is covered by the caller's `actions: write`).
- Tests use fakes and `APT_RETRY_DELAY=0`; no real apt, no network, no `act` runs.
- Conventional Commits, scope `pipeline`; reference `#597`.

## Review Focus

1. Exactly one report per failure: pre-agent via `implement_prefail`, agent-phase via the gate. Task 3.
2. Parked or paused runs post nothing. Task 3.
3. The report is a non-start (`counts:false`, no `attempt`). Task 2.
4. Hostile step names cannot reach the marker. Task 2.
5. apt: two failures then success exits 0; three failures still reach the fallback. Task 1.

---

### Task 1: Bounded apt retry in `ensure-toolchain.sh` (TDD)

**Files:**
- Modify: `scripts/ensure-toolchain.sh` (new `apt_install_with_retry` above `MISSING=()`, call at `:96`, header docs for `APT_ATTEMPTS` / `APT_RETRY_DELAY`)
- Modify: `tests/run-script-tests.sh` (new block directly after the #594 block, before `# AGENT unset → OpenCode install NEVER attempted`)

**Interfaces:**
- Consumes: env `APT_ATTEMPTS` (default 3), `APT_RETRY_DELAY` (seconds, default 5).
- Produces: `apt_install_with_retry <pkg>...` returning 0 on the first successful attempt, 1 when all attempts fail.

- [ ] **Step 1: Write the failing tests**

Reuse the fake-`sudo` pattern of the #594 block. The fake counts `apt-get update` calls in a file and fails the first N of them:

```bash
# #597: transient apt failures are retried before the fallback runs.
FAKE597="$(mktemp -d)"
cat > "$FAKE597/sudo" <<'SUDO'
#!/bin/bash
[[ "$1" == apt-get ]] || exit 0
if [[ "$2" == -o || "$2" == update || "$3" == update || "$4" == update ]]; then
  n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_COUNT"
  (( n <= FAKE_FAIL )) && { echo "E: Temporary failure resolving" >&2; exit 100; }
fi
exit 0
SUDO
chmod +x "$FAKE597/sudo"
# A tool that "appears" once apt succeeds: stub `command -v` target is created by the fake install.
```

Cases (adapt the "tool appears" mechanism to the harness: simplest is a `TOOLS` name for which the fake `sudo apt-get install` touches an executable of that name in `$FAKE597/bin` on `PATH`):

```bash
count="$FAKE597/count"
for fail in 0 1 2; do
  rm -f "$count"; rm -f "$FAKE597/bin/tool597"
  out="$(PATH="$FAKE597:$FAKE597/bin:$PATH" FAKE_COUNT="$count" FAKE_FAIL=$fail APT_RETRY_DELAY=0 \
         TOOLS="tool597" bash "$ENSURE" 2>&1)"; ec=$?
  assert_equals "$ec" "0" "apt fails $fail time(s) then succeeds → exit 0 (#597)"
  assert_equals "$(cat "$count")" "$((fail + 1))" "apt update attempted $((fail + 1)) time(s)"
done
assert_contains "$out" 'apt attempt 2/3 failed' "the retry is announced on stderr"

rm -f "$count"
out="$(PATH="$FAKE597:$FAKE597/bin:$PATH" FAKE_COUNT="$count" FAKE_FAIL=99 APT_RETRY_DELAY=0 \
       TOOLS="surely_no_such_tool_xyz" bash "$ENSURE" 2>&1 || true)"
assert_equals "$(cat "$count")" "3" "bounded: exactly APT_ATTEMPTS tries, no more"
assert_contains "$out" 'trying release-binary fallbacks' "retries exhausted → still falls through to the fallbacks (#594)"

rm -f "$count"
PATH="$FAKE597:$PATH" FAKE_COUNT="$count" FAKE_FAIL=99 APT_ATTEMPTS=1 APT_RETRY_DELAY=0 \
  TOOLS="surely_no_such_tool_xyz" bash "$ENSURE" >/dev/null 2>&1 || true
assert_equals "$(cat "$count")" "1" "APT_ATTEMPTS=1 → a single try"
assert_contains "$(cat "$ENSURE")" 'Acquire::Retries' "apt itself is asked to retry fetches"
rm -rf "$FAKE597"
```

Notes for the implementer: the `sudo` fake must match the real call shape, so after Step 3 re-check which argv position `update` lands in (`sudo apt-get -o Acquire::Retries=3 -qq update`); simplify the fake to `[[ " $* " == *" update "* ]]`. Creating `$FAKE597/bin` and having the fake `install` branch `touch` an executable is the only way the "success" cases satisfy the post-install `command -v` check.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -40`
Expected: the new assertions FAIL (single attempt, no `Acquire::Retries`); every pre-existing assertion passes.

- [ ] **Step 3: Implement**

```bash
# #597: a transient resolver or mirror error is retried before the release-binary
# fallback is even considered. The pair is retried as a unit because a failed
# `update` aborts before apt's own per-fetch retry matters.
APT_ATTEMPTS="${APT_ATTEMPTS:-3}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-5}"

apt_install_with_retry() {
  local attempt=1 delay
  while :; do
    if sudo apt-get -o Acquire::Retries=3 update -qq \
       && sudo apt-get -o Acquire::Retries=3 install -y -qq "$@"; then
      return 0
    fi
    (( attempt < APT_ATTEMPTS )) || return 1
    delay=$(( APT_RETRY_DELAY * attempt ))
    printf 'warning: apt attempt %d/%d failed, retrying in %ds\n' \
      "$attempt" "$APT_ATTEMPTS" "$delay" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}
```

Replace `if ! { sudo apt-get update -qq && sudo apt-get install -y -qq "${PKGS[@]}"; }; then` with `if ! apt_install_with_retry "${PKGS[@]}"; then`. Document `APT_ATTEMPTS` and `APT_RETRY_DELAY` in the header's "Optional environment variables" list. Leave the duplicate `MISSING=()` line alone.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -40; shellcheck scripts/ensure-toolchain.sh`
Expected: all green, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/ensure-toolchain.sh tests/run-script-tests.sh
git commit -m "fix(pipeline): retry transient apt failures in ensure-toolchain.sh (#597)"
```

---

### Task 2: `PRE_AGENT_STEP` in `post-run-report.sh` (TDD)

**Files:**
- Modify: `scripts/post-run-report.sh` (env default near `:116`, header docs, status branch near `:406-424`, marker `class`, sanitizer)
- Modify: `tests/run-script-tests.sh` (new block next to the existing `post-run-report` render-only tests)
- Test (must stay green, unmodified): `tests/run-run-report-golden-tests.sh`

**Interfaces:**
- Consumes: `PRE_AGENT_STEP` (optional free text), plus the existing `RESULT_FILE`, `ISSUE_NUMBER`, `WORKFLOW_RUN_URL`, `RENDER_ONLY`.
- Produces: with `PRE_AGENT_STEP` set, a `## ai-implement run` report whose outcome is `failed: before the agent started (step: <sanitized>)`, label `ai:failed`, marker `counts:false`, `class:"pre_agent"`, `subtype:"pre_agent_failure"`, no `attempt`.

- [ ] **Step 1: Write the failing tests**

Follow the neighbouring `post-run-report` cases for how they build a result file and run with `RENDER_ONLY=1`. Cases:

```bash
# --- #597: pre-agent failure report ---------------------------------------
R597="$(mktemp)"; printf '%s' '{"is_error":true,"subtype":"pre_agent_failure","num_turns":0,"total_cost_usd":0,"duration_ms":0}' > "$R597"
prefail_render() {  # <step> → rendered report
  RESULT_FILE="$R597" ISSUE_NUMBER=7 WORKFLOW_RUN_URL=https://example/run/1 RENDER_ONLY=1 \
    PRE_AGENT_STEP="$1" bash "$ROOT/scripts/post-run-report.sh"
}
out="$(prefail_render 'Ensure toolchain')"
assert_contains "$out" '## ai-implement run' "heading is the run report's, so tooling that matches it finds it"
assert_contains "$out" 'failed: before the agent started (step: Ensure toolchain)' "names the step"
assert_contains "$out" 'LABELS: ai:failed' "stamps ai:failed"
m="$(sed -n 's/^<!-- ai-run: \(.*\) -->$/\1/p' <<<"$out")"
assert_equals "$(jq -r '.counts' <<<"$m")" "false" "non-start: counts false"
assert_equals "$(jq -r 'has("attempt")' <<<"$m")" "false" "no attempt number"
assert_equals "$(jq -r '.class' <<<"$m")" "pre_agent" "marker class"
assert_equals "$(jq -r '.subtype' <<<"$m")" "pre_agent_failure" "marker subtype"
assert_not_contains "$m" 'Ensure toolchain' "step name is not in the marker"

# Hostile step name: one marker, sanitized visible line.
out="$(prefail_render $'x --> `rm` <b>\nline2')"
assert_equals "$(grep -c '^<!-- ai-run: ' <<<"$out")" "1" "hostile step → still one marker"
assert_not_contains "$(grep 'before the agent started' <<<"$out")" '<b>' "markup stripped from the visible line"
assert_not_contains "$(grep 'before the agent started' <<<"$out")" '`' "backticks stripped"

# Unset → no change (belt and braces next to the golden suite).
out="$(RESULT_FILE="$R597" ISSUE_NUMBER=7 WORKFLOW_RUN_URL=u RENDER_ONLY=1 bash "$ROOT/scripts/post-run-report.sh")"
assert_not_contains "$out" 'before the agent started' "PRE_AGENT_STEP unset → no pre-agent wording"
rm -f "$R597"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30`
Expected: the new cases FAIL; golden suite and all pre-existing cases pass.

- [ ] **Step 3: Implement**

- Default and header doc: `PRE_AGENT_STEP="${PRE_AGENT_STEP:-}"` beside the other optional inputs.
- Sanitize once, right after the defaults: collapse to one line, keep `[A-Za-z0-9 ._:()#/-]`, cut to 80 chars, `unknown` when empty after cleaning:

```bash
if [[ -n "$PRE_AGENT_STEP" ]]; then
  PRE_AGENT_STEP="$(printf '%s' "$PRE_AGENT_STEP" | tr '\n\r\t' '   ' | tr -cd 'A-Za-z0-9 ._:()#/-' | cut -c1-80)"
  [[ -n "${PRE_AGENT_STEP// /}" ]] || PRE_AGENT_STEP='unknown'
fi
```

- In the status chain, a new first branch **after** the pause-class branch and before `model_not_found`:

```bash
elif [[ -n "$PRE_AGENT_STEP" ]]; then
  # #597: the implement job died before the agent started. Zero turns and $0.00
  # make check-attempt-cap.sh count it as a non-start, never as an attempt.
  STATUS_EMOJI=':x:'
  STATUS_TEXT="failed: before the agent started (step: ${PRE_AGENT_STEP})"
  STATUS_LABEL='ai:failed'
```

- Marker: in `render_run_marker`, when `PRE_AGENT_STEP` is set, emit `class` as `pre_agent` (override `FAILURE_CLASS` for that call only; do not touch the visible path). `subtype` already comes from the result file.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30; bash tests/run-run-report-golden-tests.sh; shellcheck scripts/post-run-report.sh`
Expected: all green, golden suite unmodified and passing.

- [ ] **Step 5: Commit**

```bash
git add scripts/post-run-report.sh tests/run-script-tests.sh
git commit -m "feat(pipeline): report a pre-agent failure as a non-start run report (#597)"
```

---

### Task 3: `implement_prefail` job and its step-lookup script (TDD)

**Files:**
- Create: `scripts/find-failed-step.sh`
- Modify: `.github/workflows/agent-implement.yml` (new job directly before `implement_gate:` at `:1023`)
- Modify: `tests/run-script-tests.sh` (script cases, plus a structural block modelled on the `awk` extraction at `:4641-4655`)

**Interfaces:**
- `find-failed-step.sh` consumes `REPO`, `RUN_ID`, `RUN_ATTEMPT`, `JOB_NAME_SUFFIX`, optional seam `JOBS_JSON` (tests: skips the API call). It prints the first failed step's name of the first failed job whose name ends with `JOB_NAME_SUFFIX`, or `unknown`, always exits 0.
- The job consumes `needs.implement.result` and `needs.implement.outputs.agent-eligible`.

- [ ] **Step 1: Write the failing tests**

Script cases with a fixture `tests/fixtures/prefail-jobs.json` (a trimmed `jobs` payload: one successful job, one job named `agent / Implement issue #7` with steps `Checkout` success, `Ensure toolchain` failure, `Triage model` skipped):

```bash
J="$ROOT/tests/fixtures/prefail-jobs.json"
out="$(JOBS_JSON="$(cat "$J")" JOB_NAME_SUFFIX='Implement issue #7' bash "$ROOT/scripts/find-failed-step.sh")"
assert_equals "$out" "Ensure toolchain" "names the failed step of the implement job"
out="$(JOBS_JSON="$(cat "$J")" JOB_NAME_SUFFIX='Implement issue #8' bash "$ROOT/scripts/find-failed-step.sh")"
assert_equals "$out" "unknown" "no job matches → unknown"
out="$(JOBS_JSON='not json' JOB_NAME_SUFFIX='x' bash "$ROOT/scripts/find-failed-step.sh")"
assert_equals "$out" "unknown" "garbage → unknown, exit 0"
```

Structural cases on the workflow (extract the job body with the same `awk` idiom as `:4643`):

```bash
WF597="$ROOT/.github/workflows/agent-implement.yml"
pf="$(awk '/^  implement_prefail:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$WF597")"
assert_contains "$pf" "needs.implement.result == 'failure'" "reports only a failed implement job"
assert_contains "$pf" "needs.implement.outputs.agent-eligible != 'true'" "complement of the gate: never double-reports"
assert_contains "$pf" "!cancelled()" "a superseded run stays silent (#571)"
assert_contains "$pf" "!inputs.stub-claude" "stub runs are tests, never report"
assert_contains "$pf" "PRE_AGENT_STEP" "hands the step to post-run-report.sh"
assert_contains "$pf" "actions: read" "needs the jobs API, nothing more"
assert_not_contains "$pf" "actions: write" "no dispatch rights: it only reports"
gate597="$(awk '/^  implement_gate:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$WF597")"
assert_contains "$gate597" "needs.implement.outputs.agent-eligible == 'true'" "gate's own condition is unchanged"
```


- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30`
Expected: new cases FAIL (script and job missing).

- [ ] **Step 3: Implement**

`scripts/find-failed-step.sh`, `set -euo pipefail`, header comment in the repo's style:

```bash
JSON="${JOBS_JSON:-}"
if [[ -z "$JSON" ]]; then
  JSON="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT:-1}/jobs" 2>/dev/null)" || JSON=''
fi
name="$(jq -r --arg suffix "${JOB_NAME_SUFFIX:-}" '
  [ .jobs[]? | select(.conclusion == "failure")
              | select(.name | endswith($suffix))
              | .steps[]? | select(.conclusion == "failure") | .name ][0] // empty
' <<<"$JSON" 2>/dev/null)" || name=''
printf '%s\n' "${name:-unknown}"
```

The job in `agent-implement.yml`, directly before `implement_gate:`:

```yaml
  implement_prefail:
    # #597: the implement job failed before the agent started, so
    # implement_gate (agent-eligible == 'true') was skipped and nothing would
    # tell the issue. Complement of the gate's condition: exactly one of the
    # two reports a given failure. Own job, own runner: the failure is often the
    # runner itself. Best effort, not a guarantee.
    name: Report pre-agent failure — issue #${{ inputs.issue-number }}
    needs: implement
    if: ${{ !cancelled() && !inputs.stub-claude
            && needs.implement.result == 'failure'
            && needs.implement.outputs.agent-eligible != 'true' }}
    runs-on: ${{ fromJSON(inputs.gate-runner-labels != '' && inputs.gate-runner-labels || inputs.runner-labels) }}
    timeout-minutes: 10
    permissions:
      contents: read
      issues: write
      actions: read
    env:
      PIPELINE_APP_ID: ${{ secrets.PIPELINE_APP_ID }}
    steps:
      # token mint, consumer checkout, agent-workflow checkout and the
      # local-scripts mirror: copy the four steps from implement_gate unchanged.
      - name: Find the failed step
        id: failed_step
        env:
          REPO: ${{ github.repository }}
          RUN_ID: ${{ github.run_id }}
          RUN_ATTEMPT: ${{ github.run_attempt }}
          GH_TOKEN: ${{ github.token }}
          JOB_NAME_SUFFIX: Implement issue #${{ inputs.issue-number }}
        run: printf 'step=%s\n' "$(bash .claude-pipeline/scripts/find-failed-step.sh)" >> "$GITHUB_OUTPUT"
      - name: Post the pre-agent failure report
        env:
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          WORKFLOW_RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
          REPO: ${{ github.repository }}
          GH_TOKEN: ${{ github.token }}
          RENDER_ONLY: ${{ inputs.dry-run && '1' || '0' }}
          PRE_AGENT_STEP: ${{ steps.failed_step.outputs.step }}
          RETRY_ATTEMPT: ${{ inputs.attempt }}
        run: |
          RESULT_FILE="$RUNNER_TEMP/prefail-result.json"
          printf '%s' '{"is_error":true,"subtype":"pre_agent_failure","num_turns":0,"total_cost_usd":0,"duration_ms":0}' > "$RESULT_FILE"
          RESULT_FILE="$RESULT_FILE" bash .claude-pipeline/scripts/post-run-report.sh
```

If `inputs.gate-runner-labels` and the checkout steps differ from the gate's by the time this lands, copy the gate's current versions, not the text above. Do not touch `implement_gate`.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -30; bash tests/run-caller-permissions-tests.sh; shellcheck scripts/find-failed-step.sh; actionlint .github/workflows/agent-implement.yml` (skip actionlint if not installed)
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/find-failed-step.sh tests/fixtures/prefail-jobs.json tests/run-script-tests.sh .github/workflows/agent-implement.yml
git commit -m "feat(pipeline): report an implement job that fails before the agent (#597)"
```

---

### Task 4: ADR, docs, CHANGELOG

**Files:**
- Modify: `docs/DECISIONS.md` (append the next free ADR number, `ADR-023` if `ADR-022` from #593 has landed, else `ADR-022`; heading dated the day it lands)
- Modify: `docs/RUNNER-REQUIREMENTS.md` (one line: apt is retried, `APT_ATTEMPTS` / `APT_RETRY_DELAY`)
- Modify: `docs/DECISIONS.md` ADR-021's class list is immutable: do **not** edit it, state the new `pre_agent` value in the new ADR
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append the ADR** (Status accepted, Context, Decision, Consequences, mirroring ADR-021): the complement rule between `implement_prefail` and `implement_gate`; the non-start semantics and the `MAX_NON_STARTS` ceiling; marker `class: "pre_agent"` and `subtype: "pre_agent_failure"` as additive enum values, consumers treat an unknown class as "failed, not retryable by class"; the step name is visible-only.
- [ ] **Step 2: CHANGELOG.** Under `## [Unreleased]`: `### Fixed` "`ensure-toolchain.sh` retries transient apt failures (3 attempts, backoff) before the release-binary fallback (#597)"; `### Added` "A failure of the implement job before the agent starts now posts a run report naming the failed step, stamps `ai:failed`, and does not count as an attempt (#597)".
- [ ] **Step 3: Verify** `grep -c '^## ADR-02[23] ' docs/DECISIONS.md` shows the new ADR once; run the repo's markdown lint (`just lint` or `markdownlint` per `justfile`).
- [ ] **Step 4: Commit** `docs(pipeline): ADR for pre-agent failure reports (#597)`.

---

### Task 5: Full verification

- [ ] **Step 1:** `bash tests/run-all.sh` passes; `shellcheck scripts/ensure-toolchain.sh scripts/post-run-report.sh scripts/find-failed-step.sh` clean.
- [ ] **Step 2:** Walk the complement by reading the two `if:` lines side by side: for every combination of `implement.result` in {success, failure, cancelled, skipped} and `agent-eligible` in {true, false, empty}, at most one of `implement_gate` / `implement_prefail` runs. Write the table in the PR description.
- [ ] **Step 3:** Open the PR (`fix(pipeline): retry apt and report pre-agent failures (#597)`), `Closes #597`. After merge, the only real-world proof is the next consumer run that hits a pre-agent failure; do not fake one with a dispatch.
