# Re-enrichment replaces its own sections — design (#499)

## Why

Re-running `/enrich` on an issue that was already enriched appends a second
`## Acceptance Criteria` block, a second plan and a second spec link. The body
then carries two of each and nothing says which is current.

The cause is the same on every forge. Each write-back prepends "the original
description", and the original is re-read right before composing:

- GitHub Step 6 (`commands/enrich.md:419`, read at `:443`)
- Forgejo Step 6 (`commands/enrich.md:765`, read at `:743`)
- Azure DevOps (`commands/enrich.md:910`, `orig="$(azdo_description …)"`, then
  `$orig<h2>Acceptance Criteria</h2>…` at `:919`)
- `/enrich-phased` phase `issue`, GitHub (`commands/enrich-phased.md:196`) and
  Forgejo (`:475`). Its Azure DevOps section reuses `/enrich`'s write verbatim
  (`commands/enrich-phased.md:584`).

On a second run that re-read body already contains the first run's sections, so
they are carried forward and a fresh set is appended under them.

This is reachable. The stale-lock takeover in Step 1.5 exists so that a second run
can proceed on an issue a previous run touched, and re-enriching after a spec
changes is a normal thing to want. A headless run that ended in `needs-human`
leaves an `## Assumptions` block (Headless mode, step 1). The human-resolved re-run
then duplicates that block too.

## Goal

A re-run of `/enrich` (or `/enrich-phased`) leaves **exactly one** set of
enrich-owned sections on the issue: the new one. Everything above the old set is
kept byte-for-byte. All forges behave the same way. The Azure DevOps path keeps
its read-modify-write guard: a failed read never becomes a write.

## Non-goals

- Refusing to re-enrich, or keeping the old block marked as superseded. Both were
  options in #499 and were rejected by the confirmed answer below.
- Changing which sections enrich writes, their order or their content.
- Changing `azdo_description` / `azdo_set_description` or anything else in
  `scripts/lib/azdo.sh`. #498 and #500 both change that file. This fix does not
  need to.
- A race re-check for Azure DevOps locks, or any other lock change.

## Anti-goals

- Losing human-written description text on a **first** enrichment. That is the
  failure the existing "never compose from an unverified read" rule guards
  against, and this fix must not open a second route to it.
- Turning a failed Azure DevOps read into an empty `$orig` that then gets written.

## Design

### One helper library, two filters

New file `scripts/lib/enrich-body.sh`. `setup/link-commands.sh:105` already
installs every `scripts/lib/*.sh` into `~/.claude/scripts/lib/`, so the commands
source it as `$HOME/.claude/scripts/lib/enrich-body.sh`, the same way they source
`detect-forge.sh` and `parse-enrich-args.sh`.

Both filters read the body on stdin and write the kept prefix on stdout. They exit
0 on success, including when there is nothing to strip, in which case the input
passes through unchanged. They exit non-zero only when the interpreter fails. They
are pure text filters: no network, no `gh`, no `az`.

**`enrich_body_strip_markdown`**, used by GitHub and Forgejo:

- The cut point is the first line that is a level-2 heading whose text is exactly
  one of the **enrich-owned headings**:
  - `Acceptance Criteria`
  - `Assumptions`
  - `Consequences`
  - `Implementation Plan`
  - `Spec`
  - `Spec & Implementation Plan` (Forgejo)
- A match is line-anchored (`^##` + spaces + name + optional trailing spaces). It
  is exact: `## Specification` and `## Scope` do not match, and neither does a
  heading quoted inline in a sentence or a bullet. #499's own body is such a case.
