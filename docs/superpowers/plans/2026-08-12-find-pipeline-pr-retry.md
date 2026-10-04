# find-pipeline-pr.sh Search-Index Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `find-pipeline-pr.sh` retry its GitHub search query on an empty
result before reporting `found=false`, so a just-created PR isn't missed due
to search-index propagation lag (observed: `game-geography-quiz#13`,
tracked: `agent-workflow#249`).

**Architecture:** A small retry loop wraps the existing `gh pr list --search`
call inside `scripts/find-pipeline-pr.sh`. It retries on *empty result*, not
command failure — a different trigger than `scripts/lib/gh-retry.sh`'s
`with_backoff` (which retries on non-zero exit matching a transient-error
signature). The existing `PIPELINE_PRS_JSON` test seam bypasses the retry
entirely (single check, as today) so all current tests are unaffected. A new
`PIPELINE_PRS_JSON_SEQUENCE_CMD` seam drives the new retry-specific tests,
using the same counter-file shim idiom already used for `with_backoff`'s
tests.

**Tech Stack:** Bash, `gh` CLI, `jq`. Existing test harness:
`tests/run-script-tests.sh` (hand-rolled `assert_equals`/`assert_contains`/
`section` helpers, no external test framework).

## Global Constraints

- Retry budget: `FIND_PR_RETRY_MAX` default `3` attempts, `FIND_PR_RETRY_BASE_SLEEP`
  default `2` seconds, sleep = `FIND_PR_RETRY_BASE_SLEEP * attempt` (2s, 4s,
  6s — worst case ~12s added latency across 3 attempts, inside the ~15s
  budget approved in the spec).
- No change to the author-normalization, draft filter, or highest-number
  tiebreak logic in `find-pipeline-pr.sh` — those are byte-for-byte
  unchanged; only the *acquisition* of `PIPELINE_PRS_JSON` gains a retry loop
  around it.
- No workflow YAML changes. No changes to `verify-or-recover-pr.sh` — it
  calls `find-pipeline-pr.sh` and inherits the fix for free.
- All 8 existing tests at `tests/run-script-tests.sh:1462+` (section
  `"find-pipeline-pr — discover the draft PR opened for an issue"`) must pass
  unmodified — this is a regression gate, not just a nice-to-have.

---

### Task 1: Add the empty-result retry loop to `find-pipeline-pr.sh`

**Files:**
- Modify: `scripts/find-pipeline-pr.sh`
- Test: `tests/run-script-tests.sh` (new tests appended to the existing
  `"find-pipeline-pr — discover the draft PR opened for an issue"` section,
  which starts at line 1462)

**Interfaces:**
- Consumes: nothing new from other tasks (this is the only task).
- Produces: `scripts/find-pipeline-pr.sh` behavior — same `found=` /
  `pr-number=` / `head-sha=` / `head-ref=` output contract as today, plus two
  new optional env inputs: `PIPELINE_PRS_JSON_SEQUENCE_CMD` (path to an
  executable that replaces the `gh pr list` call when set, and is NOT
  short-circuited by the retry loop — each retry attempt re-invokes it),
  `FIND_PR_RETRY_MAX` (default `3`), `FIND_PR_RETRY_BASE_SLEEP` (default
  `2`), `FIND_PR_RETRY_SLEEP_CMD` (default `sleep`).

The full current script (for reference — this task rewrites the middle
section between the env-var declarations and the output-emission block):

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [[ -z "${ISSUE_NUMBER:-}" ]]; then
  printf 'error: ISSUE_NUMBER must be set\n' >&2
  exit 2
fi
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  printf 'error: REPO or GITHUB_REPOSITORY must be set\n' >&2
  exit 2
fi

AUTHOR_ALLOWLIST="${AUTHOR_ALLOWLIST:-github-actions[bot]}"

if [[ -z "${PIPELINE_PRS_JSON:-}" ]]; then
  PIPELINE_PRS_JSON="$(gh pr list \
    --repo "$REPO" \
    --state open \
    --search "closes #${ISSUE_NUMBER} in:body" \
    --json number,isDraft,headRefOid,headRefName,author \
    --limit 10 2>/dev/null || printf '[]')"
fi

ALLOWED_JSON="$(printf '%s\n' "$AUTHOR_ALLOWLIST" \
  | awk 'NF > 0' \
  | jq -R . | jq -sc .)"

SELECTED="$(printf '%s' "$PIPELINE_PRS_JSON" \
  | jq -c --argjson allow "$ALLOWED_JSON" '
    def norm: (. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "");
    ($allow | map(norm)) as $a
    | [ .[]
        | select(.isDraft == true
                 and ((.author.login | norm) as $au | ($a | index($au)) != null)) ]
    | sort_by(-.number) | .[0] // {}')"
