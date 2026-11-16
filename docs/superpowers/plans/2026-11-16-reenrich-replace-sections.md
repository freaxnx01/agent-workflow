# Re-enrichment Replaces Its Own Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `/enrich` or `/enrich-phased` runs again on an issue it already enriched, the previous enrich-owned sections are replaced, not duplicated. This holds on GitHub, Forgejo and Azure DevOps.

**Architecture:** A new sourced library, `scripts/lib/enrich-body.sh`, provides two stdin→stdout filters:

- `enrich_body_strip_markdown`, for GitHub and Forgejo
- `enrich_body_strip_html`, for the Azure DevOps HTML description

Each filter cuts the body at the first enrich-owned heading. Every write-back site in `commands/enrich.md` and `commands/enrich-phased.md` reads the body exactly as it does today, with its existing guard, then strips it in a separate guarded statement, then composes from the stripped text.

**Tech Stack:** Bash 5 (`set -euo pipefail`, `IFS=$'\n\t'`), inline `python3` (stdlib only: `re`, `html`, `sys`), Layer-1 runners discovered by `tests/run-all.sh`, `shellcheck` via `just lint-shell`.

**Spec:** `docs/superpowers/specs/2026-11-16-reenrich-replace-sections-design.md`

## Global Constraints

- `scripts/lib/azdo.sh` is **not** modified. #498 and #500 change it.
- The enrich-owned markdown headings are exactly these level-2 headings:
  - `Acceptance Criteria`
  - `Assumptions`
  - `Consequences`
  - `Implementation Plan`
  - `Spec`
  - `Spec & Implementation Plan`
- The enrich-owned HTML `<h2>` texts are the same six plus `Spec & Plan`. They are compared case-insensitively, after stripping inner tags, HTML-unescaping and collapsing whitespace.
- Cut from the first owned heading to the end of the body. Trailing blank lines (including `\r`-only lines) at the end of the kept prefix are dropped. The kept prefix is otherwise byte-identical to the input.
- Markdown matching is line-anchored and exact, ignores lines inside ```` ``` ```` / `~~~` fences, and treats `\r\n` as `\n` for matching only.
- On Azure DevOps the guarded `azdo_description` read stays a separate statement before the strip. It is never `azdo_description … | enrich_body_strip_html`.
- Both filters exit 0 when there is nothing to strip, passing the input through unchanged.
- The GitHub Step 6 pre-write assertion compares against the **stripped** prefix.
- Existing tests pass unmodified, in particular `tests/run-enrich-headless-doc-tests.sh`, `tests/run-enrich-cost-rules-doc-tests.sh` and `tests/run-azdo-lib-tests.sh`.
- Use Conventional Commits with scope `enrich`, and reference `#499`.

## Review Focus

1. **A fresh, never-enriched body** with no owned heading must come back byte-identical, including CRLF line endings and no trailing-newline normalisation beyond dropping trailing blank lines. Task 1, `fresh_body_unchanged` / `crlf_body_unchanged`.
2. **#499's own body**, which quotes `## Acceptance Criteria` and `## Spec` inline inside a bullet, must not be cut. Task 1, `inline_mention_not_cut`.
3. **A body that is only enrich sections** (the previous original was empty) must strip to empty and exit 0, not fail. Task 1, `only_sections_strips_to_empty`. Task 2, `html_only_sections_strips_to_empty`.
4. **A failed Azure DevOps read** must abort before any write, even though the strip now sits between the read and the write. Task 3, the doc-test ordering asserts.
5. **Re-running twice** must converge: stripping a composed body gives back the same kept prefix. Task 1, `idempotent_after_recompose`. Task 2, `html_idempotent_after_recompose`.

---

### Task 1: Markdown filter

**Files:**
- Create: `scripts/lib/enrich-body.sh`
- Create: `tests/run-enrich-body-tests.sh`
- Create: `tests/fixtures/enrich-body/` (fixture inputs and expected outputs, one pair per case)

**Interfaces:**
- Produces: `enrich_body_strip_markdown`. It takes no arguments, reads the issue body on stdin and writes the kept prefix on stdout. It returns 0 on success, including when nothing was stripped, and non-zero only if `python3` fails.
- The file header follows `scripts/lib/parse-enrich-args.sh`: `#!/usr/bin/env bash`, a "sourced, not executed" comment listing each function, `set -euo pipefail`, `IFS=$'\n\t'`.

