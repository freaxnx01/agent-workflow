# find-pipeline-pr false-positive matching — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `find-pipeline-pr.sh` accepting any open PR whose body merely contains the issue's digits, so `verify-or-recover-pr.sh`'s salvage path stops being suppressed by a false match.

**Architecture:** The `gh pr list --search` call is demoted to a prefilter. `select_from_json` gains a `closes_issue` predicate that accepts a candidate only if GitHub's own `closingIssuesReferences` links it to this issue in this repo, or its body carries a closing keyword for the issue. Both fields come from the existing single `gh pr list` call, so no extra API requests.

**Tech Stack:** Bash 5, `jq` (Oniguruma regex via `test()`), `gh` CLI, the repo's own `tests/run-script-tests.sh` harness.

**Spec:** `docs/superpowers/specs/2026-09-13-find-pipeline-pr-false-positive-design.md`

## Global Constraints

- Shell is `bash` with `set -euo pipefail` and `IFS=$'\n\t'` — already set at the top of `find-pipeline-pr.sh`; do not change it.
- **No additional API calls per invocation.** The verification data must come from the existing `gh pr list` request by widening `--json`.
- The retry loop (`FIND_PR_RETRY_MAX`, `#249`) keeps its current behaviour. Do not modify the loop.
- The `PIPELINE_PRS_JSON` and `PIPELINE_PRS_JSON_SEQUENCE_CMD` test seams keep their current meaning.
- Existing outputs are unchanged: `found`, `pr-number`, `head-sha`, `head-ref`.
- The closing-keyword regex is exactly `(?i)\b(close[sd]?|fix(es|ed)?|resolve[sd]?)\s+#N\b`.
- Every test in this plan runs via `bash tests/run-script-tests.sh`; the whole suite must pass at the end of each task.

---

### Task 1: Make the existing fixtures carry the linkage

The fixtures in the `find-pipeline-pr` section pass PR objects with only `number`, `isDraft`, `headRefOid`, `headRefName` and `author`. Real `gh pr list` output for this call will also carry `body` and `closingIssuesReferences`. Task 2's predicate rejects a candidate that has neither, so these fixtures must first become realistic — otherwise Task 2 turns the whole section red for a reason that has nothing to do with the bug.

This task changes **no production code** and the suite must stay green: today's `select_from_json` ignores fields it does not read.

**Files:**
- Modify: `tests/run-script-tests.sh` — the section beginning `section "find-pipeline-pr — discover the draft PR opened for an issue"` (around line 1802)

**Interfaces:**
- Consumes: nothing.
- Produces: fixtures that already satisfy Task 2's predicate, so Task 2's only red test is the new regression one.

- [ ] **Step 1: Confirm the suite is green before touching it**

Run: `bash tests/run-script-tests.sh`
Expected: PASS. Note the total count — Task 1 must not change it.

- [ ] **Step 2: Add `closingIssuesReferences` to every fixture in the section**

All these tests use `ISSUE_NUMBER=42 REPO=o/r`, so the linkage object is the same everywhere:

```json
"closingIssuesReferences":[{"number":42,"repository":{"name":"r","owner":{"login":"o"}}}]
```

Add it to each PR object in these fixtures (identified by the PR numbers they contain):

- the single-draft case — PR `17`
- the multiple-drafts case — PRs `17` and `99`
- the non-allowlisted-author case — PRs `100` and `101`
- the custom-allowlist case — PR `50`
- the `app/github-actions` case — PR `7`
- the symmetric-normalization case — PR `8`
- the human-author rejection case — PR `9`
- the non-draft case — PR `17`
- the retry shim's `real_json` (`make_flaky_pr_list "$shim1" 1 …`) — PR `17`
- the `PIPELINE_PRS_JSON`-takes-priority case — PR `5`

Add it to the *rejection* cases (PR `9`, the non-draft `17`) as well. Each of those tests exists to isolate one rejection reason — author, draft status — and leaving the linkage out would give it a second, unrelated reason to fail.

Example, before and after, for the first fixture:

```bash
# before
PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"deadbeef","headRefName":"feat/fix-thing","author":{"login":"github-actions[bot]"}}]'
# after
PIPELINE_PRS_JSON='[{"number":17,"isDraft":true,"headRefOid":"deadbeef","headRefName":"feat/fix-thing","author":{"login":"github-actions[bot]"},"closingIssuesReferences":[{"number":42,"repository":{"name":"r","owner":{"login":"o"}}}]}]'
```

Leave the `[]` empty-result case and the all-empty retry shims (`shim2`, `shim4`) alone — they contain no PR objects.

