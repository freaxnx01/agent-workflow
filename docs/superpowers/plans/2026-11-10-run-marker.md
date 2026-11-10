# Run Marker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Append one hidden `<!-- ai-run: {...} -->` line to every GitHub run report so consumers (bridge #367/#368) can read attempt, class, retry decision and PR without regexes, while the visible report stays byte-identical.

**Architecture:** First freeze today's rendered report as golden files and test exact equality. Then `post-run-report.sh` gains a `render_run_marker` function whose output is the last line of `render_comment`; four new env vars feed it from steps that already run before `Post run report` in `agent-implement.yml`. Docs: a new ADR-021 (schema, versioning, trust rule, Azure DevOps non-emission), a D2 amendment note, CHANGELOG.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), `jq`, GitHub Actions YAML, Layer-1 fixture tests (`tests/run-*-tests.sh`, discovered by `tests/run-all.sh`), `shellcheck`.

**Spec:** `docs/superpowers/specs/2026-11-10-run-marker-design.md`

## Global Constraints

- The visible report — every byte `render_comment` printed before this change, plus the `RENDER_ONLY` `---` / `LABELS:` trailer — is unchanged. Proven by exact `diff` against golden files captured from the **unmodified** script.
- Marker line format, exactly: prefix `<!-- ai-run: `, one compact JSON object, suffix ` -->`. It is the last line of `render_comment`, directly after the `[View workflow run](…)` line (one `\n` between them).
- `v` is `1`.
- A field whose source is empty or invalid is **omitted** — never `null`, never `0`.
- No free text in the marker: never `.result`, never an error message, never `has_plan`.
- After `jq -nc`, every `<` becomes `\u003c` and every `>` becomes `\u003e` (JSON escapes, so a JSON parser decodes them back). The marker line contains `-->` exactly once, at its end.
- `attempt` is present only when `ATTEMPT` is a non-negative integer **and** `counts` is `true`.
- `counts` is `false` when `FAILURE_CLASS` is a pause class (`is_pause_class`), or when `turns == 0` and `cost_usd == 0`; `true` otherwise.
- Existing tests in `tests/run-script-tests.sh`, `tests/run-pipeline-alarm-tests.sh`, `tests/run-opencode-model-tests.sh`, `tests/run-ai-stats-tests.sh` pass **unmodified**.
- `check-attempt-cap.sh` and `scripts/lib/ai-stats.sh` are **not** changed.
- No change to `implement-azdo.sh` / `azdo-report-failure.sh` (Azure DevOps emits no marker in v1).
- Conventional Commits, scope `report`; reference `#585`.

## Review Focus

1. A model id containing `-->` or `<` (e.g. `MODEL='x-->y<z'`) — the marker must stay one HTML comment and decode back to the exact id. Test in Task 2.
2. `ATTEMPT` / `RETRY_ATTEMPT` / `PR_NUMBER` empty or non-numeric (`""`, `abc`, `3a`) — field omitted, marker still valid JSON. Test in Task 2.
3. A non-start (0 turns, `$0.00`) or a paused run with `ATTEMPT=3` set — `counts:false`, no `attempt`, paused has no `status`. Test in Task 2.
4. A tiny cost that jq prints in exponent form (`4.2e-05`) — must still be emitted as a JSON number, not dropped and not a string. Validate numbers with `jq -e 'type=="number"'`, not a regex. Test in Task 2.
5. A future edit to the report body that silently changes the visible part — the golden test must fail with a readable diff, and goldens are only regenerated deliberately (`UPDATE_GOLDEN=1`). Test in Task 1.

---

### Task 1: Freeze today's visible report as golden files

**Files:**
- Create: `tests/run-run-report-golden-tests.sh`
- Create: `tests/fixtures/run-report-golden/<case>.txt` (one per case below)

**Interfaces:**
- Consumes: nothing.
- Produces: a case table and a `render_case <name>` helper in `tests/run-run-report-golden-tests.sh`; a `strip_marker` helper (deletes lines matching `^<!-- ai-run: .* -->$`, a no-op today). Task 2 adds its marker assertions to this same file and reuses both helpers.

Cases (all with `RENDER_ONLY=1 ISSUE_NUMBER=42 WORKFLOW_RUN_URL=https://example/run/test`, fixtures under `tests/fixtures/`):

