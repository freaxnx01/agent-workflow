# Headless Escalation Fails Closed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the auto lane's `needs-human` brake hold in two places where it can fail today: the driver's "enrich did not complete" branch, and headless `/enrich` running where `needs-human` was never created.

**Architecture:** The contract between the nested `claude --print` session and `scripts/autopilot.sh` is **issue label state**, not exit status (the CLI exits 0 whatever the model decides). Task 1 makes the driver escalate the one ambiguous state it currently skips, through a helper it shares with the crash path. Task 2 makes `commands/enrich.md`'s headless mode create `needs-human` before applying it, read it back, and stop rather than wait on any failed or denied call — the driver from Task 1 is the backstop for that stop.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `gh` (mocked in tests by `tests/mocks/gh`), Markdown command files, Layer-1 fixture tests discovered by `tests/run-all.sh`.

**Spec:** `docs/superpowers/specs/2026-10-04-headless-escalation-fail-closed-design.md`

## Global Constraints

- Every escalation write is **one** `gh issue edit` carrying both `--add-label needs-human` and `--remove-label enrichment-ongoing` — two calls race (#365).
- Every escalation write in the driver goes through `with_backoff` (from `scripts/lib/gh-retry.sh`) and sets `AUTOPILOT_WROTE=1` **before** the call.
- `needs-human` color is `D93F0B`, description `Autopilot could not decide this unattended — a human must resolve it` — verbatim from `scripts/ensure-issue-labels.sh:113`.
- The crash branch's existing log text (`failed (enrich exited <rc>)`, `failed (enrich timed out after <n>s)`, and the `; ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set` suffix) is unchanged.
- No escalation path ever applies `ai-implement`.
- Never modify an existing assertion to make it pass, except the one Task 1 changes on purpose (the spec changes that behaviour).
- `shellcheck -x`, `actionlint`, `markdownlint-cli2` and `bash tests/run-all.sh` must all be clean before the PR.

## Review Focus

1. **The not-completed branch when the label re-read fails.** `issue_label_state` returning 2 for `needs-enrichment` must still *skip* (no write) — escalating on an unreadable state would be a write based on a guess. The existing "an unreadable label state dispatches nothing" test covers it; it must still pass unchanged.
2. **`needs-human` already present after an incomplete run.** Covered by the earlier `needs-human` arm (logs `needs-human`, no write) — order of the arms must not change.
3. **`gh label create` against an existing label** fails non-zero; the headless snippet must swallow that (`2>/dev/null || true`) or a repo that already has the label could never escalate. Task 2's doc test asserts the `|| true`.
4. **The read-back reports `false`** (label write silently lost). The headless text must say: report and stop, do not dispatch — asserted in Task 2's doc test via the `index("needs-human")` read-back line.
5. **A lock left behind by a stopped session.** The driver's escalation removes `enrichment-ongoing` regardless of whether the session's best-effort release worked — Task 1's test asserts `--remove-label enrichment-ongoing` in the single edit.

---

### Task 1: Driver escalates an enrich that neither enriched nor escalated

**Files:**
- Modify: `scripts/autopilot.sh:171-244` (`process_issue`; add `escalate_issue` just above it)
- Modify: `docs/AUTOPILOT.md:118` and `:121` (log table) and `:149-154` ("When something is wedged")
- Test: `tests/run-autopilot-driver-tests.sh:308-333` (the "rc==0 with needs-enrichment still present" case) plus one new case after it

**Interfaces:**
- Consumes: `with_backoff` (`scripts/lib/gh-retry.sh`), `log_issue <repo> <n> <text>`, `AUTOPILOT_WROTE` (all existing in `scripts/autopilot.sh`).
- Produces: `escalate_issue <repo> <n> <reason>` — command, returns 0 always. Adds `needs-human` and removes `enrichment-ongoing` in one retried call; logs `<reason>` on success, `<reason>; ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set` on failure.

- [ ] **Step 1: Write the failing test**

In `tests/run-autopilot-driver-tests.sh`, replace the block that starts at
`out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-not-enriched.map" run_driver)"` and ends
with the `fi` closing the "an incomplete enrich dispatches nothing (Fix 1)"
check with:

```bash
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-not-enriched.map" run_driver)"
case "$out" in
  *"o/r#41 failed (enrich did not complete)"*)
    pass "rc==0 with needs-enrichment still present is logged as a failure (#458)" ;;
  *) fail "rc==0 with needs-enrichment still present is logged as a failure (#458)" "output was: $out" ;;
esac
edits="$(grep 'issue edit' "$GH_MOCK_LOG" || true)"
assert_eq "an incomplete enrich escalates in a single call (#458)" "1" \
  "$(printf '%s\n' "$edits" | grep -c 'issue edit')"
case "$edits" in
  *"--add-label needs-human"*"--remove-label enrichment-ongoing"*)
    pass "an incomplete enrich adds needs-human and releases the lock (#458)" ;;
  *) fail "an incomplete enrich adds needs-human and releases the lock (#458)" "edits were: $edits" ;;
esac
if printf '%s\n' "$edits" | grep -q 'ai-implement'; then
  fail "an incomplete enrich dispatches nothing (Fix 1)" "$edits"
else
  pass "an incomplete enrich dispatches nothing (Fix 1)"
fi

# --- #458: the same incomplete enrich, and the escalation write fails too.
#     Must be called out distinctly, and still never dispatch. ---
printf 'issue edit\n' > "$TMPDIR_T/gh-fail-edit-458.map"
out="$(GH_MOCK_STDOUT_MAP="$TMPDIR_T/gh-not-enriched.map" \
  GH_MOCK_FAIL_MAP="$TMPDIR_T/gh-fail-edit-458.map" GH_RETRY_MAX=1 run_driver)"
case "$out" in
  *"failed (enrich did not complete); ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set"*)
    pass "a failed escalation of an incomplete enrich is called out (#458)" ;;
  *) fail "a failed escalation of an incomplete enrich is called out (#458)" "output was: $out" ;;
esac
if grep 'issue edit' "$GH_MOCK_LOG" | grep -q 'ai-implement'; then
  fail "a failed escalation of an incomplete enrich dispatches nothing (#458)" "$(grep 'issue edit' "$GH_MOCK_LOG")"
else
  pass "a failed escalation of an incomplete enrich dispatches nothing (#458)"
fi
```

Also update the comment above the `labels-not-enriched.json` fixture (the
lines ending `…not just on the absence of needs-human. ---`) by appending:

```bash
#     Since #458 it also escalates: the state is exactly what a session that
#     stopped on an error (or whose own needs-human write failed) leaves
#     behind, and skipping it left enrichment-ongoing set with no human told.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-autopilot-driver-tests.sh`
Expected: FAIL — `rc==0 with needs-enrichment still present is logged as a failure (#458)` (output still says `skipped (enrich did not complete — …)`), `an incomplete enrich escalates in a single call (#458)` (expected 1, actual 0), and both new `#458` failure-path assertions.

- [ ] **Step 3: Write minimal implementation**

In `scripts/autopilot.sh`, add this helper directly above `process_issue()`:

```bash
# Hands issue $2 in repo $1 to a human: needs-human added and the
# enrichment-ongoing lock released in ONE call, so a failure cannot release
# the lock while leaving the issue unlabelled (#365). Retried via gh-retry.sh
# because a transient blip on this exact call is the one failure mode that
# defeats the whole anti-poison-issue design: needs-human never lands,
# enrichment-ongoing stays set, and autopilot-candidates.sh excludes issues
# carrying enrichment-ongoing — so the issue silently drops out of the lane
# for good. $3 is the log reason; on success it is logged alone, which
# docs/AUTOPILOT.md documents as "escalated".
escalate_issue() {
  local repo="$1" n="$2" reason="$3" rc=0
  AUTOPILOT_WROTE=1
  with_backoff gh issue edit "$n" --repo "$repo" \
    --add-label needs-human --remove-label enrichment-ongoing >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )); then
    log_issue "$repo" "$n" \
      "$reason; ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set"
    return 0
  fi
  log_issue "$repo" "$n" "$reason"
}
```

Replace the crash branch (`if (( rc != 0 )); then … fi` after the `timeout`
call) with:

```bash
  if (( rc != 0 )); then
    # A crash escalates to a human, not just to the log. Without this, an issue
    # that reliably kills the enrich session re-spawns a paid nested session on
    # every run, forever.
    local reason
    if (( rc == 124 )); then
      reason="failed (enrich timed out after ${AUTOPILOT_ENRICH_TIMEOUT}s)"
    else
      reason="failed (enrich exited $rc)"
    fi
    escalate_issue "$repo" "$n" "$reason"
    return 0
  fi
```

Replace the `needs-enrichment` arm `0)` with:

```bash
    0) # The session returned without enriching OR escalating — a prose-only
       # reply, a denied tool, a stop on an error, or its own needs-human
       # write failing. Escalate rather than skip: a skip leaves
       # enrichment-ongoing set and nobody told (#458).
       escalate_issue "$repo" "$n" "failed (enrich did not complete)"; return 0 ;;
```

Leave the `*)` arm (`skipped (could not read labels — not dispatching)`) unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-autopilot-driver-tests.sh`
Expected: PASS, `failed: 0` — including the unchanged crash, timeout, "an unreadable label state dispatches nothing" and "the escalation write failure is visible (Critical 2)" cases.

- [ ] **Step 5: Update `docs/AUTOPILOT.md`**

Replace the table row at `:121` (`skipped (enrich did not complete — needs-enrichment still present)`) with:

```markdown
| `failed (enrich did not complete)` | The nested session exited 0 but neither enriched nor escalated the issue (prose-only reply, a denied tool, a stop on an error, or its own `needs-human` write failing) — `needs-enrichment` is still there and `needs-human` is not. Escalated to `needs-human` and the lock released, so the issue cannot silently drop out of the lane (#458) |
```

Replace the row at `:118` with:

```markdown
| `failed (…); ESCALATION FAILED: needs-human not applied, enrichment-ongoing may still be set` | Any escalation above (timeout, crash, incomplete enrich), AND the escalation call itself failed — the issue may be stuck; fix by hand |
```

In "When something is wedged", replace the first sentence of the
stuck-`enrichment-ongoing` bullet (`**An issue is stuck with \`enrichment-ongoing\` and no run in flight.**`) by:

```markdown
- **An issue is stuck with `enrichment-ongoing` and no run in flight.** The
  driver releases the lock on every escalation, so this means either a run
  logged `ESCALATION FAILED`, or the run itself was killed (e.g. the unit's
  `TimeoutStartSec`). Nothing releases it automatically after that:
```

keeping the rest of the bullet (`/enrich`'s staleness check … `--remove-label enrichment-ongoing`) as is.

- [ ] **Step 6: Lint and commit**

Run: `shellcheck -x -e SC1091 scripts/autopilot.sh tests/run-autopilot-driver-tests.sh && npx --no-install markdownlint-cli2 docs/AUTOPILOT.md`
Expected: no output from shellcheck, `0 issues` from markdownlint.

```bash
git add scripts/autopilot.sh tests/run-autopilot-driver-tests.sh docs/AUTOPILOT.md
git commit -m "fix(autopilot): escalate an enrich that neither enriched nor escalated

Refs #458"
```

---

### Task 2: Headless `/enrich` creates `needs-human`, reads it back, never waits

**Files:**
- Modify: `commands/enrich.md:55-105` (the `## Headless mode` section)
- Create: `tests/run-enrich-headless-doc-tests.sh` (auto-discovered by `tests/run-all.sh`)

**Interfaces:**
- Consumes: Task 1's driver behaviour — the never-wait rule names it as the backstop (doc reference only, no code dependency).
- Produces: nothing other tasks call.

- [ ] **Step 1: Write the failing test**

Create `tests/run-enrich-headless-doc-tests.sh`:

```bash
#!/usr/bin/env bash
#
# run-enrich-headless-doc-tests.sh — Layer-1 checks on commands/enrich.md's
# "## Headless mode" section (#458). The section is a prompt, not a script, so
# these assert the shape the headless escalation depends on:
#   - needs-human is created before the escalation edit applies it, with the
#     color and description scripts/ensure-issue-labels.sh registers;
#   - the create swallows "already exists";
#   - the escalation is read back;
#   - the never-wait rule is stated, and says label state is the contract.
#
# Usage: tests/run-enrich-headless-doc-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/enrich.md"
LABELS="$ROOT/scripts/ensure-issue-labels.sh"

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

# The headless section: from its heading up to the next level-2 heading.
section="$(awk '/^## Headless mode$/{on=1; print; next} on && /^## /{exit} on{print}' "$DOC")"
[[ -n "$section" ]] || { printf 'no "## Headless mode" section in %s\n' "$DOC" >&2; exit 1; }

# needs-human's registered color and description, from the label registry.
registry_line="$(grep -E "^create needs-human " "$LABELS")"
color="$(printf '%s\n' "$registry_line" | awk '{print $3}')"
description="$(printf '%s\n' "$registry_line" | sed -E "s/^create needs-human [0-9A-Fa-f]{6} '(.*)'$/\1/")"

create_line="$(printf '%s\n' "$section" | grep -n 'gh label create needs-human' | head -1 | cut -d: -f1 || true)"
edit_line="$(printf '%s\n' "$section" | grep -n 'gh issue edit .*--add-label needs-human' | head -1 | cut -d: -f1 || true)"

if [[ -n "$create_line" ]]; then
  pass "headless mode creates needs-human"
else
  fail "headless mode creates needs-human" "no 'gh label create needs-human' in the section"
fi

if [[ -n "$create_line" && -n "$edit_line" ]] && (( create_line < edit_line )); then
  pass "the create precedes the escalation edit"
else
  fail "the create precedes the escalation edit" "create at ${create_line:-none}, edit at ${edit_line:-none}"
fi

if printf '%s\n' "$section" | grep -q -- "--color $color"; then
  pass "the create uses the registry color ($color)"
else
  fail "the create uses the registry color ($color)"
fi

if printf '%s\n' "$section" | grep -qF -- "$description"; then
  pass "the create uses the registry description"
else
  fail "the create uses the registry description" "expected: $description"
fi

if printf '%s\n' "$section" | grep -A3 'gh label create needs-human' | grep -qF '|| true'; then
  pass "the create swallows 'already exists'"
else
  fail "the create swallows 'already exists'"
fi

if printf '%s\n' "$section" | grep -qF 'index("needs-human")'; then
  pass "the escalation is read back"
else
  fail "the escalation is read back"
fi

if printf '%s\n' "$section" | grep -q '^### Never wait$'; then
  pass "the never-wait rule has its own heading"
else
  fail "the never-wait rule has its own heading"
fi

if printf '%s\n' "$section" | grep -qi 'label state'; then
  pass "the rule names label state as the contract"
else
  fail "the rule names label state as the contract"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'failed:\n'
  for n in "${FAIL_NAMES[@]}"; do printf -- '  - %s\n' "$n"; done
  exit 1
fi
exit 0
```

Then `chmod +x tests/run-enrich-headless-doc-tests.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run-enrich-headless-doc-tests.sh`
Expected: FAIL — `headless mode creates needs-human`, `the create precedes the escalation edit`, the color/description/`|| true` checks, `the escalation is read back`, `the never-wait rule has its own heading`. (`label state` may also fail.)

- [ ] **Step 3: Write minimal implementation**

In `commands/enrich.md`, replace this part of `## Headless mode`:

````markdown
Apply steps 3 and 4 in a **single** `gh issue edit` call — two calls against the
same issue race, which is the lesson of #365:

```bash
gh issue edit $ISSUE --add-label needs-human --remove-label enrichment-ongoing
```
````

with:

````markdown
Apply steps 3 and 4 in a **single** `gh issue edit` call — two calls against the
same issue race, which is the lesson of #365. Create `needs-human` first: a repo
that has never run the pipeline does not have it yet, and one missing label
fails the whole edit, so the escalation would not happen at all (#455, #458).
Color and description match `scripts/ensure-issue-labels.sh`; the create fails
harmlessly when the label already exists. Then read it back:

```bash
gh label create needs-human --color D93F0B \
  --description "Autopilot could not decide this unattended — a human must resolve it" \
  2>/dev/null || true
gh issue edit $ISSUE --add-label needs-human --remove-label enrichment-ongoing
gh issue view $ISSUE --json labels --jq '[.labels[].name] | index("needs-human") != null'
```

If the read-back prints anything but `true`, the escalation did not land.
Follow [Never wait](#never-wait): report the error and stop. Do not retry
with variations and do not go on to any later step.

### Never wait

A headless run has nobody to answer a prompt and nobody to notice a stall. If a
tool call fails or is denied and the current step cannot go on without it:

1. Do not retry it with variations — a denied call stays denied.
2. Release the lock, best effort:
   `gh issue edit $ISSUE --remove-label enrichment-ongoing`. If that fails
   too, say so.
3. Make the exact error text the final output, and stop.

The session's exit status is **not** part of the contract: `claude --print`
exits 0 whatever the model decides. Label state is. A run that stops this way
leaves `needs-enrichment` on and `needs-human` off, and `scripts/autopilot.sh`
escalates exactly that state to `needs-human` (#458). Outside the lane — a
manual `/enrich --headless`, a batch of subagents — the error text is the only
signal, so it must be the last thing the run says.
````

Leave the paragraph that follows (`Headless mode changes nothing else. …`) where it is, after the new `### Never wait` subsection.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run-enrich-headless-doc-tests.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Full suite, lint, commit**

Run: `bash tests/run-all.sh && shellcheck -x -e SC1091 tests/run-enrich-headless-doc-tests.sh && npx --no-install markdownlint-cli2 commands/enrich.md`
Expected: every runner passes, no shellcheck output, `0 issues`.

```bash
git add commands/enrich.md tests/run-enrich-headless-doc-tests.sh
git commit -m "fix(enrich): headless mode creates needs-human and never waits

Refs #458"
```

The PR body says `Closes #458` and quotes both RED/GREEN runs.
