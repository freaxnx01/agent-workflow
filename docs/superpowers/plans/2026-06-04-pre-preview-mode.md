# Pre-preview Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third review flow — "pre-preview" — where the pipeline's agent reviews its own freshly-opened draft PR and, on `approve`, promotes it to ready for a *human* to merge (no envelope, no auto-merge).

**Architecture:** A new per-repo input `pre-preview` + per-issue label `ai-pre-preview` gate a new `pre_preview` job in `claude-implement.yml`, parallel to the ADR-002 `auto_review` job. It reuses `find-pipeline-pr.sh` / `review-pr.sh` / `post-auto-review-block.sh`; its only terminal action on approve is `gh pr ready`. Precedence (pre-preview wins over auto-review when both are set) is one added clause on the `auto_review` job gate, leaving its audited internals untouched.

**Tech Stack:** Bash scripts (fixture-tested via `tests/run-script-tests.sh`), GitHub Actions reusable workflow (`actionlint` + `shellcheck` lint, `act` layer-2 test).

**Reference spec:** `docs/superpowers/specs/2026-06-04-pre-preview-mode-design.md`

**Conventions for every task below:**

- Layer-1 tests live in `tests/run-script-tests.sh`; run the whole suite with `bash tests/run-script-tests.sh` (must finish < 5s, exit 0).
- Lint with `shellcheck -x -e SC1091 <file>.sh` for scripts and `actionlint` for workflow YAML.
- Commit after each task. Branch is already `feat/pre-preview-mode` (spec already committed there).

---

## Task 1: Add the `ai-pre-preview` label

**Files:**

- Modify: `scripts/ensure-issue-labels.sh` (gates group)
- Test: `tests/run-script-tests.sh` (`ensure-issue-labels` section)

- [ ] **Step 1: Write the failing test**

In `tests/run-script-tests.sh`, in the `section "ensure-issue-labels — ..."` block, immediately after the existing `assert_contains "$log" 'label create ai-auto-review --repo owner/repo' ...` line, add:

```bash
assert_contains "$log" 'label create ai-pre-preview --repo owner/repo' "creates ai-pre-preview"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — `✗ creates ai-pre-preview` (label not yet created).

- [ ] **Step 3: Write minimal implementation**

In `scripts/ensure-issue-labels.sh`, immediately after this line:

```bash
create ai-auto-review  0E8A16 'Run auto-review after PR opens; auto-merge on approve+green'
```

add:

```bash
create ai-pre-preview  1D76DB 'Run agent pre-review after PR opens; promote to ready for human merge (no auto-merge)'
```

Also update the `gates` description in the script's header comment (lines ~13-15) from:

```text
#   gates      ai-auto-review, ai-chain, ai:chain-paused
```

to:

```text
#   gates      ai-auto-review, ai-pre-preview, ai-chain, ai:chain-paused
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-script-tests.sh`
Expected: PASS — `✓ creates ai-pre-preview`, suite exits 0.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/ensure-issue-labels.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/ensure-issue-labels.sh tests/run-script-tests.sh
git commit -m "feat(labels): add ai-pre-preview gate label (#77)"
```

---

## Task 2: `check-preview-gate.sh` — the pre-preview gate

A near-clone of `scripts/check-auto-review-gate.sh`: `enabled=true` iff `INPUT_PRE_PREVIEW == true` AND the issue carries `ai-pre-preview`.

**Files:**

- Create: `scripts/check-preview-gate.sh`
- Test: `tests/run-script-tests.sh` (new section)

- [ ] **Step 1: Write the failing tests**

In `tests/run-script-tests.sh`, immediately after the entire `section "check-auto-review-gate — input + label combinations"` block (i.e. just before `section "review-prompt — ADR-002 §2.4 ..."`), add:

