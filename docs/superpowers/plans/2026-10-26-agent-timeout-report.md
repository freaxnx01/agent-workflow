# Agent-Step Timeout Report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Claude agent step hits its wall-clock cap, the run still gets a report that says it timed out, grades the work already pushed to the PR (`ai:partial`), and is not retried.

**Architecture:** Builds on #535's `implement_gate`. A trusted pre-agent start time travels as an implement output; a new gate script turns "no result + Claude + elapsed ≥ cap" into a synthetic `error_agent_timeout` result; classify maps it to a no-retry class; the gate's PR lookup also runs on a timeout so plan coverage grades the pushed work; the run report gets a dedicated rung.

**Tech Stack:** Bash 5, jq, GitHub Actions YAML, Layer-1 fixture tests.

**Spec:** `docs/superpowers/specs/2026-10-26-agent-timeout-report-design.md`

> **Blocked by #535.** Task 3 edits the `implement_gate` job and the `agent_reached` step that #535 adds. Do not start before #535 has merged; confirm with `grep -n 'implement_gate:' .github/workflows/agent-implement.yml`.

## Global Constraints

- Bash scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, a header comment with env, outputs and exit codes (match `scripts/plan-coverage-step.sh`). Exit 2 on missing required env.
- New Layer-1 runners are auto-discovered by `tests/run-all.sh`; copy the helper block from `tests/run-plan-coverage-tests.sh:16-30`. Hermetic: no network, no real `gh`.
- Job outputs reach a `run:` script only through `env:`. Never write `${{ needs.* }}` or `${{ steps.*.outputs.* }}` inside a `run:` body.
- A synthetic result's `.result` text must contain no digits: `classify-failure.sh` matches `5[0-9]{2}` as `transient`. Numbers go in their own JSON fields.
- Pinned actions only; no consumer stub change (`tests/run-caller-permissions-tests.sh` stays green); `tests/run-agent-isolation-tests.sh` stays green.
- After every task: `bash tests/run-all.sh`, `shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh`, `actionlint .github/workflows/*.yml`.

## Review Focus

1. A run that returns a **valid** result close to the cap is never relabelled a timeout (`valid=true` short-circuits) — pinned in Task 1.
2. A run with no result that ended **well before** the cap stays `error_invalid_evidence` — pinned in Task 1.
3. An **OpenCode** run with no result past the cap is not called a timeout (no step cap exists for it) — pinned in Task 1.
4. An empty or non-numeric `AGENT_STARTED_AT` (e.g. a stub run) disables detection instead of failing the gate — pinned in Task 1.
5. A timeout **without a PR** reports `ai:failed`, never `ai:partial` — pinned in Task 2.

---

### Task 1: `detect-agent-timeout.sh` — the decision, with tests

**Files:**
- Create: `scripts/detect-agent-timeout.sh`
- Test: `tests/run-agent-timeout-tests.sh`

**Interfaces:**
- Consumes env: `RESULT_FILE` (required, the imported result), `EVIDENCE_VALID` (required, `true|false` from `import-result-output.sh`), `AGENT` (required), `AGENT_TIMEOUT_MINUTES` (required, integer), `AGENT_STARTED_AT` (optional epoch seconds; empty disables detection), `NOW` (optional epoch seconds, default `date +%s`; for tests).
- Produces (`$GITHUB_OUTPUT` when set, always stdout): `timed-out=true|false`. On `true` it rewrites `RESULT_FILE` to `{type:"result", subtype:"error_agent_timeout", is_error:true, duration_ms:<elapsed*1000>, num_turns:0, total_cost_usd:0, timeout_minutes:<cap>, session_id:"gate", result:<text without digits>, usage:{…zeros}}`.
- Exit codes: 0 decided; 2 missing required env.