- [ ] **Step 3: Run the suite to prove nothing changed**

Run: `bash tests/run-script-tests.sh`
Expected: PASS, with the same number of assertions as Step 1. Production code was not touched, so a failure here means a fixture was malformed — check the JSON with `jq .` on the offending string.

- [ ] **Step 4: Commit**

```bash
git add tests/run-script-tests.sh
git commit -m "test(find-pipeline-pr): give fixtures the closingIssuesReferences the API returns

No behaviour change — select_from_json ignores fields it does not read. This
makes the fixtures match the shape of a real gh pr list response so the
verification predicate can be introduced without turning the section red for
reasons unrelated to the bug."
```

---

### Task 2: Reject candidates the issue is not actually linked to

**Files:**
- Modify: `scripts/find-pipeline-pr.sh:72-74` (the `--json` field list in `fetch_prs`)
- Modify: `scripts/find-pipeline-pr.sh:88-98` (`select_from_json`) and its two call sites (around lines 110 and 116)
- Test: `tests/run-script-tests.sh`, same section

**Interfaces:**
- Consumes: Task 1's fixtures.
- Produces: `select_from_json <json> <allowed_json> <issue_number> <repo>` — the arity grows from 2 to 4. Both existing call sites must pass `"$ISSUE_NUMBER"` and `"$REPO"`.

- [ ] **Step 1: Write the failing regression test**

Add this directly after the `# Empty result → not found` case in the section. It is the observed failure from the issue, with PR #28's real body text:

```bash
# --- false-positive rejection (#343) -----------------------------------

# GitHub's search tokenises `closes #11` and matches any body containing the
# bare number, so the result set can hold a PR that closes something else
# entirely. PR #28 in game-wipfelkratzer matched issue 11 on the phrase
# "chairs at cells 5 and 11" — a cell index. Accepting it suppressed
# verify-or-recover-pr.sh's salvage and the run's work was lost.
out="$(find_pr_run env ISSUE_NUMBER=11 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":28,"isDraft":true,"headRefOid":"wrong","author":{"login":"github-actions[bot]"},"body":"- **After, tall** (floors: 10, chairs at cells 5 and 11 next to the stair opening)","closingIssuesReferences":[{"number":13,"repository":{"name":"r","owner":{"login":"o"}}}]}]')"
assert_contains "$out" 'found=false'  "bare number in body, linked to another issue → rejected (#343)"
assert_contains "$out" 'pr-number='   "  → no pr-number, so salvage can run"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A2 '#343'`
Expected: FAIL — today's code reports `found=true pr-number=28`, because it filters on draft status and author only.

- [ ] **Step 3: Widen the fetched fields**

In `fetch_prs`, extend the `--json` list. Nothing else in the function changes:

```bash
  gh pr list \
    --repo "$REPO" \
    --state open \
    --search "closes #${ISSUE_NUMBER} in:body" \
    --json number,isDraft,headRefOid,headRefName,author,body,closingIssuesReferences \
    --limit 10 2>/dev/null || printf '[]'
