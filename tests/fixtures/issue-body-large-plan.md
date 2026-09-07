The two review flows are named for the wrong thing.

`pre-preview` names a *stage* — and a doubled one, a thing before a preview —
when the actual differentiator against its sibling is **who merges**.
`auto-review` has the mirror problem: it names the review half and stays silent
on the automatic merge, the part that carries all the risk. Neither name tells a
maintainer scanning issue labels which flow ends with a machine pushing to
`main`.

Rename both to actor-pair names — who reviews, who merges:

| old | new |
|---|---|
| `auto-review` / `ai-auto-review` / `auto_review` | `ai-review-ai-merge` |
| `pre-preview` / `ai-pre-preview` / `pre_preview` | `ai-review-human-merge` |

Old workflow inputs and issue labels keep working with a `::warning::`
annotation until **v3**. Behaviour and precedence are unchanged.

## Acceptance Criteria

- [ ] Workflow inputs `ai-review-ai-merge` and `ai-review-human-merge` exist and drive their flows
- [ ] Issue labels `ai-review-ai-merge` and `ai-review-human-merge` are what `ensure-issue-labels.sh` creates
- [ ] Jobs are `ai_review_ai_merge` and `ai_review_human_merge`
- [ ] Gate scripts are `check-ai-merge-gate.sh` and `check-human-merge-gate.sh`
- [ ] Deprecated inputs `auto-review` / `pre-preview` still enable their flow, each emitting `::warning::… (removed in v3)`
- [ ] Deprecated labels `ai-auto-review` / `ai-pre-preview` still match, each emitting `::warning::… (removed in v3)`
- [ ] An issue carrying both the new and the old label reports the new one and warns about neither
- [ ] Output `auto-review-enabled` still resolves, as an alias of `ai-review-ai-merge-enabled`
- [ ] Precedence unchanged: both flows enabled → human-merge runs, ai-merge is skipped
- [ ] `ensure-issue-labels.sh` creates only the new labels; no label is deleted, and no issue's labels are mutated by the pipeline
- [ ] Nothing under `docs/superpowers/`, no released `CHANGELOG.md` entry, and no ADR-002/ADR-004 body text is renamed (one appended supersession line each is the only edit)
- [ ] ADR-009 records the decision
- [ ] `docs/CONSUMER-SETUP.md` carries the migration section with the `gh` bulk-relabel commands
- [ ] `just lint`, `just test` (under 5s) and `just test-act` all green

## Implementation Plan

# Actor-Pair Flow Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the pipeline's two review flows so their names state who reviews and who merges — `auto-review` becomes `ai-review-ai-merge`, `pre-preview` becomes `ai-review-human-merge` — while old workflow inputs and issue labels keep working until v3.

**Architecture:** Two gate scripts decide whether each flow runs. They gain dual-name tolerance: each reads both the new and the deprecated env var, ORs them, matches either the new or the deprecated issue label, and emits a `::warning::` annotation when a deprecated spelling is what matched. Everything else — job ids, workflow inputs/outputs, `MODE` values, onboarding flags, docs — is a mechanical rename with no behaviour change. Precedence is unchanged: when both flows are enabled for an issue, the human-merge flow wins.

**Tech Stack:** Bash 5 (`set -euo pipefail`), GitHub Actions reusable workflows, `gh` CLI, `shellcheck`, `actionlint`, `act`, fixture-driven bash tests in `tests/run-script-tests.sh`.

**Spec:** `docs/superpowers/specs/2026-08-30-actor-pair-flow-naming-design.md`

## Global Constraints

- Every bash script starts with `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. Quote every variable expansion. Use `[[ ... ]]`, never `[ ... ]`. No `eval`.
- Exit codes are API: `0` success, `2` required env missing or an input value outside `{true,false}`.
- Deprecated names are removed in **v3**. Every deprecation warning must say so verbatim: `(removed in v3)`.
- Warnings go to **stdout**, not stderr — GitHub Actions only parses workflow commands (`::warning::`) from stdout, and the Layer-1 tests capture stdout.
- Never delete a label from a consumer repo, and never mutate labels on an issue. The pipeline tolerates old labels; the maintainer migrates them.
- Files under `docs/superpowers/plans/`, `docs/superpowers/specs/`, and existing `CHANGELOG.md` entries are **immutable history** — do not rename anything inside them. The bodies of ADR-002 and ADR-004 in `docs/DECISIONS.md` are likewise immutable except for one appended supersession line each.
- Do not pin GitHub Actions to floating tags. Do not loosen workflow `permissions:`. Do not add inline bash longer than 5 lines to a YAML step.
- Commit messages follow Conventional Commits. Commit after every task.

**The rename map** (memorize; it recurs in every task):

| Surface | old | new |
|---|---|---|
| Input / label (flow 2) | `auto-review` / `ai-auto-review` | `ai-review-ai-merge` |
| Input / label (flow 3) | `pre-preview` / `ai-pre-preview` | `ai-review-human-merge` |
| Job id | `auto_review` / `pre_preview` | `ai_review_ai_merge` / `ai_review_human_merge` |
| Gate script | `check-auto-review-gate.sh` / `check-preview-gate.sh` | `check-ai-merge-gate.sh` / `check-human-merge-gate.sh` |
| Gate env var | `INPUT_AUTO_REVIEW` / `INPUT_PRE_PREVIEW` | `INPUT_AI_REVIEW_AI_MERGE` / `INPUT_AI_REVIEW_HUMAN_MERGE` |
| `post-auto-review-block.sh` `MODE=` | `auto-review` / `pre-preview` | `ai-merge` / `human-merge` |
| `onboard-consumer.sh` flag | `--auto-review` / `--pre-preview` | `--ai-review-ai-merge` / `--ai-review-human-merge` |

---

### Task 1: Human-merge gate script

The flow-3 gate. Renamed file, dual-name input and label tolerance, deprecation warnings.

**Files:**
- Rename: `scripts/check-preview-gate.sh` → `scripts/check-human-merge-gate.sh` (use `git mv`)
- Test: `tests/run-script-tests.sh` (section currently titled `check-preview-gate — input + label combinations`, around line 611)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a script read via `bash .claude-pipeline/scripts/check-human-merge-gate.sh`. Env in: `ISSUE_NUMBER` (required), `REPO` (or `GITHUB_REPOSITORY`, required), `INPUT_AI_REVIEW_HUMAN_MERGE` (`true`/`false`, default `false`), `INPUT_PRE_PREVIEW` (deprecated, same domain and default), `ISSUE_LABELS` (optional; newline-separated, skips the `gh` call), `GH_TOKEN`. Writes `enabled=true|false` and `reason=<text>` to `$GITHUB_OUTPUT`. Task 4 wires it.

- [ ] **Step 1: Rename the file**

```bash
git mv scripts/check-preview-gate.sh scripts/check-human-merge-gate.sh
```

- [ ] **Step 2: Write the failing tests**

In `tests/run-script-tests.sh`, replace the whole `section "check-preview-gate — input + label combinations"` block (from that `section` line down to, but not including, the next `section` line) with:

```bash
section "check-human-merge-gate — input + label combinations"