- [ ] **Step 1: Write the failing tests**

Model the runner on `tests/run-enrich-headless-doc-tests.sh`: `pass`/`fail` counters, a summary and exit 1 on any failure. Add an `assert_strip <name> <input-fixture> <expected-fixture>` helper. It sources `$ROOT/scripts/lib/enrich-body.sh` and compares the output byte-for-byte; use `cmp`, so CRs count.

Cases, with fixtures in `tests/fixtures/enrich-body/<case>.in.md` / `<case>.out.md`:

- `fresh_body_unchanged`: a description with `## Scope` and `## How it is reached`. Output equals input.
- `crlf_body_unchanged`: the same body with `\r\n` endings. Output equals input.
- `inline_mention_not_cut`: #499's original body, verbatim from the issue (the bullet ``- replace the previous `## Acceptance Criteria` / `## Implementation Plan` / `## Spec` sections…``). Output equals input.
- `cuts_prior_enrichment`: a description, a blank line, then:
  - `## Acceptance Criteria` with `- [ ]` items
  - `## Assumptions`
  - `## Consequences`
  - `## Implementation Plan`, containing `## Global Constraints` and `### Task 1`
  - `## Spec`

  The output is the description only, with no trailing blank lines.
- `cuts_headless_assumptions_only`: a description, then `## Assumptions` with a `⛔` item. The output is the description.
- `cuts_forgejo_heading`: a description, then `## Acceptance Criteria`, then `## Spec & Implementation Plan`. The output is the description.
- `cuts_crlf_enrichment`: `cuts_prior_enrichment` with `\r\n` endings. The output is the description, still with `\r\n` endings, and with no trailing `\r\n` blank lines.
- `fenced_heading_not_cut`: a description containing a ```` ``` ```` fence with a `## Acceptance Criteria` line inside it, and a `~~~` fence with `## Spec`. Output equals input.
- `similar_heading_not_cut`: a description with `## Specification`, `## Acceptance criteria notes` and `### Acceptance Criteria`. Output equals input. Only an exact level-2 match counts.
- `trailing_spaces_heading_cut`: `## Acceptance Criteria   ` (trailing spaces) is still cut.
- `only_sections_strips_to_empty`: the body starts with `## Acceptance Criteria`. The output is empty and the exit status is 0.
- `idempotent_after_recompose`: no fixture pair. Take `cuts_prior_enrichment.in.md`, strip it to get `K`, append a fresh `## Acceptance Criteria` … `## Spec` block, and strip again. The result equals `K`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-enrich-body-tests.sh`
Expected: FAIL. `scripts/lib/enrich-body.sh` does not exist yet, or `enrich_body_strip_markdown: command not found`.

- [ ] **Step 3: Implement `enrich_body_strip_markdown` in `scripts/lib/enrich-body.sh`**

It is an inline `python3 -c` that reads `sys.stdin.buffer` and decodes UTF-8 with `newline=''` semantics, so CRs are preserved. Split with `splitlines(keepends=True)`. Keep a fence state that toggles on lines whose `rstrip('\r\n').lstrip()` starts with ```` ``` ```` or `~~~`. Outside a fence, a line is a cut when `re.fullmatch(r'##[ \t]+(Acceptance Criteria|Assumptions|Consequences|Implementation Plan|Spec|Spec & Implementation Plan)[ \t]*', line.rstrip('\r\n'))` matches. Emit the lines before the cut, then remove trailing lines that are empty after `rstrip('\r\n')`. If there is no cut, emit the input untouched. Write with `sys.stdout.buffer`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run-enrich-body-tests.sh && just lint-shell`
Expected: all cases `✓`, exit 0, and shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/enrich-body.sh tests/run-enrich-body-tests.sh tests/fixtures/enrich-body/
git commit -m "feat(enrich): add a markdown filter that strips a previous enrichment (#499)"
```

---

### Task 2: HTML filter

**Files:**
- Modify: `scripts/lib/enrich-body.sh` (add a function and extend the header comment)
- Modify: `tests/run-enrich-body-tests.sh`
- Create: `tests/fixtures/enrich-body/*.in.html` / `*.out.html`