- [ ] **Step 1: Write the failing tests** — new `tests/run-agent-timeout-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-agent-timeout-tests.sh — Layer-1 tests for scripts/detect-agent-timeout.sh
# (#567). No network, no gh.
#
# Usage: tests/run-agent-timeout-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'
unset GITHUB_OUTPUT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$ROOT/scripts/detect-agent-timeout.sh"
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
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# invalid_result <path> — what import-result-output.sh writes for missing evidence
invalid_result() {
  jq -n '{type:"result", subtype:"error_invalid_evidence", is_error:true, duration_ms:0,
          num_turns:0, total_cost_usd:0, session_id:"gate",
          result:"The gate received no valid result evidence from the implement job.",
          usage:{input_tokens:0, output_tokens:0, cache_creation_input_tokens:0, cache_read_input_tokens:0}}' > "$1"
}

# detect <result-file> <valid> <agent> <started-at> <now> [cap] → stdout
detect() {
  RESULT_FILE="$1" EVIDENCE_VALID="$2" AGENT="$3" AGENT_STARTED_AT="$4" NOW="$5" \
    AGENT_TIMEOUT_MINUTES="${6:-100}" bash "$DETECT"
}

section "a Claude run with no result past its cap is a timeout"
invalid_result "$T/r1.json"
out="$(detect "$T/r1.json" false claude 1000 $((1000 + 100 * 60 + 90)))"
assert_eq "timed-out=true" "true" "$(field "$out" timed-out)"
assert_eq "subtype rewritten" "error_agent_timeout" "$(jq -r .subtype "$T/r1.json")"
assert_eq "still an error" "true" "$(jq -r .is_error "$T/r1.json")"
assert_eq "duration is the elapsed time" "6090000" "$(jq -r .duration_ms "$T/r1.json")"
assert_eq "cap is recorded" "100" "$(jq -r .timeout_minutes "$T/r1.json")"
assert_eq "result text carries no digits" "" "$(jq -r .result "$T/r1.json" | tr -cd '0-9')"

section "exactly at the cap counts"
invalid_result "$T/r2.json"
out="$(detect "$T/r2.json" false claude 1000 $((1000 + 10 * 60)) 10)"
assert_eq "elapsed == cap → timed-out" "true" "$(field "$out" timed-out)"

section "a valid result is never relabelled (Review Focus 1)"
jq -n '{type:"result", subtype:"success", is_error:false, result:"done"}' > "$T/ok.json"
out="$(detect "$T/ok.json" true claude 1000 $((1000 + 200 * 60)))"
assert_eq "valid → timed-out=false" "false" "$(field "$out" timed-out)"
assert_eq "valid result untouched" "success" "$(jq -r .subtype "$T/ok.json")"

section "no result well before the cap stays invalid evidence (Review Focus 2)"
invalid_result "$T/r3.json"
out="$(detect "$T/r3.json" false claude 1000 $((1000 + 5 * 60)))"
assert_eq "early crash → timed-out=false" "false" "$(field "$out" timed-out)"
assert_eq "subtype untouched" "error_invalid_evidence" "$(jq -r .subtype "$T/r3.json")"

section "OpenCode has no step cap (Review Focus 3)"
invalid_result "$T/r4.json"
out="$(detect "$T/r4.json" false opencode 1000 $((1000 + 200 * 60)))"
assert_eq "opencode → timed-out=false" "false" "$(field "$out" timed-out)"
assert_eq "subtype untouched" "error_invalid_evidence" "$(jq -r .subtype "$T/r4.json")"

section "no usable start time disables detection (Review Focus 4)"
invalid_result "$T/r5.json"
out="$(detect "$T/r5.json" false claude '' 999999)"
assert_eq "empty start → timed-out=false" "false" "$(field "$out" timed-out)"
out="$(detect "$T/r5.json" false claude 'abc' 999999)"
assert_eq "non-numeric start → timed-out=false" "false" "$(field "$out" timed-out)"
assert_eq "subtype untouched" "error_invalid_evidence" "$(jq -r .subtype "$T/r5.json")"

section "missing required env"
rc=0; RESULT_FILE="$T/r5.json" EVIDENCE_VALID=false AGENT=claude bash "$DETECT" >/dev/null 2>&1 || rc=$?
assert_eq "no AGENT_TIMEOUT_MINUTES → exit 2" "2" "$rc"

section "GITHUB_OUTPUT receives the decision"
invalid_result "$T/r6.json"
: > "$T/gho"
GITHUB_OUTPUT="$T/gho" RESULT_FILE="$T/r6.json" EVIDENCE_VALID=false AGENT=claude \
  AGENT_STARTED_AT=1000 NOW=$((1000 + 100 * 60)) AGENT_TIMEOUT_MINUTES=100 bash "$DETECT" >/dev/null
assert_eq "output file holds timed-out=true" "timed-out=true" "$(cat "$T/gho")"

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/run-agent-timeout-tests.sh`
Expected: FAIL — `scripts/detect-agent-timeout.sh` does not exist.

