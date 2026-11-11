# Resume Clears `ai:paused` Before It Dispatches — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pipeline-resume.sh` removes `ai:paused` before dispatching, skips the dispatch when the removal fails, and re-adds the label when the dispatch fails, so a resume can never double-dispatch an issue. `paused_issue_clear` reports failure instead of swallowing it.

**Architecture:** One library change (`scripts/lib/paused-issues.sh`: `paused_issue_clear` returns gh's status), one reorder in the resume loop (`scripts/pipeline-resume.sh`), and a `|| true` at the one caller that must stay tolerant (`scripts/check-pipeline-pause.sh`). Docs follow in `docs/ALARMS.md`.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `jq`, `gh` (mocked by `tests/mocks/gh` with `GH_MOCK_FAIL_MAP`), Layer-1 tests in `tests/run-pipeline-alarm-tests.sh`.

**Spec:** [`docs/superpowers/specs/2026-10-19-resume-clear-before-dispatch-design.md`](../specs/2026-10-19-resume-clear-before-dispatch-design.md)

## Global Constraints

- Per issue to dispatch, the order is exactly: `paused_issue_clear` → `gh workflow run` → (on dispatch failure only) `paused_issue_mark`.
- A failed clear means **no** `gh workflow run` for that issue in this resume.
- Warning text for a failed clear, verbatim: `warning: could not remove ai:paused from #<n> — not dispatched, so a second resume cannot double-dispatch it; run this again` (built with `printf` and `$PAUSED_ISSUE_LABEL`, not a hard-coded label name).
- `pipeline-resume.sh` exit codes are unchanged (`0` / `1` / `2`).
- `check-pipeline-pause.sh` behaviour is unchanged: its clear stays tolerant (`|| true`).
- Every script keeps `set -euo pipefail` + `IFS=$'\n\t'`; `shellcheck -x -e SC1091` stays clean.
- Never modify a test to make it green. The one existing assertion changed (`failed dispatch -> the issue keeps ai:paused`, `tests/run-pipeline-alarm-tests.sh:883`) asserts the old call order; it is replaced by an assertion of the same behaviour (the issue ends up labelled), as recorded in the spec.

## Review Focus

- `paused_issue_clear` must now return non-zero on failure. Any caller under `set -e` that does not handle it would abort. There are exactly three callers (`grep -rn paused_issue_clear scripts/`): two in `pipeline-resume.sh`, one in `check-pipeline-pause.sh`. All three are handled in this plan.
- `check-pipeline-pause.sh:115` is `[[ "$DRY_RUN" == "1" ]] || paused_issue_clear …`. The last command of an `||` list is **not** exempt from `set -e`, so without the added `|| true` a failed clear would kill the gate. Pinned by Task 1 Step 1 ("gate proceeds when its clear fails").

## Files overlapping other plans in this batch

None. #509, #549 and #550 do not touch `scripts/pipeline-resume.sh`, `scripts/lib/paused-issues.sh`, `scripts/check-pipeline-pause.sh`, `tests/run-pipeline-alarm-tests.sh` or `docs/ALARMS.md`. This issue can be dispatched in parallel with any of them.

---

### Task 1: `paused_issue_clear` reports failure; the gate tolerates it

**Files:**
- Modify: `scripts/lib/paused-issues.sh` (header lines 22; function lines 50-53)
- Modify: `scripts/check-pipeline-pause.sh:115`
- Test: `tests/run-pipeline-alarm-tests.sh` (section `check-pipeline-pause — a paused repo starts no agent`, after the `no alarm and no variable -> not paused` block ending ~line 733)

**Interfaces:**
- Produces: `paused_issue_clear <issue>` returns `0` when the label was removed (or the issue did not carry it), `1` when `gh issue edit` failed. No output on either path. Task 2 relies on this.

- [ ] **Step 1: Write the failing tests**

In `tests/run-pipeline-alarm-tests.sh`, directly after the block that ends with `"a dispatch that proceeds leaves the paused list"` and its `rm -rf "$d"`, add:

```bash
# #536: the gate's clear is best-effort. A repo that was never paused has no
# ai:paused label at all, and the gate's verdict must not depend on it.
d="$(mktemp -d)"
printf -- '--remove-label ai:paused\n' > "$d/fail-map"
ec=0
out="$(gate_run "$d" alarm-list-empty.json GH_MOCK_FAIL_MAP="$d/fail-map")" || ec=$?
assert_equals "$ec" 0 "gate proceeds when its clear fails (#536)"
assert_contains "$out" 'paused=false' "gate still reports not paused when its clear fails (#536)"
rm -rf "$d"
```

Then add a new section right before `# --- Task 6: pipeline-resume.sh ---`:

```bash
# --- #536: paused_issue_clear reports failure --------------------------------

section "paused_issue_clear — a failed removal is reported, not swallowed"

# clear_rc <dir> [extra env...] — sources the library and prints the clear's rc.
clear_rc() {
  local dir="$1"; shift
  env PATH="$MOCKS:$PATH" GH_MOCK_LOG="$dir/gh" REPO=freaxnx01/game-rhyflitzer "$@" \
    bash -c 'source "$1"; rc=0; paused_issue_clear 12 || rc=$?; printf "%s" "$rc"' _ \
    "$ROOT/scripts/lib/paused-issues.sh"
}

d="$(mktemp -d)"
assert_equals "$(clear_rc "$d")" 0 "paused_issue_clear returns 0 when gh succeeds (#536)"
printf -- '--remove-label ai:paused\n' > "$d/fail-map"
assert_equals "$(clear_rc "$d" GH_MOCK_FAIL_MAP="$d/fail-map")" 1 \
  "paused_issue_clear returns 1 when gh fails (#536)"
rm -rf "$d"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-pipeline-alarm-tests.sh 2>&1 | tail -15`
Expected: FAIL on `paused_issue_clear returns 1 when gh fails (#536)` (today it returns 0). The gate test passes already, because the clear still swallows errors; it is there to pin behaviour for Step 3.

- [ ] **Step 3: Implement**

In `scripts/lib/paused-issues.sh`, replace the header line

```bash
#   paused_issue_clear <issue>    remove the label; a silent no-op when absent
```

with

```bash
#   paused_issue_clear <issue>    remove the label. Returns 1 when gh could not
#                                 remove it, silently — the caller decides what
#                                 that means (#536). Removing a label the issue
#                                 does not carry is not a failure.
```

and the function body with

```bash
paused_issue_clear() {
  local issue="${1:?paused_issue_clear requires an issue number}"
  gh issue edit "$issue" --repo "$REPO" --remove-label "$PAUSED_ISSUE_LABEL" >/dev/null 2>&1
}
```

In `scripts/check-pipeline-pause.sh`, replace line 115

```bash
  [[ "$DRY_RUN" == "1" ]] || paused_issue_clear "$ISSUE_NUMBER"
```

with

```bash
  # Best-effort (#536): a repo that was never paused has no such label, and the
  # gate's verdict must not depend on this write.
  [[ "$DRY_RUN" == "1" ]] || paused_issue_clear "$ISSUE_NUMBER" || true
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-pipeline-alarm-tests.sh 2>&1 | tail -5`
Expected: the two new `paused_issue_clear` assertions and the gate assertion PASS. The resume section may now fail on its `skipping #34` path only if the mock fails it; with no fail map it still passes.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/lib/paused-issues.sh scripts/check-pipeline-pause.sh tests/run-pipeline-alarm-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/paused-issues.sh scripts/check-pipeline-pause.sh tests/run-pipeline-alarm-tests.sh
git commit -m "fix(resume): report a failed ai:paused clear instead of swallowing it (#536)"
```

---

### Task 2: Resume clears before it dispatches

**Files:**
- Modify: `scripts/pipeline-resume.sh` (re-dispatch loop, lines 107-127; header comment block lines 10-16)
- Test: `tests/run-pipeline-alarm-tests.sh` (section `pipeline-resume — clearing the alarm re-dispatches the queued issues`, ~lines 788-897)

**Interfaces:**
- Consumes: `paused_issue_clear` returning 1 on failure (Task 1); `paused_issue_mark` as it is today (returns 1 and warns on failure).

- [ ] **Step 1: Write the failing tests**

In `tests/run-pipeline-alarm-tests.sh`, replace the existing failed-dispatch block

```bash
# A dispatch that fails keeps the label, so a second run retries it.
d="$(mktemp -d)"
printf 'workflow run\n' > "$d/fail-map"
out="$(resume_run "$d" resume-alarm.json resume-paused-issues.json GH_MOCK_FAIL_MAP="$d/fail-map")"
assert_not_contains "$(cat "$d/gh")" 'issue edit 12' "failed dispatch -> the issue keeps ai:paused"
assert_contains "$out" 'could not re-dispatch #12' "failed dispatch -> says so"
rm -rf "$d"
```

with

```bash
# A dispatch that fails ends with the label back on, so a second run retries it.
# The label was removed before the dispatch (#536), so it is re-added.
d="$(mktemp -d)"
printf 'workflow run\n' > "$d/fail-map"
out="$(resume_run "$d" resume-alarm.json resume-paused-issues.json GH_MOCK_FAIL_MAP="$d/fail-map")"
assert_contains "$(grep 'issue edit 12 ' "$d/gh" | tail -1)" '--add-label ai:paused' \
  "failed dispatch -> the issue ends up labelled ai:paused again (#536)"
assert_contains "$out" 'could not re-dispatch #12' "failed dispatch -> says so"
rm -rf "$d"

# #536: the label comes off BEFORE the dispatch, so a dispatched issue is never
# still on the list a second resume reads.
d="$(mktemp -d)"
resume_run "$d" resume-alarm.json resume-paused-issues.json >/dev/null
clear_line="$(grep -n 'issue edit 12 .*--remove-label ai:paused' "$d/gh" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'issue-number=12' "$d/gh" | head -1 | cut -d: -f1)"
if [[ -n "$clear_line" && -n "$run_line" ]] && (( clear_line < run_line )); then
  pass "ai:paused is removed before the issue is re-dispatched (#536)"
else
  fail "ai:paused is removed before the issue is re-dispatched (#536)" \
    "clear at ${clear_line:-none}, dispatch at ${run_line:-none}"
fi
rm -rf "$d"

# #536: a clear that fails means no dispatch — the next resume retries it,
# instead of a second resume dispatching an issue already in flight.
d="$(mktemp -d)"
printf -- 'issue edit 12 --repo freaxnx01/game-rhyflitzer --remove-label ai:paused\n' > "$d/fail-map"
ec=0
out="$(resume_run "$d" resume-alarm.json resume-paused-issues.json GH_MOCK_FAIL_MAP="$d/fail-map")" || ec=$?
assert_equals "$ec" 0 "failed clear -> still exit 0 (#536)"
assert_not_contains "$(cat "$d/gh")" 'issue-number=12' "failed clear -> the issue is not dispatched (#536)"
assert_contains "$out" 'could not remove ai:paused from #12' "failed clear -> says so (#536)"
assert_contains "$out" 'cannot double-dispatch' "failed clear -> says why it was not dispatched (#536)"
rm -rf "$d"

# #536: dispatch fails AND the re-mark fails — paused_issue_mark's own warning
# names the issue, so it is not silently dropped from the list.
d="$(mktemp -d)"
printf 'workflow run\n--add-label ai:paused\n' > "$d/fail-map"
out="$(resume_run "$d" resume-alarm.json resume-paused-issues.json GH_MOCK_FAIL_MAP="$d/fail-map")"
assert_contains "$out" 'could not re-dispatch #12' "dispatch + re-mark fail -> the dispatch failure is reported (#536)"
assert_contains "$out" 'warning: could not label issue #12' "dispatch + re-mark fail -> the lost label is reported (#536)"
rm -rf "$d"

# #536: the skipped path (no ai-implement) dispatches nothing either way, but
# a failed clear there is still reported.
d="$(mktemp -d)"
printf -- 'issue edit 34 --repo freaxnx01/game-rhyflitzer --remove-label ai:paused\n' > "$d/fail-map"
out="$(resume_run "$d" resume-alarm.json resume-paused-issues.json GH_MOCK_FAIL_MAP="$d/fail-map")"
assert_contains "$out" 'could not remove ai:paused from #34' "skipped issue, failed clear -> says so (#536)"
assert_not_contains "$(cat "$d/gh")" 'issue-number=34' "skipped issue, failed clear -> still not dispatched (#536)"
rm -rf "$d"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-pipeline-alarm-tests.sh 2>&1 | grep -E '✗|passed:'`
Expected: FAIL on `ai:paused is removed before the issue is re-dispatched`, `failed clear -> the issue is not dispatched`, `failed clear -> says so`, `failed dispatch -> the issue ends up labelled ai:paused again`, `dispatch + re-mark fail -> the lost label is reported`, `skipped issue, failed clear -> says so`.

- [ ] **Step 3: Implement**

In `scripts/pipeline-resume.sh`, replace the loop body from `resumed=0` through `done` (lines 107-127) with:

```bash
resumed=0
for issue in ${paused_issues[@]+"${paused_issues[@]}"}; do
  has_label="$(jq -r --argjson n "$issue" --arg l "$DISPATCH_LABEL" \
    '(map(select(.number == $n)) | .[0].labels // []) | map(.name) | index($l) != null' <<<"$paused")"
  if [[ "$has_label" != "true" ]]; then
    printf 'skipping #%s: no %s label — parked or handled by hand\n' "$issue" "$DISPATCH_LABEL"
    paused_issue_clear "$issue" \
      || printf 'warning: could not remove %s from #%s\n' "$PAUSED_ISSUE_LABEL" "$issue" >&2
    continue
  fi
  redispatch_issue "$issue" && resumed=$((resumed + 1))
done
```

and add this function directly above the `resumed=0` line (below the `# --- re-dispatch ---` banner):

```bash
# redispatch_issue <n> — take <n> off the paused list, THEN dispatch it (#536).
# The other order left a window where a failed clear kept a dispatched issue on
# the list, and a second resume dispatched it again. Returns 0 only when the
# dispatch was sent.
redispatch_issue() {
  local issue="$1"
  if ! paused_issue_clear "$issue"; then
    printf 'warning: could not remove %s from #%s — not dispatched, so a second resume cannot double-dispatch it; run this again\n' \
      "$PAUSED_ISSUE_LABEL" "$issue" >&2
    return 1
  fi
  # No `-f attempt=` on purpose: the paused run never reached the agent, so the
  # re-run is attempt 1 and classify-agent.sh's escalation does not fire.
  if gh workflow run "$CONSUMER_WORKFLOW" --repo "$REPO" -f issue-number="$issue" >/dev/null 2>&1; then
    printf 're-dispatched #%s as attempt 1\n' "$issue"
    return 0
  fi
  # Put it back so running this again retries exactly these. A failed re-mark
  # is warned about and named in the step summary by paused_issue_mark itself.
  paused_issue_mark "$issue" || true
  printf 'warning: could not re-dispatch #%s — it keeps %s; run this again or dispatch it by hand\n' \
    "$issue" "$PAUSED_ISSUE_LABEL" >&2
  return 1
}
```

In the header comment, after the paragraph that ends `…the resume would achieve nothing.` (line 16), add:

```bash
#
# Per issue, the label comes off BEFORE the dispatch, and goes back on if the
# dispatch fails (#536). A clear that fails means the issue is not dispatched
# this time: a dispatched issue still carrying ai:paused would be dispatched
# again by the next resume.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/run-pipeline-alarm-tests.sh 2>&1 | tail -5`
Expected: `failed: 0`.

- [ ] **Step 5: Lint**

Run: `shellcheck -x -e SC1091 scripts/pipeline-resume.sh tests/run-pipeline-alarm-tests.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add scripts/pipeline-resume.sh tests/run-pipeline-alarm-tests.sh
git commit -m "fix(resume): clear ai:paused before dispatching so a resume cannot double-dispatch (#536)"
```

---

### Task 3: Document the new order

**Files:**
- Modify: `docs/ALARMS.md` (resume paragraph, lines 69-76)

- [ ] **Step 1: Edit the paragraph**

Replace the paragraph that starts `The script re-dispatches the **open issues labelled \`ai:paused\`**` and ends `…escalating the next one.` with:

```markdown
The script re-dispatches the **open issues labelled `ai:paused`**. For each one
it removes the label **first** and dispatches second, so an issue that is in
flight is never still on the list a later resume reads (#536). If the label
cannot be removed, the issue is not dispatched this time and the script says
so — run it again. If the dispatch fails, the label is put back, so running the
script again retries it; if even that fails, the script names the issue so it
can be re-dispatched by hand. One that lost its `ai-implement` label in the
meantime is not dispatched and only loses `ai:paused`. Closing the alarm by
hand first is fine — the script still finds the labelled issues. Nothing is
dispatched with `-f attempt=`, so each one runs as attempt 1 on the default
agent — a paused run did no work, and nothing was learned that would justify
escalating the next one.
```

- [ ] **Step 2: Verify the docs assertions still hold**

Run: `bash tests/run-pipeline-alarm-tests.sh 2>&1 | grep -E 'ALARMS.md|passed:'`
Expected: `ALARMS.md names the paused label` PASS; `failed: 0`.

- [ ] **Step 3: Run the whole suite**

Run: `bash tests/run-all.sh 2>&1 | tail -5`
Expected: all runners pass.

- [ ] **Step 4: Commit**

```bash
git add docs/ALARMS.md
git commit -m "docs(alarms): resume clears ai:paused before it dispatches (#536)"
```
