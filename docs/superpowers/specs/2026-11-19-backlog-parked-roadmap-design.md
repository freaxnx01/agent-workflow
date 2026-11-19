# `/parked` and `/roadmap` move issues to `backlog` (#644) — design

**Issue:** freaxnx01/agent-workflow#644
**Convention:** freaxnx01/ai-instructions#61 — every open issue has a milestone;
unscheduled, parked and roadmap work lives in a standing `backlog` milestone.
**Siblings (enriched in parallel):** #645 (`/new` falls back to `backlog`),
#646 (CI guard + backfill).

## Problem

ADR-010 (`docs/DECISIONS.md:1070`) defined `parked` and `roadmap` issues as
*having no milestone*, and enforced it downstream:

- `/parked repark` strips the milestone and records it as `milestone-was:`
  (`commands/parked.md:101-152`, Forgejo `:282-349`).
- `/roadmap defer` strips it without recording (`commands/roadmap.md:94-121`,
  Forgejo `:228-274`).
- `/milestone triage` walks only the no-milestone gap and filters `parked` /
  `roadmap` out of it (`commands/milestone.md:131-181`, Forgejo `:330-390`,
  Azure DevOps `:530-549`).

ai-instructions#61 replaces "no milestone" with "the `backlog` milestone". The
three commands must follow, on all three forges.

## Design

### The `backlog` milestone

- Matched by its exact title `backlog` among **open** milestones. It is never
  created by these commands. When it is missing, the command says so, points at
  `/milestone new backlog`, and **stops before any write**.
- **Azure DevOps:** `backlog` is the project's **root iteration**
  (`System.IterationPath == $AZDO_PROJECT`), which is what `/milestone triage`
  already treats as "unassigned" (`commands/milestone.md:532-540`). The root
  always exists, so the missing-backlog check cannot fire on this forge and is
  not written there.

### `/parked repark <n> "<reason>"`

1. Check that `backlog` exists (GitHub: `gh api …/milestones?state=open`;
   Forgejo: `tea api …/milestones?state=open`). Missing → report, point at
   `/milestone new backlog`, stop. Nothing has been written yet, so no orphan
   `parked:` comment is left behind.
2. Capture the current milestone (unchanged).
3. Post the `parked: <reason>` comment. Add `milestone-was: <name>` on the
   second line only when the current milestone is set **and is not `backlog`**,
   so `unpark` never offers `backlog` back.
4. Read back the reason (unchanged).
5. Move the issue to `backlog` (GitHub `gh issue edit <n> --milestone backlog`;
   Forgejo `tea milestones issues add --login git-home backlog <n>`) and read
   back. The read-back must show `backlog`.

Azure DevOps: add the `parked` tag (unchanged), post the reason (unchanged),
then set `System.IterationPath` to `$AZDO_PROJECT` and report the read-back.

### `/parked unpark <n>`

Unchanged flow: remove `parked`, read back, then offer the recorded
`milestone-was:` back. What changes is the fallback. On a decline, an empty
record, or a closed/deleted recorded milestone, the issue **stays in `backlog`**
(previously: stayed un-milestoned). No extra write is needed — `repark` already
put it there. Azure DevOps keeps its current unpark: tag removal only.

### `/roadmap defer <n> "<reason>"`

1. Check that `backlog` exists (GitHub/Forgejo). Missing → report, point at
   `/milestone new backlog`, stop before the comment.
2. Post the `roadmap: <reason>` comment and read it back (unchanged).
3. Move the issue to `backlog` instead of stripping the milestone. Read back.

`defer` still records no `milestone-was:` (A8). Azure DevOps: add the
`roadmap` tag, post the reason, set `System.IterationPath` to `$AZDO_PROJECT`.

### `/roadmap promote <n> to <milestone>`

Unchanged writes. `gh issue edit -m` / `tea milestones issues add` *replace*
the milestone, so the issue moves from `backlog` to the target. The text changes
from "someday → scheduled" to "`backlog` → the chosen milestone", and the
step-1 read-back is stated as the proof that the issue left `backlog`.

