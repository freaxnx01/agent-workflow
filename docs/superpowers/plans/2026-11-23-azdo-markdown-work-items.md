# Markdown work items carry the plan inline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Azure DevOps, `/enrich` writes the GitHub-shaped body, with the plan
inlined, into Markdown-format work items. `/new` creates Markdown items. The
driver sizes the budget from an inlined plan.

**Architecture:**
- Two `azdo.sh` helpers: read the description format, and write a Markdown
  description.
- The `/enrich` and `/new` ADO sections branch on the format.
- `classify_issue` accepts an inlined plan when there is no pointer.
- ADR-025 records the decision.

**Tech Stack:** Bash 5, curl (REST, PAT via `-K -`), `python3` for JSON, and
Markdown command docs.

**Spec:** `docs/superpowers/specs/2026-11-23-azdo-markdown-work-items-design.md`

## Global Constraints

- **Format op:** `{"op":"add","path":"/multilineFieldsFormat/System.Description","value":"Markdown"}`.
- **Format read:** `GET <org url>/<project percent-encoded>/_apis/wit/workitems/<id>?api-version=7.1`,
  the key `multilineFieldsFormat["System.Description"]`, compared
  case-insensitively. An absent key means `html`.
- **The GitHub-shaped body** has these headings, exactly:
  - `## Acceptance Criteria`
  - `## Implementation Plan`
  - `## Spec`
- **Size limit:** stop above 1,000,000 characters.
- **The fallback suffix** ` (unplanned default: no plan pointer)` is printed
  only when the body has neither a pointer nor a line `## Implementation Plan`.
- **ADR heading:** `## ADR-025 — A Markdown work item carries the plan inline (2026-11-23)`
- **Reuse from #642:** `azdo_create_markdown_item <type> <title> <area> <tags> <description-file>`
  and `azdo_project_url_path`. Do not re-implement them.
- **Secrets and names:** the PAT appears in no argv. No work-organization names;
  use `contoso`.

## Review Focus

- **An item whose format key reads `Markdown`, not `markdown`:**
  case-insensitive comparison. Task 1 tests this.
- **An HTML item enriched after this change:** the bytes it gets are unchanged
  from today. Task 2's doc test checks that the HTML branch still names
  `azdo_set_description` and `azdo_html_escape`.
- **A body that contains `## Implementation Plan` only inside a fenced code
  block:** this is existing classify-turns behaviour, and it stays unchanged.
  No test.
- **The pointer and the inline plan disagree:** the pointer wins. Task 3 tests
  this.
- **A format read failure mid-enrich:** stop and release the lock, never fall
  through to HTML. Task 2's doc test checks it.

---

### Task 1: `azdo.sh` — read the format, write a Markdown description

**Files:**
- Modify: `scripts/lib/azdo.sh` (two functions, added to the header list)
- Modify: `tests/run-azdo-lib-tests.sh`

