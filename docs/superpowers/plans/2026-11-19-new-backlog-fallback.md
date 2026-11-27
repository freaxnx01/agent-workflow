# `/new` backlog fallback Implementation Plan (#645)

**Goal:** `/new` resolves a silent or declined milestone answer, `none` and zero active milestones to `backlog`, never counts `backlog` as active, and reports (never creates) a missing `backlog`.

**Architecture:** Markdown edits to `commands/new.md` (GitHub, Forgejo, Azure DevOps sections), an ADR-010 amendment note, a CHANGELOG entry, and one new Layer-1 runner that extracts the documented filters from `new.md` and executes them against fixtures.

**Spec:** `docs/superpowers/specs/2026-11-19-new-backlog-fallback-design.md`

## Global Constraints

- Touch only `commands/new.md`, `tests/run-new-milestone-tests.sh`, `docs/DECISIONS.md` (one amendment note above `### Context` of ADR-010) and `CHANGELOG.md`.
- Do not touch `docs/generated/software-factory-knowledge.md` (generated), `tests/run-script-tests.sh` (#616 edits it), or the ADO paragraph that #616 rewords ("Do not apply `needs-enrichment`").
- Do not touch `commands/milestone.md`, `roadmap.md`, `parked.md` (#644) or any CI guard (#646).
- Never create the `backlog` milestone from `/new`, and do not add `general-*` handling anywhere.
- No `Closes #645` (or any `Closes #N`) in a commit message of the docs PR.
- Plain ASCII in added text. Locate edits by the quoted text, not by line number (line numbers are from `main` at `58f7503`).
- Each filter documented in `new.md` must be one extractable unit: the GitHub `--jq '...'` expressions each on a single line, the Forgejo python snippet closed by a line holding only `'`.

### Task 1: Failing test that executes the documented filters

**Files:**
- Create: `tests/run-new-milestone-tests.sh`

- [ ] **Step 1: Write the runner**

```bash
#!/usr/bin/env bash
#
# run-new-milestone-tests.sh -- Layer-1 tests for /new's milestone selection (#645).
# commands/new.md is a prompt, so the logic worth testing is the filter each
# section documents. This extracts those filters and RUNS them on fixtures:
#   - backlog is never an "active" milestone;
#   - active milestones keep the soonest-due-first, undated-last order;
#   - a missing backlog is detectable (so /new can report it, not create it);
#   - general-<month>-<year> handling is gone from /new.
#
# Usage: tests/run-new-milestone-tests.sh
# Exit codes: 0 all pass; 1 at least one assertion failed.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/commands/new.md"
PASS=0; FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; return 0; }
assert_eq() { # actual expected label
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi
}

section_of() { # heading line -> body up to the next ### heading
  awk -v h="$1" '$0==h{on=1;next} on&&/^### /{exit} on{print}' "$DOC"
}

gh_sec="$(section_of '### Milestone selection (GitHub)')"
fj_sec="$(section_of '### Milestone selection (Forgejo)')"
[[ -n "$gh_sec" && -n "$fj_sec" ]] || { echo "milestone sections missing in $DOC" >&2; exit 1; }

# GitHub: the --jq expressions, in document order: [0] active list, [1] backlog count.
mapfile -t gh_jq < <(printf '%s\n' "$gh_sec" | sed -n "s/^ *--jq '\(.*\)'\$/\1/p")
if [[ ${#gh_jq[@]} -ne 2 ]]; then
  fail "GitHub section documents exactly two --jq filters" "found ${#gh_jq[@]}"
else
  pass "GitHub section documents exactly two --jq filters"
  fixture='[{"title":"backlog","due_on":null},{"title":"undated","due_on":null},{"title":"later","due_on":"2026-12-30T00:00:00Z"},{"title":"next","due_on":"2026-12-01T00:00:00Z"}]'
  assert_eq "$(printf '%s' "$fixture" | jq -r "${gh_jq[0]}" | cut -f1 | paste -sd,)" "next,later,undated" \
    "GitHub: active = sorted, undated last, backlog excluded, next kept"
  assert_eq "$(printf '%s' "$fixture" | jq -r "${gh_jq[1]}")" "1" "GitHub: backlog present -> 1"
  only='[{"title":"backlog","due_on":null}]'
  assert_eq "$(printf '%s' "$only" | jq -r "${gh_jq[0]}" | wc -l | tr -d ' ')" "0" \
    "GitHub: backlog alone -> zero active"
  none='[{"title":"a","due_on":null}]'
  assert_eq "$(printf '%s' "$none" | jq -r "${gh_jq[1]}")" "0" "GitHub: no backlog -> 0 (report, never create)"
  caps='[{"title":"Backlog","due_on":null}]'
  assert_eq "$(printf '%s' "$caps" | jq -r "${gh_jq[1]}")" "0" "GitHub: title match is exact and case-sensitive"
fi

# Forgejo: the python snippet, from "python3 -c '" to the line holding only "'".
fj_py="$(printf '%s\n' "$fj_sec" | awk '/python3 -c .$/{on=1;next} on&&/^.$/{exit} on{print}')"
if [[ -z "$fj_py" ]]; then
  fail "Forgejo section documents an extractable python3 -c snippet"
else
  pass "Forgejo section documents an extractable python3 -c snippet"
  fj_fixture='[{"title":"backlog","due_on":null},{"title":"undated","due_on":null},{"title":"later","due_on":"2026-12-30T00:00:00Z"}]'
  out="$(printf '%s' "$fj_fixture" | python3 -I -c "$fj_py")"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^active')" "2" "Forgejo: two active rows, backlog excluded"
  assert_eq "$(printf '%s\n' "$out" | sed -n '1p' | cut -f2)" "later" "Forgejo: dated first"
  assert_eq "$(printf '%s\n' "$out" | grep '^backlog' | cut -f2)" "yes" "Forgejo: backlog present"
  out2="$(printf '%s' '[{"title":"a","due_on":null}]' | python3 -I -c "$fj_py")"
  assert_eq "$(printf '%s\n' "$out2" | grep '^backlog' | cut -f2)" "no" "Forgejo: backlog missing"
fi

# Prose guards (secondary to the executed filters above).
assert_eq "$(grep -c 'general-' "$DOC" || true)" "0" "new.md no longer mentions general-<month>-<year>"
assert_eq "$(grep -c '`none`' "$DOC" || true)" "0" "new.md no longer offers a none option"
for sec in "$gh_sec" "$fj_sec"; do
  assert_eq "$(printf '%s\n' "$sec" | grep -q '/milestone new backlog' && echo yes || echo no)" "yes" \
    "a forge section points at /milestone new backlog"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run, expect failure**

Run: `chmod +x tests/run-new-milestone-tests.sh && git add tests/run-new-milestone-tests.sh && bash tests/run-new-milestone-tests.sh; echo rc=$?`
Expected: FAIL lines for "exactly two --jq filters" (the current section has one), the Forgejo snippet and all three prose guards; `rc=1`.

### Task 2: GitHub section of `new.md`

**Files:**
- Modify: `commands/new.md` (`### Milestone selection (GitHub)`, from the line "If my notes name no milestone, read the open ones" down to, and including, the bullet "A picker caps at four options ...", plus the last paragraph "`/new` never guesses roadmap/parked intent from my notes.")

- [ ] **Step 1: Replace the case 2-4 block**

Replace everything from `If my notes name no milestone, read the open ones` through the end of the `**4 — Two or more open milestones.**` bullets with:

````markdown
If my notes name no milestone, read the open ones. **`backlog` is the fallback
bucket, not an active milestone** (ai-instructions#61): list only the **active**
ones — open and not titled `backlog` — **sorted locally**, see *The sort rule*
below, and separately check whether `backlog` exists. Take case 2, 3, or 4 by how
many active milestones came back:

```bash
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'sort_by(.due_on // "9999") | map(select(.title != "backlog")) | .[] | [.title, (.due_on // "-")] | @tsv'
gh api "repos/$repo/milestones?state=open&per_page=100" \
  --jq 'map(select(.title == "backlog")) | length'
```

The second prints `1` when `backlog` exists and `0` when it does not. The match is
the exact, case-sensitive title.

**2 — Zero active milestones.** Assign `backlog` with `-m "backlog"`, silently,
and report it from the read-back (same discipline as case 3). `/new` no longer
offers or creates `general-<month>-<year>`.

**3 — Exactly one active milestone.** Assign it silently with `-m "<name>"`. The
read-back must show it: a silent assignment is always *reported*, never implicit.
`backlog` is not counted, so a repo holding one other milestone plus `backlog`
lands here, not in case 4.

**4 — Two or more active milestones.** Ask. Offer the active titles in sorted
order, then `backlog` as the last option, and the **first active entry is the
proposal** (pre-selected). Rules:

- **Silence is never an assignment *to an active milestone*.** No answer, or a
  declined question, means `backlog`.
- **`backlog` replaces the old `none` option.** There is no "no milestone" answer
  while `backlog` exists.
- This pre-selection does **not** contradict `/milestone triage`'s "No default
  milestone, no inferring from labels or title". That rule forbids assigning
  *without an explicit answer*, which this still requires for an active
  milestone. Don't "fix" the apparent contradiction by removing the pre-selection.
- A picker caps at four options, so above three active milestones it can't hold
  them all plus `backlog` -- fall back to a numbered plain-text list that names the
  first entry as the proposal and lists `backlog` last.

**`backlog` missing** (the second command printed `0`). Say so in the output --
"no `backlog` milestone in `<repo>`; create it with `/milestone new backlog`" --
and **never create it from `/new`**; it is created by hand, with `/milestone`'s
confirmation and due-date rules. A closed `backlog` counts as missing, and
`/milestone new backlog` reports the closed one and stops. Where the fallback was
needed (case 2, or case 4 with no answer) file the issue with **no milestone** and
say that in the report; the issue is the deliverable, so a missing bucket never
aborts filing. In case 4 the `backlog` option is then left out.
````

- [ ] **Step 2: Reword the closing paragraph**

Replace the paragraph beginning `**`/new` never guesses roadmap/parked intent from my notes.**` with:

```markdown
**`/new` never guesses roadmap/parked intent from my notes.** At creation time an
issue carries only `needs-enrichment` -- nothing adds those labels. What happens
to the milestone of an issue *entering* those states belongs to `/roadmap defer`
and `/parked repark` (#644), not to `/new`.
```

- [ ] **Step 3: Read-back sentence**

In the paragraph after `gh issue create` ("After creating, print the issue number, title, and URL"), append: `Report the milestone from the read-back; when the fallback should have assigned `backlog` and the read-back shows none, say so rather than claiming it.`

- [ ] **Step 4: Run the test**

Run: `bash tests/run-new-milestone-tests.sh; echo rc=$?`
Expected: all GitHub assertions pass; the Forgejo and Forgejo-section `/milestone new backlog` assertions still FAIL; `general-`/`none` guards still fail until Task 3 (the Forgejo section still carries them).

### Task 3: Forgejo and Azure DevOps sections of `new.md`

**Files:**
- Modify: `commands/new.md` (`### Milestone selection (Forgejo)`; the Forgejo `tea issues create` comment `# only when my notes named one`; the Azure DevOps `### Create` section)

- [ ] **Step 1: Rewrite cases 2-4 in the Forgejo section**

Replace from `Otherwise read the open milestones.` through the line `` `tea`'s milestone flags carry the same epistemic caveat ... `` (keep that caveat paragraph) with:

````markdown
Otherwise read the open milestones. This is the existing `/milestone list` idiom,
and its `"9999"` sentinel is already the sort rule -- soonest due first, **undated
last**. `backlog` is the fallback bucket, not an active milestone, so the snippet
prints the **active** ones as `active` rows and reports `backlog` on its own line:

```bash
tea api --login git-home "repos/$repo/milestones?state=open&limit=50" | python3 -c '
import sys, json
ms = json.load(sys.stdin)
for m in sorted(ms, key=lambda x: x.get("due_on") or "9999"):
    if m["title"] != "backlog":
        print("active", m["title"], m.get("due_on") or "-", sep="\t")
print("backlog", "yes" if any(m["title"] == "backlog" for m in ms) else "no", sep="\t")
'
```

**2 — Zero active milestones.** Assign `backlog` with `-m "backlog"`, silently,
and report it from the read-back. `general-<month>-<year>` is no longer offered or
created.

**3 — Exactly one active milestone.** Assign it silently, and let the read-back
report it. `backlog` is not counted.

**4 — Two or more active milestones.** Ask, first active entry pre-selected, then
`backlog` as the last option; silence or a decline means `backlog`.

**`backlog` missing** (the snippet's last line says `no`). Say so -- "no `backlog` milestone in
`<repo>`; create it with `/milestone new backlog`" -- and never create it from
`/new`. Where the fallback was needed, file the issue with no milestone and say so;
leave the `backlog` option out of case 4.
````

- [ ] **Step 2: Update the `tea issues create` comment**

Change `-m "<milestone>"            # only when my notes named one` to `-m "<milestone>"            # the case 1-4 result, backlog included`.

- [ ] **Step 3: Azure DevOps note**

In `## Azure DevOps` -> `### Create`, after the `az boards work-item create` code block and before `**Do not apply `needs-enrichment`.**`, insert:

```markdown
**No milestone fallback here.** A milestone on this forge is an iteration (ADR-012)
and this create sets only Area Path and description, so the `backlog` fallback
`/new` applies on GitHub and Forgejo does not apply to a work item.
```

Do not edit the `needs-enrichment` paragraph (#616).

- [ ] **Step 4: Run and verify the tests and lint**

Run: `bash tests/run-new-milestone-tests.sh; echo rc=$?`
Expected: every assertion passes, `rc=0`.
Run: `bash tests/run-all.sh 2>&1 | tail -15; echo rc=$?`
Expected: all runners pass (the new runner is discovered automatically).
Run: `grep -n 'general-\|`none`' commands/new.md; echo rc=$?`
Expected: no output, `rc=1`.

### Task 4: ADR-010 amendment, CHANGELOG, final verification

**Files:**
- Modify: `docs/DECISIONS.md` (ADR-010, directly above the existing `> **Amended 2026-10-04:**` block)
- Modify: `CHANGELOG.md` (`## [Unreleased]` -> `### Changed`)

- [ ] **Step 1: Amendment note**

Insert, followed by a blank line, above `> **Amended 2026-10-04:**`:

```markdown
> **Amended 2026-11-19:** the `none` option and the zero-milestone
> `general-<month>-<year>` offer no longer hold (#645, ai-instructions#61). `backlog`
> is the default milestone: it replaces `none`, it is what a silent or declined
> answer and zero active milestones resolve to, and it is not counted as an active
> milestone. A missing `backlog` is reported, never created. The proposal ordering,
> the sort rule and the silent single assignment stand.
```

- [ ] **Step 2: CHANGELOG**

Add this bullet at the end of the `### Changed` list under `## [Unreleased]` (the one at the Unreleased section, not an older release's):

```markdown
- **new:** `/new` falls back to the `backlog` milestone instead of `none` (#645). `backlog` replaces the `none` option, is what a silent or declined answer and zero active milestones resolve to, and is not counted as an active milestone; it is reported, never created, when missing. `/new` no longer offers or creates `general-<month>-<year>`.
```

- [ ] **Step 3: Verify**

Run: `awk '/^## \[Unreleased\]/{on=1;next} on&&/^## \[/{exit} on' CHANGELOG.md | grep -c '#645'`
Expected: `1`.
Run: `bash tests/run-new-milestone-tests.sh && bash tests/run-all.sh >/dev/null 2>&1; echo rc=$?`
Expected: `rc=0`.
Run: `pre-commit run --files commands/new.md tests/run-new-milestone-tests.sh docs/DECISIONS.md CHANGELOG.md docs/superpowers/specs/2026-11-19-new-backlog-fallback-design.md docs/superpowers/plans/2026-11-19-new-backlog-fallback.md` (after `git add`; untracked files are skipped)
Expected: all hooks pass.