- [ ] **Step 3: Write the script** — `scripts/detect-agent-timeout.sh`:

```bash
#!/usr/bin/env bash
#
# detect-agent-timeout.sh — implement_gate's "Detect an agent wall-clock
# timeout" step (#567).
#
# When `Run Claude Code` hits its step-level timeout-minutes, the runner kills
# it before the action writes a result, so the gate imports no evidence and
# import-result-output.sh writes a synthetic error_invalid_evidence result.
# This script tells that case apart from a crash: no valid result, the Claude
# agent, and the time since the trusted pre-agent start marker at or past the
# cap. Every input is trusted (pre-agent output, workflow input, this clock);
# elapsed time includes the post-agent steps, so it can only overstate.
#
# On a timeout it rewrites RESULT_FILE as error_agent_timeout. The result text
# carries no digits (classify-failure.sh reads 5xx as transient); the cap and
# the elapsed time go in their own fields.
#
# Required env:
#   RESULT_FILE            imported result (import-result-output.sh)
#   EVIDENCE_VALID         true|false (import-result-output.sh `valid`)
#   AGENT                  claude|opencode
#   AGENT_TIMEOUT_MINUTES  inputs.claude-timeout-minutes
# Optional env:
#   AGENT_STARTED_AT       epoch seconds from the implement job; empty or
#                          non-numeric disables detection
#   NOW                    epoch seconds (tests); default: date +%s
# Outputs ($GITHUB_OUTPUT when set, always stdout):
#   timed-out=true|false
# Exit codes: 0 decided; 2 missing required env.
set -euo pipefail
IFS=$'\n\t'

for v in RESULT_FILE EVIDENCE_VALID AGENT AGENT_TIMEOUT_MINUTES; do
  if [[ -z "${!v:-}" ]]; then
    printf '%s must be set\n' "$v" >&2
    exit 2
  fi
done

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'timed-out=%s\n' "$1" >> "$GITHUB_OUTPUT"; fi
  printf 'timed-out=%s\n' "$1"
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

started="${AGENT_STARTED_AT:-}"
now="${NOW:-$(date +%s)}"

if [[ "$EVIDENCE_VALID" == "true" || "$AGENT" != "claude" ]] \
   || ! is_integer "$started" || ! is_integer "$AGENT_TIMEOUT_MINUTES"; then
  emit false
  exit 0
fi

elapsed=$(( now - started ))
if (( elapsed < AGENT_TIMEOUT_MINUTES * 60 )); then
  emit false
  exit 0
fi

jq -n --argjson ms "$(( elapsed * 1000 ))" --argjson cap "$AGENT_TIMEOUT_MINUTES" \
  '{type: "result", subtype: "error_agent_timeout", is_error: true,
    duration_ms: $ms, num_turns: 0, total_cost_usd: 0, timeout_minutes: $cap,
    session_id: "gate",
    result: "The agent step hit its wall-clock cap and was stopped before it reported a result.",
    usage: {input_tokens: 0, output_tokens: 0,
            cache_creation_input_tokens: 0, cache_read_input_tokens: 0}}' > "$RESULT_FILE"
printf '::warning title=Agent timed out::the agent step used its whole wall-clock cap; grading the pushed work\n'
emit true
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/run-agent-timeout-tests.sh`
Expected: all pass. Then `shellcheck -x -e SC1091 scripts/detect-agent-timeout.sh tests/run-agent-timeout-tests.sh` → clean.

- [ ] **Step 5: Commit and push**

```bash
git add scripts/detect-agent-timeout.sh tests/run-agent-timeout-tests.sh
git commit -m "feat(gate): tell an agent wall-clock timeout from missing evidence (#567)"
git push
```

### Task 2: classify, retry and report the timeout