```bash
section "check-preview-gate — input + label combinations"

PGATE="$ROOT/scripts/check-preview-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=false ISSUE_LABELS='ai-implement' bash "$PGATE")"
assert_contains "$out" 'enabled=false (workflow input pre-preview=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=false ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$PGATE")"
assert_contains "$out" 'enabled=false (workflow input pre-preview=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS='ai-implement' bash "$PGATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-pre-preview missing)' "input=true, no label → disabled"

# Both on → enabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$PGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-pre-preview present)' "input=true, label set → enabled"

# Default INPUT_PRE_PREVIEW (unset) → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-pre-preview' bash "$PGATE")"
assert_contains "$out" 'enabled=false (workflow input pre-preview=false)' "unset INPUT_PRE_PREVIEW defaults to false"

# Invalid INPUT_PRE_PREVIEW → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=yes ISSUE_LABELS='' bash "$PGATE")"
assert_equals "$ec" "2" "invalid INPUT_PRE_PREVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_PRE_PREVIEW=true bash "$PGATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_PRE_PREVIEW=true bash "$PGATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — the new `check-preview-gate` assertions error (script does not exist).

- [ ] **Step 3: Write the implementation**

Create `scripts/check-preview-gate.sh`:

```bash
#!/usr/bin/env bash
#
# check-preview-gate.sh — Decide whether to run the pre-preview flow for
# this issue. The flow itself lives in the `pre_preview` job; this script
# only computes the gate so callers can branch on its output.
#
# Pre-preview mode (ADR-004 / #77): after the pipeline opens a draft PR,
# the agent reviews it and, on approve, promotes it to ready so a HUMAN
# can merge. It never auto-merges. This gate is the sibling of
# check-auto-review-gate.sh.
#
# The gate is `true` iff BOTH:
#   - the workflow input `pre-preview` is `true`, AND
#   - the issue carries the `ai-pre-preview` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. Precedence vs. auto-review (pre-preview
# wins when both are enabled) is enforced in the workflow, not here.
#
# Required environment variables:
#   ISSUE_NUMBER       GitHub issue number
#   REPO               owner/repo (default: $GITHUB_REPOSITORY)
#   INPUT_PRE_PREVIEW  "true" or "false" — the workflow input value
#   GH_TOKEN           (or ambient gh auth)
#
# Optional environment variables:
#   ISSUE_LABELS  Newline- or space-separated labels. If set, skips the
#                 `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `enabled=true|false` and `reason=<text>` to $GITHUB_OUTPUT
#   when set, and prints a one-line `enabled=<bool> (<reason>)` summary
#   to stdout.
#
# Exit codes:
#   0  success
#   2  required env missing or INPUT_PRE_PREVIEW not in {true,false}
set -euo pipefail
IFS=$'\n\t'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

INPUT_PRE_PREVIEW="${INPUT_PRE_PREVIEW:-false}"
case "$INPUT_PRE_PREVIEW" in
  true|false) ;;
  *)
    printf 'error: INPUT_PRE_PREVIEW must be "true" or "false" (got %q)\n' "$INPUT_PRE_PREVIEW" >&2
    exit 2
    ;;
esac

# --- short-circuit: input off ---------------------------------------------

if [[ "$INPUT_PRE_PREVIEW" != "true" ]]; then
  enabled=false
  reason='workflow input pre-preview=false'
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  has_label=false
  while IFS= read -r label; do
    if [[ "$label" == 'ai-pre-preview' ]]; then
      has_label=true
      break
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$has_label" == 'true' ]]; then
    enabled=true
    reason='input=true AND label ai-pre-preview present'
  else
    enabled=false
    reason='input=true but label ai-pre-preview missing'
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
```

- [ ] **Step 4: Make it executable and run tests to verify they pass**

```bash
chmod +x scripts/check-preview-gate.sh
bash tests/run-script-tests.sh
```

Expected: PASS — all 8 `check-preview-gate` assertions green, suite exits 0.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/check-preview-gate.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-preview-gate.sh tests/run-script-tests.sh
git commit -m "feat(gate): add check-preview-gate.sh for pre-preview mode (#77)"
```

---

## Task 3: `MODE` wording in `post-auto-review-block.sh`

Reuse the block script for pre-preview, but make its comment say "Pre-review held" instead of "Auto-merge held" / "Auto-review held". Default behavior is byte-for-byte unchanged.

**Files:**

- Modify: `scripts/post-auto-review-block.sh`
- Test: `tests/run-script-tests.sh` (`post-auto-review-block` section)

- [ ] **Step 1: Write the failing test**

In `tests/run-script-tests.sh`, inside `section "post-auto-review-block — reason selection + PR-vs-issue addressing"`, immediately after the `# Verdict != approve → reason quotes the verdict and gate 4` block (the one asserting `'agent review verdict: request_changes (gate 4)'`), add:

```bash
# MODE=pre-preview → comment prefix is "Pre-review held", not "Auto-merge held"
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true \
VERDICT=block MODE=pre-preview \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains     "$calls" 'pr comment 100 --repo o/r --body Pre-review held: agent review verdict: block (gate 4)' "MODE=pre-preview → 'Pre-review held' PR comment"
assert_not_contains "$calls" 'Auto-merge held'                                                                        "MODE=pre-preview → no 'Auto-merge held' wording"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — comment still says `Auto-merge held` (MODE not yet honored).

- [ ] **Step 3: Write minimal implementation**

In `scripts/post-auto-review-block.sh`, in the block of variable defaults, after this line:

```bash
FAILED_GATES="${FAILED_GATES:-}"
```

add:

```bash
MODE="${MODE:-auto-review}"