| Case | Result fixture | Extra env |
|---|---|---|
| `success` | `result-success-cheap.json` | — |
| `success-full` | `result-success-expensive.json` | `MODEL=claude-sonnet-5 AGENT=claude MAX_TURNS=80 HAS_PLAN=true PR_PRESENT=true PLAN_COVERAGE=complete` |
| `high-context` | `result-high-context.json` | `EXECUTION_FILE=exec-high-context.ndjson` |
| `failed-max-turns` | `result-max-turns.json` | `FAILURE_CLASS=task_failure MODEL=claude-sonnet-5 AGENT=claude MAX_TURNS=60` |
| `failed-no-pr` | `result-success-cheap.json` | `PR_PRESENT=false` |
| `partial` | `result-success-expensive.json` | `PLAN_COVERAGE=partial MISSING_TASKS=2,3 PR_PRESENT=true` |
| `unverifiable` | `result-success-cheap.json` | `PLAN_COVERAGE=unverifiable PLAN_COVERAGE_REASON='no plan headings'` |
| `salvaged` | `result-success-cheap.json` | `SALVAGED=true PR_PRESENT=true` |
| `checks-blocked` | `result-success-cheap.json` | `CHECKS_RUNNABLE=false CHECKS_BLOCKED_REASON=no-app-token` |
| `paused` | `result-rate-limit.json` | `FAILURE_CLASS=out_of_credits` |
| `model-not-found` | `result-opencode-model-not-found.json` | `FAILURE_CLASS=model_not_found MODEL=z-ai/glm-9 AGENT=opencode` |

- [ ] **Step 1: Write the test file** — same prelude, colour helpers and PASS/FAIL summary as `tests/run-caller-permissions-tests.sh`; clear `GITHUB_REPOSITORY` / `GITHUB_OUTPUT` like `tests/run-script-tests.sh` does. For each case: `actual="$(render_case "$name" | strip_marker)"`, then compare to `tests/fixtures/run-report-golden/$name.txt` with `diff -u`; on mismatch record a failure named `golden: $name` and print the diff. When `UPDATE_GOLDEN=1`, write `render_case "$name"` output to the golden file instead of comparing (and say so). A missing golden file is a failure, not a silent pass.

- [ ] **Step 2: Run it without goldens to verify it fails**

Run: `bash tests/run-run-report-golden-tests.sh`
Expected: FAIL, one `golden: <case>` failure per case (golden file missing).

- [ ] **Step 3: Generate goldens from the unmodified script**

Run: `git diff --quiet HEAD -- scripts/post-run-report.sh && git log --oneline -1 -- scripts/post-run-report.sh && UPDATE_GOLDEN=1 bash tests/run-run-report-golden-tests.sh`
Expected: the `git diff` guard passes and the last commit touching the script predates this branch (script untouched), 11 files written. Open `paused.txt` and `model-not-found.txt` and check they contain `## ai-implement paused` and `failed: model_not_found` respectively.

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/run-run-report-golden-tests.sh && bash tests/run-all.sh`
Expected: PASS, 11/11; full suite green.

- [ ] **Step 5: Commit**

```bash
git add tests/run-run-report-golden-tests.sh tests/fixtures/run-report-golden/
git commit -m "test(report): freeze the visible run report as golden files (#585)"
```

### Task 2: Render the run marker

**Files:**
- Modify: `scripts/post-run-report.sh` — header env docs (`:13-55`), env reads (`:85-105`), new functions after `labels_csv`, `render_comment` (`:383-401`)
- Modify: `tests/run-run-report-golden-tests.sh`

**Interfaces:**
- Consumes: `render_case`, `strip_marker` from Task 1.
- Produces: new optional env vars on `post-run-report.sh` — `ATTEMPT`, `RETRY_ATTEMPT`, `RETRY_DECISION`, `PR_NUMBER` (Task 3 wires them). Functions `run_counts` (prints `true`|`false`) and `render_run_marker` (prints the marker line, no trailing newline handling beyond `render_comment`'s heredoc).

- [ ] **Step 1: Write the failing tests** (append to `tests/run-run-report-golden-tests.sh`; a helper `marker_json "$out"` = the JSON between prefix and suffix of the single marker line, via `sed -n 's/^<!-- ai-run: \(.*\) -->$/\1/p'`)

Assertions, each its own named check:

```text
every case:        exactly one marker line; it is the last line before "\n---\nLABELS:";
                   marker_json parses with jq; .v == 1; .run_url == "https://example/run/test";
                   strip_marker output == golden (Task 1 test keeps covering this)
