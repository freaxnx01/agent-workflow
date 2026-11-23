# Migrate open GitHub issues to Azure DevOps work items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `scripts/migrate-gh-issues-to-azdo.sh` moves a consumer's open GitHub
issues to Markdown-format Azure DevOps work items, with their comments, once and
idempotently.

**Architecture:**
- Two new `azdo.sh` helpers do the ADO writes: a Markdown item create and a
  Markdown comment.
- A small sourced library holds the pure mapping logic: labels → tags, type
  choice, marker build and match, and comment headers.
- The entry-point script orchestrates validation, the per-issue steps,
  `--dry-run` and `--limit`.

**Tech Stack:** Bash 5, `gh`, `curl` (REST, PAT via `-K -`), `python3` for JSON,
and the repo's Layer-1 harness with `tests/mocks/{gh,curl}`.

**Spec:** `docs/superpowers/specs/2026-11-23-migrate-gh-issues-to-azdo-design.md`

## Global Constraints

- **Work item format:**
  - The work item create sets
    `{"op":"add","path":"/multilineFieldsFormat/System.Description","value":"Markdown"}`.
  - Comments go to `…/workItems/<id>/comments?format=markdown&api-version=7.1-preview.4`.
- **Description:** the issue body verbatim, then a blank line, then
  `_Migrated from <issue html url>._`
- **Comment header:** `**<login>** on GitHub, <createdAt UTC YYYY-MM-DD>:`, then
  a blank line and the body verbatim. A null author is shown as `ghost`.
- **Marker:** `<!-- awf-migrated-to: <org url>/<project percent-encoded>#<id> -->`.
  The write-back comment is
  `Migrated to Azure DevOps work item [#<id>](<org url>/<project percent-encoded>/_workitems/edit/<id>).`,
  then a newline and the marker.
- **Dropped labels:** `ai-implement`, the gates `ai-review-ai-merge`,
  `ai-review-human-merge` and `ai-chain`, the deprecated `ai-auto-review` and
  `ai-pre-preview`, `enrichment-ongoing`, and every label matching `ai:*`,
  `agent:*`, `ctx:*` or `turns:*`.
  In the remaining labels, `;` is replaced by `,`. They are joined with `; `.
- **Type:** an issue labelled `bug` gets `--bug-type`, default `Bug`. Every other
  issue gets `--story-type`, default `User Story`. `--type` overrides both.
- **Exit codes:**
  - `0` — done, including a dry run;
  - `1` — a write failed, or an orphan was left;
  - `2` — a usage or validation error.
- **Orphan message:**
  `orphan work item <id> for #<n>: delete it, or add the marker to the issue by hand`
- **Secrets:** the PAT appears in no argv, only in curl's `-K -` stdin.
- **Public repo:** no work-organization, repo or host names anywhere. Fixtures
  use `contoso` / `Contoso Project`.

## Review Focus

- **A project name with a space:** `Contoso Project` must be percent-encoded in
  the create URL, the link and the marker. Task 1 and Task 2 test this.
- **A body with `"`, backslashes, a fenced block and a task list:** it must
  arrive byte-identical in the JSON payload. Task 1 tests this.
- **An issue with no comments, and one with more than 100 comments:** paginated
  reads. Task 3 tests this, with a mock serving two pages.
- **A label that is exactly `ai:done` versus `aide`:** only the `ai:` prefix is
  dropped. Task 2 tests this.
- **A marker for another project on the issue:** the issue is not skipped. Task 2
  tests this.

---

### Task 1: `azdo.sh` — Markdown item create and Markdown comment

**Files:**
- Modify: `scripts/lib/azdo.sh` (two new functions, listed in the file header)
- Modify: `tests/run-azdo-lib-tests.sh`

**Interfaces:**
- Consumes: `azdo_org_url`, `AZDO_PROJECT`, `AZURE_DEVOPS_EXT_PAT`, and the
  existing curl `-K -` pattern in `azdo_set_description`.
- Produces:
  - `azdo_create_markdown_item <type> <title> <area> <tags> <description-file>`.
    It prints the new id and returns 0, or returns 1 with stderr on failure.
  - `azdo_comment_markdown <id> <text-file>`: returns 0, or 1 with stderr on
    failure.
  - `azdo_project_url_path`: prints `<org url>/<percent-encoded project>`.

- [ ] **Step 1: Write the failing tests**

