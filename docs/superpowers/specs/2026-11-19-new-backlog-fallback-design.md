# `/new` falls back to the `backlog` milestone instead of `none` (#645)

## Problem

`commands/new.md` can still file an issue with no milestone. Its milestone
selection has four cases (GitHub at `:54-134`, Forgejo at `:192-241`):

1. notes name a milestone -> use it;
2. zero open milestones -> offer to create `general-<month>-<year>`; a declined
   create files the issue with no milestone;
3. exactly one open milestone -> assign silently;
4. two or more -> ask, with a `none` option; "silence is never an assignment".

ai-instructions#61 makes `backlog` the default milestone for every open issue.
So `none`, the declined create and silence must all resolve to `backlog`, and
`backlog` must not count as an *active* milestone (otherwise a repo whose only
other milestone is `backlog` is treated as having two, and is asked instead of
silently assigned).

## Design

Docs-only, in `commands/new.md`, plus a Layer-1 test that executes the filters
the command documents.

Terminology: **active** = open and not titled `backlog`. `backlog` is matched by
exact, case-sensitive title.

Selection, first match wins (case 1 unchanged):

1. Notes name a milestone -> as today. Naming `backlog` explicitly is an ordinary
   case 1.
2. **Zero active milestones** -> `backlog`, assigned silently and reported from
   the read-back (same discipline as case 3). `general-<month>-<year>`, its
   create offer, the `LC_ALL=C` month rule and the closed-milestone `422` rule
   are removed from `/new`.
3. **Exactly one active milestone** -> assign it silently. `backlog` is not
   counted.
4. **Two or more active** -> ask. Options are the active titles in the existing
   sort order (soonest due first, undated last) plus `backlog` as the last
   option, replacing `none`. The first active entry stays the pre-selected
   proposal. Silence or a decline means `backlog`.

`backlog` missing (not in the open list): `/new` says so, points at
`/milestone new backlog`, and never creates it. Where the fallback was needed the
issue is filed with no milestone and the report says why; in case 4 the
`backlog` option is then omitted, because it cannot be assigned.

`next` is not special-cased in any filter. It is deprecated (ai-instructions#61,
merged as #62) and closed in this repo, so it is never listed; anywhere it is
still open it is just another non-`backlog` milestone.

Mechanics: the GitHub list command filters `backlog` out with jq and a second
command counts it; the Forgejo python snippet prints `active` rows and a
`backlog yes|no` line. Both are written so the test can extract and run them.

Azure DevOps: the section has no milestone selection today (it sets Area Path
and description only, `commands/new.md:283-288`), so no behaviour changes. The
section gets one sentence saying why the backlog fallback does not apply.

The closing paragraph "/new never guesses roadmap/parked intent" is reworded so
it no longer says those commands "strip the milestone", which #644 changes; it
says they own the milestone of those issues and points at #644.

`docs/DECISIONS.md`: ADR-010 (the one that
defines `none` and `general-<month>-<year>`) gets an `Amended 2026-11-19` note at
its top, in the form of the existing 2026-10-04 amendment. No new ADR: the
ordering, the sort rule and the silent-single-assignment rule stand.
`docs/generated/software-factory-knowledge.md` is a generated bundle and is not
hand-edited.

## Assumptions

- **A1** [confirmed, revised 2026-11-19] `general-<month>-<year>` is dropped and
  `next` is deprecated. /new no longer offers or auto-creates
  general-<month>-<year>. With zero active (non-backlog) open milestones it falls
  back to `backlog`. The first answer was "Drop general-*, keep next"; it was
  revised to match ai-instructions#61 as merged (#62), and `next` in this repo was
  closed with its open issues moved to `backlog`. /new needs no `next` handling.
- **A2** [confirmed] `backlog` existence. Answer: "Create in both now": it exists
  in freaxnx01/agent-workflow (#7) and freaxnx01/ai-instructions (#2). In other
  repos where it is missing, /new reports it and points at `/milestone new
  backlog`; never creates it silently.
- **A3** [confirmed] Ordering vs ai-instructions#61. Answer: "Parallel":
  implement now; #61's doc follows the same rule.
- **A4** [high] `backlog` is matched by exact, case-sensitive title.
  Rejected: case-insensitive match. The issue names the title `backlog` and
  `/milestone new backlog`; the existing code matches titles exactly
  (`commands/new.md:75-77`).
- **A5** [high] Case 1 is untouched. Rejected: forcing notes through the
  backlog logic. `commands/new.md:59-69` already handles an explicit name and its
  create-with-confirmation rule.
- **A6** [high] Zero-active assignment of `backlog` is silent but reported from
  the read-back. Rejected: asking. Case 3 already assigns silently and reports
  (`commands/new.md:108-109`), and the confirmed answer says "falls back".
- **A7** [med] Azure DevOps gets a one-sentence note, no behaviour change.
  Rejected: assigning an iteration named `backlog`. The ADO create sets only Area
  Path and description (`commands/new.md:283-288`), `/new` ADO has no milestone
  selection to amend, and ADR-012 models milestones as dated sprint iterations.
  The issue lists the ADO section; the note is the smallest honest reading.
- **A8** [med] With `backlog` missing, the issue is still filed, with no
  milestone, and the report names the gap; in case 4 the `backlog` option is
  omitted and no `none` option replaces it. Rejected: aborting the filing (the
  issue is the deliverable; `commands/new.md:97-98`) and keeping `none` (it would
  reintroduce the un-milestoned path the issue removes).
- **A9** [med] A closed `backlog` counts as missing, since only open milestones
  are listed. `/milestone new backlog` then reports the closed one and stops
  (`commands/new.md:104-106`), so the pointer stays correct.
- **A10** [med] The roadmap/parked closing paragraph is reworded neutrally and
  defers to #644, rather than stating the new move-to-backlog rule here.
  Rejected: describing #644's behaviour in `/new`, which would be wrong if #644
  lands differently or later.
- **A11** [med] The ADR change is an amendment note, not a new ADR, and the
  generated knowledge bundle is not hand-edited.
- **A12** [med] Tests go in a new `tests/run-new-milestone-tests.sh` (picked up
  by `run-all.sh` discovery), not in `tests/run-script-tests.sh`. This avoids a
  merge collision with #616, which edits `run-script-tests.sh`.

## Consequences

- A repo with no `backlog` milestone gets un-milestoned issues exactly as before,
  plus a visible report; the AC "never files without a milestone" holds only
  where `backlog` exists.
- Issues that used to be filed with `none` (roadmap/parked intent) now land in
  `backlog`. Whether those two states keep a milestone is #644's decision.
- The first `/new` in a repo with zero active milestones no longer creates a
  monthly bucket, so those repos stop accumulating `general-*` milestones.
- Existing `general-*` milestones are untouched; they are just ordinary active
  milestones now.

## Shared files

`commands/new.md` (also edited by #616, ADO paragraph only, no hunk overlap),
`CHANGELOG.md` (all of #644, #645, #646), `docs/DECISIONS.md` (possibly #644).