**Files:**
- Create: `tests/fixtures/result-agent-timeout.json`
- Modify: `scripts/classify-failure.sh` (header class list `:17-18`; new branch right after the `error_agent_cut_off` branch, `:105-111`)
- Modify: `scripts/retry-dispatch.sh` (the `case "$CLASS"` block, `:60-93`)
- Modify: `scripts/post-run-report.sh` (status ladder, new rung after the `model_not_found` rung `:352-358`, before the generic agent-error rung `:359`)
- Test: `tests/run-script-tests.sh`

**Interfaces:**
- Consumes: the `error_agent_timeout` result shape from Task 1 (`timeout_minutes`, `duration_ms`).
- Produces: `classify-failure.sh` → `class=agent_timeout`; `retry-dispatch.sh` → `decision=stop` for it; `post-run-report.sh` status texts below, read by #568's work and by `ai-stats`.

- [ ] **Step 1: Add the fixture** — `tests/fixtures/result-agent-timeout.json`:

```json
{
  "type": "result",
  "subtype": "error_agent_timeout",
  "is_error": true,
  "duration_ms": 6090000,
  "num_turns": 0,
  "total_cost_usd": 0,
  "timeout_minutes": 100,
  "session_id": "gate",
  "result": "The agent step hit its wall-clock cap and was stopped before it reported a result.",
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0
  }
}
```

- [ ] **Step 2: Write the failing tests** — in `tests/run-script-tests.sh`:

After the `max-turns with is_error=false → task_failure` assertion in section `classify-failure — buckets per fixture`:

```bash
# #567: a wall-clock timeout is its own class — never a retry, and keyed on
# the structural subtype, not on the word in the text.
out="$(RESULT_FILE="$FIXTURES/result-agent-timeout.json" bash "$CLASSIFY_FAIL")"
assert_contains "$out" 'class=agent_timeout' "agent-timeout fixture → agent_timeout"
```

After the `task_failure attempt=2 → stop` assertion:

```bash
out="$(CLASS=agent_timeout ATTEMPT=1 ISSUE_NUMBER=42 REPO=o/r DRY_RUN=1 bash "$RETRY")"
assert_contains "$out" 'decision=stop' "agent_timeout attempt=1 → stop (#567)"
```

At the end of section `plan coverage grading (#457)`:

```bash
section "agent wall-clock timeout (#567)"

out="$(RESULT_FILE="$FIXTURES/result-agent-timeout.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PR_PRESENT=true PLAN_COVERAGE=partial MISSING_TASKS=11 \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" ":warning: timed out at the agent's 100-minute wall-clock cap: plan task(s) 11 have no file in the PR" \
  "timeout with a partial PR names the cap and the missing tasks"
assert_contains "$out" 'LABELS: ai:partial' "timeout with a PR labels ai:partial"
assert_contains "$out" '101m 30s' "the duration is the measured elapsed time"

out="$(RESULT_FILE="$FIXTURES/result-agent-timeout.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PR_PRESENT=true PLAN_COVERAGE=complete \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" 'every plan task has a file in the PR, but the run did not finish' \
  "timeout with full coverage still says the run did not finish"
assert_contains "$out" 'LABELS: ai:partial' "timeout with full coverage is still ai:partial"

out="$(RESULT_FILE="$FIXTURES/result-agent-timeout.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PR_PRESENT=true PLAN_COVERAGE=unverifiable \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" 'work was pushed to the PR; plan coverage unverifiable' \
  "timeout with unverifiable coverage says so"

out="$(RESULT_FILE="$FIXTURES/result-agent-timeout.json" ISSUE_NUMBER=42 \
        WORKFLOW_RUN_URL=https://example.test/run/1 RENDER_ONLY=1 \
        PR_PRESENT=false \
        bash "$ROOT/scripts/post-run-report.sh")"
assert_contains "$out" ":x: failed: timed out at the agent's 100-minute wall-clock cap before a PR was opened" \
  "timeout without a PR is a failure (Review Focus 5)"
assert_contains "$out" 'LABELS: ai:failed' "timeout without a PR labels ai:failed"
assert_not_contains "$out" 'ai:partial' "timeout without a PR is never ai:partial"
```