HGATE="$ROOT/scripts/check-human-merge-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=false ISSUE_LABELS='ai-implement' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=false ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS='ai-implement' bash "$HGATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-review-human-merge missing)' "input=true, no label → disabled"

# Both new → enabled, no deprecation warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "new input + new label → enabled"
assert_not_contains "$out" '::warning::' "new input + new label → no deprecation warning"

# Deprecated input + deprecated label → enabled, two warnings
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-pre-preview present)' "deprecated input + deprecated label → enabled"
assert_contains "$out" "::warning::workflow input 'pre-preview' is deprecated; rename it to 'ai-review-human-merge' (removed in v3)" "deprecated input → warning"
assert_contains "$out" "::warning::issue label 'ai-pre-preview' is deprecated; relabel it to 'ai-review-human-merge' (removed in v3)" "deprecated label → warning"

# New input + deprecated label → enabled, label warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-implement\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-pre-preview present)' "new input + deprecated label → enabled"
assert_not_contains "$out" "workflow input 'pre-preview' is deprecated" "new input + deprecated label → no input warning"
assert_contains "$out" "::warning::issue label 'ai-pre-preview' is deprecated" "new input + deprecated label → label warning"

# Deprecated input + new label → enabled, input warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=true ISSUE_LABELS=$'ai-implement\nai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "deprecated input + new label → enabled"
assert_contains "$out" "::warning::workflow input 'pre-preview' is deprecated" "deprecated input + new label → input warning"
assert_not_contains "$out" "issue label 'ai-pre-preview' is deprecated" "deprecated input + new label → no label warning"

# Both labels present → new label wins the reason text, no label warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true ISSUE_LABELS=$'ai-review-human-merge\nai-pre-preview' bash "$HGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-human-merge present)' "both labels → new label wins"
assert_not_contains "$out" "issue label 'ai-pre-preview' is deprecated" "both labels → no label warning"

# Both inputs unset → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-review-human-merge' bash "$HGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-human-merge=false)' "unset inputs default to false"

# Invalid new input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=yes ISSUE_LABELS='' bash "$HGATE")"
assert_equals "$ec" "2" "invalid INPUT_AI_REVIEW_HUMAN_MERGE → exit 2"

# Invalid deprecated input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_PRE_PREVIEW=yes ISSUE_LABELS='' bash "$HGATE")"
assert_equals "$ec" "2" "invalid INPUT_PRE_PREVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_AI_REVIEW_HUMAN_MERGE=true bash "$HGATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_AI_REVIEW_HUMAN_MERGE=true bash "$HGATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-script-tests.sh`
Expected: FAIL — the assertions reference `INPUT_AI_REVIEW_HUMAN_MERGE`, which the script ignores, so it reports `enabled=false (workflow input pre-preview=false)`.

- [ ] **Step 4: Rewrite the script**

Replace the entire contents of `scripts/check-human-merge-gate.sh` with:

```bash
#!/usr/bin/env bash
#
# check-human-merge-gate.sh — Decide whether to run the AI-review /
# human-merge flow for this issue. The flow itself lives in the
# `ai_review_human_merge` job; this script only computes the gate so
# callers can branch on its output.
#
# The flow (ADR-004, renamed by ADR-009): after the pipeline opens a draft
# PR, the agent reviews it and, on approve, promotes it to ready so a HUMAN
# merges. It never auto-merges. Sibling of check-ai-merge-gate.sh.
#
# The gate is `true` iff BOTH:
#   - the workflow input `ai-review-human-merge` is `true`, AND
#   - the issue carries the `ai-review-human-merge` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. Precedence vs. the AI-merge flow (human-merge
# wins when both are enabled) is enforced in the workflow, not here.
#
# Deprecated spellings (ADR-009, removed in v3): the input `pre-preview`
# and the label `ai-pre-preview` are still honoured, each with a
# `::warning::` annotation naming the replacement.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   INPUT_AI_REVIEW_HUMAN_MERGE  "true" or "false" (default "false")
#   INPUT_PRE_PREVIEW            deprecated alias of the above
#   ISSUE_LABELS  Newline- or space-separated labels. If set, skips the
#                 `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `enabled=true|false` and `reason=<text>` to $GITHUB_OUTPUT
#   when set, and prints a one-line `enabled=<bool> (<reason>)` summary
#   to stdout. Deprecation warnings precede that line on stdout, because
#   GitHub only parses workflow commands from stdout.
#
# Exit codes:
#   0  success
#   2  required env missing, or an input is not in {true,false}
set -euo pipefail
IFS=$'\n\t'

NEW_INPUT_NAME='ai-review-human-merge'
OLD_INPUT_NAME='pre-preview'
NEW_LABEL='ai-review-human-merge'
OLD_LABEL='ai-pre-preview'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *)
      printf 'error: %s must be "true" or "false" (got %q)\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

INPUT_NEW="${INPUT_AI_REVIEW_HUMAN_MERGE:-false}"
INPUT_OLD="${INPUT_PRE_PREVIEW:-false}"
require_bool INPUT_AI_REVIEW_HUMAN_MERGE "$INPUT_NEW"
require_bool INPUT_PRE_PREVIEW "$INPUT_OLD"

# --- resolve the input, preferring the new spelling -----------------------

input_on=false
if [[ "$INPUT_NEW" == 'true' ]]; then
  input_on=true
elif [[ "$INPUT_OLD" == 'true' ]]; then
  input_on=true
  printf "::warning::workflow input '%s' is deprecated; rename it to '%s' (removed in v3)\n" \
    "$OLD_INPUT_NAME" "$NEW_INPUT_NAME"
fi

# --- short-circuit: input off ---------------------------------------------

if [[ "$input_on" != 'true' ]]; then
  enabled=false
  reason="workflow input ${NEW_INPUT_NAME}=false"
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  matched_label=''
  while IFS= read -r label; do
    if [[ "$label" == "$NEW_LABEL" ]]; then
      matched_label="$NEW_LABEL"
      break
    fi
    if [[ "$label" == "$OLD_LABEL" ]]; then
      matched_label="$OLD_LABEL"
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$matched_label" == "$OLD_LABEL" ]]; then
    printf "::warning::issue label '%s' is deprecated; relabel it to '%s' (removed in v3)\n" \
      "$OLD_LABEL" "$NEW_LABEL"
  fi

  if [[ -n "$matched_label" ]]; then
    enabled=true
    reason="input=true AND label ${matched_label} present"
  else
    enabled=false
    reason="input=true but label ${NEW_LABEL} missing"
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
```

Note the loop deliberately `break`s only on the new label: the old label is recorded but the scan continues, so an issue carrying both reports the new one and warns about neither.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-script-tests.sh`
Expected: PASS, all assertions in the `check-human-merge-gate` section green, whole suite under 5 seconds.

