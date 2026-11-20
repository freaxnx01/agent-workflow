# ADO turn budget from the plan file Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Size an Azure DevOps `ai-implement` run's turn budget from the plan
file the work item points to, instead of always falling back to the unplanned
default.

**Architecture:**
- A small library function extracts the plan path from the work item's HTML.
- `classify_issue` reads that file from `HEAD` and injects it as the
  `ISSUE_BODY` of the `classify-turns.sh` call only.

**Tech Stack:** Bash 5, git, the existing Layer-1 harnesses.

**Spec:** `docs/superpowers/specs/2026-11-20-azdo-turn-budget-from-plan-file-design.md`

## Global Constraints

- **Pointer regex:** `docs/[A-Za-z0-9._/-]*plans/[A-Za-z0-9._/-]*\.md`, first
  match wins.
- **Rejected paths:** any containing `..`, and any starting with `/`.
- **Source:** the plan is read with `git show "HEAD:<path>"` only. The working
  tree and the filesystem are never read.
- **Injected body:**
  `<title>` + newline + `## Implementation Plan` + newline + `<plan content>`.
  It is passed only to the `classify-turns.sh` invocation.
- **Fallback suffixes on the `turns :` line:**
  - ` (unplanned default: no plan pointer)`
  - ` (unplanned default: <path> not in checkout)`
- **Public repo:** no work-organization names in fixtures. Use `contoso`.

## Review Focus

- **Two plan pointers in one body:** the first one wins. Task 1 tests this.
- **A pointer inside HTML entities or tags:** `<code>docs/x/plans/a.md</code>`
  and `&lt;code&gt;` neighbours must still extract the bare path. Task 1 tests
  this.
- **A plan file whose code blocks contain `### Task` examples:** this is
  existing GitHub behaviour (they count), and it stays unchanged. No new test.
- **A title containing `## Implementation Plan`:** irrelevant, since the
  injected body adds the heading itself. No test.
- **A `turns:N` tag together with a pointer:** the tag wins. Task 2 tests this.

---

### Task 1: `scripts/lib/azdo-plan-pointer.sh`

**Files:**
- Create: `scripts/lib/azdo-plan-pointer.sh`
- Create: `tests/run-azdo-plan-pointer-tests.sh`

**Interfaces:**
- Produces: `azdo_plan_pointer <body>`. It prints the path and returns 0, or
  prints nothing and returns 1.

- [ ] **Step 1: Write the failing tests**

```bash
# azdo_plan_pointer_ExtractsFromCodeTag:
#   '<li><code>docs/superpowers/plans/2026-01-01-x.md</code></li>' → docs/superpowers/plans/2026-01-01-x.md, rc 0
# azdo_plan_pointer_SkipsSpecPath:
#   body with specs/…-design.md before plans/….md → the plans/ path
# azdo_plan_pointer_FirstOfTwo: two plans/ paths → the first
# azdo_plan_pointer_None: body without a plans/ path → empty, rc 1
# azdo_plan_pointer_RejectsDotDot: 'docs/../plans/x.md' and 'docs/plans/../../etc/x.md' → rc 1
# azdo_plan_pointer_RejectsAbsolute: '/docs/plans/x.md' as the only match → rc 1
```

Use the prelude, `section` and `assert_*` helpers of
`tests/run-agent-boundary-lib-tests.sh`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-azdo-plan-pointer-tests.sh`
Expected: FAIL, because the library does not exist yet.

- [ ] **Step 3: Implement `azdo_plan_pointer`**

Use `grep -oE` with the Global Constraints regex and take the first match.

For the absolute-path check, look at the character before the match: it must
not be `/`. Simplest: match with an optional leading `/` captured, and reject
the path when it is present.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-azdo-plan-pointer-tests.sh && shellcheck -x -e SC1091 scripts/lib/azdo-plan-pointer.sh tests/run-azdo-plan-pointer-tests.sh`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/azdo-plan-pointer.sh tests/run-azdo-plan-pointer-tests.sh
git commit -m "feat(azdo): extract the plan pointer from an enriched work item (#651)"
```

### Task 2: Size from the plan in `classify_issue`, amend ADR-017

**Files:**
- Modify: `scripts/implement-azdo.sh` (source the lib next to `lib/azdo.sh`; `classify_issue`)
- Modify: `tests/run-implement-azdo-tests.sh`
- Modify: `docs/DECISIONS.md` (ADR-017: a new `**Amendment (2026-11-20, #651).**` paragraph after the 2026-11-02 one)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Fixed`)

**Interfaces:**
- Consumes: `azdo_plan_pointer` from Task 1, and the globals `ISSUE_BODY`,
  `ISSUE_JSON` and `ISSUE_LABELS` from `forge_export_issue`.
- Produces: `TURNS_BUDGET` sized from the plan file, and the `turns :` log line
  with the fallback suffix.

- [ ] **Step 1: Write the failing tests**

In `tests/run-implement-azdo-tests.sh`, call `classify_issue` directly (sourcing
pattern as in the `report_metrics_line` cases around line 351). Set up:
- a temp git repo as `cwd`, with a committed fixture plan
  `docs/superpowers/plans/p.md`;
- `ISSUE_LABELS=''` and `WORK_DIR`;
- `ISSUE_BODY` = title + HTML containing
  `<code>docs/superpowers/plans/p.md</code>`.

```bash
# classify_issue_SizesFromPlanFile: the fixture has 1 task (`## Task 1:`) → TURNS_BUDGET equals what
#   classify-turns.sh returns for an inlined 1-task plan (compute it in the test by calling
#   classify-turns.sh with ISSUE_BODY=$'t\n## Implementation Plan\n## Task 1: x', not a hard-coded number)
# classify_issue_LargePlan: a 6-task fixture → the 6-task tier, which differs from the 1-task tier
# classify_issue_NoPointer: no plans/ path → TURNS_BUDGET == UNPLANNED (120);
#   output contains "(unplanned default: no plan pointer)"
# classify_issue_MissingFile: a pointer to an uncommitted path → 120;
#   output contains "(unplanned default: docs/superpowers/plans/missing.md not in checkout)"
# classify_issue_UncommittedFileIgnored: the file exists in the working tree but not at HEAD → the "not in checkout" fallback
# classify_issue_TagWins: ISSUE_LABELS='turns:50' + a 6-task pointer → 50
# classify_issue_LeavesBodyAlone: ISSUE_BODY after the call is byte-identical to before
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-implement-azdo-tests.sh`
Expected: the new cases FAIL, and the existing cases pass.

- [ ] **Step 3: Implement**

In `classify_issue`:
- Compute the plan body with a small helper
  `plan_body_for_classify() -> prints the injected body, rc 1 + sets PLAN_FALLBACK_REASON`.
- Run `classify-turns.sh` with `ISSUE_BODY=<that>` as a command-scoped
  assignment.
- Append the suffix to the `turns :` printf when falling back.

Leave `classify-agent.sh` as it is. Write the ADR-017 amendment in the voice of
the 2026-11-02 one: the pipeline sizes the budget from the pointed-to plan file,
the decision stands, and the plan stays out of the HTML field.

- [ ] **Step 4: Run the full suite and lint**

Run: `just test` and `pre-commit run --all-files` (after `git add`)
Expected: all runners report `0 failed`, and pre-commit passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh docs/DECISIONS.md CHANGELOG.md
git commit -m "fix(azdo): size the turn budget from the plan file the work item points to (#651)"
```