- Lines inside fenced code blocks (```` ``` ```` or `~~~`) never match.
- CRLF bodies are matched as if LF. GitHub web edits store `\r\n`. The kept prefix
  is emitted unchanged, CRs included.
- Everything from the cut point to the end of the body is dropped. Trailing blank
  lines at the end of the kept prefix are dropped too, so the composer's own
  separator is the only gap.

**`enrich_body_strip_html`**, used by Azure DevOps:

- The cut point is the first `<h2 …>…</h2>` element whose text matches one of the
  enrich-owned headings, or `Spec & Plan` (the heading the ADO write uses at
  `commands/enrich.md:920`). The comparison is case-insensitive.
- The text is compared after:
  - stripping inner tags
  - HTML-unescaping, so `&amp;` and `&` are equal
  - collapsing whitespace
- This matters because Azure DevOps rewrites stored markup:
  `scripts/lib/azdo.sh:369` records that `<p>x</p>` comes back as `<p>x </p>`.
  Attributes on the `<h2>` are allowed.
- Everything from the opening `<h2` of that element to the end is dropped.

Python 3 does the matching, inline in the shell functions. That is the convention
`azdo.sh` already follows, for example `azdo_html_escape` at `:329`, and python3
is already a hard dependency of the ADO write path.

### Why "first owned heading to the end"

Enrich always appends its sections **last**, in a fixed order (Step 6 items 1–5).
The inlined plan carries its own `##` headings (`## Global Constraints`, task
headings), so a section-by-section removal would leave plan fragments behind. A
single cut at the first owned heading removes the whole previous set and keeps
everything above it. This is what the confirmed answer asks for.

### Wiring into the commands

The order of operations is the same at every site:

1. **Read with the existing guard**, unchanged:
   - GitHub/Forgejo: the 3-try loop plus `[ -s orig-body.md ] || abort`.
   - ADO: `orig="$(azdo_description …)" || { echo "read failed — not writing"; exit 1; }`.
2. **Then strip**, as a separate statement on the verified read:
   - Markdown: `enrich_body_strip_markdown < orig-body.md > kept-body.md`, with
     its own `|| abort`.
   - ADO: `orig="$(printf '%s' "$orig" | enrich_body_strip_html)" || { …; exit 1; }`.
3. **Compose from the stripped text.**

For ADO the strip must **never** be piped directly off the read
(`azdo_description … | enrich_body_strip_html`). Without `pipefail` the
pipeline's status is the filter's, so a failed read would produce an empty
`$orig` and exit 0. That is exactly the read-becomes-write hole the guard closes.
The doc test asserts this order.