```

- [ ] **Step 4: Add the predicate to `select_from_json`**

Replace the function, and its doc comment, with:

```bash
# The search query is a PREFILTER, not an answer. GitHub tokenises
# `closes #N in:body` and drops the `#`, so the result set contains every open
# PR whose body mentions the bare number anywhere — a line number, a cell
# index, a viewport width. Accepting one of those made verify-or-recover-pr.sh
# believe a PR already existed and skip salvage, losing the run's work (#343).
#
# So verify each candidate. Two signals, either is sufficient:
#   1. closingIssuesReferences — GitHub's own computed link, scoped to this
#      repo so the same number in another repo does not count. Definitive.
#   2. a closing keyword for the issue in the body — covers the window before
#      the link is computed. Without this fallback, a link that has not
#      materialised yet becomes a false negative, which is what #249's retry
#      loop exists to prevent.
#
# select_from_json <json> <allowed_json> <issue_number> <repo> → the selected
# PR object (or {}).
select_from_json() {
  printf '%s' "$1" \
    | jq -c --argjson allow "$2" --arg issue "$3" --arg repo "$4" '
      def norm: (. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "");
      def closes_issue($n; $r):
        ((.closingIssuesReferences // [])
           | any(.number == ($n | tonumber)
                 and ((.repository.owner.login + "/" + .repository.name) == $r)))
        or ((.body // "")
              | test("(?i)\\b(close[sd]?|fix(es|ed)?|resolve[sd]?)\\s+#" + $n + "\\b"));
      ($allow | map(norm)) as $a
      | [ .[]
          | select(.isDraft == true
                   and ((.author.login | norm) as $au | ($a | index($au)) != null)
                   and closes_issue($issue; $repo)) ]
      | sort_by(-.number) | .[0] // {}'
}
```

- [ ] **Step 5: Pass the two new arguments at both call sites**

There are exactly two. The `PIPELINE_PRS_JSON` branch:

```bash
  SELECTED="$(select_from_json "$PIPELINE_PRS_JSON" "$ALLOWED_JSON" "$ISSUE_NUMBER" "$REPO")"
```

and the one inside the retry loop:

```bash
    SELECTED="$(select_from_json "$PRS_JSON" "$ALLOWED_JSON" "$ISSUE_NUMBER" "$REPO")"
```

Verify none were missed — this must print nothing:

```bash
grep -n 'select_from_json "' scripts/find-pipeline-pr.sh | grep -v '"\$ISSUE_NUMBER" "\$REPO"'
```

- [ ] **Step 6: Run the regression test and then the whole suite**

Run: `bash tests/run-script-tests.sh`
Expected: PASS, including the new `#343` assertions. If a Task 1 fixture was missed it fails here as `found=false` where the test expects a PR number — add the linkage to that fixture rather than weakening the predicate.

- [ ] **Step 7: Commit**

```bash
git add scripts/find-pipeline-pr.sh tests/run-script-tests.sh
git commit -m "fix(find-pipeline-pr): verify the PR actually closes the issue

The search query is a prefilter: GitHub tokenises 'closes #N in:body' and
matches any open PR whose body contains the bare number. select_from_json
filtered on draft status and author but never on whether the PR had anything
to do with the issue, so an unrelated PR could be returned as the run's own.

A false hit is expensive: verify-or-recover-pr.sh concludes a PR already
exists and skips salvage, so a run that pushed nothing ends as success with
the work discarded.

Candidates are now checked against closingIssuesReferences (scoped to this
repo) or a closing keyword in the body. Both fields come from the existing
gh pr list call, so this costs no extra API requests.

Closes #343"
```

---

### Task 3: Cover the remaining acceptance criteria

Task 2 proves the reported failure is gone. These lock in the edges — most importantly that the fix did not overshoot into rejecting real PRs.

**Files:**
- Modify: `tests/run-script-tests.sh`, same section, after the `#343` case

**Interfaces:**
- Consumes: `select_from_json`'s 4-argument form from Task 2.
- Produces: nothing.

- [ ] **Step 1: Write the edge-case tests**

```bash
# The linkage is authoritative: a body that never names the issue is still a
# match when GitHub linked it.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":30,"isDraft":true,"headRefOid":"linked","author":{"login":"github-actions[bot]"},"body":"no mention at all","closingIssuesReferences":[{"number":42,"repository":{"name":"r","owner":{"login":"o"}}}]}]')"
assert_contains "$out" 'pr-number=30' "closingIssuesReferences alone is enough"

# The body fallback covers the window before GitHub computes the link — the
# false negative #249's retry loop exists to avoid.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":31,"isDraft":true,"headRefOid":"kw","author":{"login":"github-actions[bot]"},"body":"Implements the thing.\n\nCloses #42","closingIssuesReferences":[]}]')"
assert_contains "$out" 'pr-number=31' "body keyword alone is enough when the link is not computed yet"

# Every keyword GitHub honours, one fixture each.
for kw in "Close" "Closes" "Closed" "fixes" "Fixed" "resolve" "Resolves" "RESOLVED"; do
  out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
          PIPELINE_PRS_JSON="[{\"number\":32,\"isDraft\":true,\"headRefOid\":\"kw\",\"author\":{\"login\":\"github-actions[bot]\"},\"body\":\"$kw #42\",\"closingIssuesReferences\":[]}]")"
  assert_contains "$out" 'pr-number=32' "keyword '$kw' is accepted"
done

# A mention without a closing keyword is not a claim on the issue.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":33,"isDraft":true,"headRefOid":"mention","author":{"login":"github-actions[bot]"},"body":"Related to #42, see the discussion there.","closingIssuesReferences":[]}]')"
assert_contains "$out" 'found=false' "a bare mention without a closing keyword is rejected"

# Prefix collision: #420 must not satisfy issue 42.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":34,"isDraft":true,"headRefOid":"prefix","author":{"login":"github-actions[bot]"},"body":"Closes #420","closingIssuesReferences":[]}]')"
assert_contains "$out" 'found=false' "Closes #420 does not satisfy issue 42"

# Linked, but to a different issue in the same repo.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":35,"isDraft":true,"headRefOid":"other","author":{"login":"github-actions[bot]"},"body":"x","closingIssuesReferences":[{"number":43,"repository":{"name":"r","owner":{"login":"o"}}}]}]')"
assert_contains "$out" 'found=false' "a link to a different issue is rejected"

# Linked to the same number, but in a different repository.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":36,"isDraft":true,"headRefOid":"xrepo","author":{"login":"github-actions[bot]"},"body":"x","closingIssuesReferences":[{"number":42,"repository":{"name":"other","owner":{"login":"o"}}}]}]')"
assert_contains "$out" 'found=false' "a link to the same number in another repo is rejected"

# Several valid candidates → the highest-numbered still wins, unchanged.
out="$(find_pr_run env ISSUE_NUMBER=42 REPO=o/r \
        PIPELINE_PRS_JSON='[{"number":40,"isDraft":true,"headRefOid":"lo","author":{"login":"github-actions[bot]"},"body":"Closes #42","closingIssuesReferences":[]},{"number":41,"isDraft":true,"headRefOid":"hi","author":{"login":"github-actions[bot]"},"body":"Closes #42","closingIssuesReferences":[]}]')"
assert_contains "$out" 'pr-number=41' "highest-numbered valid candidate still wins"

# A result set of nothing but false positives must exhaust the retries and
# report found=false — that is what lets salvage run.
shim5="$(mktemp)"; ctr5="$(mktemp)"; : > "$ctr5"
make_flaky_pr_list "$shim5" 0 \
  '[{"number":28,"isDraft":true,"headRefOid":"wrong","author":{"login":"github-actions[bot]"},"body":"cells 5 and 11","closingIssuesReferences":[{"number":13,"repository":{"name":"r","owner":{"login":"o"}}}]}]' \
  "$ctr5"
out="$(find_pr_run env ISSUE_NUMBER=11 REPO=o/r \
        PIPELINE_PRS_JSON_SEQUENCE_CMD="$shim5" \
        FIND_PR_RETRY_SLEEP_CMD=: FIND_PR_RETRY_MAX=3)"
assert_contains "$out" 'found=false' "an all-false-positive result set exhausts the retries"
assert_equals "$(cat "$ctr5")" "3"   "  → retried FIND_PR_RETRY_MAX times, then gave up"
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/run-script-tests.sh`
Expected: PASS. Every one of these was checked against the predicate before the plan was written; a failure means the jq differs from Task 2 Step 4 — diff it rather than adjusting the expectation.

- [ ] **Step 3: Commit**

```bash
git add tests/run-script-tests.sh
git commit -m "test(find-pipeline-pr): cover the verification edges

Keyword variants, prefix collision (#420 vs #42), a link to another issue, a
link to the same number in another repo, and an all-false-positive result set
exhausting the retry loop — the last one is what proves salvage gets its
chance back."
```

---

### Task 4: Record the decision

`docs/DECISIONS.md` carries this repo's architecture record. The search-as-prefilter rule is the kind of thing a future reader will otherwise undo — the query still *looks* like it selects by issue.

**Files:**
- Modify: `docs/DECISIONS.md` — append to the end, following the format of the entries already there

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Read the two most recent entries to match their shape**

Run: `tail -60 docs/DECISIONS.md`
Match the heading level, the `### Context` / `### Decision` structure, and the numbering the file already uses.

- [ ] **Step 2: Append the entry**

Content to record, in the file's own format:

- **Context:** `find-pipeline-pr.sh` finds the pipeline's PR through a GitHub search query. Search has no phrase semantics for `closes #N in:body`; the `#` is dropped and any body containing the number matches. #249 had already added a retry loop for the opposite failure, an empty result from index lag — and that loop stops at the first selection, so a false positive is never reconsidered.
- **Decision:** The search result is a prefilter. A candidate is accepted only via `closingIssuesReferences` scoped to this repo, or a closing keyword for the issue in its body. Both fields ride along on the existing `gh pr list` request.
- **Consequences:** Verification costs no extra API calls. Fixtures for this script must carry the two fields, because a fixture without them no longer resembles a real response. A candidate that satisfies neither signal is discarded even if search returned it, which for `verify-or-recover-pr.sh` means salvage runs — the safe direction, since a false negative there self-corrects while a false positive discards the run's work.

- [ ] **Step 3: Commit**

```bash
git add docs/DECISIONS.md
git commit -m "docs(decisions): record search-as-prefilter for find-pipeline-pr (#343)"
```