success:           .status=="ai:done", .subtype=="success", .turns==4, .cost_usd==0.0042,
                   .counts==true, has("decision")|not, has("attempt")|not, has("pr")|not
success-full + ATTEMPT=2 RETRY_ATTEMPT=1 PR_NUMBER=42:
                   .attempt==2, .retry_attempt==1, .pr==42, .agent=="claude",
                   .model=="claude-sonnet-5", .max_turns==80, .plan_coverage=="complete"
failed-max-turns + RETRY_DECISION=stop ATTEMPT=2:
                   .class=="task_failure", .decision=="stop", .status=="ai:failed",
                   .subtype=="error_max_turns", .turns==60, .attempt==2, .counts==true
paused + ATTEMPT=3:  .class=="out_of_credits", .counts==false, has("attempt")|not, has("status")|not
model-not-found + ATTEMPT=3:
                   .class=="model_not_found", .status=="ai:failed", .turns==0, .cost_usd==0,
                   .counts==false, has("attempt")|not
partial:           .status=="ai:partial", .plan_coverage=="partial"
escaping:          success + MODEL='x-->y<z' → the marker line contains "-->" exactly once and
                   no "<" after its first 4 chars; marker_json | .model == "x-->y<z"
invalid numbers:   success + ATTEMPT=abc RETRY_ATTEMPT='' PR_NUMBER=3a → no attempt,
                   retry_attempt or pr key; still valid JSON
exponent cost:     a temp result JSON copied from result-success-cheap.json with
                   total_cost_usd 0.000042 → (.cost_usd|type)=="number" and .cost_usd==0.000042
no free text:      model-not-found marker_json has no key "result" and does not contain
                   the fixture's .result text
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run-run-report-golden-tests.sh`
Expected: the 11 golden checks PASS, every marker check FAILs (no marker line).

- [ ] **Step 3: Implement in `scripts/post-run-report.sh`**

- Document the four env vars in the header block in the existing style; read them next to `FAILURE_CLASS` (`ATTEMPT="${ATTEMPT:-}"` etc.).
- `run_counts` — `false` when `is_pause_class "$FAILURE_CLASS"`; `false` when `NUM_TURNS` is `0` and `awk` reads `COST_USD + 0 == 0`; else `true`.
- `render_run_marker` — one `jq -nc` call building the object from `--arg`/`--argjson` values and `with_entries`/conditional adds so empty sources are omitted. Integers (`attempt`, `retry_attempt`, `turns`, `max_turns`, `duration_ms`, `pr`) only when they match `^[0-9]+$`; `cost_usd` only when `printf '%s' "$COST_USD" | jq -e 'type=="number"'` succeeds; `attempt` additionally only when `run_counts` is `true`; `status` from `$STATUS_LABEL` only when non-empty; `decision`, `class`, `agent`, `model`, `plan_coverage` only when non-empty; `subtype` and `run_url` always. Pipe through `sed -e 's/</\\u003c/g' -e 's/>/\\u003e/g'` and print `<!-- ai-run: %s -->`.
- `render_comment` — add `$(render_run_marker)` as a new line directly after `[View workflow run](${WORKFLOW_RUN_URL})`, nothing else changed in the heredoc.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-run-report-golden-tests.sh && bash tests/run-all.sh && shellcheck scripts/post-run-report.sh tests/run-run-report-golden-tests.sh`
Expected: all PASS; existing suites unmodified and green; shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/post-run-report.sh tests/run-run-report-golden-tests.sh
git commit -m "feat(report): append a machine-readable run marker to the run report (#585)"
```

### Task 3: Wire the marker inputs in the workflow

**Files:**
- Modify: `.github/workflows/agent-implement.yml` — `Post run report` step env (`:1122-1148`)
- Modify: `tests/run-run-report-golden-tests.sh`

**Interfaces:**
- Consumes: env names from Task 2.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test** — a `workflow wiring` check that extracts the `Post run report` step's `env:` block from `.github/workflows/agent-implement.yml` (awk from `- name: Post run report` to the next `- name:`) and asserts it contains each of these exact lines (leading whitespace ignored):

```text
ATTEMPT: ${{ steps.attempt_cap.outputs.attempt }}
RETRY_ATTEMPT: ${{ inputs.attempt }}
RETRY_DECISION: ${{ steps.retry.outputs.decision }}
PR_NUMBER: ${{ steps.verify_pr.outputs.pr-number }}
```

and that the step ids `attempt_cap`, `retry`, `verify_pr` are each defined (`id: <name>`) on a line **before** `- name: Post run report`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-run-report-golden-tests.sh`
Expected: FAIL on the four wiring checks; order checks PASS.

