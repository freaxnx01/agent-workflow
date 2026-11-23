# Azure DevOps: Markdown work items carry the plan inline (#683)

## Intent

ADR-017 kept the implementation plan out of the work item because
`System.Description` was HTML-only. That premise is gone. The work item API takes
`{"op":"add","path":"/multilineFieldsFormat/System.Description","value":"Markdown"}`
and stores Markdown verbatim, as probed on the sandbox on 2026-11-23. #642
creates Markdown-format items.

Today `/enrich` on ADO writes HTML through `azdo_set_description`. In a Markdown
item that HTML is stored as raw text, and the format cannot be patched back
without a value. Sixteen migrated items wait for enrichment.

## Decided (by the user, 2026-11-23)

- **A Markdown item gets the plan inline, exactly like a GitHub issue body:**
  1. the original description;
  2. `## Acceptance Criteria`;
  3. `## Implementation Plan` (the full plan);
  4. `## Spec` (a link).

  ADR-017 stays in force for HTML items only, which keep AC + pointers.
- **`/new` on ADO creates Markdown items.**

## Goals

- `/enrich` detects the item's description format and writes the matching body.
- The driver sizes the turn budget from an inlined plan, with no misleading
  fallback line.
- New items are Markdown from creation.

## Non-goals

- Converting existing HTML items to Markdown.
- Any change on the GitHub or Forgejo paths.
- The ADO readiness tag question (`needs-enrichment` on ADO). That is a
  separate issue if wanted.

## Approaches

1. **Detect the format per item and branch (chosen).** It works for mixed
   boards, where old HTML items sit next to new and migrated Markdown items.
2. **Force every item to Markdown on first enrich.** Rejected: an HTML
   description written as Markdown renders as raw tags, and converting HTML to
   Markdown needs a converter the host does not have.

## Design

- **`scripts/lib/azdo.sh`:**
  - **`azdo_description_format <id>`:** prints `markdown` or `html`. It reads
    `GET <org url>/<project>/_apis/wit/workitems/<id>?api-version=7.1` with
    curl (`-K -`), and takes `multilineFieldsFormat["System.Description"]`
    case-insensitively. When the key is absent, it prints `html`, which is what
    the API means by absent. On a read failure it returns 1 and prints nothing.
  - **`azdo_set_markdown_description <id> <file>`:** replaces
    `System.Description` with the file's content, and includes the
    `/multilineFieldsFormat/System.Description` = `Markdown` op in the same
    patch. It prints the stored description, like `azdo_set_description` does.
  - **Reuse from #642:** `azdo_create_markdown_item` (create) and
    `azdo_project_url_path`.
- **`commands/enrich.md`, Azure DevOps section:**
  1. After acquiring the lock, read `fmt=$(azdo_description_format "$ISSUE")`.
     A failure stops the run and releases the lock.
  2. **`markdown`:** compose the body exactly as the GitHub Step 6 does (original
     description, `## Acceptance Criteria`, `## Implementation Plan` with the
     full plan verbatim, `## Spec` link). Write it with
     `azdo_set_markdown_description`. Assert that the read-back contains the
     three headings.
  3. **`html`:** today's path, unchanged.
  4. The "ADR-017" sentence at the top of the section names both cases.
  - **Size:** ADO long-text fields hold far more than GitHub's 65,536
    characters. No elision is needed below 1,000,000 characters. Above that,
    stop and say so.
- **`commands/new.md`, Azure DevOps section:** create the item with
  `azdo_create_markdown_item`. It takes the type, title, area
  `$AZDO_PROJECT\$AZDO_REPO`, tags and a body file. This replaces the
  `az boards work-item create … System.Description=<body>` call.
- **`scripts/implement-azdo.sh` `classify_issue` (#651 follow-up):**
  - When no plan pointer is found but `ISSUE_BODY` already contains a line
    `## Implementation Plan`, run `classify-turns.sh` on the body as it is.
    `ISSUE_BODY` is exported by `forge_export_issue`.
  - Print **no** fallback suffix in that case.
  - The suffix ` (unplanned default: no plan pointer)` stays for a body with
    neither a pointer nor an inlined plan.
  - A pointer still wins when both exist. The file is the committed source of
    truth.
- **`docs/DECISIONS.md`:** a new **ADR-025**, "A Markdown work item carries the
  plan inline (2026-11-23)":
  - context: the probe, and #642;
  - decision: as above;
  - consequences: parity with GitHub, HTML items unchanged, #651 as the HTML
    fallback.

  ADR-017 gets an amendment line naming ADR-025 as superseding it for Markdown
  items.

## Tests (Layer 1)

- **`tests/run-azdo-lib-tests.sh`:**
  - `azdo_description_format_Markdown`: the curl mock returns
    `{"multilineFieldsFormat":{"System.Description":"markdown"}}` → `markdown`.
  - `…_AbsentIsHtml` → `html`.
  - `…_ReadFails` → rc 1.
  - `azdo_set_markdown_description_SetsFormatOp`: the logged patch contains the
    `/multilineFieldsFormat/System.Description` op and the file content
    byte-identical.
  - The PAT is not in argv.
- **`tests/run-implement-azdo-tests.sh`:**
  - `classify_issue_InlinePlanNoPointer`: the body has
    `## Implementation Plan` + 6 `## Task` headings and no pointer → the
    6-task tier, and the output has no `unplanned default`.
  - `classify_issue_PointerWinsOverInline`: a pointer to a 1-task file plus a
    6-task inline plan → the 1-task tier.
- **A doc test, `tests/run-azdo-markdown-doc-tests.sh`:**
  - `commands/enrich.md`'s ADO section names `azdo_description_format`,
    `azdo_set_markdown_description` and `## Implementation Plan`, and still
    names `azdo_set_description` for the HTML branch.
  - `commands/new.md`'s ADO section uses `azdo_create_markdown_item`, and no
    longer contains `System.Description=<body>`.
  - `docs/DECISIONS.md` has `## ADR-025`.

## Acceptance criteria

- [ ] `azdo_description_format` returns `markdown` / `html` from the REST
      response, `html` when the key is absent, and rc 1 on a read failure.
- [ ] `azdo_set_markdown_description` writes the body verbatim and keeps the
      Markdown format.
- [ ] `/enrich` on a Markdown item writes the GitHub-shaped body with the plan
      inlined. On an HTML item it behaves as before.
- [ ] `/new` on ADO creates Markdown items.
- [ ] A Markdown item with an inlined plan and no pointer is sized from the
      inlined plan, with no fallback suffix. A pointer still wins.
- [ ] ADR-025 is recorded, and ADR-017 is amended to point at it.
- [ ] No PAT in argv. No work-organization names.

## Dependencies

This needs #642 merged, for `azdo_create_markdown_item` and
`azdo_project_url_path`. Dispatch it after #642.
