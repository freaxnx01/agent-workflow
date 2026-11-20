# Forgejo triage truncation guard (#663) Implementation Plan

**Goal:** Forgejo `/milestone triage` Phase 1 prints `fetched: N of at most 100`
and tells the reader to act on a full page, with a fixture test.

**Architecture:** One Python fence and one prose paragraph in
`commands/milestone.md` (Forgejo section), mirrored from the GitHub section
(#656). Test in `tests/run-backlog-milestone-tests.sh`, which runs the fence with
a `tea` stub serving fixtures.

## Global Constraints

- Test first; never edit a test to make it green.
- No pagination. No change to the GitHub section, the other Forgejo fences or the
  tea stub.
- No `Closes #N` in any commit message.
- Do not touch `CHANGELOG.md` (git-cliff generates it at release).
- Pre-commit lints tracked files only: `git add` new files before running it.

## Files

- Modify: `tests/run-backlog-milestone-tests.sh`
- Modify: `commands/milestone.md` (Forgejo, `triage`, Phase 1 only)

### Task 1: Failing tests for the Forgejo guard

**Files:** `tests/run-backlog-milestone-tests.sh`

**Interfaces:** the Forgejo Phase 1 fence is fence 1 of `Forgejo` > `triage` in
`commands/milestone.md`; `run`, `ok`, `has`, `numbers` and `ISSUES=` are the
existing helpers.

- [ ] **Step 1: Write the failing test**

Add a 100-row fixture directly after the existing `issues-full-page.json` block
(fixtures section):

```bash
# A full Forgejo page: 100 open issues (its limit=100 cap), all but three already
# scheduled into v1.2, so the filter leaves three rows.
jq -n '[range(1; 101) | {number: ., title: "issue \(.)", labels: [],
  milestone: (if . <= 3 then null else {title: "v1.2 · goal"} end),
  createdAt: "2026-01-01T00:00:00Z"}]' > "$WORK/issues-full-page-fj.json"
```

In the `/milestone triage — Forgejo Phase 1` section, after the "lists backlog"
assertion and before the missing-backlog `run`, add:

```bash
ok "reports what was fetched, not what survived the filter" "$OUT" \
  has "$OUT" "fetched: 6 of at most 100"
ISSUES="$WORK/issues-full-page-fj.json" run "$code" "$WORK/ms-with-backlog.json" /dev/null
ok "a full page of 100 reports the cap even when the filter leaves 3 rows" \
  "rows: $(numbers "$OUT"); $OUT" has "$OUT" "fetched: 100 of at most 100"
ok "the full page still lists only the 3 unscheduled issues" "got: $(numbers "$OUT")" \
  test "$(numbers "$OUT")" = "1,2,3"
```

- [ ] **Step 2: Run it and see it fail**

Run: `bash tests/run-backlog-milestone-tests.sh`
Expected: exit 1; the two `fetched:` assertions fail, every other assertion passes
(the row assertion on the full page already passes, rows come from the unchanged
filter).

- [ ] **Step 3: Commit** (`git add` the test file first)

`git commit -m "test(milestone): cover the Forgejo triage truncation guard (#663)"`

### Task 2: Print the fetched count and document the guard

**Files:** `commands/milestone.md`

- [ ] **Step 1: Change the Python fence.** In the Forgejo Phase 1 fence, replace

```python
import sys, json
rows = []
for i in json.load(sys.stdin):
```

with

```python
import sys, json
issues = json.load(sys.stdin)
print("fetched:", len(issues), "of at most 100")
rows = []
for i in issues:
```

`for i in json.load(sys.stdin):` must occur exactly once in the Forgejo `triage`
section: check with `grep -n 'for i in json.load' commands/milestone.md` and edit
by the exact surrounding text, so no other fence changes.

- [ ] **Step 2: Change the prose** directly before `**Phase 2` in the Forgejo
`triage` section. Replace

```markdown
Print the count with the list, and show for each row whether it sits in
`backlog` or has `no milestone`. If nothing came back, say there is nothing to
triage and **stop. Do not enter the walk.**
```

with

```markdown
Print the count with the list, and show for each row whether it sits in
`backlog` or has `no milestone`. **Truncation guard:** the fetch caps at 100
open issues, and the filter runs over that page alone — so read the `fetched:`
line, not the number of rows. If it says 100, say the list may be incomplete
rather than implying it is everything, even when the filter left few rows or
none. If no rows came back, say there is nothing to triage and **stop. Do not
enter the walk.**
```

The GitHub section's copy of the old sentence was already replaced in #656, so the
old text occurs only in the Forgejo section; confirm with `grep -c` before editing.

- [ ] **Step 3: Run the tests**

Run: `bash tests/run-backlog-milestone-tests.sh`
Expected: exit 0, all assertions pass, including the three added in Task 1.

- [ ] **Step 4: Commit**

`git commit -m "fix(milestone): warn when Forgejo triage hits its 100-issue cap (#663)"`

### Task 3: Verify the logic, the whole suite and lint

- [ ] **Step 1: Execute the fence on a full page by hand** (not a grep):

```bash
jq -n '[range(1;101) | {number:., title:"t", labels:[], milestone:{title:"v1"}}]' \
  | python3 -c "$(awk '/^tea api .*type=issues&limit=100/{f=1} f&&/python3 -c/{g=1;next} g&&/^.$/{exit} g{print}' commands/milestone.md | sed "s/^'//")"
```

Expected first line `fetched: 100 of at most 100`, then `to triage: 0`. If the awk
extraction proves fiddly, run the same Python body from the edited fence directly;
the point is that a 100-row input prints the cap line and zero rows.

- [ ] **Step 2: Run every layer-1 suite.**

Run: `bash tests/run-script-tests.sh` and `bash tests/run-backlog-milestone-guard-tests.sh`
Expected: exit 0.

- [ ] **Step 3: Lint.**

Run: `shellcheck -x -e SC1091 tests/run-backlog-milestone-tests.sh` and
`pre-commit run --files commands/milestone.md tests/run-backlog-milestone-tests.sh`
Expected: both clean.