# Comment-prefix wording differs by mode; reason text is identical.
case "$MODE" in
  pre-preview)
    pr_prefix='Pre-review held'
    issue_prefix='Pre-review held'
    ;;
  *)
    pr_prefix='Auto-merge held'
    issue_prefix='Auto-review held'
    ;;
esac
```

Then replace this existing block:

```bash
if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "Auto-merge held: $reason. PR stays draft for human review."
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "Auto-review held: $reason."
fi
```

with:

```bash
if [[ -n "$PR_NUMBER" ]]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" \
    --body "$pr_prefix: $reason. PR stays draft for human review."
else
  gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
    --body "$issue_prefix: $reason."
fi
```

Also extend the script header comment's "Optional environment variables" list to document `MODE` (default `auto-review`; `pre-preview` switches the comment prefix).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-script-tests.sh`
Expected: PASS — new `MODE=pre-preview` assertions green AND the pre-existing `'Auto-merge held: self-modification guard (ADR-002)'` / `'Auto-review held'` assertions still green (default unchanged).

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/post-auto-review-block.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/post-auto-review-block.sh tests/run-script-tests.sh
git commit -m "feat(block): MODE=pre-preview comment wording (#77)"
```

---

## Task 4: `verify-gh-mock-merge.sh` also reports `ready-attempted`

The act assertions need to confirm `gh pr ready` *was* called (approve path) and `gh pr merge` was *not*. Extend the existing mock-log inspector to emit `ready-attempted` alongside `merge-attempted`.

**Files:**

- Modify: `scripts/verify-gh-mock-merge.sh`
- Test: `tests/run-script-tests.sh` (`verify-gh-mock-merge` section)

- [ ] **Step 1: Write the failing tests**

In `tests/run-script-tests.sh`, inside `section "verify-gh-mock-merge — detect gh pr merge in the mock log"`, immediately after the first sub-test (the one asserting `'merge-attempted=true'` for a log containing `pr merge`), add:

```bash
# Same log also reports ready-attempted=true (it contains a 'pr ready' line)
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr ready 9999 --repo o/r\npr merge 9999 --repo o/r --auto --squash\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'ready-attempted=true' "log with 'pr ready' → ready-attempted=true"

# Log without 'pr ready' → ready-attempted=false
LOG="$(mktemp)"
GO="$(mktemp)"
printf 'pr comment 9999 --repo o/r --body held\nissue edit 42 --repo o/r --add-label ai:review-blocked\n' > "$LOG"
GITHUB_OUTPUT="$GO" GH_MOCK_LOG="$LOG" bash "$VERIFY_MOCK" >/dev/null
out="$(cat "$GO")"; rm -f "$LOG" "$GO"
assert_contains "$out" 'ready-attempted=false' "log without 'pr ready' → ready-attempted=false"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run-script-tests.sh`
Expected: FAIL — `ready-attempted` not in output yet.

- [ ] **Step 3: Write minimal implementation**

In `scripts/verify-gh-mock-merge.sh`, immediately after this existing block:

```bash
printf 'merge-attempted=%s\n' "$attempted"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'merge-attempted=%s\n' "$attempted" >> "$GITHUB_OUTPUT"
fi
```

add:

```bash
# Pre-preview promotes the draft with `gh pr ready` (no merge). Report
# whether that happened so the act assertions can distinguish the
# approve path (ready=true, merge=false) from the block path (both false).
if [[ -n "$log" && -r "$log" ]] && grep -qE '^pr ready ' "$log"; then
  ready=true
else
  ready=false
fi

printf 'ready-attempted=%s\n' "$ready"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ready-attempted=%s\n' "$ready" >> "$GITHUB_OUTPUT"
fi
```

Also update the script's header comment to note it emits both `merge-attempted` and `ready-attempted`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-script-tests.sh`
Expected: PASS — both new `ready-attempted` assertions green; existing `merge-attempted` assertions still green.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/verify-gh-mock-merge.sh`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-gh-mock-merge.sh tests/run-script-tests.sh
git commit -m "feat(test-helper): verify-gh-mock-merge reports ready-attempted (#77)"
```

---

## Task 5: Workflow — implement job gate + precedence

Wire the new gate into the `implement` job and add the precedence clause to the `auto_review` job. (The `pre_preview` job and the workflow_call outputs it feeds come in Task 6, so this task keeps the YAML lint-clean on its own.)

**Files:**

- Modify: `.github/workflows/claude-implement.yml`

- [ ] **Step 1: Add the two inputs**