### `/milestone triage`

Phase 1 lists the union of:

- issues in `backlog` that carry neither `parked` nor `roadmap`, and
- **every** issue with no milestone, whatever its labels. Under the new
  convention an issue with no milestone breaks the rule, legacy parked/roadmap
  issues stripped by the old commands included.

Each row shows where it sits (`backlog` or `no milestone`). The GitHub filter:

```jq
map(select(.milestone == null
  or (.milestone.title == "backlog"
      and (([.labels[].name] | any(. == "parked" or . == "roadmap")) | not))))
```

Forgejo uses the same predicate in `python3`. Phase 1 also checks for
`backlog`. If it is missing, it says so once and points at
`/milestone new backlog`, then walks the no-milestone gap anyway.

Phase 2: an issue already in `backlog` is offered the open milestones
**except** `backlog`, plus `skip`. An issue with no milestone is offered all
open milestones, `backlog` included.

Azure DevOps: on this forge, backlog and no milestone are both the root
iteration. The existing WIQL gains
`AND NOT [System.Tags] CONTAINS 'parked' AND NOT [System.Tags] CONTAINS 'roadmap'`.

### Docs

- `commands/README.md`: one sentence under **Forge-agnostic** stating that
  `/parked repark` and `/roadmap defer` move an issue to `backlog`, and that
  `/milestone triage` walks `backlog` plus the no-milestone gap.
- `docs/COMMAND-CHEATSHEET.md`: one sentence under the step table, next to the
  Sort row.
- `docs/DECISIONS.md`: a dated **amendment** block at the top of ADR-010, in
  the same form as its existing 2026-10-04 amendment, saying that the
  "carry no milestone" decision is superseded by `backlog` (#644,
  ai-instructions#61).
- `CHANGELOG.md` `[Unreleased]` → `### Changed`: one entry.

### Tests

New Layer-1 test `tests/run-backlog-milestone-tests.sh`, picked up
automatically by `tests/run-all.sh` (`run-*-tests.sh` discovery). It
**executes** the command text rather than grepping it:

- It extracts the GitHub and Forgejo triage blocks from `commands/milestone.md`
  and runs them against a fixture of six issues: no milestone, backlog,
  backlog+parked, backlog+roadmap, `next`, and no milestone+parked. It asserts
  that exactly the expected issue numbers come out.
- It extracts the GitHub `repark` blocks of `commands/parked.md` and the
  GitHub `defer` blocks of `commands/roadmap.md`, substitutes the placeholders,
  and runs them with a stub `gh` function that serves fixture JSON through the
  real `jq` and logs every write. It asserts:
  - with `backlog` present: a `--milestone backlog` write, no
    `--remove-milestone`, and a `milestone-was: next` line;
  - with the issue already in `backlog`: no `milestone-was:` line;
  - with `backlog` absent: no write at all, and the output names
    `/milestone new backlog`.

## Out of scope

- `commands/new.md` (`:116`, `:134` still say parked issues have no milestone).
  #645 owns `new.md`.
- Backfill of existing parked/roadmap issues, and the CI guard. These belong to
  #646. `/milestone triage` surfacing no-milestone parked issues is a side
  effect, not a backfill.
- `docs/generated/` and `docs/knowledge-bundle.txt`, which CI regenerates on
  `main`.

## Assumptions

- **A1** [confirmed] `general-<month>-<year>` and `next`: "Drop general-*, keep
  next": /new stops auto-creating general-<month>-<year> (handled in #645, not
  here); `next` stays as a documented exception alongside backlog. This issue
  therefore treats `next` as an ordinary scheduled milestone: triage does not
  list it, and promote can target it.