**Interfaces:**
- Consumes: the file and runner from Task 1.
- Produces: `enrich_body_strip_html`. It takes no arguments, reads `System.Description` HTML on stdin and writes the kept prefix on stdout. It returns 0 on success, including when nothing was stripped, and non-zero only if `python3` fails.

- [ ] **Step 1: Write the failing tests**

Reuse `assert_strip` with an optional filter argument, or add `assert_strip_html`. Cases:

- `html_no_owned_heading_unchanged`: `<div>Bug text</div><h2>Repro</h2><p>steps</p>`. Output equals input.
- `html_cuts_exact_write`: the exact shape `commands/enrich.md` writes:

  ```html
  <div>orig</div><h2>Acceptance Criteria</h2><ul><li>a</li></ul>
  <h2>Spec &amp; Plan</h2><ul><li><code>docs/x.md</code></li></ul>
  <p>Read the plan before writing any code.</p>
  ```

  The output is `<div>orig</div>`.
- `html_cuts_sanitized_shape`: `<div>orig </div><h2 style="margin:0">  acceptance   criteria </h2><ul><li>a </li></ul>`. The output is `<div>orig </div>`.
- `html_cuts_spec_and_plan_first`: the description is followed directly by `<h2>Spec & Plan</h2>`, with a raw `&` and no AC heading. The output is the description.
- `html_cuts_wrapped_heading`: `<h2><span>Acceptance Criteria</span></h2>`. Cut.
- `html_similar_heading_not_cut`: `<h2>Acceptance Criteria notes</h2>` and `<h3>Acceptance Criteria</h3>`. Output equals input.
- `html_only_sections_strips_to_empty`: the input starts with `<h2>Acceptance Criteria</h2>`. The output is empty, exit 0.
- `html_empty_input`: empty stdin gives empty output, exit 0.
- `html_idempotent_after_recompose`: strip `html_cuts_exact_write.in.html` to get `K`, append the exact-write AC/Spec block again, and strip again. The result equals `K`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-enrich-body-tests.sh`
Expected: the HTML cases FAIL with `enrich_body_strip_html: command not found`. The Task 1 cases still pass.

- [ ] **Step 3: Implement `enrich_body_strip_html` in `scripts/lib/enrich-body.sh`**

It is an inline `python3 -c`. Iterate over `re.finditer(r'<h2\b[^>]*>(.*?)</h2\s*>', text, re.I | re.S)`. For each match, normalise group 1 like this:

1. Strip tags with `re.sub(r'<[^>]+>', '', …)`.
2. `html.unescape`.
3. Collapse whitespace with `' '.join(s.split())`.
4. `casefold()`.

The first match whose normalised text is in the owned set (Global Constraints, case-folded) is the cut at `m.start()`. Emit `text[:cut]` with trailing whitespace removed via `rstrip()`, or the input untouched when no match is owned.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run-enrich-body-tests.sh && just lint-shell`
Expected: all cases `✓`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/enrich-body.sh tests/run-enrich-body-tests.sh tests/fixtures/enrich-body/
git commit -m "feat(enrich): add an HTML filter for Azure DevOps descriptions (#499)"
```

---

### Task 3: Wire the filters into every write-back site

**Files:**
- Modify: `commands/enrich.md`. GitHub Step 6 (around `:430-455`), Forgejo Step 6 (around `:731-772`) and the Azure DevOps write block (around `:903-930`).
- Modify: `commands/enrich-phased.md`. Phase `issue` for GitHub (around `:194-202`) and Forgejo (around `:472-480`).
- Create: `tests/run-enrich-reenrich-doc-tests.sh`

**Interfaces:**
- Consumes: `enrich_body_strip_markdown` and `enrich_body_strip_html` from Tasks 1–2. The commands source them as `source "$HOME/.claude/scripts/lib/enrich-body.sh"`.

- [ ] **Step 1: Write the failing doc test**

The runner style follows `tests/run-enrich-headless-doc-tests.sh`. Extract sections with awk between headings: `## GitHub`, `## Forgejo` and `## Azure DevOps` in `commands/enrich.md`, and in `commands/enrich-phased.md` the `### Phase \`issue\`` subsection under `## GitHub` and the one under `## Forgejo`. Assertions:

- `enrich.md GitHub Step 6 strips before composing`: the section contains `enrich-body.sh` and `enrich_body_strip_markdown`. The first `enrich_body_strip_markdown` line comes after the `[ -s orig-body.md ] ||` guard line and before `gh issue edit $ISSUE --body-file`.
- `enrich.md GitHub assertion uses the stripped prefix`: the Step 6 section mentions `kept-body.md` in the pre-write assertion paragraph (the one containing `user-attachments`).
- `enrich.md Forgejo Step 6 strips before composing`: the same check, before `tea api -X PATCH`.
- `enrich.md ADO read guard precedes the strip`: in `## Azure DevOps`, the line matching `orig="$(azdo_description` and `|| {` comes before the first `enrich_body_strip_html` line, and that comes before `azdo_set_description "$ISSUE"`.
- `enrich.md ADO strip is guarded`: the `enrich_body_strip_html` line carries `|| {`.
- `enrich.md ADO strip is not piped off the read`: no line matches `azdo_description[^|]*\|[^|]`.
- `enrich-phased.md GitHub issue phase strips` and `enrich-phased.md Forgejo issue phase strips`: each subsection names `enrich_body_strip_markdown`.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run-enrich-reenrich-doc-tests.sh`
Expected: FAIL on every assertion except `ADO strip is not piped off the read`, which already holds.

- [ ] **Step 3: Edit `commands/enrich.md` GitHub Step 6**

After the existing fetch-with-retry block, add a block that sources the lib and strips `orig-body.md` into `kept-body.md`:

```bash
source "$HOME/.claude/scripts/lib/enrich-body.sh"
enrich_body_strip_markdown < orig-body.md > kept-body.md \
  || { echo "could not strip the previous enrichment — aborting"; exit 1; }
```

Add one paragraph saying why. A re-run's "original" already holds the previous run's sections. The filter cuts from the first enrich-owned heading to the end, so the old AC, Assumptions, Consequences, Plan and Spec are replaced, not duplicated, and everything above them is kept (#499). Change item 1 of the body list and the assertion paragraph to refer to `kept-body.md`, the stripped prefix, instead of the raw original. Add a sentence that `kept-body.md` may be empty when the issue had no description of its own, and that this is not an error.

- [ ] **Step 4: Edit `commands/enrich.md` Forgejo Step 6**

Make the same insertion after its fetch-with-retry block, and compose `bodyfile.md` from `kept-body.md`.

- [ ] **Step 5: Edit `commands/enrich.md` Azure DevOps write block**

Directly after the unchanged `orig="$(azdo_description "$ISSUE")" || { echo "read failed — not writing"; exit 1; }` line, add these two lines and leave the rest of the block as it is:

```bash
source "$HOME/.claude/scripts/lib/enrich-body.sh"
orig="$(printf '%s' "$orig" | enrich_body_strip_html)" || { echo "strip failed — not writing"; exit 1; }
```

Add a short paragraph after the existing escaping paragraph. It should say that the strip cuts at the first enrich-owned `<h2>`, matched on normalised text because the service rewrites stored markup. It should also say that the read and the strip are deliberately two statements: piping the read into the filter would take the filter's exit status, and a failed read would then become a write.

- [ ] **Step 6: Edit `commands/enrich-phased.md` phase `issue`**

For both GitHub and Forgejo, change the first bullet "the original description (keep it for humans)" to: the original description **with any previous enrichment stripped**, using `enrich_body_strip_markdown` exactly as in `/enrich` Step 6, which is the source of truth. Add a one-line pointer there; do not copy the block. The Azure DevOps section already defers to `/enrich`'s block verbatim, so leave it alone.

- [ ] **Step 7: Run the doc test and the full suite**

Run: `bash tests/run-enrich-reenrich-doc-tests.sh && bash tests/run-all.sh && just lint-shell`
Expected: all `✓`. `run-all.sh` exits 0 and lists both new runners. Shellcheck is clean.

- [ ] **Step 8: Commit**

```bash
git add commands/enrich.md commands/enrich-phased.md tests/run-enrich-reenrich-doc-tests.sh
git commit -m "fix(enrich): replace a previous enrichment instead of appending a second one (#499)"
```