The GitHub Step 6 pre-write assertion ("starts with the original's first line,
retains every `user-attachments` reference") is checked against the **stripped**
prefix. Otherwise an image that only lived inside an old enrich section would fail
the assertion on every re-run.

Sites changed:

- `commands/enrich.md`:
  - GitHub Step 6
  - Forgejo Step 6
  - Azure DevOps write block
- `commands/enrich-phased.md`:
  - Phase `issue`, GitHub
  - Phase `issue`, Forgejo
  - The ADO section already defers to `/enrich`'s block verbatim, so it is
    covered by the `/enrich` change.

The Headless-mode escalation writes its `## Assumptions` block "as usual", through
Step 6's composition. It therefore inherits the strip with no change of its own.

### Tests

- `tests/run-enrich-body-tests.sh`, a new Layer-1 runner. `tests/run-all.sh`
  discovers it automatically. It covers:
  - a fresh body passes through unchanged
  - a body with one prior enrichment is cut at its first owned heading
  - a needs-human body with only `## Assumptions` is cut
  - the Forgejo heading is cut
  - headings inside fences and inline mentions are ignored
  - `## Specification` is ignored
  - CRLF input
  - idempotence: `strip(strip(x) + new sections) == strip(x)`
  - HTML: a sanitized round-trip shape (attributes, trailing spaces, `&amp;`,
    upper case), `Spec &amp; Plan`, a description with no owned `<h2>`, and empty
    input
- `tests/run-enrich-reenrich-doc-tests.sh`, a new Layer-1 doc test on the two
  command files. It asserts that:
  - every prepend site sources `enrich-body.sh` and calls the matching filter
    before composing
  - in the ADO block, the guarded `azdo_description` read precedes the strip
  - the strip is not piped off `azdo_description`

## Assumptions

- **A1** [confirmed] Re-enrichment replaces the previous sections. Answer, quoted:
  "Replace the sections: swap out the previous ## Acceptance Criteria /
  ## Implementation Plan / ## Spec sections, preserve everything above them."
  Both forges (GitHub and Azure DevOps) must behave the same, and the Azure DevOps
  path must keep its read-modify-write guard: a failed read must never become a
  write.
  Rejected: refuse-when-present, and append-marked-superseded (#499 Scope).
- **A2** [high] The set of replaced sections is every section enrich owns, not
  only AC/Plan/Spec. It adds `## Assumptions` and `## Consequences`, which quick
  mode writes between AC and Plan (`commands/enrich.md:421-422`), and Forgejo's
  `## Spec & Implementation Plan` (`:769`).
  Rejected: AC/Plan/Spec only. That would leave a stale `## Assumptions` block
  from a headless needs-human run above the cut and duplicate it on the re-run.
  This applies A1, it is not a new decision.
- **A3** [high] The cut runs from the first owned heading to the end of the body.
  Rejected: removing each owned section individually. The inlined plan has its own
  `##` headings (for example `## Global Constraints` in
  `docs/superpowers/plans/2026-11-12-pre-agent-failures.md`), so per-section
  removal leaves plan fragments behind.
- **A4** [med] Anything a human appended **below** a previous run's sections is
  dropped with them.
  Rejected: preserving trailing non-owned headings. That is indistinguishable from
  the plan's own headings (A3).
- **A5** [med] The strip also runs on a first enrichment. An original
  human-written description that itself uses an exact owned heading (for example
  `## Assumptions` or `## Spec`) is truncated from that heading on.
  Rejected: an invisible `<!-- enrich -->` marker. Azure DevOps sanitizes stored
  HTML (`scripts/lib/azdo.sh:369`), so the marker cannot be relied on there, which
  would break parity. Legacy enriched bodies carry no marker anyway.
  `/new` does not seed any owned heading: `commands/new.md` contains none of them.
  Exact matching keeps `## Specification` and `## Scope` safe.
- **A6** [high] The filters live in a new `scripts/lib/enrich-body.sh`, not in
  `scripts/lib/azdo.sh`.
  Rejected: adding the HTML filter to `azdo.sh`. It is not an ADO API call, and
  #498/#500 are both changing that file.
  `setup/link-commands.sh:105` installs every `scripts/lib/*.sh`.
- **A7** [med] The fix also covers the Forgejo path and `/enrich-phased`'s
  GitHub and Forgejo `issue` phase, not just the two forges #499 names.
  Rejected: GitHub and ADO only. Those other sites have the identical prepend
  (`commands/enrich.md:765`, `commands/enrich-phased.md:196`, `:475`) and would
  keep the bug, which breaks the "all paths agree" intent.
- **A8** [med] Azure DevOps headings are matched by normalized text: inner tags
  stripped, unescaped, whitespace collapsed, case-insensitive.
  Rejected: a literal `<h2>Acceptance Criteria</h2>` match. The service rewrites
  stored markup (`scripts/lib/azdo.sh:369`). How exactly it rewrites `<h2>` has
  not been observed live.
- **A9** [high] On ADO the read and the strip are separate guarded statements,
  never one pipeline.
  Rejected: `azdo_description | enrich_body_strip_html`. Without `pipefail` a
  failed read would yield an empty `$orig` with exit 0
  (`commands/enrich.md:910`'s guard exists for exactly this).
- **A10** [high] Python 3 does the matching.
  Rejected: awk/sed. Fence tracking and HTML unescaping are awkward there, and
  python3 is already required by `azdo.sh` (`:329`) and by the ADO block in
  `commands/enrich.md:911`.

## Consequences

- A re-run silently discards hand edits made inside the previous AC, Assumptions
  or Plan sections. The new run's sections are the only ones left.
- The GitHub Step 6 pre-write assertion now compares against the stripped prefix.
  An image referenced only inside an old enrich section is no longer required to
  survive.
- Issues enriched before this change are cleaned up on their next re-run, with no
  migration step.
- `commands/enrich.md` and `commands/enrich-phased.md` gain a `source` line for a
  second helper library at each write site.
