# Migrate a consumer's open GitHub issues to Azure DevOps work items (#642)

## Intent

A consumer that moves from the GitHub pipeline to the Azure DevOps path needs its
**open** GitHub issues as work items, so the backlog lives on the forge the team
works on. No tool for this exists. The first consumer has 31 open issues:
- 2 enriched, with the plan inlined in the body;
- 16 carrying `needs-enrichment`;
- 12 with comments, 19 comments in all;
- no image attachments;
- bodies of up to 37 KB.

The run happens once per consumer, on the cutover day (#643). It must be safe to
re-run after a partial failure.

## Goals

- Every open issue becomes one work item. The body is preserved verbatim, the
  comments follow, and the labels become tags.
- Every migrated GitHub issue carries a link to its work item, and a re-run
  skips it.
- `--dry-run` shows exactly what would be created, and writes nothing.

## Non-goals

- Closed issues, pull requests, milestones, assignees, reactions and project
  boards.
- Rewriting `/enrich` for Markdown work items, which is #683.
- Committing plans into the consumer repository.

## Anti-goals

- Losing content: no Markdown→HTML conversion and no truncation.
- Carrying pipeline state across forges: `ai:*`, `agent:*`, `ai-implement`, the
  review/merge and chain gates, `enrichment-ongoing`, `ctx:*` and `turns:*`
  would trigger, pin or confuse the ADO pipeline.
- A second work item for an issue that was already migrated.

## Approaches

The body format was decided after a live probe on the sandbox. The work item API
accepts `{"op":"add","path":"/multilineFieldsFormat/System.Description","value":"Markdown"}`,
and stores the Markdown verbatim. The comments API takes `?format=markdown`.

1. **Markdown-format work items (chosen).** The body and comments are lossless,
   and no converter is needed: neither `pandoc` nor `python-markdown` is on the
   host. The cost is that `/enrich` on ADO writes HTML today, and that HTML would
   be stored as raw text in a Markdown item. #683 fixes that, and the
   `needs-enrichment` items are enriched only after it.
2. **HTML through a small in-house Markdown→HTML converter.** This matches
   today's `/enrich`, but it is lossy, and the converter would need maintaining.
   Rejected.
3. **HTML with the body in a `<pre>` block.** Lossless and trivial, but
   unreadable on the board. Rejected.

## Decided (by the user, 2026-11-23)

- **Format:** the description and comments are written as Markdown.
- **Comments:** each GitHub comment becomes a work item comment, in order. It
  starts with the header line `**<login>** on GitHub, <YYYY-MM-DD>:` followed by
  a blank line and the comment body verbatim.
- **Enriched issues:** the body is carried verbatim, plan included. Nothing is
  committed to the consumer repository. #683 re-decides whether a Markdown item
  keeps an inlined plan.
- **The GitHub issue:** by default it gets one comment linking the work item and
  stays open. `--close` also closes it.
- **Type:** an issue labelled `bug` becomes a `Bug`, everything else a
  `User Story`. `--type <name>` overrides this for all issues.

## Design

**Entry point:** `scripts/migrate-gh-issues-to-azdo.sh`, run by an operator from a
checkout of the consumer repository, which has an ADO `origin` or
`--org/--project`.

**Inputs:**
- `--repo <owner/name>` (required): the GitHub source.
- `--area <path>` (required): the area path the ADO service-hook guard needs.
- `--type <name>`, `--close` and `--dry-run` (optional).
- `--limit <n>` (optional): migrates the first n issues only, for a trial.

**Auth:** `gh` reads GitHub with its own login. ADO writes use
`AZURE_DEVOPS_EXT_PAT` through `scripts/lib/azdo.sh`'s existing curl pattern
(`-K -`, never in argv).

**Per issue, oldest first:**

1. **Skip if migrated.** If an issue comment contains the marker
   `<!-- awf-migrated-to: <org url>/<project>/_workitems/edit/<id> -->`, the issue
   is reported as `skip #N (already work item <id>)`.
2. **Create the work item:** one `POST …/_apis/wit/workitems/$<type>?api-version=7.1`
   with these fields:
   - `System.Title` = the issue title;
   - `System.AreaPath` = `--area`;
   - `System.Description` = the body plus a trailing line
     `_Migrated from <issue url>._`;
   - `/multilineFieldsFormat/System.Description` = `Markdown`;
   - `System.Tags` = the mapped labels joined with `; `;
   - `Microsoft.VSTS.Common.Priority` is not set.
3. **Copy the comments** in order, each with
   `POST …/workItems/<id>/comments?format=markdown&api-version=7.1-preview.4`.
4. **Write back to GitHub:** one comment
   `Migrated to Azure DevOps work item [#<id>](<url>).` followed by the marker.
   With `--close`, also `gh issue close`.

**Label → tag:**
- `bug` stays a tag and also selects the type.
- Every other label is kept as a tag, `needs-enrichment` and `roadmap` included.
- Dropped: `ai-implement`, the gates `ai-review-ai-merge`,
  `ai-review-human-merge`, `ai-chain` and the deprecated spellings
  `ai-auto-review` and `ai-pre-preview`, `enrichment-ongoing`, and anything
  matching `ai:*`, `agent:*`, `ctx:*` or `turns:*`.
- A tag containing `;` has it replaced by `,`.

**Failure:** stop at the first failed write and print which issue and step
failed. Where it applies, also print the work item id that was already created.
- A work item without its GitHub write-back is **not** marked as migrated. A
  re-run would create a second item, so the script prints the orphan id and
  tells the operator to delete it or add the marker by hand. That is preferable
  to guessing.
- Exit codes:
  - `0` — done, including a dry run;
  - `1` — a write failed;
  - `2` — a usage error.

**Dry run:** reads everything, and per issue prints the title, the type, the
tags, the number of comments and the body size. It writes nothing on either
forge.

## Settled after the builder check (author's calls)

- **Marker:** the format is `<!-- awf-migrated-to: <org url>/<project, percent-encoded>#<id> -->`.
  - The skip check matches the prefix **and** the same org and project.
  - An issue migrated to a different project is not skipped.
  - Comments are read with `gh api --paginate repos/<repo>/issues/<n>/comments`,
    not with the capped `gh issue view`.
- **Partial failure after create**, in either step 3 (comments) or step 4
  (write-back), is an orphan:
  - the run stops;
  - it prints `orphan work item <id> for #<n>: delete it, or add the marker to the issue by hand`;
  - it exits 1.

  There is no resume mode. The run is one-off and small, and an honest stop is
  easier to recover from than a half-resume.
- **Validation up front,** in both real and dry runs, before any issue is read:
  - The types must exist, checked with `azdo_work_item_types`. The defaults
    stay `Bug` / `User Story`, and `--bug-type` / `--story-type` override
    them, since a Basic process has `Issue`.
  - The area must exist, checked with `azdo_areas`.

  A failure exits 2. A dry run therefore needs the PAT for these **reads**, but
  never writes.
- **Comment header:** `**<login>** on GitHub, <createdAt as UTC YYYY-MM-DD>:`.
  A null author (a deleted account) becomes `ghost`, as on GitHub.
- **New `azdo.sh` helpers:** both are new, not reuses.
  - `azdo_create_markdown_item <type> <json-fields-file>` uses the
    project-scoped URL `<org url>/<project>/_apis/wit/workitems/$<type>`, with
    the project percent-encoded.
  - `azdo_comment_markdown <id> <text>` uses the comments REST API
    (`?format=markdown`), not `az boards --discussion`.
  - Both use the existing curl `-K -` pattern.
- **Test seams:**
  - The GitHub write-back uses `gh issue comment --body-file`, so
    `GH_MOCK_BODY_LOG` captures it.
  - The PAT check asserts on argv only (the curl mock's log), which is the
    guarantee: `-K -` stdin is the intended carrier.

## Tests (Layer 1)

All tests use mocks: `tests/mocks/gh` (issues, comments, close) and
`tests/mocks/curl` (create, comment). Cases:
- a plain issue;
- a bug;
- the label filter;
- a `;` in a label;
- Markdown fidelity, with a fenced block, a task list and a 37 KB body passed
  byte-identically;
- comments in order with the header;
- the GitHub write-back with the marker;
- `--close`;
- the skip on re-run;
- a failure after create, which prints the orphan id and exits 1;
- `--dry-run` making no write calls;
- `--limit`;
- no PAT in any argv.

## Acceptance criteria

- [ ] Every open issue (not PRs, not closed) becomes one Markdown-format work
      item with the body verbatim, plus the migrated-from line.
- [ ] Comments are copied in order as Markdown comments with the author/date
      header.
- [ ] Labels map to tags with pipeline-state labels dropped. `bug` → `Bug`,
      otherwise `User Story`, and `--type` overrides.
- [ ] `--area` is set on every item, and the script refuses to run without it.
- [ ] Each migrated GitHub issue gets a link comment with the marker. `--close`
      closes it.
- [ ] A re-run skips issues that carry the marker.
- [ ] `--dry-run` writes nothing, and reports per issue.
- [ ] A failed write stops the run and names the issue, the step and any orphan
      work item id.
- [ ] The PAT never appears in argv, and the tests prove it.
- [ ] No work-organization, repo or host names in code, tests or docs. Use
      `contoso` / `<org>`.

## Left to the builder

- Whether the script sources `scripts/lib/azdo.sh` or adds two helpers there.
  The helpers would be `azdo_create_markdown_item` and `azdo_comment_markdown`.
  Adding them to the library is preferred, so #683 can reuse them.
- The JSON building: `python3` is what `azdo.sh` already uses.
- Pagination of `gh issue list`: use `--limit 1000` or `gh api --paginate`.
