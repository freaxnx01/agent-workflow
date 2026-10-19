# Agent Isolation via Gate Jobs — Implementation Plan

> Spec: `docs/superpowers/specs/2026-10-19-agent-isolation-gate-jobs-design.md` (issue #535).

**Goal:** No decision about an agent's work runs in a job where an agent with a bash tool ran. The `implement`, `ai_review_ai_merge` and `ai_review_human_merge` jobs only produce evidence (job outputs); three new jobs (`implement_gate`, `ai_review_ai_merge_gate`, `ai_review_human_merge_gate`) make every decision on their own runner, from a fresh `.claude-pipeline` checkout at `inputs.pipeline-ref`, and never run an agent.

**Architecture:** implement → (job outputs: `result-json`, `execution-usage`, trusted pre-agent outputs) → `implement_gate` (classify, pause, retry, report, coverage, red/green) → review job (review + self-fix, outputs only) → review gate (gated verdict, head binding, coverage on final head, envelope, merge pinned with `--match-head-commit`).

**Split:** Tasks 1–4 ship on their own (the implement side is isolated, review jobs only re-point their `needs`). Tasks 5–8 isolate the review side. Two PRs, in that order, is recommended; every task leaves the workflow working.

## Global Constraints

- Bash scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`, a header comment with env, outputs and exit codes (match `scripts/plan-coverage-step.sh`). Exit 2 on missing required env.
- New Layer-1 runners are auto-discovered by `tests/run-all.sh`; copy the helper block (`section/pass/fail/assert_eq`) from `tests/run-plan-coverage-tests.sh:16-30`. Hermetic: no network, no real `gh`.
- Job outputs reach a `run:` script only through `env:`. Never write `${{ needs.* }}` or `${{ steps.*.outputs.* }}` inside a `run:` body.
- Moved steps are moved **verbatim** (comments included) unless a step below says which lines change.
- Every new job: `persist-credentials: false` on its consumer checkout, its own pipeline checkout (`ref: ${{ inputs.pipeline-ref }}`, sparse `scripts tests/mocks tests/fixtures`) or the local-scripts mirror, no agent step, no `ensure-toolchain.sh` with `AGENT: opencode`.
- Pinned actions only (reuse the SHAs already in the file). Do not change any consumer stub; `tests/run-caller-permissions-tests.sh` must stay green.
- After every task: `bash tests/run-all.sh`, `shellcheck -x -e SC1091 scripts/*.sh scripts/lib/*.sh tests/*.sh`, `actionlint .github/workflows/*.yml`.
- A synthetic result's text must not contain three-digit numbers starting with 5 (classify-failure.sh matches `5[0-9]{2}` as `transient`), so never write the issue number into it.

### Task 1: Export the implement result as job outputs

**Files:**
- Create: `scripts/export-result-output.sh`
- Test: `tests/run-gate-evidence-tests.sh`

**Interfaces:**
- Consumes env: `RESULT_FILE` (required), `EXECUTION_FILE` (optional), `RESULT_TEXT_HALF` (optional, default 4000).
- Produces (`$GITHUB_OUTPUT`, else stdout): `result-json=<compact JSON or empty>`, `execution-usage=<compact JSON array>`, `is-error=true|false`.

- [ ] **Step 1: Write the failing tests** — new `tests/run-gate-evidence-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-gate-evidence-tests.sh — Layer-1 tests for the evidence hand-over between
# an agent job and its gate job (#535): export-result-output.sh,
# import-result-output.sh, check-verdict-binding.sh.
set -euo pipefail
IFS=$'\n\t'
unset GITHUB_OUTPUT GITHUB_REPOSITORY GITHUB_ACTIONS GITHUB_TOKEN

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
EXPORT="$ROOT/scripts/export-result-output.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAIL_NAMES=()
section() { printf '\n── %s ──\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; [[ $# -gt 1 ]] && printf '      %s\n' "$2"; return 0; }
assert_eq() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

section "export: a normal result passes through compact"
out="$(RESULT_FILE="$FIX/result-success-cheap.json" bash "$EXPORT")"
assert_eq "result-json is the compact result" "$(jq -c . "$FIX/result-success-cheap.json")" "$(field "$out" result-json)"
assert_eq "is-error=false on success" "false" "$(field "$out" is-error)"
assert_eq "no execution file → empty usage array" "[]" "$(field "$out" execution-usage)"

section "export: a long result text is elided head+tail"
jq --arg t "$(printf 'A%.0s' $(seq 1 6000))$(printf 'Z%.0s' $(seq 1 6000))" '.result = $t' \
  "$FIX/result-success-cheap.json" > "$T/long.json"
rj="$(field "$(RESULT_FILE="$T/long.json" bash "$EXPORT")" result-json)"
text="$(printf '%s' "$rj" | jq -r .result)"
assert_eq "head kept" "$(printf 'A%.0s' $(seq 1 4000))" "${text:0:4000}"
assert_eq "tail kept" "$(printf 'Z%.0s' $(seq 1 4000))" "${text: -4000}"
if [[ "$text" == *"elided by export-result-output.sh"* ]]; then pass "elision is marked"; else fail "elision is marked"; fi

section "export: usage events only, both stream shapes"
u="$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$FIX/exec-high-context.ndjson" bash "$EXPORT")" execution-usage)"
assert_eq "claude NDJSON → only assistant usage entries" \
  "$(jq -cs '[.[] | select(.type=="assistant") | {type, message:{usage:(.message.usage // {})}}]' "$FIX/exec-high-context.ndjson")" "$u"
u="$(field "$(RESULT_FILE="$FIX/result-opencode-success.json" EXECUTION_FILE="$FIX/opencode-success.json" bash "$EXPORT")" execution-usage)"
assert_eq "opencode stream → only step_finish token entries" \
  "$(jq -cs '[.[] | select(.type=="step_finish") | {type, part:{tokens:(.part.tokens // {})}}]' "$FIX/opencode-success.json")" "$u"
printf 'not json at all\n' > "$T/garbage.txt"
assert_eq "unparseable stream → []" "[]" "$(field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$T/garbage.txt" bash "$EXPORT")" execution-usage)"

section "export: the report renders the same from the reduced usage"
render() { RESULT_FILE="$FIX/result-success-cheap.json" ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example.test/run/1 \
  RENDER_ONLY=1 MODEL=claude-sonnet-5 AGENT=claude EXECUTION_FILE="$1" bash "$ROOT/scripts/post-run-report.sh"; }
field "$(RESULT_FILE="$FIX/result-success-cheap.json" EXECUTION_FILE="$FIX/exec-high-context.ndjson" bash "$EXPORT")" execution-usage > "$T/usage.json"
assert_eq "same report from full stream and reduced usage" "$(render "$FIX/exec-high-context.ndjson")" "$(render "$T/usage.json")"

section "export: bad input"
printf '{not json' > "$T/bad.json"
out="$(RESULT_FILE="$T/bad.json" bash "$EXPORT")"
assert_eq "invalid result → empty result-json" "" "$(field "$out" result-json)"
assert_eq "invalid result → is-error=true" "true" "$(field "$out" is-error)"
rc=0; RESULT_FILE='' bash "$EXPORT" >/dev/null 2>&1 || rc=$?
assert_eq "missing RESULT_FILE → exit 2" "2" "$rc"
: > "$T/go"; GITHUB_OUTPUT="$T/go" RESULT_FILE="$FIX/result-success-cheap.json" bash "$EXPORT" >/dev/null
assert_eq "writes exactly three single-line outputs" "3" "$(wc -l < "$T/go" | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then printf '  - %s\n' "${FAIL_NAMES[@]}"; exit 1; fi
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run-gate-evidence-tests.sh` → fails (script missing).

- [ ] **Step 3: Implement `scripts/export-result-output.sh`:**

```bash
#!/usr/bin/env bash
#
# export-result-output.sh — hands an agent job's canonical result to its gate
# job as job outputs (#535, ADR-020). Runs in the implement job AFTER the agent,
# so everything it emits is evidence, not a decision: the gate re-validates it.
#
# Required env:
#   RESULT_FILE       canonical result JSON (ADR-001 §2)
# Optional env:
#   EXECUTION_FILE    raw agent stream (Claude array/NDJSON or opencode NDJSON)
#   RESULT_TEXT_HALF  chars kept from each end of .result (default 4000)
# Outputs ($GITHUB_OUTPUT, else stdout), one line each:
#   result-json       compact result, .result elided; empty if not a JSON object
#   execution-usage   compact array of usage-bearing events only ([] if none)
#   is-error          true|false — a local hint for salvage, never a verdict
# Exit: 0; 2 RESULT_FILE unset.
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${RESULT_FILE:-}" ]]; then
  printf 'error: RESULT_FILE must be set\n' >&2
  exit 2
fi
half="${RESULT_TEXT_HALF:-4000}"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

compact_result() {
  jq -ce --argjson h "$half" '
    select(type == "object")
    | if (.result | type) == "string" and (.result | length) > ($h * 2)
      then .result = (.result[0:$h] + "\n[... elided by export-result-output.sh ...]\n" + .result[-$h:])
      else . end' "$RESULT_FILE" 2>/dev/null || true
}

usage_events() {
  [[ -n "${EXECUTION_FILE:-}" && -r "$EXECUTION_FILE" ]] || { printf '[]'; return; }
  jq -cs '
    (if length == 1 and (.[0] | type) == "array" then .[0] else . end) as $ev
    | [ $ev[] | select(type == "object" and .type == "assistant")
        | {type, message: {usage: (.message.usage // {})}} ]
    + [ $ev[] | select(type == "object" and .type == "step_finish")
        | {type, part: {tokens: (.part.tokens // {})}} ]' \
    "$EXECUTION_FILE" 2>/dev/null || printf '[]'
}

result_json="$(compact_result)"
is_error=true
if [[ -n "$result_json" ]]; then
  is_error="$(printf '%s' "$result_json" | jq -r '(.is_error == true) or ((.subtype // "") | startswith("error_"))')"
fi

emit result-json "$result_json"
emit execution-usage "$(usage_events)"
emit is-error "$is_error"
```

- [ ] **Step 4: Run** `bash tests/run-gate-evidence-tests.sh` → all pass. If the opencode-shape assertion fails because the fixture is a JSON array rather than NDJSON, keep the script (it handles both) and fix only the test's expected-value `jq` to unwrap the array the same way.

- [ ] **Step 5: Commit** — `feat(security): export the implement result as job outputs (#535)`.

### Task 2: Import and validate the evidence in a gate

**Files:**
- Create: `scripts/import-result-output.sh`
- Test: `tests/run-gate-evidence-tests.sh`

**Interfaces:**
- Consumes env: `RESULT_JSON` (may be empty), `EXECUTION_USAGE` (may be empty), `OUT_DIR` (optional, default `$RUNNER_TEMP` or a `mktemp -d`).
- Produces: `result-file=<path>`, `execution-file=<path or empty>`, `valid=true|false`.

- [ ] **Step 1: Add failing tests** (before the summary block of `tests/run-gate-evidence-tests.sh`; add `IMPORT="$ROOT/scripts/import-result-output.sh"` next to `EXPORT`):

```bash
section "import: a valid result round-trips"
rj="$(jq -c . "$FIX/result-success-cheap.json")"
out="$(RESULT_JSON="$rj" EXECUTION_USAGE='[]' OUT_DIR="$T/imp1" bash "$IMPORT")"
assert_eq "valid=true" "true" "$(field "$out" valid)"
assert_eq "result file holds the result" "$rj" "$(jq -c . "$(field "$out" result-file)")"
assert_eq "an empty usage array still yields a file" "[]" "$(jq -c . "$(field "$out" execution-file)")"

section "import: anything else becomes a synthetic failure"
for bad in '' '{not json' '[]' '{"type":"assistant","is_error":false}' '{"type":"result","is_error":"no"}'; do
  out="$(RESULT_JSON="$bad" OUT_DIR="$T/imp-bad" bash "$IMPORT" 2>/dev/null)"
  rf="$(field "$out" result-file)"
  assert_eq "valid=false for: ${bad:-<empty>}" "false" "$(field "$out" valid)"
  assert_eq "synthetic result is an error for: ${bad:-<empty>}" "true error_invalid_evidence" \
    "$(jq -r '"\(.is_error) \(.subtype)"' "$rf")"
  assert_eq "classifies as bug for: ${bad:-<empty>}" "class=bug" \
    "$(RESULT_FILE="$rf" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"
done

section "import: usage that is not an array is dropped"
out="$(RESULT_JSON="$rj" EXECUTION_USAGE='{"x":1}' OUT_DIR="$T/imp3" bash "$IMPORT")"
assert_eq "no execution file" "" "$(field "$out" execution-file)"

section "export → import end to end"
ex="$(RESULT_FILE="$FIX/result-opencode-rate-limit.json" bash "$EXPORT")"
out="$(RESULT_JSON="$(field "$ex" result-json)" EXECUTION_USAGE="$(field "$ex" execution-usage)" OUT_DIR="$T/imp4" bash "$IMPORT")"
assert_eq "a rate limit survives the hand-over" "class=rate_limit" \
  "$(RESULT_FILE="$(field "$out" result-file)" bash "$ROOT/scripts/classify-failure.sh" | tail -1)"
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `scripts/import-result-output.sh`:**

```bash
#!/usr/bin/env bash
#
# import-result-output.sh — the gate side of the evidence hand-over (#535,
# ADR-020). Writes the agent job's result back to a file for classify-failure.sh
# / post-run-report.sh, after checking its shape. Anything that is not a
# canonical result object — including an empty value, which is also what GitHub
# leaves when it drops an output it thinks holds a secret — becomes a synthetic
# failure, so a missing result is reported, never silently skipped.
#
# Optional env:
#   RESULT_JSON      compact result from export-result-output.sh
#   EXECUTION_USAGE  compact usage array from export-result-output.sh
#   OUT_DIR          where to write (default $RUNNER_TEMP, else mktemp -d)
# Outputs: result-file, execution-file (empty when no usable array), valid
# Exit: 0 always.
set -euo pipefail
IFS=$'\n\t'

OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-$(mktemp -d)}}"
mkdir -p "$OUT_DIR"
result_file="$OUT_DIR/claude-result.json"
usage_file="$OUT_DIR/execution-usage.json"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

is_canonical() {
  printf '%s' "${RESULT_JSON:-}" \
    | jq -e 'type == "object" and .type == "result" and (.is_error | type) == "boolean"' >/dev/null 2>&1
}

write_synthetic() {
  jq -n '{type: "result", subtype: "error_invalid_evidence", is_error: true,
          duration_ms: 0, num_turns: 0, total_cost_usd: 0, session_id: "gate",
          result: "The gate received no valid result evidence from the implement job.",
          usage: {input_tokens: 0, output_tokens: 0,
                  cache_creation_input_tokens: 0, cache_read_input_tokens: 0}}' > "$result_file"
}

if is_canonical; then
  printf '%s' "$RESULT_JSON" | jq . > "$result_file"
  valid=true
else
  write_synthetic
  valid=false
  printf '::warning title=No valid result evidence::the implement job handed over no canonical result; reporting the run as failed\n'
fi

execution_file=''
if printf '%s' "${EXECUTION_USAGE:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  printf '%s' "$EXECUTION_USAGE" > "$usage_file"
  execution_file="$usage_file"
fi

emit result-file "$result_file"
emit execution-file "$execution_file"
emit valid "$valid"
```

- [ ] **Step 4: Run** `bash tests/run-gate-evidence-tests.sh` → all pass.

- [ ] **Step 5: Commit** — `feat(security): validate agent evidence in the gate (#535)`.

### Task 3: Structural test — no decision after an agent step

**Files:**
- Create: `tests/run-agent-isolation-tests.sh`

**Interfaces:**
- Produces: a Layer-1 runner; `PENDING_JOBS` (bash array) lists jobs not yet converted. Tasks 6 and 7 empty it.

- [ ] **Step 1: Write the test** (it must fail on the current workflow for `implement`):

```bash
#!/usr/bin/env bash
#
# run-agent-isolation-tests.sh — structural guard for ADR-020 (#535): in any job
# of agent-implement.yml, no step after the first agent step runs a decision
# script; every job that runs a decision script after an agent ran upstream has
# its own pipeline-ref checkout and no agent step; and no run: block
# interpolates another job's outputs.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/agent-implement.yml"
# Jobs not yet split. Task 6 removes ai_review_ai_merge, Task 7 ai_review_human_merge.
PENDING_JOBS=(ai_review_ai_merge ai_review_human_merge)

out="$(python3 - "$WF" "${PENDING_JOBS[@]}" <<'PY'
import sys, yaml
wf, pending = sys.argv[1], set(sys.argv[2:])
jobs = yaml.safe_load(open(wf))["jobs"]
AGENT = ("anthropics/claude-code-base-action", "opencode run", "review-pr.sh", "self-fix-loop.sh")
DECIDE = ("classify-failure.sh", "pipeline-pause.sh", "notify-ntfy.sh", "retry-dispatch.sh",
          "post-run-report.sh", "plan-coverage-step.sh", "check-pr-checks-runnable.sh",
          "ensure-issue-labels.sh", "check-merge-envelope.sh", "post-auto-review-block.sh",
          "check-verdict-binding.sh", "gh pr merge", "gh pr ready", "outcome=")
def text(step): return f'{step.get("uses","")}\n{step.get("run","")}'
problems = []
for name, job in jobs.items():
    steps = job.get("steps") or []
    agent_at = next((i for i, s in enumerate(steps) if any(m in text(s) for m in AGENT)), None)
    for s in steps:
        if "${{ needs." in (s.get("run") or ""):
            problems.append(f"{name}: run: interpolates needs.* in '{s.get('name')}'")
    if name in pending or agent_at is None:
        continue
    for s in steps[agent_at + 1:]:
        hit = [m for m in DECIDE if m in text(s)]
        if hit:
            problems.append(f"{name}: '{s.get('name')}' runs {hit[0]} after an agent step")
for name, job in jobs.items():
    steps = job.get("steps") or []
    if any(any(m in text(s) for m in AGENT) for s in steps):
        continue
    if any(any(m in text(s) for m in DECIDE) for s in steps):
        refs = [s for s in steps if (s.get("with") or {}).get("ref") == "${{ inputs.pipeline-ref }}"]
        if not refs:
            problems.append(f"{name}: decides but has no pipeline-ref checkout of its own")
print("\n".join(problems))
PY
)"

if [[ -z "$out" ]]; then
  printf '  ✓ no decision runs after an agent step, gates check out their own pipeline\n'
  exit 0
fi
printf '  ✗ agent isolation (ADR-020):\n%s\n' "$out" | sed 's/^/      /'
exit 1
```

- [ ] **Step 2: Run** `bash tests/run-agent-isolation-tests.sh` → fails, listing `implement: 'Classify failure' runs classify-failure.sh after an agent step` and the other implement post-run steps. Do **not** commit a red suite: commit this test together with Task 4.

### Task 4: Split the implement job — `implement_gate`

**Files:**
- Modify: `.github/workflows/agent-implement.yml`
- Modify: `tests/run-script-tests.sh`
- Modify: `tests/run-pipeline-alarm-tests.sh`
- Modify: `tests/run-plan-coverage-tests.sh`
- Modify: `tests/run-agent-isolation-tests.sh`

**Interfaces:**
- Consumes: `scripts/export-result-output.sh`, `scripts/import-result-output.sh`.
- Produces: job `implement_gate` with outputs `outcome, cost-usd, num-turns, failure-class, retry-decision, plan-coverage`; new implement outputs `agent-eligible, result-json, execution-usage, max-turns, has-plan, salvaged`; input `gate-runner-labels`.

- [ ] **Step 1: Update the structural assertions first (they must fail against the current file):**
  - `tests/run-script-tests.sh` section `#439` (`:4576-4593`): extract `implement_gate` instead of `implement` — change the awk pattern `'/^  implement:$/{f=1;next} ...'` to `'/^  implement_gate:$/{f=1;next} ...'`, rename variables `impl439`/messages to say "the implement gate job's LAST step"; keep all four `assert_contains`.
  - Section `#430` (`:4468-4527`): pipeline-ref checkouts `3` → `4`, `id: app_token` `3` → `4` ("all four jobs that call the App mint their own token"), `PIPELINE_APP_ID: ..{ secrets` `3` → `4`, `GH_TOKEN: ..{ steps.app_token` `13` → `14` with message `"App token consumers: 6 implement + 4 implement gate + 2 self-fix + 2 AI-merge checks readers (#482, #535)"`.
  - Add after the `#439` section:

```bash
section "agent-implement.yml — implement evidence goes to a gate job (#535)"
WF535="$ROOT/.github/workflows/agent-implement.yml"
gate535="$(awk '/^  implement_gate:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$WF535")"
assert_contains "$gate535" 'needs: implement' "the gate needs the implement job"
assert_contains "$gate535" "needs.implement.outputs.agent-eligible == 'true'" "the gate runs whenever the agent was due"
assert_contains "$gate535" 'RESULT_JSON: ${{ needs.implement.outputs.result-json }}' "the result arrives through env"
assert_contains "$gate535" 'persist-credentials: false' "the gate's consumer checkout keeps no token"
for o in outcome cost-usd num-turns failure-class retry-decision; do
  assert_contains "$(cat "$WF535")" "value: \${{ jobs.implement_gate.outputs.$o }}" "workflow output $o comes from the gate"
done
```

  - `tests/run-pipeline-alarm-tests.sh:779-781`: the count of `steps.pause_gate.outputs.paused != 'true'` goes `3` → `4`, message "attempt cap, Claude, OpenCode and the gate's agent-eligible output are all gated".
  - `tests/run-plan-coverage-tests.sh:325`: the AI-merge coverage grep becomes `&& (inputs.dry-run || needs.implement_gate.outputs.plan-coverage == 'complete')`; the message "the implement job exports plan-coverage" becomes "the implement gate exports plan-coverage" (same regex).

  Run `bash tests/run-all.sh` → the new and changed assertions fail. Any other structural assertion that breaks in Step 8 is re-targeted at the job the step moved to, never loosened or deleted.

- [ ] **Step 2: Add the input** after `runner-labels` (`:10-13`):

```yaml
      gate-runner-labels:
        description: |
          JSON array of runner labels for the gate jobs, which never run an
          agent (#535, ADR-020). Empty uses `runner-labels`. On persistent
          self-hosted runners point this at GitHub-hosted or ephemeral runners:
          an agent can leave changes in $HOME that a later job on the same
          machine inherits.
        type: string
        default: ''
```

- [ ] **Step 3: Re-point the workflow outputs** (`:320-334`): `outcome`, `cost-usd`, `num-turns`, `failure-class`, `retry-decision` read `jobs.implement_gate.outputs.<same-name>`.

- [ ] **Step 4: Change the implement job:**
  - Replace its `outputs:` (`:416-426`) with:

```yaml
    outputs:
      ai-review-ai-merge-enabled:    ${{ steps.ai_merge_gate.outputs.enabled || steps.ai_merge_gate_stub.outputs.enabled }}
      ai-review-human-merge-enabled: ${{ steps.human_merge_gate.outputs.enabled || steps.human_merge_gate_stub.outputs.enabled }}
      agent:               ${{ steps.classify_agent.outputs.agent || inputs.agent }}
      model:               ${{ steps.triage.outputs.model || inputs.default-model }}
      # Trusted: every step above finished before the first agent step (#535).
      max-turns:           ${{ steps.triage_turns.outputs.turns }}
      has-plan:            ${{ steps.issue.outputs.has-plan }}
      agent-eligible:      ${{ steps.agent_reached.outputs.reached == 'true' && steps.pause_gate.outputs.paused != 'true' && steps.attempt_cap.outputs.proceed != 'false' }}
      # Evidence: produced after the agent ran, re-validated by implement_gate.
      result-json:         ${{ steps.export_result.outputs.result-json }}
      execution-usage:     ${{ steps.export_result.outputs.execution-usage }}
      salvaged:            ${{ steps.verify_pr.outputs.salvaged }}
```

  - Insert immediately before `- name: Run Claude Code` (`:708`):

```yaml
      - name: Mark the agent step reached
        # #535: its output is captured before any agent runs, so the gate can
        # trust "an agent was due" even when no result comes back.
        id: agent_reached
        run: printf 'reached=true\n' >> "$GITHUB_OUTPUT"
```

  - Insert after `- name: Adapt execution_file -> result.json` (after `:975`):

```yaml
      - name: Export result for the gate
        # #535 / ADR-020: everything from here on is evidence. implement_gate
        # makes every decision from these outputs on its own runner.
        id: export_result
        if: always() && (steps.claude.outputs.result-file != '' || steps.opencode_adapt.outputs.result-file != '' || steps.stub_run.outputs.result-file != '')
        env:
          RESULT_FILE: ${{ steps.claude.outputs.result-file || steps.opencode_adapt.outputs.result-file || steps.stub_run.outputs.result-file }}
          EXECUTION_FILE: ${{ steps.claude.outputs.execution-file || steps.opencode_adapt.outputs.execution-file }}
        run: bash .claude-pipeline/scripts/export-result-output.sh
```

  - In `Verify or recover PR` (`:1077-1089`) change only `IS_ERROR:` to `IS_ERROR: ${{ steps.export_result.outputs.is-error }}`.
  - **Cut** these steps out of the implement job (they move in Step 5): `Classify failure`, `Raise pipeline alarm`, `Alert on model not found`, `Plan retry`, `Extract job outputs from result.json`, `Ensure issue labels exist`, `Check plan coverage`, `Check the PR's required checks can run`, `Post run report`, `Fail the job when the agent run failed`. `Verify or recover PR` stays and is now the implement job's last step.

- [ ] **Step 5: Add the gate job** between `implement` and `ai_review_ai_merge`:

```yaml
  implement_gate:
    # #535 / ADR-020: every decision about the implement run. Own runner, own
    # fresh checkouts, never an agent. Inputs are the implement job's outputs:
    # pre-agent ones are trusted, result-json / execution-usage are evidence.
    name: Judge implement run — issue #${{ inputs.issue-number }}
    needs: implement
    if: ${{ !cancelled() && needs.implement.outputs.agent-eligible == 'true' }}
    runs-on: ${{ fromJSON(inputs.gate-runner-labels != '' && inputs.gate-runner-labels || inputs.runner-labels) }}
    timeout-minutes: 15
    permissions:
      contents: read
      pull-requests: read
      issues: write
      # retry-dispatch.sh ends in `gh workflow run` (#351).
      actions: write
    env:
      PIPELINE_APP_ID: ${{ secrets.PIPELINE_APP_ID }}
    outputs:
      outcome:        ${{ steps.outputs.outputs.outcome }}
      cost-usd:       ${{ steps.outputs.outputs.cost-usd }}
      num-turns:      ${{ steps.outputs.outputs.num-turns }}
      failure-class:  ${{ steps.classify_failure.outputs.class }}
      retry-decision: ${{ steps.retry.outputs.decision }}
      plan-coverage:  ${{ steps.plan_coverage.outputs.coverage }}
    steps:
      # 1. `Mint pipeline App token (optional)` — copy of the implement job's (id: app_token).
      - name: Checkout consumer repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          persist-credentials: false
      # 2. `Checkout agent-workflow scripts` and `Mirror local scripts to
      #    .claude-pipeline (self-test mode)` — copies of the implement job's.
      - name: Ensure toolchain
        run: bash .claude-pipeline/scripts/ensure-toolchain.sh
      - name: Import the implement job's result
        id: result
        env:
          RESULT_JSON: ${{ needs.implement.outputs.result-json }}
          EXECUTION_USAGE: ${{ needs.implement.outputs.execution-usage }}
        run: bash .claude-pipeline/scripts/import-result-output.sh
      # 3. The ten steps cut in Task 4 Step 4, in their original order, with the
      #    edits listed below. Insert `Find pipeline-opened PR` (below) right
      #    after `Ensure issue labels exist`.
```

  Edits to the moved steps (everything else verbatim):
  - Every `steps.claude.outputs.result-file || steps.opencode_adapt.outputs.result-file || steps.stub_run.outputs.result-file` → `steps.result.outputs.result-file`; every `if:` test on those three → `steps.result.outputs.result-file != ''`.
  - `Post run report`: `EXECUTION_FILE: ${{ steps.result.outputs.execution-file }}`, `MODEL: ${{ needs.implement.outputs.model }}`, `AGENT: ${{ needs.implement.outputs.agent }}`, `MAX_TURNS: ${{ needs.implement.outputs.max-turns }}`, `HAS_PLAN: ${{ needs.implement.outputs.has-plan }}`, `SALVAGED: ${{ needs.implement.outputs.salvaged }}`, `PR_PRESENT: ${{ !inputs.dry-run && (steps.find_pr.outputs.found || 'false') || '' }}`, `CHECKS_*`/`PLAN_COVERAGE*`/`MISSING_TASKS` unchanged (same step ids).
  - `Alert on model not found`: `steps.triage.outputs.model || inputs.default-model` → `needs.implement.outputs.model`.
  - `Check plan coverage` and `Check the PR's required checks can run`: `if:` → `always() && !inputs.dry-run && steps.find_pr.outputs.found == 'true'`; `PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}`.
  - New step:

```yaml
      - name: Find pipeline-opened PR
        # The gate's own lookup (#535). verify-or-recover-pr.sh ran in the
        # implement job and may have opened the PR, but its outputs are evidence.
        # Mirrors its IS_ERROR short-circuit: a failed run reports no PR.
        id: find_pr
        if: always() && !inputs.dry-run && steps.outputs.outputs.outcome == 'success'
        env:
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          AUTHOR_ALLOWLIST: ${{ inputs.pipeline-author-allowlist }}
        run: bash .claude-pipeline/scripts/find-pipeline-pr.sh
```

- [ ] **Step 6: Re-point both review jobs** (`ai_review_ai_merge` `:1187-1194`, `ai_review_human_merge` `:1616-1621`): `needs: [implement, implement_gate]`; prefix the `if:` with `!cancelled() && needs.implement_gate.result == 'success' &&`; `needs.implement.outputs.outcome` → `needs.implement_gate.outputs.outcome`; `needs.implement.outputs.plan-coverage` → `needs.implement_gate.outputs.plan-coverage`. Leave the `*-enabled`, `agent`, `model` references on `needs.implement`.

- [ ] **Step 7: Narrow `PENDING_JOBS`** in `tests/run-agent-isolation-tests.sh` — unchanged (`ai_review_ai_merge ai_review_human_merge`); the test must now pass for `implement` and `implement_gate`.

- [ ] **Step 8: Verify** — `actionlint .github/workflows/*.yml`; `bash tests/run-all.sh` (all green, including `run-caller-permissions-tests.sh`, `run-pipeline-alarm-tests.sh`, `run-plan-coverage-tests.sh`, `run-opencode-model-tests.sh`); `just test-act` if Docker is available — every `verify-*` job in `agent-implement.test.yml` passes unchanged, which proves the stub results travel export → job output → import.

- [ ] **Step 9: Commit** — `fix(security): judge the implement run in a separate gate job (#535)` (includes Task 3's test file).

### Task 5: Verdict binding and the new block reasons

**Files:**
- Create: `scripts/check-verdict-binding.sh`
- Modify: `scripts/post-auto-review-block.sh`
- Test: `tests/run-gate-evidence-tests.sh`

**Interfaces:**
- `check-verdict-binding.sh` env: `REVIEW_PR_NUMBER` (required), `CLAIMED_HEAD_SHA`, `GATE_FOUND`, `GATE_PR_NUMBER`, `GATE_HEAD_SHA`. Outputs `bound=true|false`, `reason=<text>`. Exit 0; 2 when `REVIEW_PR_NUMBER` is unset.
- `post-auto-review-block.sh` new optional env: `BINDING_REASON`, `PLAN_COVERAGE`.

- [ ] **Step 1: Add failing tests** to `tests/run-gate-evidence-tests.sh` (add `BIND="$ROOT/scripts/check-verdict-binding.sh"`, `BLOCK="$ROOT/scripts/post-auto-review-block.sh"`, `MOCKS="$ROOT/tests/mocks"`):

```bash
section "binding"
bind() { env REVIEW_PR_NUMBER=7 CLAIMED_HEAD_SHA=abc1234567 GATE_FOUND=true GATE_PR_NUMBER=7 GATE_HEAD_SHA=abc1234567 "$@" bash "$BIND"; }
assert_eq "same PR, same head → bound" "true" "$(field "$(bind)" bound)"
out="$(bind GATE_HEAD_SHA=def7654321)"
assert_eq "head moved → not bound" "false" "$(field "$out" bound)"
assert_eq "head moved → reason names both heads" "PR head moved: reviewed abc1234, now def7654" "$(field "$out" reason)"
assert_eq "other PR → not bound" "the review job reviewed PR #7, the gate found PR #8" "$(field "$(bind GATE_PR_NUMBER=8)" reason)"
assert_eq "gate found none → not bound" "the gate found no pipeline PR for the issue" "$(field "$(bind GATE_FOUND=false)" reason)"
assert_eq "no claimed head → not bound" "the review job reported no head SHA" "$(field "$(bind CLAIMED_HEAD_SHA=)" reason)"
rc=0; env REVIEW_PR_NUMBER= bash "$BIND" >/dev/null 2>&1 || rc=$?
assert_eq "missing REVIEW_PR_NUMBER → exit 2" "2" "$rc"

section "block reasons"
block() { local log="$T/gh.log"; : > "$log"; env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$log" REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=approve "$@" bash "$BLOCK" >/dev/null; cat "$log"; }
calls="$(block BINDING_REASON='PR head moved: reviewed abc1234, now def7654')"
if [[ "$calls" == *'Auto-merge held: verdict not bound to the PR head — PR head moved: reviewed abc1234, now def7654'* ]]; then pass "binding failure is the reason"; else fail "binding failure is the reason" "$calls"; fi
calls="$(block PLAN_COVERAGE=partial)"
if [[ "$calls" == *'Auto-merge held: plan coverage on the final head is partial'* ]]; then pass "coverage is the reason"; else fail "coverage is the reason" "$calls"; fi
calls="$(block VERDICT=block BINDING_REASON=x)"
if [[ "$calls" == *'agent review verdict: block (gate 4)'* ]]; then pass "a non-approve verdict still wins"; else fail "a non-approve verdict still wins" "$calls"; fi
calls="$(block PLAN_COVERAGE=complete ENVELOPE=fail ENVELOPE_REASON=checks)"
if [[ "$calls" == *'merge-envelope failed: checks'* ]]; then pass "complete coverage falls through to the envelope"; else fail "complete coverage falls through to the envelope" "$calls"; fi
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `scripts/check-verdict-binding.sh`:**

```bash
#!/usr/bin/env bash
#
# check-verdict-binding.sh — binds a review verdict to the PR the gate itself
# sees (#535, ADR-020). REVIEW_PR_NUMBER is trusted (found before any agent ran);
# CLAIMED_HEAD_SHA is evidence (after self-fix it comes from the agent's job).
# The gate's own find-pipeline-pr.sh lookup must agree with both.
#
# Required env: REVIEW_PR_NUMBER
# Optional env: CLAIMED_HEAD_SHA, GATE_FOUND, GATE_PR_NUMBER, GATE_HEAD_SHA
# Outputs: bound=true|false, reason=<text, empty when bound>
# Exit: 0; 2 REVIEW_PR_NUMBER unset.
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${REVIEW_PR_NUMBER:-}" ]]; then
  printf 'error: REVIEW_PR_NUMBER must be set\n' >&2
  exit 2
fi

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { printf 'bound=%s\n' "$1"; printf 'reason=%s\n' "$2"; } >> "$GITHUB_OUTPUT"
  fi
  printf 'bound=%s\nreason=%s\n' "$1" "$2"
}

claimed="${CLAIMED_HEAD_SHA:-}"
gate_head="${GATE_HEAD_SHA:-}"
if [[ "${GATE_FOUND:-false}" != "true" ]]; then
  emit false "the gate found no pipeline PR for the issue"
elif [[ "${GATE_PR_NUMBER:-}" != "$REVIEW_PR_NUMBER" ]]; then
  emit false "the review job reviewed PR #${REVIEW_PR_NUMBER}, the gate found PR #${GATE_PR_NUMBER:-}"
elif [[ -z "$claimed" ]]; then
  emit false "the review job reported no head SHA"
elif [[ "$claimed" != "$gate_head" ]]; then
  emit false "PR head moved: reviewed ${claimed:0:7}, now ${gate_head:0:7}"
else
  emit true ""
fi
```

- [ ] **Step 4: Extend `scripts/post-auto-review-block.sh`:** document `BINDING_REASON` and `PLAN_COVERAGE` in the header's optional-env list; read them with the other defaults (`BINDING_REASON="${BINDING_REASON:-}"`, `PLAN_COVERAGE="${PLAN_COVERAGE:-}"`); in the reason chain insert, between the `VERDICT != approve` branch and the final `else` (envelope):

```bash
elif [[ -n "$BINDING_REASON" ]]; then
  reason="verdict not bound to the PR head — ${BINDING_REASON}"
elif [[ -n "$PLAN_COVERAGE" && "$PLAN_COVERAGE" != 'complete' ]]; then
  reason="plan coverage on the final head is ${PLAN_COVERAGE}"
```

  Also update the header's caller list ("Called from the review gate jobs").

- [ ] **Step 5: Run** `bash tests/run-all.sh` → green (existing `POST_BLOCK` tests in `tests/run-script-tests.sh` unchanged).

- [ ] **Step 6: Commit** — `feat(security): bind the review verdict to the gate's PR head (#535)`.

### Task 6: Split the AI-merge review job — `ai_review_ai_merge_gate`

**Files:**
- Modify: `.github/workflows/agent-implement.yml`
- Modify: `tests/run-script-tests.sh`
- Modify: `tests/run-agent-isolation-tests.sh`

**Interfaces:**
- Produces: `ai_review_ai_merge` outputs `self-mod-blocked, found, pr-number, first-verdict, verdict, head-sha, reason, self-fix-outcome, self-fix-iterations-used`; job `ai_review_ai_merge_gate` outputs `merge-attempted, outcome-label`.

- [ ] **Step 1: Tests first.** In `tests/run-agent-isolation-tests.sh` set `PENDING_JOBS=(ai_review_human_merge)`. In `tests/run-script-tests.sh`:
  - `#474` (`:1756-1767`): `SELF_FIX_OUTCOME: ${{ steps.self_fix.outcome }}` count `2` → count of `SELF_FIX_OUTCOME: ${{ needs.ai_review_` equals `1` (Task 7 makes it `2`); keep the two `self_fix_blocks` asserts and the `timeout-minutes: 45` assert (review jobs keep 45; gates use 15).
  - `#490` (`:1829`): count of `REVIEW_REASON: ${{ steps.review.outputs.reason }}` `2` → count of `REVIEW_REASON: ${{ needs.ai_review_` equals `1` (Task 7: `2`), message "blocked steps in the gate jobs pass the review reason (#490, #535)".
  - `#430`: pipeline-ref checkouts `4` → `5`; `id: app_token` and `PIPELINE_APP_ID` `4` → `5`; `GH_TOKEN: ..{ steps.app_token` `14` → `15` ("6 implement + 4 implement gate + 2 self-fix + 3 AI-merge gate").
  - Add:

```bash
section "agent-implement.yml — the AI-merge decision runs in its own gate (#535)"
aigate="$(awk '/^  ai_review_ai_merge_gate:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$ROOT/.github/workflows/agent-implement.yml")"
assert_contains "$aigate" "needs.ai_review_ai_merge.result == 'success'" "the gate runs after a completed review job"
assert_contains "$aigate" '--match-head-commit "$HEAD_SHA"' "the merge is pinned to the gate's head"
assert_contains "$aigate" 'check-verdict-binding.sh' "the verdict is bound to the PR head"
assert_contains "$aigate" 'plan-coverage-step.sh' "plan coverage is recomputed on the final head"
assert_contains "$aigate" "needs.ai_review_ai_merge.outputs.self-fix-outcome == 'skipped' && needs.ai_review_ai_merge.outputs.first-verdict" \
  "without self-fix the gate uses the pre-agent verdict"
```

  Run → fails.

- [ ] **Step 2: Re-point workflow outputs** (`:353-368`): `ai-review-ai-merge-merge-attempted` → `jobs.ai_review_ai_merge_gate.outputs.merge-attempted`; `ai-review-ai-merge-outcome-label` → `jobs.ai_review_ai_merge_gate.outputs.outcome-label`. `ai-review-ai-merge-self-fix-iterations-used` stays on `ai_review_ai_merge`.

- [ ] **Step 3: Producer job `ai_review_ai_merge`:** replace `outputs:` (`:1212-1215`) with:

```yaml
    outputs:
      # Trusted: captured before any bash agent ran in this job (#535).
      self-mod-blocked: ${{ steps.self_mod_guard.outputs.blocked }}
      found:            ${{ steps.find_pr.outputs.found }}
      pr-number:        ${{ steps.find_pr.outputs.pr-number }}
      first-verdict:    ${{ steps.verdict.outputs.value }}
      self-fix-outcome: ${{ steps.self_fix.outcome }}
      # Evidence: forgeable once the self-fix agent ran.
      verdict:          ${{ steps.final.outputs.verdict }}
      head-sha:         ${{ steps.self_fix.outputs.head-sha || steps.find_pr.outputs.head-sha }}
      reason:           ${{ steps.review.outputs.reason }}
      self-fix-iterations-used: ${{ steps.final.outputs.iterations-used }}
```

  **Cut** `Wait for required checks (post self-fix approve)`, `Check merge envelope`, `Promote draft to ready + enable auto-merge`, `Mark issue blocked when review or envelope refuses`, `Verify gh mock log (test mode)`. The job now ends at `Resolve final verdict (post self-fix)`. Keep `timeout-minutes: 45`.

- [ ] **Step 4: Gate job** after `ai_review_ai_merge`:

```yaml
  ai_review_ai_merge_gate:
    # #535 / ADR-020: the AI-merge decision, on its own runner, never an agent.
    name: Gate AI merge — PR for issue #${{ inputs.issue-number }}
    needs: [implement, implement_gate, ai_review_ai_merge]
    if: ${{ !cancelled() && needs.ai_review_ai_merge.result == 'success' }}
    runs-on: ${{ fromJSON(inputs.gate-runner-labels != '' && inputs.gate-runner-labels || inputs.runner-labels) }}
    timeout-minutes: 15
    env:
      PIPELINE_APP_ID: ${{ secrets.PIPELINE_APP_ID }}
    permissions:
      contents: write
      pull-requests: write
      issues: write
    outputs:
      merge-attempted: ${{ steps.verify_mock.outputs.merge-attempted }}
      outcome-label:   ${{ steps.verify_mock.outputs.outcome-label }}
    steps:
      # Copies of the producer job's: `Mint pipeline App token (optional)`,
      # `Checkout consumer repo` (+ `with: persist-credentials: false`; it
      # supplies .claude-auto-merge-blocklist from the default branch),
      # `Checkout agent-workflow scripts`, `Mirror local scripts ...`,
      # `Wire gh mock + stub PR JSON (test mode)`, `Find pipeline-opened PR`
      # (id: find_pr, add `if: needs.ai_review_ai_merge.outputs.found == 'true'`).
      - name: Resolve gated verdict
        # Without self-fix no bash agent ran, so the first verdict is trusted.
        id: verdict
        env:
          VERDICT: ${{ needs.ai_review_ai_merge.outputs.self-fix-outcome == 'skipped' && needs.ai_review_ai_merge.outputs.first-verdict || needs.ai_review_ai_merge.outputs.verdict }}
          ITERATIONS: ${{ needs.ai_review_ai_merge.outputs.self-fix-iterations-used }}
        run: |
          printf 'value=%s\n' "$VERDICT" >> "$GITHUB_OUTPUT"
          printf 'iterations-used=%s\n' "${ITERATIONS:-0}" >> "$GITHUB_OUTPUT"
      - name: Check verdict binding
        id: binding
        if: |
          needs.ai_review_ai_merge.outputs.self-mod-blocked != 'true'
          && needs.ai_review_ai_merge.outputs.found == 'true'
          && steps.verdict.outputs.value == 'approve'
        env:
          REVIEW_PR_NUMBER: ${{ needs.ai_review_ai_merge.outputs.pr-number }}
          CLAIMED_HEAD_SHA: ${{ needs.ai_review_ai_merge.outputs.head-sha }}
          GATE_FOUND: ${{ steps.find_pr.outputs.found }}
          GATE_PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          GATE_HEAD_SHA: ${{ steps.find_pr.outputs.head-sha }}
        run: bash .claude-pipeline/scripts/check-verdict-binding.sh
      - name: Recheck plan coverage on the final head
        id: coverage
        continue-on-error: true
        if: steps.binding.outputs.bound == 'true' && !inputs.dry-run
        env:
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
        run: bash .claude-pipeline/scripts/plan-coverage-step.sh
```

  Then the four cut steps, in order, with these edits (rest verbatim):
  - `Wait for required checks (post self-fix approve)`: `if:` → `steps.binding.outputs.bound == 'true' && steps.verdict.outputs.iterations-used != '0' && inputs.stub-review-verdict == ''`; `PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}`.
  - `Check merge envelope`: `if:` → `steps.binding.outputs.bound == 'true' && (inputs.dry-run || steps.coverage.outputs.coverage == 'complete')`.
  - `Promote draft to ready + enable auto-merge`: `if:` → `steps.binding.outputs.bound == 'true' && steps.envelope.outputs.envelope == 'pass'`; add `HEAD_SHA: ${{ steps.find_pr.outputs.head-sha }}` to `env:`; second command becomes `gh pr merge "$PR_NUMBER" --repo "$REPO" --auto --squash --match-head-commit "$HEAD_SHA"`.
  - `Mark issue blocked when review or envelope refuses`: `if:` →

```yaml
        if: |
          needs.ai_review_ai_merge.outputs.self-mod-blocked == 'true'
          || needs.ai_review_ai_merge.outputs.found != 'true'
          || steps.verdict.outputs.value != 'approve'
          || steps.binding.outputs.bound != 'true'
          || (!inputs.dry-run && steps.coverage.outputs.coverage != 'complete')
          || steps.envelope.outputs.envelope != 'pass'
```

    env: `PR_NUMBER`/`FOUND` from `needs.ai_review_ai_merge.outputs.{pr-number,found}`, `VERDICT: ${{ steps.verdict.outputs.value }}`, `REVIEW_REASON: ${{ needs.ai_review_ai_merge.outputs.reason }}`, `SELF_FIX_OUTCOME: ${{ needs.ai_review_ai_merge.outputs.self-fix-outcome }}`, `SELF_MOD_BLOCKED: ${{ needs.ai_review_ai_merge.outputs.self-mod-blocked }}`, `SELF_FIX_ITERATIONS: ${{ steps.verdict.outputs.iterations-used }}`, add `BINDING_REASON: ${{ steps.binding.outputs.reason }}` and `PLAN_COVERAGE: ${{ steps.coverage.outputs.coverage }}`; `ENVELOPE*`/`FAILED_GATES`/`SELF_FIX_MAX` unchanged.
  - Then `Verify gh mock log (test mode)` verbatim.

- [ ] **Step 5: Verify** — `actionlint`; `bash tests/run-all.sh`; `just test-act` if available: `verify-ai-merge-*` (approve-safe merges, unsafe-github / request-changes / block / review-failed do not, outcome label asserted, self-fix approve/exhausted) all pass. In the stub path the review job's `head-sha` and the gate's `find_pr` both read `stubsha`, so the binding holds.

- [ ] **Step 6: Commit** — `fix(security): decide AI merge in a separate gate job (#535)`.

### Task 7: Split the human-merge review job — `ai_review_human_merge_gate`

**Files:**
- Modify: `.github/workflows/agent-implement.yml`
- Modify: `tests/run-script-tests.sh`
- Modify: `tests/run-agent-isolation-tests.sh`

**Interfaces:**
- Produces: `ai_review_human_merge` outputs `found, pr-number, first-verdict, verdict, head-sha, reason, self-fix-outcome, self-fix-iterations-used`; job `ai_review_human_merge_gate` outputs `merge-attempted, ready-attempted`.

- [ ] **Step 1: Tests first.** `PENDING_JOBS=()` in `tests/run-agent-isolation-tests.sh` (keep the array, empty). In `tests/run-script-tests.sh`: the `SELF_FIX_OUTCOME: ${{ needs.ai_review_` and `REVIEW_REASON: ${{ needs.ai_review_` counts `1` → `2`; pipeline-ref checkouts `5` → `6`; `id: app_token`, `PIPELINE_APP_ID` and the App-token consumer count stay (`5`, `5`, `15` — this gate calls nothing that needs the App). Add:

```bash
hmgate="$(awk '/^  ai_review_human_merge_gate:$/{f=1;next} f && /^  [a-z_]+:$/{exit} f' "$ROOT/.github/workflows/agent-implement.yml")"
assert_contains "$hmgate" 'check-verdict-binding.sh' "human-merge promotion is bound to the PR head (#535)"
assert_not_contains "$hmgate" 'gh pr merge' "the human-merge gate never merges"
```

  Run → fails.

- [ ] **Step 2: Workflow outputs** (`:369-381`): `ai-review-human-merge-merge-attempted` and `-ready-attempted` → `jobs.ai_review_human_merge_gate.outputs.*`; self-fix iterations stays on `ai_review_human_merge`.

- [ ] **Step 3: Producer job** — outputs as Task 6 Step 3 minus `self-mod-blocked` (this job has no guard). Cut `Promote draft to ready (human-merge — no auto-merge)`, `Mark issue blocked when review refuses or PR missing`, `Verify gh mock log (test mode)`.

- [ ] **Step 4: Gate job** after it: same header shape as Task 6 Step 4 with `name: Gate human merge — PR for issue #${{ inputs.issue-number }}`, `needs: [implement, implement_gate, ai_review_human_merge]`, `if: ${{ !cancelled() && needs.ai_review_human_merge.result == 'success' }}`, `permissions: { contents: read, pull-requests: write, issues: write }`, no `env:`/mint, outputs `merge-attempted`/`ready-attempted` from `steps.verify_mock`. Steps: consumer checkout (`persist-credentials: false`), pipeline checkout + mirror, `Wire gh mock + stub PR JSON (test mode)`, `Find pipeline-opened PR` (`if: needs.ai_review_human_merge.outputs.found == 'true'`), `Resolve gated verdict` and `Check verdict binding` as in Task 6 with `ai_review_human_merge` and without the self-mod clause, then:
  - `Promote draft to ready (human-merge — no auto-merge)`: `if:` → `steps.binding.outputs.bound == 'true'`; `PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}`.
  - `Mark issue blocked when review refuses or PR missing`: `if:` → `needs.ai_review_human_merge.outputs.found != 'true' || steps.verdict.outputs.value != 'approve' || steps.binding.outputs.bound != 'true'`; env re-pointed as in Task 6 plus `BINDING_REASON`, `MODE: human-merge` kept, no `PLAN_COVERAGE`.
  - `Verify gh mock log (test mode)` verbatim.

- [ ] **Step 5: Verify** — `actionlint`; `bash tests/run-all.sh` (isolation test passes with no pending jobs); `just test-act` if available (`verify-human-merge-*`, `verify-human-merge-precedence`).

- [ ] **Step 6: Commit** — `fix(security): decide human-merge promotion in a separate gate job (#535)`.

### Task 8: Record the decision

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/DESIGN.md`
- Modify: `docs/CONSUMER-SETUP.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1:** Append to `docs/DECISIONS.md`:

```markdown
## ADR-020 — Agents produce evidence; a fresh gate job decides (2026-10-19)

**Status:** accepted

**Context.** ADR-019's known gap: the implement agent and the self-fix agent ran
with a bash tool as the same user, in the same job, as the steps that judged
them. They could rewrite `.claude-pipeline/scripts/`, forge the result stream or
the verdict, and write `$GITHUB_ENV` to run code in every later step (#535).

**Decision.** A job that runs an agent only produces job outputs. Every decision
— failure class, pause, retry, outcome, labels, run report, plan coverage,
verdict, merge envelope, promotion, auto-merge — runs in a gate job
(`implement_gate`, `ai_review_ai_merge_gate`, `ai_review_human_merge_gate`) on
its own runner, with fresh checkouts of the consumer repo (no persisted token)
and of `.claude-pipeline` at `pipeline-ref`. Outputs of steps that finished
before the first agent step are trusted; everything later is evidence. The
gates re-derive the PR, recompute plan coverage from the PR diff, bind the
verdict to the PR head and merge with `--match-head-commit`.
`tests/run-agent-isolation-tests.sh` enforces the layout.

**Rejected: re-checkout inside the same job** — `$GITHUB_ENV`, `$GITHUB_PATH` and
detached processes survive it. **Rejected: the agent as a separate user** —
brittle on self-hosted runners. **Rejected: artifacts for the evidence** — they
fail on a full artifact quota (#404); job outputs carry the few KB needed.

**Residual risk.** The evidence is still forgeable: a forged 402 can only pause a
repo whose budget already reads low (ADR-019); a forged verdict after self-fix
still has to pass the envelope, plan coverage, head binding and the required
checks branch protection enforces, but its quality judgement is not re-checked.
The agents' own write tokens can push and enable auto-merge directly, bounded
only by branch protection. On persistent self-hosted runners an agent can leave
changes for a later job; `gate-runner-labels` moves the gates elsewhere. See the
spec `docs/superpowers/specs/2026-10-19-agent-isolation-gate-jobs-design.md`.
```

  In ADR-019's **Known gap** paragraph, append: `Closed by ADR-020 for the pipeline's own decisions; the residuals are listed there.`

- [ ] **Step 2:** `docs/DESIGN.md` — under `## Pipeline behavior` add a `### Job layout and trust boundary` subsection (5-8 lines): the six jobs, "agents produce, gates decide", pointer to ADR-020.

- [ ] **Step 3:** `docs/CONSUMER-SETUP.md` — next to the existing inputs documentation, add `gate-runner-labels` (optional, defaults to `runner-labels`; recommended `'["ubuntu-latest"]'` for consumers on persistent self-hosted runners). State that no stub change is required. Do not touch any yaml fence's `permissions:` block.

- [ ] **Step 4:** `CHANGELOG.md` — under `## [Unreleased]` (create it above `## [2.1.0]` if missing), `### Security`: "Decisions about an agent's work (failure class, pause, retry, run report, plan coverage, verdict, merge) now run in separate gate jobs that never run an agent; the merge is pinned to the reviewed head (#535, ADR-020)." `### Added`: "`gate-runner-labels` input (#535)."

- [ ] **Step 5: Verify** — `bash tests/run-all.sh` (`run-caller-permissions-tests.sh` still finds the CONSUMER-SETUP stub), markdown lint as `just lint` runs it.

- [ ] **Step 6: Commit** — `docs(security): record ADR-020 agent isolation (#535)`.