- **A2** [confirmed] `backlog` existence: "Create in both now": it now exists in
  freaxnx01/agent-workflow (milestone #7) and freaxnx01/ai-instructions
  (milestone #2). The commands must still report a missing backlog in other
  repos and point at `/milestone new backlog`, never create it silently.
- **A3** [confirmed] Ordering vs ai-instructions#61: "Parallel": implement now;
  #61's doc follows the same rule.
- **A4** [high] `backlog` is matched by its exact lowercase title among open
  milestones. Rejected: case-insensitive matching. The issue, ai-instructions#61
  and milestone #7 all spell it `backlog`, and `/milestone` already refuses fuzzy
  matching (`commands/milestone.md:128-129`).
- **A5** [med] With `backlog` missing, `repark`/`defer` stop **before any
  write**, the reason comment included.
  Rejected: falling back to the old strip, which would silently produce the
  state the convention forbids. Rejected: posting the comment first, which leaves
  an orphan `parked:` comment.
- **A6** [med] A *closed* `backlog` milestone counts as missing. Only open
  milestones are queried, matching `/milestone assign` (`commands/milestone.md:128`).
  Rejected: reopening it, which would be a silent write.
- **A7** [high] `repark` writes no `milestone-was:` when the current milestone
  is already `backlog`. Otherwise `unpark` would offer `backlog` back, which is
  a no-op.
- **A8** [med] `/roadmap defer` keeps recording **no** `milestone-was:`. The
  issue's "keep recording `milestone-was:`" describes existing behaviour, and
  only `repark` has that (ADR-010, `docs/DECISIONS.md:1138-1145`). `promote`
  names its target explicitly, so nothing is lost. Rejected: starting to record
  it for `defer`.
- **A9** [high] On `unpark`, when the recorded milestone is declined, absent or
  closed, the issue stays in `backlog` with no extra write.
- **A10** [med] `/milestone triage` lists **every** no-milestone issue,
  including `parked`/`roadmap` ones. It excludes `parked`/`roadmap` only inside
  `backlog`. This is the literal reading of the issue ("walk issues in `backlog`
  (excluding `parked` / `roadmap`) plus any issue with no milestone"). Under the
  convention, a no-milestone issue always breaks the rule. Rejected: excluding
  parked/roadmap from the no-milestone part as well.
- **A11** [med] Triage Phase 2 offers `backlog` as a target only to
  no-milestone issues, never to issues already in it. A missing `backlog` is
  reported once in Phase 1 and does not stop the walk of the no-milestone gap.
- **A12** [high] Azure DevOps: `backlog` is the root iteration, as the issue
  states. `repark`/`defer` set `System.IterationPath` to `$AZDO_PROJECT`, and
  triage adds tag exclusions to its existing root-iteration query.
- **A13** [med] Azure DevOps records no `milestone-was:`, and its `unpark` does
  not offer one back, the same as today (`commands/parked.md:414-439`).
  Rejected: adding it now. The ADO discussion field is HTML, and nobody has
  tested a multi-line bookkeeping comment through `azdo_comment` /
  `azdo_comments`. ADO parity for the round trip can follow separately.
- **A14** [med] ADR-010 gets a dated amendment block rather than a new ADR.
  Rejected: ADR-024. #645 and #646 are enriched in parallel, and three new ADRs
  would race for the same number, while an amendment has precedent at
  `docs/DECISIONS.md:1075-1078`.
- **A15** [high] `commands/new.md:116` and `:134` are left to #645. They become
  stale when this lands and are corrected there. See Consequences.

## Consequences

- **Until #645 lands, `commands/new.md` contradicts this change.** It still
  says parked issues are "defined by having no milestone" and that `repark`
  strips it.
- **The first `/milestone triage` run after this lands lists legacy
  parked/roadmap issues** that the old `repark`/`defer` stripped. That is
  expected under the convention, and #646's backfill makes it go away.
- `/parked repark` and `/roadmap defer` stop working in any repo without an
  open `backlog` milestone until someone runs `/milestone new backlog`.
- ADR-010's "Consequences" bullets about partial enforcement still hold: a
  `parked` label added by hand in the web UI does not move the milestone.