- [ ] **Step 6: Lint**

Run: `shellcheck -x -e SC1091 scripts/check-human-merge-gate.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-human-merge-gate.sh tests/run-script-tests.sh
git commit -m "refactor(gate): rename pre-preview gate to check-human-merge-gate

Renames the flow-3 gate to name its actor pair and teaches it to accept
the deprecated 'pre-preview' input and 'ai-pre-preview' label, each with
a ::warning:: naming the replacement. Removed in v3."
```

---

### Task 2: AI-merge gate script

The flow-2 gate. Same shape as Task 1, mirrored onto the AI-merge names.

**Files:**
- Rename: `scripts/check-auto-review-gate.sh` → `scripts/check-ai-merge-gate.sh` (use `git mv`)
- Test: `tests/run-script-tests.sh` (section currently titled `check-auto-review-gate — input + label combinations`, around line 575)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a script read via `bash .claude-pipeline/scripts/check-ai-merge-gate.sh`. Env in: `ISSUE_NUMBER` (required), `REPO` (or `GITHUB_REPOSITORY`, required), `INPUT_AI_REVIEW_AI_MERGE` (`true`/`false`, default `false`), `INPUT_AUTO_REVIEW` (deprecated, same domain and default), `ISSUE_LABELS` (optional), `GH_TOKEN`. Writes `enabled=true|false` and `reason=<text>` to `$GITHUB_OUTPUT`. Task 4 wires it.

- [ ] **Step 1: Rename the file**

```bash
git mv scripts/check-auto-review-gate.sh scripts/check-ai-merge-gate.sh
```

- [ ] **Step 2: Write the failing tests**

In `tests/run-script-tests.sh`, replace the whole `section "check-auto-review-gate — input + label combinations"` block (from that `section` line down to, but not including, the next `section` line) with:

```bash
section "check-ai-merge-gate — input + label combinations"

AGATE="$ROOT/scripts/check-ai-merge-gate.sh"

# Both off → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=false ISSUE_LABELS='ai-implement' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "input=false, no label → disabled"

# Label only → still disabled (input gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=false ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "input=false, label set → disabled (input wins)"

# Input only → disabled (label gate not satisfied)
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS='ai-implement' bash "$AGATE")"
assert_contains "$out" 'enabled=false (input=true but label ai-review-ai-merge missing)' "input=true, no label → disabled"

# Both new → enabled, no deprecation warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "new input + new label → enabled"
assert_not_contains "$out" '::warning::' "new input + new label → no deprecation warning"

# Deprecated input + deprecated label → enabled, two warnings
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-auto-review present)' "deprecated input + deprecated label → enabled"
assert_contains "$out" "::warning::workflow input 'auto-review' is deprecated; rename it to 'ai-review-ai-merge' (removed in v3)" "deprecated input → warning"
assert_contains "$out" "::warning::issue label 'ai-auto-review' is deprecated; relabel it to 'ai-review-ai-merge' (removed in v3)" "deprecated label → warning"

# New input + deprecated label → enabled, label warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-implement\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-auto-review present)' "new input + deprecated label → enabled"
assert_not_contains "$out" "workflow input 'auto-review' is deprecated" "new input + deprecated label → no input warning"
assert_contains "$out" "::warning::issue label 'ai-auto-review' is deprecated" "new input + deprecated label → label warning"

# Deprecated input + new label → enabled, input warning only
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=true ISSUE_LABELS=$'ai-implement\nai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "deprecated input + new label → enabled"
assert_contains "$out" "::warning::workflow input 'auto-review' is deprecated" "deprecated input + new label → input warning"
assert_not_contains "$out" "issue label 'ai-auto-review' is deprecated" "deprecated input + new label → no label warning"

# Both labels present → new label wins the reason text, no label warning
out="$(ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true ISSUE_LABELS=$'ai-review-ai-merge\nai-auto-review' bash "$AGATE")"
assert_contains "$out" 'enabled=true (input=true AND label ai-review-ai-merge present)' "both labels → new label wins"
assert_not_contains "$out" "issue label 'ai-auto-review' is deprecated" "both labels → no label warning"

# Both inputs unset → disabled
out="$(ISSUE_NUMBER=1 REPO=o/r ISSUE_LABELS='ai-review-ai-merge' bash "$AGATE")"
assert_contains "$out" 'enabled=false (workflow input ai-review-ai-merge=false)' "unset inputs default to false"

# Invalid new input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AI_REVIEW_AI_MERGE=yes ISSUE_LABELS='' bash "$AGATE")"
assert_equals "$ec" "2" "invalid INPUT_AI_REVIEW_AI_MERGE → exit 2"

# Invalid deprecated input → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 REPO=o/r INPUT_AUTO_REVIEW=yes ISSUE_LABELS='' bash "$AGATE")"
assert_equals "$ec" "2" "invalid INPUT_AUTO_REVIEW → exit 2"

# Missing ISSUE_NUMBER → exit 2
ec="$(run_capture_ec env REPO=o/r INPUT_AI_REVIEW_AI_MERGE=true bash "$AGATE")"
assert_equals "$ec" "2" "missing ISSUE_NUMBER → exit 2"

# Missing REPO → exit 2
ec="$(run_capture_ec env ISSUE_NUMBER=1 INPUT_AI_REVIEW_AI_MERGE=true bash "$AGATE")"
assert_equals "$ec" "2" "missing REPO → exit 2"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `tests/run-script-tests.sh`
Expected: FAIL — the assertions reference `INPUT_AI_REVIEW_AI_MERGE`, which the script ignores, so it reports `enabled=false (workflow input auto-review=false)`.

- [ ] **Step 4: Rewrite the script**

Replace the entire contents of `scripts/check-ai-merge-gate.sh` with:

```bash
#!/usr/bin/env bash
#
# check-ai-merge-gate.sh — Decide whether to run the AI-review / AI-merge
# flow for this issue. The flow itself lives in the `ai_review_ai_merge`
# job; this script only computes the gate so callers can branch on its
# output.
#
# The flow (ADR-002, renamed by ADR-009): after the pipeline opens a draft
# PR, the agent reviews it and, inside the merge safety envelope,
# auto-merges. Sibling of check-human-merge-gate.sh.
#
# The gate is `true` iff BOTH:
#   - the workflow input `ai-review-ai-merge` is `true`, AND
#   - the issue carries the `ai-review-ai-merge` label.
#
# Either condition alone is a "no" — the input is a per-repo opt-in, the
# label is a per-issue opt-in. This script intentionally does NOT enforce
# the merge envelope (path checks, branch-protection checks); that lives
# in check-merge-envelope.sh per ADR-002.
#
# Deprecated spellings (ADR-009, removed in v3): the input `auto-review`
# and the label `ai-auto-review` are still honoured, each with a
# `::warning::` annotation naming the replacement.
#
# Required environment variables:
#   ISSUE_NUMBER  GitHub issue number
#   REPO          owner/repo (default: $GITHUB_REPOSITORY)
#   GH_TOKEN      (or ambient gh auth)
#
# Optional environment variables:
#   INPUT_AI_REVIEW_AI_MERGE  "true" or "false" (default "false")
#   INPUT_AUTO_REVIEW         deprecated alias of the above
#   ISSUE_LABELS  Newline- or space-separated labels. If set, skips the
#                 `gh issue view --json labels` call. Used by Layer-1 tests.
#
# Output:
#   Writes `enabled=true|false` and `reason=<text>` to $GITHUB_OUTPUT
#   when set, and prints a one-line `enabled=<bool> (<reason>)` summary
#   to stdout. Deprecation warnings precede that line on stdout, because
#   GitHub only parses workflow commands from stdout.
#
# Exit codes:
#   0  success
#   2  required env missing, or an input is not in {true,false}
set -euo pipefail
IFS=$'\n\t'