**Interfaces:**
- Consumes: `azdo_project_url_path` (#642), `azdo_org_url`, the curl `-K -`
  pattern.
- Produces:
  - `azdo_description_format <id>`: prints `markdown` or `html`. Returns 1 and
    prints nothing on failure.
  - `azdo_set_markdown_description <id> <file>`: prints the stored description.
    Returns 1 on failure.

- [ ] **Step 1: Write the failing tests**

```bash
# azdo_description_format_Markdown: mock body {"fields":{},"multilineFieldsFormat":{"System.Description":"markdown"}} → 'markdown'
# azdo_description_format_CaseInsensitive: "Markdown" → 'markdown'
# azdo_description_format_AbsentIsHtml: {"fields":{}} → 'html'
# azdo_description_format_ReadFails: curl mock exits 22 → rc 1, empty stdout
# azdo_description_format_ProjectScopedUrl: AZDO_PROJECT='Contoso Project' → URL contains 'Contoso%20Project/_apis/wit/workitems/7?api-version=7.1'
# azdo_set_markdown_description_FormatOpAndBody: file with '"', '\', a ```bash fence → logged patch JSON has the format op
#   and json.loads(...) /fields/System.Description value == file bytes
# azdo_markdown_helpers_PatNotInArgv: AZURE_DEVOPS_EXT_PAT=s3cr3t → not in the curl argv log
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-azdo-lib-tests.sh`
Expected: the new cases FAIL.

- [ ] **Step 3: Implement both functions**

They follow `azdo_set_description`'s read-response check: a response without
`fields` is a failure.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-azdo-lib-tests.sh && shellcheck -x -e SC1091 scripts/lib/azdo.sh`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git commit -m "feat(azdo): read and write Markdown work item descriptions (#683)"
```

### Task 2: `/enrich` and `/new` on ADO write Markdown, plus ADR-025

**Files:**
- Modify: `commands/enrich.md` (the `## Azure DevOps` section)
- Modify: `commands/new.md` (the `## Azure DevOps` section, `### Create`)
- Modify: `docs/DECISIONS.md`:
  - a new ADR-025 at the end;
  - a one-line amendment under ADR-017.
- Create: `tests/run-azdo-markdown-doc-tests.sh` (mode 0755, in the style of `tests/run-enrich-cost-rules-doc-tests.sh`)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Changed`)

**Interfaces:**
- Consumes: Task 1's two functions, and `azdo_create_markdown_item` (#642).

- [ ] **Step 1: Write the failing doc test**

```bash
# enrich_ado_ReadsFormat: the ADO section of commands/enrich.md contains 'azdo_description_format'
# enrich_ado_MarkdownBranch: contains 'azdo_set_markdown_description' and '## Implementation Plan'
# enrich_ado_HtmlBranchKept: still contains 'azdo_set_description' and 'azdo_html_escape'
# enrich_ado_FormatFailureStops: contains 'azdo_remove_tag "$ISSUE" enrichment-ongoing' within the format-read paragraph
#   (assert: the line after the format read mentions stopping and releasing the lock)
# new_ado_CreatesMarkdown: the ADO section of commands/new.md contains 'azdo_create_markdown_item' and not 'System.Description=<body>'
# decisions_Adr025: docs/DECISIONS.md has '^## ADR-025 — A Markdown work item carries the plan inline (2026-11-23)'
# decisions_Adr017Amended: the ADR-017 section mentions 'ADR-025'
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-azdo-markdown-doc-tests.sh`
Expected: FAIL.

- [ ] **Step 3: Edit both command docs and write ADR-025**

Write ADR-025 per the spec's Design. Keep the HTML branch of `/enrich`
byte-identical to today, inside a "**HTML item**" subsection.

- [ ] **Step 4: Run the suite and lint**

Run: `bash tests/run-azdo-markdown-doc-tests.sh && just test`, then `git add` and `pre-commit run --all-files`
Expected: `0 failed` everywhere, and pre-commit passes.

- [ ] **Step 5: Commit**

```bash
git add commands/enrich.md commands/new.md docs/DECISIONS.md tests/run-azdo-markdown-doc-tests.sh CHANGELOG.md
git commit -m "feat(azdo): enrich and create Markdown work items with the plan inline (#683)"
```

### Task 3: `classify_issue` sizes from an inlined plan

**Files:**
- Modify: `scripts/implement-azdo.sh` (`classify_issue`, `plan_body_for_classify`)
- Modify: `tests/run-implement-azdo-tests.sh`

**Interfaces:**
- Consumes: the existing `azdo_plan_pointer` and `plan_body_for_classify` from
  #651.
- Produces: unchanged signatures. `PLAN_FALLBACK_REASON` is empty when the body
  carries an inlined plan.

- [ ] **Step 1: Write the failing tests**

```bash
# classify_issue_InlinePlanNoPointer: ISSUE_BODY=title + '## Implementation Plan' + six '## Task N:' headings, no pointer
#   → TURNS_BUDGET equals classify-turns.sh's tier for that same body; output lacks 'unplanned default'
# classify_issue_PointerWinsOverInline: pointer to a committed 1-task file + six inline tasks → the 1-task tier
# classify_issue_NeitherKeepsSuffix: no pointer, no inline plan → output contains '(unplanned default: no plan pointer)'
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-implement-azdo-tests.sh`
Expected: the first case FAILS, and the others pass or fail only on the suffix.

- [ ] **Step 3: Implement**

When there is no pointer and `grep -q '^## Implementation Plan' <<<"$ISSUE_BODY"`
matches, run `classify-turns.sh` with the inherited `ISSUE_BODY` and leave the
suffix empty.

- [ ] **Step 4: Run the full suite**

Run: `just test`
Expected: all runners report `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/implement-azdo.sh tests/run-implement-azdo-tests.sh
git commit -m "fix(azdo): size the budget from a plan inlined in a Markdown work item (#683)"
```