```bash
# azdo_create_markdown_item_PostsProjectScopedUrl: AZDO_PROJECT='Contoso Project' →
#   curl log contains 'https://dev.azure.com/contoso/Contoso%20Project/_apis/wit/workitems/$User%20Story?api-version=7.1'
# azdo_create_markdown_item_SetsMarkdownFormat: logged -d body (json) contains the op
#   {"op":"add","path":"/multilineFieldsFormat/System.Description","value":"Markdown"}
# azdo_create_markdown_item_DescriptionByteIdentical: description file with '"', '\', a ```bash fence
#   and '- [ ] x' → json.loads(logged body) value for /fields/System.Description == file content
# azdo_create_markdown_item_PrintsId: curl mock returns {"id":42,...} → stdout '42'
# azdo_create_markdown_item_ApiErrorFails: mock returns {"message":"TF401"} → rc 1, stderr names it
# azdo_comment_markdown_UsesFormatMarkdown: curl log contains '/workItems/42/comments?format=markdown&api-version=7.1-preview.4'
# azdo_writes_PatNotInArgv: AZURE_DEVOPS_EXT_PAT=s3cr3t → ! grep -q s3cr3t "$CURL_LOG"
```

Use the curl mock's existing argv/`-d` logging. Pass `-d` as a separate argv
element so the mock records the body.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-azdo-lib-tests.sh`
Expected: the new cases FAIL, and the existing cases pass.

- [ ] **Step 3: Implement both functions and `azdo_project_url_path`**

- **Percent-encoding:** use
  `python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))'`
  for the project and the type.
- **JSON:** build it in `python3` from the argv strings plus the description
  file read.
- **The patch** has four ops:
  - `/fields/System.Title`;
  - `/fields/System.AreaPath`;
  - `/fields/System.Description`;
  - `/multilineFieldsFormat/System.Description`.

  Add a fifth op, `/fields/System.Tags`, only when tags are non-empty.

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-azdo-lib-tests.sh && shellcheck -x -e SC1091 scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/azdo.sh tests/run-azdo-lib-tests.sh
git commit -m "feat(azdo): create Markdown work items and Markdown comments (#642)"
```

### Task 2: `scripts/lib/gh-issue-migration.sh` — pure mapping helpers

**Files:**
- Create: `scripts/lib/gh-issue-migration.sh`
- Create: `tests/run-gh-issue-migration-lib-tests.sh`

**Interfaces:**
- Consumes: nothing beyond bash and `python3`.
- Produces (all of them print to stdout and have no side effects):
  - `migration_tags <labels-newline-separated>`: the tag string, or empty.
  - `migration_type <labels> <bug-type> <story-type> [override]`: the type name.
  - `migration_marker <project-url-path> <id>`: the marker line.
  - `migration_marker_id <project-url-path> <comments-bodies-file>`: prints the
    id from a matching marker and returns 0, or returns 1.
  - `migration_comment_header <login-or-empty> <createdAt ISO>`: the header
    line.

- [ ] **Step 1: Write the failing tests**

```bash
# migration_tags_DropsPipelineState: $'enhancement\nai-implement\nai:done\nctx:high\nturns:120\nenrichment-ongoing\nai-review-human-merge\nai-pre-preview\nneeds-enrichment'
#   → 'enhancement; needs-enrichment'
# migration_tags_KeepsLookalike: 'aide' → 'aide'
# migration_tags_ReplacesSemicolon: 'a;b' → 'a,b'
# migration_tags_Empty: '' → ''
# migration_type_Bug: $'bug\nx' Bug 'User Story' → 'Bug'
# migration_type_Story: 'enhancement' → 'User Story'
# migration_type_Override: 'bug' Bug 'User Story' Issue → 'Issue'
# migration_marker_Format: 'https://dev.azure.com/contoso/Contoso%20Project' 42 →
#   '<!-- awf-migrated-to: https://dev.azure.com/contoso/Contoso%20Project#42 -->'
# migration_marker_id_SameProject: file with that marker inside other text → '42', rc 0
# migration_marker_id_OtherProject: marker for .../Other#7 → rc 1
# migration_comment_header_Login: 'octocat' '2026-03-04T23:59:00Z' → '**octocat** on GitHub, 2026-03-04:'
# migration_comment_header_Ghost: '' '2026-03-04T00:00:00Z' → '**ghost** on GitHub, 2026-03-04:'
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-gh-issue-migration-lib-tests.sh`
Expected: FAIL, because the library does not exist yet.

- [ ] **Step 3: Implement the five functions per the Global Constraints**

- [ ] **Step 4: Run tests and shellcheck**

Run: `bash tests/run-gh-issue-migration-lib-tests.sh && shellcheck -x -e SC1091 scripts/lib/gh-issue-migration.sh tests/run-gh-issue-migration-lib-tests.sh`
Expected: `0 failed`, and shellcheck is clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/gh-issue-migration.sh tests/run-gh-issue-migration-lib-tests.sh
git commit -m "feat(azdo): label, type and marker mapping for the issue migration (#642)"
```