NEW_INPUT_NAME='ai-review-ai-merge'
OLD_INPUT_NAME='auto-review'
NEW_LABEL='ai-review-ai-merge'
OLD_LABEL='ai-auto-review'

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'error: %s must be set\n' "$1" >&2
    exit 2
  fi
}

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *)
      printf 'error: %s must be "true" or "false" (got %q)\n' "$name" "$value" >&2
      exit 2
      ;;
  esac
}

require_env ISSUE_NUMBER
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

INPUT_NEW="${INPUT_AI_REVIEW_AI_MERGE:-false}"
INPUT_OLD="${INPUT_AUTO_REVIEW:-false}"
require_bool INPUT_AI_REVIEW_AI_MERGE "$INPUT_NEW"
require_bool INPUT_AUTO_REVIEW "$INPUT_OLD"

# --- resolve the input, preferring the new spelling -----------------------

input_on=false
if [[ "$INPUT_NEW" == 'true' ]]; then
  input_on=true
elif [[ "$INPUT_OLD" == 'true' ]]; then
  input_on=true
  printf "::warning::workflow input '%s' is deprecated; rename it to '%s' (removed in v3)\n" \
    "$OLD_INPUT_NAME" "$NEW_INPUT_NAME"
fi

# --- short-circuit: input off ---------------------------------------------

if [[ "$input_on" != 'true' ]]; then
  enabled=false
  reason="workflow input ${NEW_INPUT_NAME}=false"
else
  # --- input on; check label --------------------------------------------

  if [[ -z "${ISSUE_LABELS:-}" ]]; then
    ISSUE_LABELS="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name')"
  fi

  matched_label=''
  while IFS= read -r label; do
    if [[ "$label" == "$NEW_LABEL" ]]; then
      matched_label="$NEW_LABEL"
      break
    fi
    if [[ "$label" == "$OLD_LABEL" ]]; then
      matched_label="$OLD_LABEL"
    fi
  done <<< "$ISSUE_LABELS"

  if [[ "$matched_label" == "$OLD_LABEL" ]]; then
    printf "::warning::issue label '%s' is deprecated; relabel it to '%s' (removed in v3)\n" \
      "$OLD_LABEL" "$NEW_LABEL"
  fi

  if [[ -n "$matched_label" ]]; then
    enabled=true
    reason="input=true AND label ${matched_label} present"
  else
    enabled=false
    reason="input=true but label ${NEW_LABEL} missing"
  fi
fi

printf 'enabled=%s (%s)\n' "$enabled" "$reason"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'enabled=%s\n' "$enabled" >> "$GITHUB_OUTPUT"
  printf 'reason=%s\n'  "$reason"  >> "$GITHUB_OUTPUT"
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-script-tests.sh`
Expected: PASS, all assertions in both gate sections green.

- [ ] **Step 6: Lint**

Run: `shellcheck -x -e SC1091 scripts/check-ai-merge-gate.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-ai-merge-gate.sh tests/run-script-tests.sh
git commit -m "refactor(gate): rename auto-review gate to check-ai-merge-gate

Renames the flow-2 gate to name its actor pair and teaches it to accept
the deprecated 'auto-review' input and 'ai-auto-review' label, each with
a ::warning:: naming the replacement. Removed in v3."
```

---

### Task 3: Labels and block-comment wording

`ensure-issue-labels.sh` starts creating only the new labels; `post-auto-review-block.sh` switches its `MODE` vocabulary to the actor-pair names.

**Files:**
- Modify: `scripts/ensure-issue-labels.sh` (the `gates` category comment near line 16, and the two `create ai-auto-review` / `create ai-pre-preview` lines near line 65)
- Modify: `scripts/post-auto-review-block.sh` (the `MODE` doc block near line 27, and the `case "$MODE"` near line 60)
- Modify (comments only): `scripts/self-fix-loop.sh`, `scripts/self-fix-pr.sh`, `scripts/verify-gh-mock-merge.sh`, `scripts/check-merge-envelope.sh`, `scripts/find-pipeline-pr.sh`
- Test: `tests/run-script-tests.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `post-auto-review-block.sh` now accepts `MODE=ai-merge` (default) or `MODE=human-merge`. Task 4 sets `MODE: human-merge` on the human-merge job. The script's filename does **not** change — it is shared by both flows.

- [ ] **Step 1: Write the failing test**

`tests/run-script-tests.sh` already has a `section "post-auto-review-block — reason selection + PR-vs-issue addressing"` around line 1022, with `POST_BLOCK` already defined. Append these cases to the **end of that existing section**, before the next `section` line.

Note the idiom this suite uses: the script posts through `gh`, so assertions read the mock's call log (`$GH_MOCK_LOG`), not stdout.

