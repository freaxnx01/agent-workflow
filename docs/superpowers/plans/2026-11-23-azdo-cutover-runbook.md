# Azure DevOps cutover runbook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write `docs/AZDO-CUTOVER.md`, the ordered runbook for moving a consumer
from GitHub to Azure DevOps as its only forge. Link it from the setup doc and pin
its shape with a doc test.

**Architecture:** one Markdown runbook with ten numbered steps. Each step points
into the existing `AZDO-PIPELINE-SETUP.md` sections rather than copying them. A
Layer-1 doc test checks the structure.

**Tech Stack:** Markdown, Bash (the doc test).

**Spec:** `docs/superpowers/specs/2026-11-23-azdo-cutover-runbook-design.md`

## Global Constraints

- **Headings, exactly and in order:**
  1. `## 1. Preconditions`
  2. `## 2. Back up the GitHub repository`
  3. `## 3. Freeze on GitHub`
  4. `## 4. Last sync, then stop the mirror`
  5. `## 5. Disable the GitHub workflows`
  6. `## 6. Set up Azure DevOps`
  7. `## 7. Migrate the open issues`
  8. `## 8. Verify`
  9. `## 9. Close the GitHub issues and archive`
  10. `## 10. Rollback`
- **Each step section** contains a `- [ ]` checklist and at least one line
  starting `Check:`.
- **Placeholders only:** `<org>`, `<project>`, `<repo>`, `<owner>`, `contoso`.
  - Every `dev.azure.com/` occurrence is followed by `<org>` or `contoso`.
  - Every `github.com/` occurrence is followed by `<owner>` or `freaxnx01/agent-workflow`.
- **The mirror warning** contains the words `Never` and `git push --mirror`.
- **The link** from `docs/AZDO-PIPELINE-SETUP.md` reads `[cutover runbook](AZDO-CUTOVER.md)`
  and is placed in the doc's opening paragraph.

## Review Focus

- **Step 2's commands must run as written** once the placeholders are filled.
  Order matters: the `refs/pull/*` fetch line goes before the bundle. Task 1's
  test checks that `git bundle create` comes after `refs/pull`.
- **Step 9 must not depend on `--close` closing skipped issues.** It uses the
  marker-based `gh` loop. Task 1's test checks that `awf-migrated-to:` appears
  in step 9.
- **The archive must come after the migration write-back.** The heading order
  enforces it, and the test checks the order.
- **No real names:** the placeholder checks.
- **A future section 15 in the setup doc:** step 6 says "sections 1–14" and
  names each one, so drift is visible. No test.

---

### Task 1: The runbook, the link, and the doc test

**Files:**
- Create: `docs/AZDO-CUTOVER.md`
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (opening paragraph: add the link)
- Create: `tests/run-azdo-cutover-doc-tests.sh` (mode 0755, in the style of `tests/run-enrich-cost-rules-doc-tests.sh`)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Added`)

**Interfaces:**
- Consumes: the step content in the spec's "Design: ten steps".
- Produces: the doc at the path above.

- [ ] **Step 1: Write the failing test**

```bash
# cutover_doc_Exists: [[ -f docs/AZDO-CUTOVER.md ]]
# cutover_doc_HeadingsInOrder: grep -n '^## [0-9]*\. ' output equals the ten Global-Constraint headings, in order
# cutover_doc_EveryStepHasChecklistAndCheck: for each of the ten sections, '^- \[ \]' and '^Check:' both match
# cutover_doc_MirrorWarning: section 4 contains 'Never' and 'git push --mirror'
# cutover_doc_BackupOrder: in section 2, the line number of 'refs/pull' < that of 'git bundle create'; 'admin:org' present
# cutover_doc_Step9UsesMarker: section 9 contains 'awf-migrated-to:' and 'gh issue close'
# cutover_doc_MigrateFlags: section 7 contains '--dry-run' and '--area'; does not contain '--close'
# cutover_doc_PlaceholdersOnly: every 'dev.azure.com/' is followed by '<org>' or 'contoso';
#   every 'github.com/' by '<owner>' or 'freaxnx01/agent-workflow'
# cutover_doc_LinkedFromSetup: docs/AZDO-PIPELINE-SETUP.md contains '[cutover runbook](AZDO-CUTOVER.md)'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run-azdo-cutover-doc-tests.sh`
Expected: FAIL, because the doc does not exist yet.

- [ ] **Step 3: Write `docs/AZDO-CUTOVER.md` from the spec's ten steps, and add the link**

Open the doc with a two-sentence purpose. Add a line stating that the GitHub
repository stays as a read-only archive.

Give step 2's commands as one fenced bash block with placeholders. Give step 9's
close loop as one fenced block.

- [ ] **Step 4: Run the full suite and lint**

Run: `bash tests/run-azdo-cutover-doc-tests.sh && just test`, then `git add` and `pre-commit run --all-files`
Expected: `0 failed` everywhere, and markdownlint passes.

- [ ] **Step 5: Commit**

```bash
git add docs/AZDO-CUTOVER.md docs/AZDO-PIPELINE-SETUP.md tests/run-azdo-cutover-doc-tests.sh CHANGELOG.md
git commit -m "docs(azdo): cutover runbook from GitHub to Azure DevOps (#643)"
```