- [ ] **Step 3: Add the four env lines** to `Post run report`, after `FAILURE_CLASS`, with a short comment `# #585: run marker inputs — all from steps that run before this one.`

  **If `Post run report` is no longer in the same job as `attempt_cap` / `verify_pr` / `retry`** (PR #571 for #535 moves the post-run decisions into an `implement_gate` job): expose each missing value as an output of the job that computes it and read it as `needs.<job>.outputs.<name>` instead, keeping the env names unchanged; adapt the Step 1 order check to "defined in this job or in a job listed under `needs:`". Do not move steps between jobs to make the test pass.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-run-report-golden-tests.sh && bash tests/run-all.sh`
Expected: PASS; `lint.yml`'s actionlint step (if run locally: `actionlint .github/workflows/agent-implement.yml`) clean.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/agent-implement.yml tests/run-run-report-golden-tests.sh
git commit -m "feat(report): pass attempt, retry decision and PR into the run report (#585)"
```

### Task 4: Record the contract

**Files:**
- Modify: `docs/DECISIONS.md` — append `## ADR-021 — The run report carries a machine-readable run marker (2026-11-10)` after the last ADR. ADR-020 is already reserved by #535 / PR #571 (agent isolation gate jobs, referenced from docs on main), so this one is ADR-021
- Modify: `docs/superpowers/specs/2026-09-23-attempt-cap-nonstarts-design.md:47` — note under the D2 row
- Modify: `CHANGELOG.md` — `## [Unreleased]`

- [ ] **Step 1: Write ADR-021** — Status accepted; sections Context / Decision / Consequences like ADR-019. Decision must state, taken from the spec: the line format; the field table (name, type, source, presence rule); omission rule; no free text; the `\u003c`/`\u003e` escaping; versioning (optional field added = no bump, rename/remove/type or meaning change = bump `v`, unknown `v` = no marker); `attempt` is the cap's lifetime count and omitted when `counts` is false, `retry_attempt` is the chain position; the consumer trust rule (only comments authored by `github-actions[bot]`, the identity `Post run report` posts as via `github.token`; marker from the last line only; actions it triggers bounded by the same caps as manual ones; known gap → #535); Azure DevOps emits no marker in v1 and why; relation to D2 (amended, not reversed: visible record stays the source for `check-attempt-cap.sh` and `/ai-stats`) and to ADR-019. Consequences: retry dispatch happens before the report is posted (existing undercount window); `decision: retry` even when the re-dispatch call failed; no report → no marker (#567); #559 extends the schema additively; `check-attempt-cap.sh` does not filter by author (fails safe, recorded, not changed).

- [ ] **Step 2: D2 note** — append to the D2 row's rationale cell: `Amended by ADR-021 (#585): the marker is now emitted, additively; the visible record this decision protects is unchanged and remains what the cap and /ai-stats read.`

- [ ] **Step 3: CHANGELOG** — under `## [Unreleased]` → `### Added`: one line on the run marker, pointing at ADR-021.

- [ ] **Step 4: Verify**

Run: `bash tests/run-all.sh && grep -c '^## ADR-021' docs/DECISIONS.md`
Expected: suite green; `1`.

- [ ] **Step 5: Commit**

```bash
git add docs/DECISIONS.md docs/superpowers/specs/2026-09-23-attempt-cap-nonstarts-design.md CHANGELOG.md
git commit -m "docs(report): record the run marker contract as ADR-021 (#585)"
```
