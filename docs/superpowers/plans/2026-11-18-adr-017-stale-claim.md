# Reword the stale "pipeline is GitHub-only" claim Implementation Plan (#616)

**Goal:** Make `new.md`, `route.md`, `work.md` and `enrich.md` agree with ADR-017
as amended 2026-11-02, with a grep guard against the stale phrases.

**Architecture:** Markdown edits plus one test block. No script changes.

**Spec:** `docs/superpowers/specs/2026-11-18-adr-017-stale-claim-design.md`

## Global Constraints

- Touch only `commands/new.md`, `commands/route.md`, `commands/work.md`,
  `commands/enrich.md` and `tests/run-script-tests.sh`.
- Keep the ADR-017 citation in each file. Do not touch `docs/DECISIONS.md`,
  `commands/queue.md`, or `enrich.md:58`.
- Do not touch the `enrich.md` Azure DevOps code block (`:940-960`, #499/#500).
- Plain ASCII in added text.
- Line numbers are from `main` at `a1e850f`; locate by the quoted text, not the number.

### Task 1: Failing guard test

**Files:**
- Modify: `tests/run-script-tests.sh` (insert directly before the line `# --- summary ---` that follows the `ADR-017` assertion near `:5019`)

- [ ] **Step 1: Write the failing test**

```bash
# The "pipeline is GitHub-only" claim went stale with the ADR-017 amendment (#573, #616).
for f in new.md route.md work.md enrich.md; do
  assert_equals "$(grep -cE 'GitHub-only \(ADR-017\)|no pipeline dispatch on this forge|nothing on this forge dispatches|nothing here picks the item up|There is no .ai-implement. here' "$ROOT/commands/$f" || true)" "0" \
    "$f no longer says the pipeline is GitHub-only on Azure DevOps"
  assert_equals "$([[ "$(grep -c 'ADR-017' "$ROOT/commands/$f")" -ge 1 ]] && echo yes || echo no)" "yes" \
    "$f still cites ADR-017"
done
```

- [ ] **Step 2: Run, expect failure**

Run: `bash tests/run-script-tests.sh 2>&1 | tail -15`
Expected: four FAILs "no longer says the pipeline is GitHub-only" (route.md's phrase is split over two lines, so it matches on `GitHub-only (ADR-017)` at the start of line 219; confirm all four fail, adjust the regex if route.md does not).

### Task 2: Reword `new.md`

**Files:**
- Modify: `commands/new.md` (the "Do not apply `needs-enrichment`." paragraph in the Azure DevOps section)

- [ ] **Step 1: Replace the paragraph**

Old:

```
**Do not apply `needs-enrichment`.** That tag exists to gate GitHub's
`/gh:implement`, and there is no pipeline dispatch on this forge (ADR-017), so it
would signal a readiness state nothing here acts on.
```

New:

```
**Do not apply `needs-enrichment`.** That tag exists to gate GitHub's
`/gh:implement`. On this forge the dispatch trigger is the `ai-implement` tag
(ADR-017, amended 2026-11-02) and nothing reads `needs-enrichment`, so it would
signal a readiness state nothing here acts on.
```

### Task 3: Reword `route.md`

**Files:**
- Modify: `commands/route.md` (the first bullet of the Azure DevOps "Two differences in the inputs" list)

- [ ] **Step 1: Replace the bullet**

Old:

```
- **There is no `ai-implement` dispatch here.** agent-workflow's pipeline is
  GitHub-only (ADR-017), so the "hand it to the pipeline" route is unavailable.
  Recommend local execution instead, and say why rather than silently dropping
  the option.
```

New:

```
- **`ai-implement` dispatch depends on the Azure Pipeline being installed.**
  Tagging a work item `ai-implement` dispatches agent-workflow's pipeline where
  that pipeline is set up (ADR-017, amended 2026-11-02; setup in
  `docs/AZDO-PIPELINE-SETUP.md`). You cannot tell from here whether this project
  has it, so offer the "hand it to the pipeline" route for an enriched item as
  conditional on that, and recommend local execution otherwise. Say why rather
  than silently dropping either option. Do not apply the tag before I confirm.
```

### Task 4: Reword `work.md`

**Files:**
- Modify: `commands/work.md` (the "No pipeline dispatch." bullet in the Azure DevOps section)

- [ ] **Step 1: Replace the bullet**

Old:

```
- **No pipeline dispatch.** agent-workflow's pipeline is GitHub-only (ADR-017),
  so there is no `ai-implement` label to apply and no draft PR to wait on.
  `/enrich` can now write acceptance criteria and plan pointers onto the work
  item (ADR-017), but nothing here picks the item up afterwards, so this
  command's Azure DevOps path stays local execution only.
```

New:

```
- **No pipeline dispatch from this command.** It never applies `ai-implement`
  and has no draft PR to wait on, so its Azure DevOps path is local execution
  only. `/enrich` writes acceptance criteria and plan pointers onto the work item
  (ADR-017); where the Azure Pipeline is installed, tagging the item
  `ai-implement` dispatches it separately (ADR-017, amended 2026-11-02). That is
  a step for the user, not for this command.
```

### Task 5: Reword `enrich.md`

**Files:**
- Modify: `commands/enrich.md` (the two paragraphs after the Azure DevOps write block, starting "**Release the lock** with `azdo_remove_tag`")

- [ ] **Step 1: Replace the two paragraphs**

Old:

```
**Release the lock** with `azdo_remove_tag "$ISSUE" enrichment-ongoing`. The
lock comment stays as an audit trail. There is no readiness tag to clear — per
ADR-017 nothing on this forge dispatches, so `/new` never applies one.

**Do not claim the item is dispatchable.** There is no `ai-implement` here;
report the paths and stop.
```

New:

```
**Release the lock** with `azdo_remove_tag "$ISSUE" enrichment-ongoing`. The
lock comment stays as an audit trail. There is no readiness tag to clear — on
this forge the dispatch trigger is the `ai-implement` tag and nothing reads a
readiness tag, so `/new` never applies one (ADR-017).

**Do not apply `ai-implement`, and do not claim the item was dispatched.**
Where the Azure Pipeline is installed an enriched item is dispatchable
(ADR-017, amended 2026-11-02): report the paths, say the user can tag it
`ai-implement` to dispatch it, and stop.
```

### Task 6: Verify

- [ ] **Step 1:** `bash tests/run-script-tests.sh 2>&1 | tail -15` — all pass, including the eight new assertions.
- [ ] **Step 2:** `grep -n "GitHub-only" commands/enrich.md` shows only the `Headless mode is GitHub-only in v1` line.
- [ ] **Step 3:** `git diff --stat` lists only the five files from Global Constraints.
- [ ] **Step 4:** Commit: `docs(commands): reword the stale GitHub-only pipeline claim to match ADR-017 (#616)`