In the `on.workflow_call.inputs:` block, immediately after the `stub-auto-review-enabled:` input block (the one whose `default: false`), add:

```yaml
      stub-pre-preview-enabled:
        description: |
          Test-only. When `stub-claude: true`, forces the implement job's
          `pre-preview-enabled` output to this value instead of running
          check-preview-gate.sh. Required for end-to-end act tests of the
          pre_preview job (the real gate requires a labeled GitHub issue,
          which doesn't exist under act).
        type: boolean
        default: false
```

Then, immediately after the `auto-review:` input block (the one whose `default: false`, just before `pipeline-author-allowlist:`), add:

```yaml
      pre-preview:
        description: |
          Per-repo opt-in for pre-preview mode (#77 / ADR-004). When true
          AND the issue carries the `ai-pre-preview` label, the
          `pre_preview` job reviews the freshly-opened draft PR and, on
          approve, promotes it to ready for a HUMAN to merge — no safety
          envelope, no auto-merge. If an issue also carries
          `ai-auto-review`, pre-preview wins (the auto_review job is
          suppressed).
        type: boolean
        default: false
```

- [ ] **Step 2: Add the implement job output**

In the `jobs.implement.outputs:` block, after the `auto-review-enabled:` line, add:

```yaml
      pre-preview-enabled: ${{ steps.preview_gate.outputs.enabled || steps.preview_gate_stub.outputs.enabled }}
```

- [ ] **Step 3: Add the gate steps**

In the `implement` job steps, immediately after the existing `Stub auto-review gate (test mode)` step (the one with `id: auto_review_gate_stub`), add:

```yaml
      - name: Check pre-preview gate
        if: ${{ !inputs.stub-claude }}
        id: preview_gate
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          INPUT_PRE_PREVIEW: ${{ inputs.pre-preview }}
        run: bash .claude-pipeline/scripts/check-preview-gate.sh

      - name: Stub pre-preview gate (test mode)
        # Mirrors check-preview-gate.sh's output under stub-claude=true so
        # end-to-end act tests can drive the pre_preview job without a real
        # labeled GitHub issue.
        if: ${{ inputs.stub-claude }}
        id: preview_gate_stub
        env:
          ENABLED: ${{ inputs.stub-pre-preview-enabled }}
        run: printf 'enabled=%s\n' "$ENABLED" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 4: Add the precedence clause to the auto_review gate**

In the `auto_review` job's top-level `if:`, change this line:

```yaml
      && needs.implement.outputs.auto-review-enabled == 'true'
```

to these two lines:

```yaml
      && needs.implement.outputs.auto-review-enabled == 'true'
      && needs.implement.outputs.pre-preview-enabled != 'true'
```

- [ ] **Step 5: Lint the workflow**

Run: `actionlint .github/workflows/claude-implement.yml`
Expected: no output, exit 0. (References to `jobs.pre_preview` do not exist yet — that's why this task does NOT add the workflow_call outputs; they arrive with the job in Task 6.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/claude-implement.yml
git commit -m "feat(workflow): pre-preview gate + precedence on implement/auto_review (#77)"
```

---

## Task 6: Workflow — the `pre_preview` job + outputs

**Files:**

- Modify: `.github/workflows/claude-implement.yml`

- [ ] **Step 1: Add the workflow_call outputs**

In the `on.workflow_call.outputs:` block, after the `auto-review-merge-attempted:` output block, add:

```yaml
      pre-preview-merge-attempted:
        description: |
          "true" or "false" — whether `gh pr merge` was invoked by the
          pre_preview job. Always "false" on the pre-preview path (it never
          merges); populated only when `stub-review-verdict` is set, as the
          test workflow's "no merge in pre-preview" assertion surface.
        value: ${{ jobs.pre_preview.outputs.merge-attempted }}
      pre-preview-ready-attempted:
        description: |
          "true" or "false" — whether `gh pr ready` (promote draft→ready)
          was invoked by the pre_preview job. True on the approve path.
          Populated only when `stub-review-verdict` is set.
        value: ${{ jobs.pre_preview.outputs.ready-attempted }}
```

- [ ] **Step 2: Add the `pre_preview` job**

At the very end of the file, after the entire `auto_review:` job, add:

```yaml
  pre_preview:
    # Pre-preview mode (#77 / ADR-004): the agent reviews the freshly-
    # opened draft PR; on `approve` the draft is promoted to ready and a
    # HUMAN merges. No safety envelope and no auto-merge. Because
    # promote-to-ready performs no merge, there is intentionally NO
    # self-modification guard here (unlike auto_review) — promoting a draft
    # on freaxnx01/agent-pipeline itself is safe, so this repo can dogfood
    # the flow. Non-approve verdict or a missing PR leaves the PR draft and
    # stamps ai:review-blocked. Mutually exclusive with auto_review via the
    # implement-job gate (pre-preview wins when both labels are present).
    name: Pre-preview PR for issue #${{ inputs.issue-number }}
    needs: implement
    if: |
      (!inputs.stub-claude || inputs.stub-review-verdict != '')
      && (!inputs.dry-run || inputs.stub-review-verdict != '')
      && needs.implement.outputs.outcome == 'success'
      && needs.implement.outputs.pre-preview-enabled == 'true'
    runs-on: ${{ fromJSON(inputs.runner-labels) }}
    timeout-minutes: 10
    permissions:
      contents: write
      pull-requests: write
      issues: write
    outputs:
      merge-attempted: ${{ steps.verify_mock.outputs.merge-attempted }}
      ready-attempted: ${{ steps.verify_mock.outputs.ready-attempted }}
    steps:
      - name: Checkout consumer repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

      - name: Checkout agent-pipeline scripts
        if: ${{ !inputs.local-scripts }}
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          repository: ${{ inputs.pipeline-repo }}
          ref: ${{ inputs.pipeline-ref }}
          path: .claude-pipeline
          sparse-checkout: |
            scripts
            tests/mocks
            tests/fixtures

      - name: Mirror local scripts to .claude-pipeline (self-test mode)
        if: ${{ inputs.local-scripts }}
        run: |
          mkdir -p .claude-pipeline/scripts \
                   .claude-pipeline/tests/mocks \
                   .claude-pipeline/tests/fixtures
          cp -r scripts/. .claude-pipeline/scripts/
          if [[ -d tests/mocks ]]; then
            cp -r tests/mocks/. .claude-pipeline/tests/mocks/
          fi
          if [[ -d tests/fixtures ]]; then
            cp -r tests/fixtures/. .claude-pipeline/tests/fixtures/
          fi

      - name: Wire gh mock + stub PR JSON (test mode)
        if: inputs.stub-review-verdict != ''
        env:
          WORKSPACE: ${{ github.workspace }}
          RUNNER_TEMP_DIR: ${{ runner.temp }}
        run: |
          log="$RUNNER_TEMP_DIR/gh-mock.log"
          : > "$log"
          {
            printf 'PATH=%s/.claude-pipeline/tests/mocks:%s\n' "$WORKSPACE" "$PATH"
            printf 'GH_MOCK_LOG=%s\n' "$log"
            printf 'PIPELINE_PRS_JSON=%s\n' \
              '[{"number":9999,"isDraft":true,"headRefOid":"stubsha","author":{"login":"github-actions[bot]"}}]'
          } >> "$GITHUB_ENV"

      - name: Find pipeline-opened PR
        id: find_pr
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          AUTHOR_ALLOWLIST: ${{ inputs.pipeline-author-allowlist }}
        run: bash .claude-pipeline/scripts/find-pipeline-pr.sh

      - name: Install Claude Code CLI
        if: |
          steps.find_pr.outputs.found == 'true'
          && inputs.stub-review-verdict == ''
        run: npm install -g @anthropic-ai/claude-code

      - name: Run agent review
        if: |
          steps.find_pr.outputs.found == 'true'
          && inputs.stub-review-verdict == ''
        id: review
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          HEAD_SHA: ${{ steps.find_pr.outputs.head-sha }}
          AGENT: claude
          AGENT_CMD: ${{ github.workspace }}/.claude-pipeline/scripts/lib/agent-cmd-claude.sh
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
        run: bash .claude-pipeline/scripts/review-pr.sh

      - name: Stub agent review (test mode)
        if: |
          steps.find_pr.outputs.found == 'true'
          && inputs.stub-review-verdict != ''
        id: review_stub
        env:
          VERDICT: ${{ inputs.stub-review-verdict }}
        run: |
          {
            printf 'verdict=%s\n' "$VERDICT"
            printf 'reason=stubbed verdict for test mode\n'
          } >> "$GITHUB_OUTPUT"

      - name: Resolve review verdict
        if: steps.find_pr.outputs.found == 'true'
        id: verdict
        env:
          REAL: ${{ steps.review.outputs.verdict }}
          STUB: ${{ steps.review_stub.outputs.verdict }}
        run: printf 'value=%s\n' "${REAL:-$STUB}" >> "$GITHUB_OUTPUT"

      - name: Promote draft to ready (pre-preview — no auto-merge)
        if: |
          steps.find_pr.outputs.found == 'true'
          && steps.verdict.outputs.value == 'approve'
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
        run: |
          # Tolerate a redundant `gh pr ready` (e.g. PR already ready) — a
          # human still merges, so this must not fail the job.
          gh pr ready "$PR_NUMBER" --repo "$REPO" || true
          gh pr comment "$PR_NUMBER" --repo "$REPO" \
            --body "Pre-reviewed ✓ — promoted to ready. Merge is yours (no auto-merge in pre-preview mode)."

      - name: Mark issue blocked when review refuses or PR missing
        if: |
          steps.find_pr.outputs.found != 'true'
          || steps.verdict.outputs.value != 'approve'
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          PR_NUMBER: ${{ steps.find_pr.outputs.pr-number }}
          FOUND: ${{ steps.find_pr.outputs.found }}
          VERDICT: ${{ steps.verdict.outputs.value }}
          MODE: pre-preview
        run: bash .claude-pipeline/scripts/post-auto-review-block.sh

      - name: Verify gh mock log (test mode)
        # Surface merge-attempted (must be false) and ready-attempted
        # (true on approve) so the act assertions can verify behavior.
        if: inputs.stub-review-verdict != '' && always()
        id: verify_mock
        run: bash .claude-pipeline/scripts/verify-gh-mock-merge.sh
```