```bash
# MODE=human-merge → "Review held" prefix on the PR comment
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block MODE=human-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Review held:' "MODE=human-merge → 'Review held' prefix"
assert_not_contains "$calls" 'Pre-review held' "MODE=human-merge → no stale 'Pre-review held'"

# MODE=ai-merge (explicit) → auto-merge wording
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block MODE=ai-merge \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held:' "MODE=ai-merge → 'Auto-merge held' prefix"

# Unset MODE → same as ai-merge (default unchanged for callers mid-migration)
LOG="$(mktemp)"
PATH="$MOCKS:$PATH" GH_MOCK_LOG="$LOG" \
REPO=o/r ISSUE_NUMBER=42 PR_NUMBER=100 FOUND=true VERDICT=block \
  bash "$POST_BLOCK" >/dev/null
calls="$(cat "$LOG")"; rm -f "$LOG"
assert_contains "$calls" 'pr comment 100 --repo o/r --body Auto-merge held:' "unset MODE defaults to ai-merge wording"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `tests/run-script-tests.sh`
Expected: FAIL on the first new assertion — `MODE=human-merge` is unrecognized today, so the script falls through to the `*)` branch and posts `Auto-merge held:` instead of `Review held:`.

- [ ] **Step 3: Update `post-auto-review-block.sh`**

Replace the `MODE` lines in the header comment block:

```bash
#   MODE              Operational mode (default: ai-merge).
#                     "human-merge" switches the comment prefix to "Review held"
#                     instead of "Auto-merge held" / "Auto-review held".
#   SELF_FIX_ITERATIONS  Iterations the self-fix loop actually used (#81).
#                        "0" or unset → unchanged wording.
```

Replace the default assignment:

```bash
MODE="${MODE:-ai-merge}"
```

Replace the `case` block:

```bash
# Comment-prefix wording differs by mode; reason text is identical.
case "$MODE" in
  human-merge)
    pr_prefix='Review held'
    issue_prefix='Review held'
    ;;
  *)
    pr_prefix='Auto-merge held'
    issue_prefix='Auto-review held'
    ;;
esac
```

- [ ] **Step 4: Update `ensure-issue-labels.sh`**

Replace the `gates` line in the header comment block:

```bash
#   gates      ai-review-ai-merge, ai-review-human-merge, ai-chain, ai:chain-paused
#              — read by the review flows (epic #3, ADR-009) and
#                chain-dispatch (epic #4) workflows; user-applied opt-ins /
#                kill switch. The pre-ADR-009 names ai-auto-review and
#                ai-pre-preview are still honoured by the gates until v3,
#                but are no longer created here.
```

Replace the two `create` calls:

```bash
create ai-review-ai-merge     0E8A16 'AI reviews the PR and auto-merges on approve+green'
create ai-review-human-merge  1D76DB 'AI reviews the PR and promotes it to ready; a human merges'
```

Leave every other `create` line untouched.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run-script-tests.sh`
Expected: PASS.

- [ ] **Step 6: Update job names in shared-script comments**

Four shared scripts name the jobs in their header comments and must follow the rename. No logic changes — comments only:

- `scripts/self-fix-loop.sh` — header says "pre-preview's self-fix pass" and "the pre_preview job"; both become the human-merge flow / `ai_review_human_merge` job. Since #193 generalized this pass to both flows, word it as "invoked by whichever review job runs".
- `scripts/self-fix-pr.sh` — same header reference to "pre-preview's self-fix pass".
- `scripts/verify-gh-mock-merge.sh` — two comments naming "the pre_preview job" and "Pre-preview promotes the draft with `gh pr ready`".
- `scripts/check-merge-envelope.sh` and `scripts/find-pipeline-pr.sh` — one `auto_review` / `auto-review` mention each.

Verify: `grep -rn 'pre_preview\|pre-preview' scripts/` returns hits only in the two gate scripts' deprecated-name handling.

- [ ] **Step 7: Lint**

Run: `shellcheck -x -e SC1091 scripts/ensure-issue-labels.sh scripts/post-auto-review-block.sh scripts/self-fix-loop.sh scripts/self-fix-pr.sh scripts/verify-gh-mock-merge.sh`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/ensure-issue-labels.sh scripts/post-auto-review-block.sh scripts/self-fix-loop.sh scripts/self-fix-pr.sh scripts/verify-gh-mock-merge.sh scripts/check-merge-envelope.sh scripts/find-pipeline-pr.sh tests/run-script-tests.sh
git commit -m "refactor(labels): create actor-pair labels, rename block MODE values

ensure-issue-labels.sh creates ai-review-ai-merge and
ai-review-human-merge; pre-existing old labels are left alone since the
gates still honour them. MODE becomes ai-merge / human-merge."
```

---

### Task 4: Reusable workflow — inputs, outputs, jobs

The core rename. `agent-implement.yml` is the reusable workflow consumers call.

**Files:**
- Modify: `.github/workflows/agent-implement.yml`

**Interfaces:**
- Consumes: `scripts/check-ai-merge-gate.sh` and `scripts/check-human-merge-gate.sh` from Tasks 1–2, with the env-var names they document; `MODE=human-merge` from Task 3.
- Produces: inputs `ai-review-ai-merge`, `ai-review-human-merge` (booleans, default `false`); deprecated inputs `auto-review`, `pre-preview` retained; jobs `ai_review_ai_merge`, `ai_review_human_merge`; outputs `ai-review-ai-merge-enabled`, `ai-review-human-merge-enabled`, `ai-review-human-merge-merge-attempted`, `ai-review-human-merge-ready-attempted`, `ai-review-human-merge-self-fix-iterations-used`, `ai-review-ai-merge-merge-attempted`, `ai-review-ai-merge-self-fix-iterations-used`, plus the retained alias `auto-review-enabled`. Stub inputs become `stub-ai-merge-enabled`, `stub-human-merge-enabled`. Task 5 consumes all of these.

- [ ] **Step 1: Add the new inputs, deprecate the old**

In the `on.workflow_call.inputs` block, keep `auto-review:` and `pre-preview:` exactly where they are but replace each description, and add two new inputs after them:

```yaml
      auto-review:
        description: |
          DEPRECATED (ADR-009, removed in v3) — use `ai-review-ai-merge`.
          Still honoured by check-ai-merge-gate.sh, which emits a warning
          annotation when this is the only spelling set.
        type: boolean
        default: false
      pre-preview:
        description: |
          DEPRECATED (ADR-009, removed in v3) — use `ai-review-human-merge`.
          Still honoured by check-human-merge-gate.sh, which emits a warning
          annotation when this is the only spelling set.
        type: boolean
        default: false
      ai-review-ai-merge:
        description: |
          Per-repo opt-in for the AI-review + AI-merge flow (epic #3,
          ADR-002; named by ADR-009). When true AND the issue carries the
          `ai-review-ai-merge` label, the `ai_review_ai_merge` job runs.
          Default false preserves the original "draft PRs only" posture.
          The full safety envelope is enforced in `check-merge-envelope.sh`.
        type: boolean
        default: false
      ai-review-human-merge:
        description: |
          Per-repo opt-in for the AI-review + human-merge flow (#77 /
          ADR-004; named by ADR-009). When true AND the issue carries the
          `ai-review-human-merge` label, the `ai_review_human_merge` job
          reviews the freshly-opened draft PR and, on approve, promotes it
          to ready for a HUMAN to merge — no safety envelope, no
          auto-merge. If an issue also enables `ai-review-ai-merge`,
          human-merge wins (the `ai_review_ai_merge` job is suppressed).
        type: boolean
        default: false