- [ ] **Step 3: Run to see them fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: the new assertions fail (`class=bug`, `decision=stop` via the `*` default with a warning, `failed: error_agent_timeout`).

- [ ] **Step 4: Implement**

`scripts/classify-failure.sh` — header class list becomes:

```bash
#   class=success | out_of_credits | model_not_found | rate_limit | api_auth |
#         transient | task_failure | agent_timeout | bug
```

and add a header line in the per-class list that follows: `#   - agent_timeout → no retry: the agent step hit its wall-clock cap (#567)`. Insert right after the `error_agent_cut_off` branch:

```bash
elif [[ "$subtype" == "error_agent_timeout" ]]; then
  # The agent step used its whole wall-clock cap (#567). detect-agent-timeout.sh
  # writes this subtype in the gate from trusted inputs only. Not retried: a
  # retry is a second full-length run that starts from the issue, while the
  # first run's work already sits on the PR.
  class=agent_timeout
```

`scripts/retry-dispatch.sh` — add to the stop case:

```bash
  out_of_credits|model_not_found|api_auth|agent_timeout|bug)
```

and append to that case's comment: `agent_timeout (#567) is a run that used its whole wall clock; its work is on the PR, and a retry would repeat the most expensive kind of run from scratch.`

`scripts/post-run-report.sh` — new rung between the `model_not_found` rung and the generic `IS_ERROR` rung:

```bash
elif [[ "$SUBTYPE" == "error_agent_timeout" ]]; then
  # #567: the agent step hit its wall-clock cap. Grade what it pushed rather
  # than calling it a plain failure: a PR with work on it is partial.
  timeout_minutes="$(jq -r '.timeout_minutes // empty' "$RESULT_FILE")"
  cap_text="the agent's ${timeout_minutes:+${timeout_minutes}-minute }wall-clock cap"
  if [[ "${PR_PRESENT:-}" == "true" ]]; then
    STATUS_EMOJI=':warning:'
    STATUS_LABEL='ai:partial'
    case "$PLAN_COVERAGE" in
      partial)  STATUS_TEXT="timed out at ${cap_text}: plan task(s) ${MISSING_TASKS//,/, } have no file in the PR" ;;
      complete) STATUS_TEXT="timed out at ${cap_text}: every plan task has a file in the PR, but the run did not finish" ;;
      *)        STATUS_TEXT="timed out at ${cap_text}: work was pushed to the PR; plan coverage unverifiable" ;;
    esac
  else
    STATUS_EMOJI=':x:'
    STATUS_TEXT="failed: timed out at ${cap_text} before a PR was opened"
    STATUS_LABEL='ai:failed'
  fi
```

Also add `error_agent_timeout` to the header comment block that documents the status grades (`:36-52`), one line, matching its style.

- [ ] **Step 5: Run the tests**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -3` and `bash tests/run-all.sh`
Expected: all pass.

- [ ] **Step 6: Commit and push**

```bash
git add tests/fixtures/result-agent-timeout.json scripts/classify-failure.sh scripts/retry-dispatch.sh scripts/post-run-report.sh tests/run-script-tests.sh
git commit -m "feat(report): grade a timed-out run's pushed work instead of failing it silently (#567)"
git push
```

### Task 3: wire it into the implement job and `implement_gate`

**Files:**
- Modify: `.github/workflows/agent-implement.yml` (the `agent_reached` step and implement `outputs:` from #535; `implement_gate` steps)
- Modify: `tests/run-script-tests.sh` (structural assertions)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:**
- Consumes: `scripts/detect-agent-timeout.sh` (Task 1); #535's `agent_reached` step, `Import the implement job's result` step (`id: result`, outputs `result-file`, `valid`) and `Find pipeline-opened PR` step (`id: find_pr`).
- Produces: implement output `agent-started-at`; gate step `id: agent_timeout` with output `timed-out`.

- [ ] **Step 1: Write the failing structural tests** — in `tests/run-script-tests.sh`, next to #535's `gate535` assertions (search for `gate535=`; reuse that variable, which holds the `implement_gate` job text, and the workflow path variable used there):