- [ ] **Step 3: Lint the workflow**

Run: `actionlint .github/workflows/claude-implement.yml`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/claude-implement.yml
git commit -m "feat(workflow): add pre_preview job (#77)"
```

---

## Task 7: Layer-2 act scenarios

Add three reusable-workflow calls + their assertion jobs to the test workflow: approve (promotes, no merge), block (stays draft, no merge), precedence (both labels → pre-preview runs, no merge).

**Files:**

- Modify: `.github/workflows/claude-implement.test.yml`

- [ ] **Step 1: Add the three call jobs**

At the end of `.github/workflows/claude-implement.test.yml`, after the `call-auto-review-block:` job (and before the `verify-auto-review-*` jobs is fine too — order is not significant), add:

```yaml
  # ─── Pre-preview path (issue #77 / ADR-004) ───────────────────────────────
  # Pre-preview reviews the draft PR and, on approve, runs `gh pr ready`
  # (promote) but never `gh pr merge`. The gh mock captures both so the
  # asserts can check ready=true / merge=false on approve, and both=false
  # on block. The precedence call sets BOTH gates; pre-preview must win.

  call-pre-preview-approve:
    name: Reusable workflow — pre-preview approve
    uses: ./.github/workflows/claude-implement.yml
    with:
      issue-number: 9007
      timeout-minutes: 10
      local-scripts: true
      stub-claude: true
      stub-fixture: success
      pre-preview: true
      dry-run: true
      stub-pre-preview-enabled: true
      stub-review-verdict: approve
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: not-used-by-stub

  call-pre-preview-block:
    name: Reusable workflow — pre-preview block
    uses: ./.github/workflows/claude-implement.yml
    with:
      issue-number: 9008
      timeout-minutes: 10
      local-scripts: true
      stub-claude: true
      stub-fixture: success
      pre-preview: true
      dry-run: true
      stub-pre-preview-enabled: true
      stub-review-verdict: block
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: not-used-by-stub

  call-pre-preview-precedence:
    name: Reusable workflow — pre-preview wins over auto-review
    uses: ./.github/workflows/claude-implement.yml
    with:
      issue-number: 9009
      timeout-minutes: 10
      local-scripts: true
      stub-claude: true
      stub-fixture: success
      auto-review: true
      pre-preview: true
      dry-run: true
      stub-auto-review-enabled: true
      stub-pre-preview-enabled: true
      stub-review-verdict: approve
      stub-pr-files: |
        src/foo.ts
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: not-used-by-stub
```

- [ ] **Step 2: Add the three assertion jobs**

After the `verify-auto-review-block:` job at the end of the file, add:

```yaml
  verify-pre-preview-approve:
    name: Assert pre-preview approve → promoted, no merge
    needs: call-pre-preview-approve
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      READY:     ${{ needs.call-pre-preview-approve.outputs.pre-preview-ready-attempted }}
      ATTEMPTED: ${{ needs.call-pre-preview-approve.outputs.pre-preview-merge-attempted }}
    steps:
      - name: Assert gh pr ready called and gh pr merge NOT called
        run: |
          fail=0
          [[ "$READY" == "true" ]]      || { echo "::error::ready-attempted=$READY (want true — approve must promote)"; fail=1; }
          [[ "$ATTEMPTED" == "false" ]] || { echo "::error::merge-attempted=$ATTEMPTED (want false — pre-preview never merges)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "pre-preview approve OK: ready=$READY merge=$ATTEMPTED"

  verify-pre-preview-block:
    name: Assert pre-preview block → draft, no promote, no merge
    needs: call-pre-preview-block
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      READY:     ${{ needs.call-pre-preview-block.outputs.pre-preview-ready-attempted }}
      ATTEMPTED: ${{ needs.call-pre-preview-block.outputs.pre-preview-merge-attempted }}
    steps:
      - name: Assert neither gh pr ready nor gh pr merge was called
        run: |
          fail=0
          [[ "$READY" == "false" ]]     || { echo "::error::ready-attempted=$READY (want false — block must NOT promote)"; fail=1; }
          [[ "$ATTEMPTED" == "false" ]] || { echo "::error::merge-attempted=$ATTEMPTED (want false)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "pre-preview block OK: ready=$READY merge=$ATTEMPTED"

  verify-pre-preview-precedence:
    name: Assert pre-preview wins → promoted, no merge
    needs: call-pre-preview-precedence
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    env:
      READY:           ${{ needs.call-pre-preview-precedence.outputs.pre-preview-ready-attempted }}
      PREVIEW_MERGE:   ${{ needs.call-pre-preview-precedence.outputs.pre-preview-merge-attempted }}
      AUTO_MERGE:      ${{ needs.call-pre-preview-precedence.outputs.auto-review-merge-attempted }}
    steps:
      - name: Assert pre-preview ran and nothing auto-merged
        run: |
          fail=0
          [[ "$READY" == "true" ]]          || { echo "::error::ready-attempted=$READY (want true — pre-preview should run and promote)"; fail=1; }
          [[ "$PREVIEW_MERGE" == "false" ]] || { echo "::error::pre-preview-merge-attempted=$PREVIEW_MERGE (want false)"; fail=1; }
          [[ "$AUTO_MERGE" != "true" ]]     || { echo "::error::auto-review-merge-attempted=$AUTO_MERGE (want not-true — auto_review must be suppressed)"; fail=1; }
          (( fail == 0 )) || exit 1
          echo "precedence OK: ready=$READY preview-merge=$PREVIEW_MERGE auto-merge=$AUTO_MERGE"
```

- [ ] **Step 3: Lint the test workflow**

Run: `actionlint .github/workflows/claude-implement.test.yml`
Expected: no output, exit 0.

- [ ] **Step 4: (Optional) run the act scenarios locally if `act` + Docker are available**

Run: `act pull_request -W .github/workflows/claude-implement.test.yml -j verify-pre-preview-approve`
Expected: job passes (`pre-preview approve OK: ready=true merge=false`).
If `act`/Docker is unavailable, skip — these run in CI on the pushed PR (Task 9).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/claude-implement.test.yml
git commit -m "test(act): pre-preview approve/block/precedence scenarios (#77)"
```

---

## Task 8: Docs — CONSUMER-SETUP flow #3 + ADR-004

**Files:**

- Modify: `docs/CONSUMER-SETUP.md`
- Modify: `docs/DECISIONS.md`

- [ ] **Step 1: Add flow #3 to CONSUMER-SETUP.md**

In `docs/CONSUMER-SETUP.md`, change the flows list near the top from:

```text
1. **Minimum stub** — labeled-issue → draft PR (no auto-merge).
2. **Auto-review + auto-merge** — labeled-issue → draft PR → agent review → squash-merge, inside ADR-002's safety envelope.
```

to:

```text
1. **Minimum stub** — labeled-issue → draft PR (no auto-merge).
2. **Auto-review + auto-merge** — labeled-issue → draft PR → agent review → squash-merge, inside ADR-002's safety envelope.
3. **Pre-preview** — labeled-issue → draft PR → agent reviews its own PR → on approve, promote draft→ready; a human merges. No envelope, no auto-merge. Opt in with `pre-preview: true` + the `ai-pre-preview` label. See ADR-004.
```

- [ ] **Step 2: Add ADR-004 to DECISIONS.md**

In `docs/DECISIONS.md`, after the end of the `## ADR-003 — Issue-chain dispatch on auto-merge (2026-05-24)` section, append:

```markdown
---

## ADR-004 — Pre-preview mode (agent self-review → human merge) (2026-06-04)

**Status:** Accepted
**Tracking:** [#77](https://github.com/freaxnx01/agent-pipeline/issues/77)

### Context

The pipeline has two end-states after it opens a draft PR: flow #1 leaves a
*raw* draft for a human (no agent review), and flow #2 (ADR-002) runs an agent
review and, inside a safety envelope, **auto-merges**. There is no middle
ground for a repo that wants the agent's review rigor but keeps the merge
decision with a human.

### Decision

Add a third flow, **pre-preview**, as a `pre_preview` job parallel to
`auto_review`:

- **Opt-in:** per-repo input `pre-preview: true` AND per-issue label
  `ai-pre-preview` (sibling of `auto-review` / `ai-auto-review`), computed by
  `scripts/check-preview-gate.sh`.
- **Behavior:** reuse `find-pipeline-pr.sh` + `review-pr.sh`. On `approve`,
  `gh pr ready` only — **no merge envelope, no `gh pr merge`**; a human merges.
  Non-approve / missing PR leaves the PR draft and stamps `ai:review-blocked`
  via `post-auto-review-block.sh` (with `MODE=pre-preview` wording).
- **No self-modification guard.** Promote-to-ready performs no merge, so
  (unlike auto_review) it is safe on `freaxnx01/agent-pipeline` itself — this
  repo can dogfood pre-preview.
- **Precedence:** if an issue carries both gating labels, **pre-preview wins**
  — the `auto_review` job gate gains `&& pre-preview-enabled != 'true'`. This
  fail-safes toward human control: ambiguous intent must not auto-merge.
- **Self-fix deferred.** The agent fixing its own findings is out of scope;
  tracked as a follow-up.

### Consequences

- Two near-duplicate jobs (`auto_review`, `pre_preview`) share scaffolding by
  copy, not abstraction. Accepted for isolation — the ADR-002 auto-merge job's
  internals stay byte-for-byte. If a fourth flow appears, extract the shared
  "checkout + find PR + review" into a composite action (brainstorming
  approach C).
- The reusable workflow gains `pre-preview` / `stub-pre-preview-enabled` inputs
  and `pre-preview-{merge,ready}-attempted` outputs.
```

- [ ] **Step 3: Lint (markdown has no linter here; just confirm the build isn't broken)**

Run: `bash tests/run-script-tests.sh`
Expected: PASS (docs don't affect scripts; this just confirms nothing regressed).

- [ ] **Step 4: Commit**

```bash
git add docs/CONSUMER-SETUP.md docs/DECISIONS.md
git commit -m "docs: pre-preview flow #3 + ADR-004 (#77)"
```

---

## Task 9: Push, open PR, confirm CI green, update #77

**Files:** none (integration)

- [ ] **Step 1: Run the full local gate once more**

```bash
bash tests/run-script-tests.sh
shellcheck -x -e SC1091 scripts/check-preview-gate.sh scripts/post-auto-review-block.sh scripts/verify-gh-mock-merge.sh scripts/ensure-issue-labels.sh
actionlint
```

Expected: all green / no output.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/pre-preview-mode
```

(Use the freaxnx01 `.envrc` token: `direnv exec /home/admin/repos/github/freaxnx01 bash -c 'GITHUB_TOKEN="$GH_TOKEN" git push -u origin feat/pre-preview-mode'`.)

- [ ] **Step 3: Open the PR** (as freaxnx01)

```bash
gh pr create -R freaxnx01/agent-pipeline --base main --head feat/pre-preview-mode \
  --title "feat: pre-preview mode — agent self-review → human merge (#77)" \
  --body "Implements pre-preview mode per docs/superpowers/specs/2026-06-04-pre-preview-mode-design.md and ADR-004. Closes #77."
```

- [ ] **Step 4: Confirm CI green**

Run: `gh pr checks <PR#> -R freaxnx01/agent-pipeline`
Expected: `actionlint`, `shellcheck`, and the new `verify-pre-preview-*` jobs all pass; existing `verify-auto-review-*` jobs still pass (no regression).

- [ ] **Step 5: Update issue #77**

Check off the acceptance-criteria items now satisfied; note that self-fix remains a follow-up. (Do not auto-close — the human merges this PR, which closes #77 via "Closes #77".)

---

## Self-Review notes (author)

- **Spec coverage:** opt-in surface (Tasks 1,2,5) · precedence/pre-preview-wins (Task 5) · separate pre_preview job, no envelope, no self-mod guard (Task 6) · MODE wording (Task 3) · ready-attempted assertion helper (Task 4) · two-layer tests (Tasks 1-4 layer-1, Task 7 layer-2) · docs + ADR-004 (Task 8). Self-fix explicitly deferred (ADR-004). All spec sections map to a task.
- **No placeholders:** every script/YAML/edit shows full content.
- **Name consistency:** `check-preview-gate.sh`, input `pre-preview`, `stub-pre-preview-enabled`, label `ai-pre-preview`, job `pre_preview`, outputs `pre-preview-enabled` / `pre-preview-merge-attempted` / `pre-preview-ready-attempted`, `MODE=pre-preview` — used identically across all tasks.