pr_number="$(printf '%s' "$SELECTED" | jq -r '.number // ""')"
head_sha="$(printf '%s' "$SELECTED" | jq -r '.headRefOid // ""')"
head_ref="$(printf '%s' "$SELECTED" | jq -r '.headRefName // ""')"

if [[ -n "$pr_number" ]]; then
  found=true
else
  found=false
fi

printf 'found=%s pr-number=%s head-sha=%s head-ref=%s\n' "$found" "$pr_number" "$head_sha" "$head_ref"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'found=%s\n'     "$found"
    printf 'pr-number=%s\n' "$pr_number"
    printf 'head-sha=%s\n'  "$head_sha"
    printf 'head-ref=%s\n'  "$head_ref"
  } >> "$GITHUB_OUTPUT"
fi
```

- [ ] **Step 1: Write the failing tests**

Append these three tests to `tests/run-script-tests.sh` immediately after the
existing `"empty list → found=false"` test (right before the `# Error paths`
comment, i.e. right before line 1533 in the current file — the exact line
will have shifted slightly by the time this runs; anchor on the comment text
`# Error paths` and insert above it):

```bash
# --- retry-on-empty-result (search-index lag, #249) --------------------

# Fake `gh pr list` shim: returns "[]" on its first N invocations (tracked
# via a counter file, same idiom as gh-retry.sh's `make_flaky`), then the
# real PR JSON on the next. Used to drive find-pipeline-pr.sh's retry loop.
make_flaky_pr_list() {
  local script="$1" empty_times="$2" real_json="$3" ctr="$4"
  cat > "$script" <<EOF
#!/usr/bin/env bash
n=\$(cat "$ctr" 2>/dev/null || printf 0)
n=\$((n + 1)); printf '%s' "\$n" > "$ctr"
if (( n <= $empty_times )); then printf '[]\n'; exit 0; fi
printf '%s\n' '$real_json'
EOF
  chmod +x "$script"
}

# Empty on attempt 1, PR found on attempt 2 → found=true, exactly 2 invocations.
shim1="$(mktemp)"; ctr1="$(mktemp)"; : > "$ctr1"
make_flaky_pr_list "$shim1" 1 \
  '[{"number":17,"isDraft":true,"headRefOid":"deadbeef","headRefName":"feat/x","author":{"login":"github-actions[bot]"}}]' \
  "$ctr1"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim1" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'found=true'   "retries once on empty, finds PR on attempt 2"
assert_contains "$out" 'pr-number=17' "  → pr-number from the successful attempt"
assert_equals "$(cat "$ctr1")" "2"    "  → exactly 2 invocations (1 empty + 1 success)"

# Empty for all FIND_PR_RETRY_MAX attempts → found=false, exactly MAX invocations.
shim2="$(mktemp)"; ctr2="$(mktemp)"; : > "$ctr2"
make_flaky_pr_list "$shim2" 99 '[]' "$ctr2"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim2" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'found=false' "gives up after FIND_PR_RETRY_MAX empty attempts"
assert_equals "$(cat "$ctr2")" "3"   "  → exactly FIND_PR_RETRY_MAX (3) invocations, not infinite"

# PIPELINE_PRS_JSON (existing seam) still short-circuits with zero retries —
# regression guard that the retry loop doesn't touch the deterministic-JSON
# path every other existing test in this section relies on.
shim3="$(mktemp)"; ctr3="$(mktemp)"; : > "$ctr3"
make_flaky_pr_list "$shim3" 99 '[]' "$ctr3"
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":5,"isDraft":true,"headRefOid":"x","author":{"login":"github-actions[bot]"}}]' \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim3" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'pr-number=5'      "PIPELINE_PRS_JSON takes priority over the sequence shim"
assert_equals "$(cat "$ctr3")" "0"        "  → shim never invoked when PIPELINE_PRS_JSON is set"
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A2 "find-pipeline-pr"`

Expected: the three new assertions FAIL (e.g. `PIPELINE_PRS_JSON_SEQUENCE_CMD`
is not yet recognized, so the shim is never invoked and `ctr1`/`ctr2` stay at
`0`, or the script errors trying to read an unset seam) while the 8 existing
tests in this section still PASS.

- [ ] **Step 3: Implement the retry loop**

Replace the acquisition block in `scripts/find-pipeline-pr.sh` — from `if
[[ -z "${PIPELINE_PRS_JSON:-}" ]]; then` through its closing `fi` — with:

```bash
FIND_PR_RETRY_MAX="${FIND_PR_RETRY_MAX:-3}"
FIND_PR_RETRY_BASE_SLEEP="${FIND_PR_RETRY_BASE_SLEEP:-2}"
FIND_PR_RETRY_SLEEP_CMD="${FIND_PR_RETRY_SLEEP_CMD:-sleep}"

fetch_prs() {
  if [[ -n "${PIPELINE_PRS_JSON_SEQUENCE_CMD:-}" ]]; then
    "$PIPELINE_PRS_JSON_SEQUENCE_CMD"
    return
  fi
  gh pr list \
    --repo "$REPO" \
    --state open \
    --search "closes #${ISSUE_NUMBER} in:body" \
    --json number,isDraft,headRefOid,headRefName,author \
    --limit 10 2>/dev/null || printf '[]'
}

# select_from_json <json> <allowed_json> → prints the selected PR object (or {}).
select_from_json() {
  printf '%s' "$1" \
    | jq -c --argjson allow "$2" '
      def norm: (. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "");
      ($allow | map(norm)) as $a
      | [ .[]
          | select(.isDraft == true
                   and ((.author.login | norm) as $au | ($a | index($au)) != null)) ]
      | sort_by(-.number) | .[0] // {}'
}

ALLOWED_JSON="$(printf '%s\n' "$AUTHOR_ALLOWLIST" \
  | awk 'NF > 0' \
  | jq -R . | jq -sc .)"

if [[ -n "${PIPELINE_PRS_JSON:-}" ]]; then
  # Explicit static seam — used by every non-retry test. No retry: a caller
  # that already knows the exact JSON to return doesn't want the loop.
  SELECTED="$(select_from_json "$PIPELINE_PRS_JSON" "$ALLOWED_JSON")"
else
  attempt=1
  SELECTED='{}'
  while :; do
    PRS_JSON="$(fetch_prs)"
    SELECTED="$(select_from_json "$PRS_JSON" "$ALLOWED_JSON")"
    [[ "$SELECTED" != '{}' ]] && break
    (( attempt >= FIND_PR_RETRY_MAX )) && break
    "$FIND_PR_RETRY_SLEEP_CMD" "$(( FIND_PR_RETRY_BASE_SLEEP * attempt ))"
    attempt=$(( attempt + 1 ))
  done
fi
```

Leave everything from `pr_number="$(printf '%s' "$SELECTED" | jq -r
'.number // ""')"` to the end of the file exactly as-is — output emission is
unchanged.

Update the script's header comment block to document the two new optional
env vars (`PIPELINE_PRS_JSON_SEQUENCE_CMD`, `FIND_PR_RETRY_MAX`,
`FIND_PR_RETRY_BASE_SLEEP`, `FIND_PR_RETRY_SLEEP_CMD`) alongside the existing
`PIPELINE_PRS_JSON` doc line, one line each, following the file's existing
comment style.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -40`

Expected: PASS for all three new assertions AND all 8 existing assertions in
the `"find-pipeline-pr — discover the draft PR opened for an issue"` section
(scan the output for that section header and confirm zero `FAIL` lines
beneath it before the next `section` header). Also confirm the full suite's
final summary line still reports zero failures overall — this script is
shared by `verify-or-recover-pr.sh`'s tests too, so a regression there would
show up elsewhere in the same run.

- [ ] **Step 5: Commit**

```bash
git add scripts/find-pipeline-pr.sh tests/run-script-tests.sh
git commit -m "fix(ci): retry find-pipeline-pr.sh search on empty result

gh pr list --search hits GitHub's full-text search index, which is
eventually consistent. A just-created PR can be invisible to a search
query issued moments later, causing find-pipeline-pr.sh to report
found=false for a PR that genuinely exists and matches every criterion.

Observed: game-geography-quiz#13 (39s/18-turn implement run, fastest
of a 4-issue batch) — pre_preview's find_pr step ran before the search
index caught up, reported found=false, and the issue was silently
stamped ai:review-blocked with no review ever having run.

Adds a retry loop (default 3 attempts, ~2s/4s/6s backoff) around the
search call, triggered on empty result rather than command failure —
a different condition than gh-retry.sh's with_backoff, which only
retries a non-zero exit. PIPELINE_PRS_JSON (the existing test seam)
is unaffected: it still short-circuits with a single check.

Closes #249"
```

---

### Task 2: Document the fix in `docs/DECISIONS.md`

**Files:**
- Modify: `docs/DECISIONS.md` (append an addendum near the existing
  ADR-002/pre-preview self-modification section — search for the line
  containing `` `agent-pipeline` itself MUST NOT `` and insert the new
  addendum immediately after that subsection's closing paragraph, following
  the same `### Addendum — <title> (<date>)` heading style already used
  elsewhere in the file, e.g. the `### Addendum — Self-fix +
  pending-checks interaction (2026-08-04)` section)