```

Also update the `default-model` description near line 20, which names both jobs, to say `ai_review_ai_merge (ADR-002) and ai_review_human_merge (ADR-004)`. And in the `self-fix` description near line 198, replace `pre-preview or auto-review` with `human-merge or ai-merge`.

- [ ] **Step 2: Rename the stub inputs**

Replace `stub-auto-review-enabled:` with `stub-ai-merge-enabled:` and `stub-pre-preview-enabled:` with `stub-human-merge-enabled:`, updating each description to name the new job (`ai_review_ai_merge` / `ai_review_human_merge`). These are test-only and get no alias.

- [ ] **Step 3: Rename the outputs**

In `on.workflow_call.outputs`, rename each output and keep exactly one alias:

```yaml
      ai-review-ai-merge-enabled:
        description: |
          "true" or "false" from check-ai-merge-gate.sh. The
          ai_review_ai_merge job reads this via needs.implement.outputs.
          Under stub-claude mode, sourced from `stub-ai-merge-enabled`.
        value: ${{ jobs.implement.outputs.ai-review-ai-merge-enabled }}
      auto-review-enabled:
        description: |
          DEPRECATED (ADR-009, removed in v3) — alias of
          `ai-review-ai-merge-enabled`, kept so existing callers keep
          resolving.
        value: ${{ jobs.implement.outputs.ai-review-ai-merge-enabled }}
      ai-review-human-merge-enabled:
        description: |
          "true" or "false" from check-human-merge-gate.sh. The
          ai_review_human_merge job reads this via needs.implement.outputs.
          Under stub-claude mode, sourced from `stub-human-merge-enabled`.
        value: ${{ jobs.implement.outputs.ai-review-human-merge-enabled }}
```

Then rename the four test-only outputs with no alias, keeping their existing descriptions but updating the job names inside them:

- `auto-review-merge-attempted` → `ai-review-ai-merge-merge-attempted`, value `${{ jobs.ai_review_ai_merge.outputs.merge-attempted }}`
- `auto-review-self-fix-iterations-used` → `ai-review-ai-merge-self-fix-iterations-used`, value `${{ jobs.ai_review_ai_merge.outputs.self-fix-iterations-used }}`
- `pre-preview-merge-attempted` → `ai-review-human-merge-merge-attempted`, value `${{ jobs.ai_review_human_merge.outputs.merge-attempted }}`
- `pre-preview-ready-attempted` → `ai-review-human-merge-ready-attempted`, value `${{ jobs.ai_review_human_merge.outputs.ready-attempted }}`
- `pre-preview-self-fix-iterations-used` → `ai-review-human-merge-self-fix-iterations-used`, value `${{ jobs.ai_review_human_merge.outputs.self-fix-iterations-used }}`

- [ ] **Step 4: Rewire the implement job's outputs and gate steps**

In the `implement` job's `outputs:` map (around line 338), replace the two gate lines:

```yaml
      ai-review-ai-merge-enabled:     ${{ steps.ai_merge_gate.outputs.enabled || steps.ai_merge_gate_stub.outputs.enabled }}
      ai-review-human-merge-enabled:  ${{ steps.human_merge_gate.outputs.enabled || steps.human_merge_gate_stub.outputs.enabled }}
```

Replace the four gate steps (around lines 473–511) with:

```yaml
      - name: Check AI-merge gate
        if: ${{ !inputs.stub-claude }}
        id: ai_merge_gate
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          INPUT_AI_REVIEW_AI_MERGE: ${{ inputs.ai-review-ai-merge }}
          INPUT_AUTO_REVIEW: ${{ inputs.auto-review }}
        run: bash .claude-pipeline/scripts/check-ai-merge-gate.sh

      - name: Stub AI-merge gate (test mode)
        # Mirrors check-ai-merge-gate.sh's output under stub-claude=true so
        # end-to-end act tests can drive the downstream ai_review_ai_merge
        # job without a real labeled GitHub issue.
        if: ${{ inputs.stub-claude }}
        id: ai_merge_gate_stub
        env:
          ENABLED: ${{ inputs.stub-ai-merge-enabled }}
        run: printf 'enabled=%s\n' "$ENABLED" >> "$GITHUB_OUTPUT"

      - name: Check human-merge gate
        if: ${{ !inputs.stub-claude }}
        id: human_merge_gate
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          ISSUE_NUMBER: ${{ inputs.issue-number }}
          INPUT_AI_REVIEW_HUMAN_MERGE: ${{ inputs.ai-review-human-merge }}
          INPUT_PRE_PREVIEW: ${{ inputs.pre-preview }}
        run: bash .claude-pipeline/scripts/check-human-merge-gate.sh

      - name: Stub human-merge gate (test mode)
        # Mirrors check-human-merge-gate.sh's output under stub-claude=true
        # so end-to-end act tests can drive the downstream
        # ai_review_human_merge job without a real labeled GitHub issue.
        if: ${{ inputs.stub-claude }}
        id: human_merge_gate_stub
        env:
          ENABLED: ${{ inputs.stub-human-merge-enabled }}
        run: printf 'enabled=%s\n' "$ENABLED" >> "$GITHUB_OUTPUT"
```

Both gate steps pass **both** env vars — the script does the OR and the warning, so the YAML stays declarative.

- [ ] **Step 5: Rename the two jobs**

Rename `auto_review:` to `ai_review_ai_merge:` (around line 768) and `pre_preview:` to `ai_review_human_merge:` (around line 1106). Inside them:

- update the `if:` conditions to `needs.implement.outputs.ai-review-ai-merge-enabled == 'true' && needs.implement.outputs.ai-review-human-merge-enabled != 'true'` and `needs.implement.outputs.ai-review-human-merge-enabled == 'true'` respectively;
- set `MODE: human-merge` on the human-merge job's block step (was `MODE: pre-preview`);
- update every comment that names `auto_review` / `pre_preview` / "pre-preview mode" to the new job names;
- change the promote-to-ready comment body to `Reviewed ✓ — promoted to ready. Merge is yours.`;
- rename the self-fix step names to `Self-fix loop (AI-merge optional self-fix pass)` and `Self-fix loop (human-merge optional self-fix pass)`.

Leave the job bodies otherwise untouched — no logic changes in this task.

- [ ] **Step 6: Verify no stale references remain in this file**

Run: `grep -n 'pre_preview\|auto_review\|pre-preview\|auto-review' .github/workflows/agent-implement.yml`
Expected: only the deprecated `auto-review:` / `pre-preview:` input declarations, the `auto-review-enabled` output alias, the two `INPUT_AUTO_REVIEW` / `INPUT_PRE_PREVIEW` env lines, and prose mentioning ADR-002/ADR-004 history. No job ids, no step ids, no `needs.*` references.

- [ ] **Step 7: Lint**

Run: `actionlint .github/workflows/agent-implement.yml`
Expected: no output, exit 0. An unrenamed `needs.` reference or a `jobs.<old-id>.outputs` in the outputs block fails here — that is the point.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/agent-implement.yml
git commit -m "refactor(workflow): rename review flows to actor-pair names

auto_review -> ai_review_ai_merge, pre_preview -> ai_review_human_merge,
with matching inputs and outputs. The auto-review / pre-preview inputs and
the auto-review-enabled output are retained as deprecated aliases until v3."
```