```bash
section "agent timeout wiring (#567)"
wf567="$(cat "$ROOT/.github/workflows/agent-implement.yml")"
assert_contains "$wf567" "printf 'started-at=%s\n' \"\$(date +%s)\" >> \"\$GITHUB_OUTPUT\"" \
  "the pre-agent marker records the start time"
assert_contains "$wf567" 'agent-started-at:    ${{ steps.agent_reached.outputs.started-at }}' \
  "the start time is an implement output"
assert_contains "$gate535" 'run: bash .claude-pipeline/scripts/detect-agent-timeout.sh' \
  "the gate runs the timeout detector"
assert_contains "$gate535" 'AGENT_STARTED_AT: ${{ needs.implement.outputs.agent-started-at }}' \
  "the detector gets the start time through env"
assert_contains "$gate535" 'AGENT_TIMEOUT_MINUTES: ${{ inputs.claude-timeout-minutes }}' \
  "the detector gets the cap through env"
assert_contains "$gate535" "steps.agent_timeout.outputs.timed-out == 'true'" \
  "the PR lookup also runs on a timeout"
```

Run: `bash tests/run-script-tests.sh 2>&1 | grep -E '✗|passed:'` → the six new assertions fail.

- [ ] **Step 2: Record the start time** — replace the `run:` line of #535's `Mark the agent step reached` step (`id: agent_reached`) with:

```yaml
        # #567: the start time is trusted for the same reason — written before
        # any agent runs. implement_gate measures the wall clock from it.
        run: |
          printf 'reached=true\n' >> "$GITHUB_OUTPUT"
          printf 'started-at=%s\n' "$(date +%s)" >> "$GITHUB_OUTPUT"
```

and add to the implement job's `outputs:`, directly under `agent-eligible:`:

```yaml
      agent-started-at:    ${{ steps.agent_reached.outputs.started-at }}
```

- [ ] **Step 3: Add the detector step** to `implement_gate`, directly after `Import the implement job's result`:

```yaml
      - name: Detect an agent wall-clock timeout
        # #567: a killed agent step leaves no result, which import turns into
        # error_invalid_evidence. With the Claude agent and the full cap spent
        # since the trusted start marker, it is a timeout: rewrite the result so
        # classify, coverage and the report treat it as one.
        id: agent_timeout
        if: always() && steps.result.outputs.result-file != ''
        env:
          RESULT_FILE: ${{ steps.result.outputs.result-file }}
          EVIDENCE_VALID: ${{ steps.result.outputs.valid }}
          AGENT: ${{ needs.implement.outputs.agent }}
          AGENT_STARTED_AT: ${{ needs.implement.outputs.agent-started-at }}
          AGENT_TIMEOUT_MINUTES: ${{ inputs.claude-timeout-minutes }}
        run: bash .claude-pipeline/scripts/detect-agent-timeout.sh
```

- [ ] **Step 4: Let the PR lookup run on a timeout** — in `Find pipeline-opened PR` (`id: find_pr`) change only the `if:` to:

```yaml
        if: always() && !inputs.dry-run && (steps.outputs.outputs.outcome == 'success' || steps.agent_timeout.outputs.timed-out == 'true')
```

and extend its comment by one line: `# #567: also on a timeout, so coverage grades the work the agent pushed.`

`Check plan coverage`, `Check the PR's required checks can run` and `Post run report` need no change: they already key on `steps.find_pr.outputs.found` and the result file.

- [ ] **Step 5: Changelog** — under `## [Unreleased]`, in its `### Fixed` section (create the heading if absent):

```markdown
- **pipeline:** an agent step that hits its wall-clock cap now gets a run report that says so and grades the work it pushed (`ai:partial`) instead of ending silently; it is not retried (#567)
```

- [ ] **Step 6: Verify**

Run: `actionlint .github/workflows/*.yml`, `bash tests/run-all.sh` (including `run-agent-isolation-tests.sh`, `run-caller-permissions-tests.sh`, `run-agent-timeout-tests.sh`), `shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh`.
Expected: all green.

- [ ] **Step 7: Commit and push**

```bash
git add .github/workflows/agent-implement.yml tests/run-script-tests.sh CHANGELOG.md
git commit -m "fix(pipeline): report an agent wall-clock timeout from the gate (#567)"
git push
```