**Interfaces:**
- Consumes: nothing (docs-only task, independent of Task 1's code — can be
  done in either order, but is written second here since it references the
  final retry parameters Task 1 lands on).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Write the addendum**

Insert this new subsection into `docs/DECISIONS.md`, formatted to match the
file's existing addendum style (a `###` heading with a `**Tracking:**` line
immediately below it, as seen in the existing `Addendum — Self-fix +
pending-checks interaction` section):

```markdown
### Addendum — find-pipeline-pr.sh search-index race (2026-08-12)

**Tracking:** [#249](https://github.com/freaxnx01/agent-workflow/issues/249)

`find-pipeline-pr.sh` locates the pipeline-opened draft PR via `gh pr list
--search "closes #N in:body"` — GitHub's full-text search index, which is
eventually consistent. On a fast `implement` run, the `auto_review`/
`pre_preview` job's `find_pr` step can query before the index catches up,
get zero results, and report `found=false` for a PR that genuinely exists
and matches every criterion (open, draft, correct `Closes #N`, allowlisted
author).

Observed on `game-geography-quiz#13` (2026-08-11): a 39s/18-turn `implement`
run — the fastest of four issues dispatched in the same batch — opened a
correct draft PR, but `find_pr` reported `found=false` immediately after.
`post-auto-review-block.sh` stamped the issue `ai:review-blocked`, which
reads identically to "an agent reviewed this and found real problems" even
though no review ever ran. The other three issues in the same batch (1m/2m/
11m durations) all found their PR correctly — the correlation with the
*shortest* run pointed at index-propagation lag rather than a logic bug.

**Fix:** `find-pipeline-pr.sh` now retries the search on an empty result
(default 3 attempts, ~2s/4s/6s backoff) before reporting `found=false`. This
is a distinct retry condition from `scripts/lib/gh-retry.sh`'s
`with_backoff`, which retries a *failed* `gh` call (non-zero exit matching a
transient-error signature) — here the call *succeeds* with a *stale-empty*
result, so a separate loop was added rather than reusing `with_backoff`
directly. Both known call sites (`verify-or-recover-pr.sh`'s recovery check,
and the `auto_review`/`pre_preview` jobs) share this script, so the fix
covers both without workflow YAML changes.

**Consequences:**
- A genuinely nonexistent PR still reports `found=false`, just after the
  retry budget (~12s worst case) instead of immediately — negligible given
  the multi-minute scale of the surrounding job.
- `verify-or-recover-pr.sh`'s "already exists" fallback comment (`# PR
  already existed — the search index lagged`) documents the same underlying
  race from the recovery-attempt angle; the retry reduces how often that
  fallback path is needed, though it remains as a second line of defense.
```

- [ ] **Step 2: Verify placement and formatting**

Run: `grep -n "^### Addendum" docs/DECISIONS.md` and confirm the new heading
appears in the list, positioned after the "Self-modification / dogfooding"
paragraph and its surrounding ADR-002 material (visually confirm by reading
the ~20 lines above and below the insertion point — no automated check for
prose placement).

- [ ] **Step 3: Commit**

```bash
git add docs/DECISIONS.md
git commit -m "docs: addendum on find-pipeline-pr.sh search-index race (#249)"
```

---

## Self-Review Notes

**Spec coverage:**
- Retry loop, empty-result triggered, distinct from `with_backoff` → Task 1 Step 3.
- `PIPELINE_PRS_JSON_SEQUENCE_CMD` seam, counter-file idiom → Task 1 Step 1 (test) + Step 3 (script support).
- 3 new tests (empty-then-found, exhausts-then-not-found, existing-seam-still-short-circuits) → Task 1 Step 1.
- 8 existing tests pass unmodified → Task 1 Step 4 explicitly checks this.
- `docs/DECISIONS.md` addendum referencing #249 and the #13 evidence → Task 2.
- Scope boundaries (no allowlist/draft-filter change, no workflow YAML change, no `verify-or-recover-pr.sh` change) → honored: Task 1's diff only touches the acquisition block, `select_from_json`'s jq filter body is byte-identical to the original `SELECTED=` filter, and no other file is modified.

**Placeholder scan:** none found — every step has literal code/commands.

**Type consistency:** `select_from_json` is introduced and used exactly once in Task 1 Step 3, with a single call signature (`json_string`, `allowed_json_string` → prints selected object). `fetch_prs` takes no arguments and is called identically in both the seam and retry branches. No cross-task signature drift since this is a single-task code change.