---

### Task 5: Callers and the act test workflow

Everything that calls the reusable workflow, plus the Layer-2 test surface.

**Files:**
- Modify: `.github/workflows/agent-implement.test.yml`
- Modify: `.github/workflows/agent.yml`
- Modify: `.github/workflows/claude-implement.yml`

**Interfaces:**
- Consumes: the inputs, outputs and job ids Task 4 produced.
- Produces: a green `act` run, which is the only check that catches a half-applied job rename in `needs:` chains.

- [ ] **Step 1: Update the test workflow's calls**

In `.github/workflows/agent-implement.test.yml`, rename the eight caller jobs and their inputs:

- `call-auto-review-*` job ids → `call-ai-merge-*`; `call-pre-preview-*` → `call-human-merge-*`
- input `auto-review: true` → `ai-review-ai-merge: true`; `pre-preview: true` → `ai-review-human-merge: true`
- input `stub-auto-review-enabled:` → `stub-ai-merge-enabled:`; `stub-pre-preview-enabled:` → `stub-human-merge-enabled:`
- every `name:` string — e.g. `Reusable workflow — pre-preview wins over auto-review` becomes `Reusable workflow — human-merge wins over ai-merge`

Deliberately use the **new** input spellings here: the deprecated ones are covered by the Layer-1 fixture matrix from Tasks 1–2, and the act suite should assert the shape consumers are being moved to.

- [ ] **Step 2: Update the test workflow's assertions**

Every assertion job reading `needs.<caller>.outputs.<name>` must use the renamed outputs from Task 4 — `ai-review-human-merge-ready-attempted`, `ai-review-human-merge-merge-attempted`, `ai-review-ai-merge-merge-attempted`, and the two `*-self-fix-iterations-used`. Update the `needs:` lists to the renamed caller job ids at the same time.

- [ ] **Step 3: Update this repo's own caller**

In `.github/workflows/agent.yml`, change `pre-preview: true` to `ai-review-human-merge: true` and rewrite the header comment block (lines 4–7) to:

```yaml
# and opens a draft PR. Because `ai-review-human-merge: true` is set here, an
# issue that ALSO carries `ai-review-human-merge` runs that flow (ADR-004,
# named by ADR-009): the agent reviews its own PR and promotes it to ready
# for a human to merge — no envelope, no auto-merge. Issues without the
# label get the plain draft-PR flow.
```

- [ ] **Step 4: Update `claude-implement.yml`**

Apply the same input and comment renames as Steps 1 and 3 to whichever of its ~20 references apply. Verify with `grep -n 'pre-preview\|auto-review' .github/workflows/claude-implement.yml` that only intentional history prose remains.

- [ ] **Step 5: Lint**

Run: `just lint`
Expected: `actionlint` and `shellcheck` both clean. `actionlint` fails loudly on a `needs:` naming a job id that no longer exists, so this catches Step 2 mistakes.

- [ ] **Step 6: Run the act suite**

Run: `just test-act`
Expected: every caller job green, including `call-human-merge-precedence` (which sets both flows and asserts the human-merge job runs while the AI-merge job is skipped) and the two self-fix calls.

If a job is unexpectedly *skipped* rather than failing, the cause is almost always an `if:` in Task 4 Step 5 still referencing an old output name — expressions referencing a nonexistent output evaluate to empty rather than erroring, so they fail silently.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/agent-implement.test.yml .github/workflows/agent.yml .github/workflows/claude-implement.yml
git commit -m "test(workflow): move callers and act suite to actor-pair names"
```

---

### Task 6: Onboarding script

`onboard-consumer.sh` wires a new consumer repo; its flags and generated `with:` block must emit the new names.

**Files:**
- Modify: `scripts/onboard-consumer.sh` (flag docs near lines 55–67, defaults near 111, arg parsing near 162, the `--auto-review` branch near 277, the `with:` block near 299)

**Interfaces:**
- Consumes: the input names Task 4 produced.
- Produces: `--ai-review-ai-merge` and `--ai-review-human-merge` flags that write `ai-review-ai-merge: true` / `ai-review-human-merge: true` into a generated `agent.yml`.

- [ ] **Step 1: Rename the variables and flags**

- `AUTO_REVIEW=false` → `AI_MERGE=false`; `PRE_PREVIEW=false` → `HUMAN_MERGE=false`
- `--auto-review)  AUTO_REVIEW=true; shift ;;` → `--ai-review-ai-merge)  AI_MERGE=true; shift ;;`
- `--pre-preview)  PRE_PREVIEW=true; shift ;;` → `--ai-review-human-merge)  HUMAN_MERGE=true; shift ;;`
- the `if [[ "$AUTO_REVIEW" == true ]]` branch near line 277 → `if [[ "$AI_MERGE" == true ]]`
- the two `with_block+=` lines → `[[ "$AI_MERGE" == true ]] && with_block+=$'\n      ai-review-ai-merge: true'` and `[[ "$HUMAN_MERGE" == true ]] && with_block+=$'\n      ai-review-human-merge: true'`

No deprecated flag aliases: this script provisions *new* repos, so there is no installed base to keep working.

- [ ] **Step 2: Update the usage block**

Rewrite the flag documentation near lines 55–67 to describe the two flows by actor pair, and to name the labels a maintainer must apply per issue (`ai-review-ai-merge` / `ai-review-human-merge`, neither applied by this script).

- [ ] **Step 3: Verify the generated output**

Run: `just onboard-help`
Expected: the usage text shows `--ai-review-ai-merge` and `--ai-review-human-merge`, and no occurrence of `--auto-review` or `--pre-preview`.

- [ ] **Step 4: Lint**

Run: `shellcheck -x -e SC1091 scripts/onboard-consumer.sh`
Expected: no output, exit 0. Watch for SC2034 (unused variable) — it fires if you rename a default but miss a use site.

- [ ] **Step 5: Commit**

```bash
git add scripts/onboard-consumer.sh
git commit -m "refactor(onboard): rename flow flags to actor-pair names"
```

---

### Task 7: Documentation and ADR-009

The record of why, plus the migration instructions a consumer needs.

**Files:**
- Modify: `docs/DECISIONS.md` (append ADR-009; add one supersession line to ADR-002 near line 138 and one to ADR-004 near line 696)
- Modify: `docs/CONSUMER-SETUP.md`
- Modify: `CHANGELOG.md` (`[Unreleased]` section only)
- Modify: `commands/gh/implement.md`, `commands/gh/review.md`

**Interfaces:**
- Consumes: the final names from all prior tasks.
- Produces: no code interface.

- [ ] **Step 1: Append the supersession lines**

Under ADR-002's heading block add:

```markdown
**Superseded in part (2026-08-30):** the names `auto-review` /
`ai-auto-review` / `auto_review` are replaced by `ai-review-ai-merge` per
ADR-009. The decision itself — the review and the merge safety envelope —
is unchanged.
```

Under ADR-004's heading block add:

```markdown
**Superseded in part (2026-08-30):** the names `pre-preview` /
`ai-pre-preview` / `pre_preview` are replaced by `ai-review-human-merge`
per ADR-009. The decision itself — agent review, human merge, no envelope —
is unchanged.
```

Do not edit anything else in either ADR body.

- [ ] **Step 2: Write ADR-009**

Append to `docs/DECISIONS.md`, following the file's existing `## ADR-00N — Title (date)` / `**Status:**` / `### Context` / `### Decision` / `### Consequences` shape and its `+` bullet style. It must record: that `pre-preview` named a stage rather than an actor and `auto-review` named only the half without the risk; the full rename map from the Global Constraints table; that inputs, labels and the `auto-review-enabled` output are aliased until v3 while stub inputs and assertion outputs are not; that `ensure-issue-labels.sh` creates only new labels and the pipeline never mutates labels on an issue; that design history is left immutable, so a grep for `pre-preview` still returns hits by design; and that of the six consumer repos ADR-006 lists, flowhub, FlowHub-CAS-AISE and agent-action-sandbox pin `@main` and therefore pick this up on merge — which is why the aliases exist.