### Task 3: `scripts/migrate-gh-issues-to-azdo.sh` — the migration run

**Files:**
- Create: `scripts/migrate-gh-issues-to-azdo.sh` (mode 0755)
- Create: `tests/run-migrate-gh-issues-tests.sh`
- Modify: `tests/mocks/gh` only if it cannot serve paginated
  `api …/issues/<n>/comments` and `issue list` fixtures. Extend it through
  env-pointed fixture files, the way it already works.
- Modify: `docs/AZDO-PIPELINE-SETUP.md` (a short "Moving a consumer's open
  issues" subsection pointing at the script and its flags)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `Added`)

**Interfaces:**
- Consumes:
  - from Task 1: `azdo_create_markdown_item`, `azdo_comment_markdown`,
    `azdo_project_url_path`;
  - from Task 2: all five functions;
  - from existing `azdo.sh`: `resolve_azdo_context`, `azdo_work_item_types`,
    `azdo_areas`.
- Produces: the CLI
  `migrate-gh-issues-to-azdo.sh --repo <owner/name> --area <path> [--type <t>] [--bug-type <t>] [--story-type <t>] [--close] [--dry-run] [--limit <n>]`.

- [ ] **Step 1: Write the failing tests**

All cases use the `gh` and `curl` mocks, with
`AZDO_ORG=contoso AZDO_PROJECT='Contoso Project'` and fixture issues 1–3, oldest
first. Issue 2 is labelled `bug` and has 3 comments, served over two pages.

```bash
# migrate_UsageWithoutArea: no --area → rc 2, no curl/gh write calls
# migrate_UnknownType: types fixture lacks 'User Story' → rc 2, message names it and --story-type
# migrate_UnknownArea: areas fixture lacks the area → rc 2
# migrate_CreatesOnePerOpenIssue: 3 create POSTs, in issue order 1,2,3; PRs in the list fixture are ignored
# migrate_BugType: issue 2's create URL ends '$Bug?api-version=7.1'
# migrate_DescriptionHasMigratedLine: issue 1's description == body + '\n\n_Migrated from <html_url>._'
# migrate_CommentsInOrderWithHeader: 3 comment POSTs for issue 2's item, in createdAt order, first starts '**'
# migrate_WriteBackWithMarker: GH_MOCK_BODY_LOG holds 'Migrated to Azure DevOps work item [#' and the marker
# migrate_CloseFlag: --close → a 'gh issue close' per issue; without it → none
# migrate_SkipsMigrated: issue 1 has the marker in a comment → no create for 1, output 'skip #1 (already work item'
# migrate_OtherProjectMarkerNotSkipped: marker for another project → issue is created
# migrate_DryRunWritesNothing: --dry-run → zero POST/PATCH in the curl log, zero gh comment/close; rc 0; one report line per issue
# migrate_Limit: --limit 1 → exactly one create
# migrate_OrphanOnCommentFailure: the comment POST fails → rc 1, stdout/stderr has the exact orphan message, no write-back for that issue, no later issue touched
# migrate_OrphanOnWriteBackFailure: gh comment fails → rc 1 with the orphan message
# migrate_PatNotInArgv: AZURE_DEVOPS_EXT_PAT=s3cr3t → not in the curl or gh argv logs
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/run-migrate-gh-issues-tests.sh`
Expected: FAIL, because the script does not exist yet.

- [ ] **Step 3: Implement the script**

- **Validation** runs in this order:
  1. usage;
  2. `resolve_azdo_context`;
  3. the types;
  4. the area.

  All of it happens before any issue is read.
- **Issue list:**
  `gh api --paginate "repos/<repo>/issues?state=open&per_page=100&direction=asc&sort=created"`.
  Drop entries that have `pull_request`.
- **Per issue:**
  1. Read the comments with `gh api --paginate …/comments`.
  2. Run the marker check.
  3. On a dry run, print `would create <type> "<title>" tags=[…] comments=<n> body=<bytes>B`.
  4. Otherwise create the item, copy the comments, and write back with
     `gh issue comment <n> --repo <repo> --body-file <tmp>`, plus the optional
     close.
- **Temp files:** keep them in a `mktemp -d` dir removed by an EXIT trap.

- [ ] **Step 4: Run the full suite and lint**

Run: `just test` and `pre-commit run --all-files` (after `git add`)
Expected: all runners report `0 failed`, and pre-commit passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/migrate-gh-issues-to-azdo.sh tests/run-migrate-gh-issues-tests.sh tests/mocks/gh docs/AZDO-PIPELINE-SETUP.md CHANGELOG.md
git commit -m "feat(azdo): migrate a consumer's open GitHub issues to work items (#642)"
```