- [ ] **Step 3: Update `docs/CONSUMER-SETUP.md`**

Rename every occurrence in the copy-paste consumer stub and prose, then add a migration section:

```markdown
### Migrating from `auto-review` / `pre-preview` (ADR-009)

The old input and label names still work but warn on every run, and are
removed in v3. Two steps per repo.

**1. Rename the inputs** in `.github/workflows/agent.yml`:

    auto-review: true   ->  ai-review-ai-merge: true
    pre-preview: true   ->  ai-review-human-merge: true

**2. Relabel open issues** — the pipeline never does this for you:

```bash
gh issue list --label ai-pre-preview --json number --jq '.[].number' \
  | xargs -I{} gh issue edit {} \
      --add-label ai-review-human-merge \
      --remove-label ai-pre-preview

gh issue list --label ai-auto-review --json number --jq '.[].number' \
  | xargs -I{} gh issue edit {} \
      --add-label ai-review-ai-merge \
      --remove-label ai-auto-review
```

Run `scripts/ensure-issue-labels.sh` first so the new labels exist. The old
labels are left in place — delete them yourself once no issue carries them.
```

- [ ] **Step 4: Update the command docs**

In `commands/gh/implement.md`, replace the `grep -q "pre-preview: true"` detection with a check for either spelling, and update the `gh issue edit` example to `--add-label ai-review-human-merge`. In `commands/gh/review.md`, replace the three `pre-preview` mentions with `ai-review-human-merge`.

- [ ] **Step 5: Update `CHANGELOG.md`**

Add to the `[Unreleased]` section only — do not touch released entries:

```markdown
### Changed

- **naming:** the two review flows are named for their actor pair —
  `auto-review` → `ai-review-ai-merge` and `pre-preview` →
  `ai-review-human-merge` — across workflow inputs, issue labels, job ids
  and the two gate scripts (ADR-009). Behaviour and precedence are
  unchanged.

### Deprecated

- **naming:** the inputs `auto-review` / `pre-preview`, the labels
  `ai-auto-review` / `ai-pre-preview`, and the output `auto-review-enabled`
  still work but emit a warning annotation. **Removed in v3.** See the
  migration section in `docs/CONSUMER-SETUP.md`.
```

- [ ] **Step 6: Commit**

```bash
git add docs/DECISIONS.md docs/CONSUMER-SETUP.md CHANGELOG.md commands/gh/implement.md commands/gh/review.md
git commit -m "docs(adr): record ADR-009 actor-pair flow naming

Adds ADR-009, supersession pointers on ADR-002 and ADR-004, the consumer
migration section, and the Unreleased changelog entries."
```

---

### Task 8: Final sweep

Confirm nothing was half-renamed and every layer is green.

**Files:** none created; fixes only if the sweep finds something.

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: a branch ready for PR.

- [ ] **Step 1: Sweep the live tree**

```bash
grep -rn 'pre_preview\|pre-preview\|auto_review\|ai-auto-review\|ai-pre-preview' \
  scripts/ tests/ .github/ commands/ docs/CONSUMER-SETUP.md justfile
```

Expected — every remaining hit is one of these, and nothing else:

- the deprecated input declarations and the `auto-review-enabled` output alias in `agent-implement.yml`
- the `INPUT_AUTO_REVIEW` / `INPUT_PRE_PREVIEW` env lines in the two gate steps
- the deprecated-name constants, comments and warning strings inside the two gate scripts
- the deprecated-name test cases in `tests/run-script-tests.sh`
- the migration section in `docs/CONSUMER-SETUP.md`
- prose in `commands/gh/implement.md` detecting either spelling

Any other hit is a missed rename. Fix it.

- [ ] **Step 2: Confirm history was not touched**

```bash
git diff --name-only main... | grep '^docs/superpowers/' || echo 'history untouched'
```

Expected: the only `docs/superpowers/` paths in the diff are this plan and its spec. `CHANGELOG.md` must show only `[Unreleased]` additions — verify with `git diff main... -- CHANGELOG.md`.

- [ ] **Step 3: Run every layer**

```bash
just lint
just test
just test-act
```

Expected: all three green. `just test` must still finish in under 5 seconds.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin HEAD
gh pr create --fill --draft
```

The PR description follows the repo's template: **Summary**, **Changes**, **Testing** (name all three layers and their results), **Checklist**. Call out explicitly that this changes the consumer-facing input and label contract, that old names still work until v3, and that the three `@main`-pinned consumers pick it up on merge without action.

## Spec

[`docs/superpowers/specs/2026-08-30-actor-pair-flow-naming-design.md`](docs/superpowers/specs/2026-08-30-actor-pair-flow-naming-design.md)
